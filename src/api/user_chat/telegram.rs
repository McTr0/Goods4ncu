use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::api::AppState;
use crate::services::chat_space::ChatSpaceService;
pub use crate::services::chat_space::{CallView, SpaceMessageView, SpaceView};

use super::{authenticated_session, authenticated_user, moderate_text};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct CreateSpaceBody {
    pub kind: String,
    pub name: String,
    pub description: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct SpaceListQuery {
    pub kind: Option<String>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct SpaceListResponse {
    pub items: Vec<SpaceView>,
}

#[derive(Debug, Deserialize)]
pub struct AddSpaceMemberBody {
    pub user_id: String,
    pub role: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct SendSpaceMessageBody {
    pub client_message_id: Uuid,
    pub content: String,
    pub reply_to_message_id: Option<i64>,
}

#[derive(Debug, Deserialize)]
pub struct MessagePageQuery {
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct SpaceMessageListResponse {
    pub items: Vec<SpaceMessageView>,
}

#[derive(Debug, Deserialize)]
pub struct CreateCallBody {
    pub conversation_id: Uuid,
    pub media: String,
    pub offer_sdp: String,
}

#[derive(Debug, Deserialize)]
pub struct AnswerCallBody {
    pub answer_sdp: String,
}

#[derive(Debug, Deserialize)]
pub struct EndCallBody {
    pub reason: Option<String>,
}

pub async fn create_space(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<CreateSpaceBody>,
) -> Result<Json<SpaceView>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let tenant = crate::services::campus::CampusService::new(state.infra.db.clone())
        .require_tenant_context_for_session(&session.user_id, session.campus_id)
        .await?;
    let user_id = session.user_id;
    let kind = normalize_space_kind(&body.kind)?;
    let name = body.name.trim();
    if name.is_empty() || name.chars().count() > 80 {
        return Err(ApiError::BadRequest(
            "空间名称必须为 1 到 80 字".to_string(),
        ));
    }
    let description = body
        .description
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty());
    let space_svc = ChatSpaceService::new(state.infra.db.clone());
    let space_id = space_svc
        .create_space(tenant.campus_id, kind, name, description, &user_id)
        .await?;
    Ok(Json(space_svc.load_space_view(space_id, &user_id).await?))
}

pub async fn list_spaces(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<SpaceListQuery>,
) -> Result<Json<SpaceListResponse>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let campus_id = crate::services::campus::CampusService::new(state.infra.db.clone())
        .require_tenant_context_for_session(&session.user_id, session.campus_id)
        .await?
        .campus_id;
    let user_id = session.user_id;
    let kind = query
        .kind
        .as_deref()
        .map(normalize_space_kind)
        .transpose()?;
    let space_svc = ChatSpaceService::new(state.infra.db.clone());
    let rows = space_svc
        .list_space_ids(
            &user_id,
            campus_id,
            kind,
            query.limit.unwrap_or(30).clamp(1, 100),
            query.offset.unwrap_or(0).max(0),
        )
        .await?;
    let mut items = Vec::with_capacity(rows.len());
    for id in rows {
        items.push(space_svc.load_space_view(id, &user_id).await?);
    }
    Ok(Json(SpaceListResponse { items }))
}

pub async fn get_space(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(space_id): Path<Uuid>,
) -> Result<Json<SpaceView>, ApiError> {
    let (user_id, campus_id) = verified_space_user(&state, &headers, space_id).await?;
    ensure_space_chat_access(&state, campus_id, space_id, &user_id).await?;
    let space_svc = ChatSpaceService::new(state.infra.db.clone());
    Ok(Json(space_svc.load_space_view(space_id, &user_id).await?))
}

pub async fn add_space_member(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(space_id): Path<Uuid>,
    Json(body): Json<AddSpaceMemberBody>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let (user_id, campus_id) = verified_space_user(&state, &headers, space_id).await?;
    ensure_space_admin(&state, space_id, &user_id).await?;
    let campus_service = crate::services::campus::CampusService::new(state.infra.db.clone());
    campus_service
        .require_verified_in_campus(&body.user_id, campus_id)
        .await?;
    let role = normalize_member_role(body.role.as_deref().unwrap_or("member"))?;
    let space_svc = ChatSpaceService::new(state.infra.db.clone());
    space_svc
        .add_space_member(space_id, &body.user_id, role)
        .await?;
    broadcast_space_event(&state, space_id, "space_member_changed").await?;
    Ok(Json(serde_json::json!({ "added": true })))
}

pub async fn remove_space_member(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((space_id, target_user_id)): Path<(Uuid, String)>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let (user_id, _) = verified_space_user(&state, &headers, space_id).await?;
    let my_role = ensure_space_member(&state, space_id, &user_id).await?;
    if user_id != target_user_id && !matches!(my_role.as_str(), "owner" | "admin") {
        return Err(ApiError::Forbidden);
    }
    let space_svc = ChatSpaceService::new(state.infra.db.clone());
    space_svc
        .remove_space_member(space_id, &target_user_id)
        .await?;
    broadcast_space_event(&state, space_id, "space_member_changed").await?;
    Ok(Json(serde_json::json!({ "removed": true })))
}

pub async fn send_space_message(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(space_id): Path<Uuid>,
    Json(body): Json<SendSpaceMessageBody>,
) -> Result<Json<SpaceMessageView>, ApiError> {
    let (user_id, campus_id) = verified_space_user(&state, &headers, space_id).await?;
    ensure_space_chat_access(&state, campus_id, space_id, &user_id).await?;
    let content = body.content.trim();
    moderate_text(&state, content)?;
    if content.is_empty() || content.chars().count() > 4000 {
        return Err(ApiError::BadRequest(
            "消息长度必须为 1 到 4000 字".to_string(),
        ));
    }
    let space_svc = ChatSpaceService::new(state.infra.db.clone());
    if let Some(reply_to) = body.reply_to_message_id {
        let is_root_topic = space_svc.is_root_topic(reply_to, space_id).await?;
        if !is_root_topic {
            return Err(ApiError::BadRequest(
                "回复必须归属当前群聊的根话题".to_string(),
            ));
        }
    }
    let view = space_svc
        .send_space_message(
            space_id,
            body.client_message_id,
            &user_id,
            content,
            body.reply_to_message_id,
        )
        .await?;
    broadcast_space_event(&state, space_id, "space_message_created").await?;
    Ok(Json(view))
}

pub async fn list_space_messages(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(space_id): Path<Uuid>,
    Query(query): Query<MessagePageQuery>,
) -> Result<Json<SpaceMessageListResponse>, ApiError> {
    let (user_id, campus_id) = verified_space_user(&state, &headers, space_id).await?;
    ensure_space_chat_access(&state, campus_id, space_id, &user_id).await?;
    let space_svc = ChatSpaceService::new(state.infra.db.clone());
    let items = space_svc
        .list_space_messages(
            space_id,
            query.limit.unwrap_or(50).clamp(1, 100),
            query.offset.unwrap_or(0).max(0),
        )
        .await?;
    Ok(Json(SpaceMessageListResponse { items }))
}

pub async fn create_call(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<CreateCallBody>,
) -> Result<Json<CallView>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let media = normalize_call_media(&body.media)?;
    let conversation =
        load_active_realtime_conversation(&state, body.conversation_id, &user_id).await?;
    let callee_id = if user_id == conversation.0 {
        conversation.1
    } else {
        conversation.0
    };
    let space_svc = ChatSpaceService::new(state.infra.db.clone());
    let view = space_svc
        .create_call(
            body.conversation_id,
            &user_id,
            &callee_id,
            media,
            &body.offer_sdp,
        )
        .await?;
    state.infra.ws_hub.broadcast_to_user(
        &callee_id,
        &serde_json::json!({
            "event": "call_invite",
            "call_id": view.id,
            "conversation_id": view.conversation_id,
            "media": view.media,
        })
        .to_string(),
    );
    Ok(Json(view))
}

pub async fn answer_call(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(call_id): Path<Uuid>,
    Json(body): Json<AnswerCallBody>,
) -> Result<Json<CallView>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let space_svc = ChatSpaceService::new(state.infra.db.clone());
    let view = space_svc
        .answer_call(call_id, &user_id, &body.answer_sdp)
        .await?;
    state.infra.ws_hub.broadcast_to_user(
        &view.caller_id,
        &serde_json::json!({
            "event": "call_answer",
            "call_id": view.id,
            "conversation_id": view.conversation_id,
        })
        .to_string(),
    );
    Ok(Json(view))
}

pub async fn end_call(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(call_id): Path<Uuid>,
    Json(body): Json<EndCallBody>,
) -> Result<Json<CallView>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let space_svc = ChatSpaceService::new(state.infra.db.clone());
    let view = space_svc
        .end_call(call_id, &user_id, body.reason.as_deref().unwrap_or("ended"))
        .await?;
    let other = if user_id == view.caller_id {
        &view.callee_id
    } else {
        &view.caller_id
    };
    state.infra.ws_hub.broadcast_to_user(
        other,
        &serde_json::json!({
            "event": "call_ended",
            "call_id": view.id,
            "conversation_id": view.conversation_id,
        })
        .to_string(),
    );
    Ok(Json(view))
}

fn normalize_space_kind(kind: &str) -> Result<&str, ApiError> {
    match kind.trim() {
        "group" => Ok("group"),
        _ => Err(ApiError::BadRequest("空间类型必须是 group".to_string())),
    }
}

fn normalize_member_role(role: &str) -> Result<&str, ApiError> {
    match role.trim() {
        "owner" => Ok("owner"),
        "admin" => Ok("admin"),
        "member" => Ok("member"),
        "banned" => Ok("banned"),
        _ => Err(ApiError::BadRequest("成员角色无效".to_string())),
    }
}

fn normalize_call_media(media: &str) -> Result<&str, ApiError> {
    match media.trim() {
        "audio" => Ok("audio"),
        "video" => Ok("video"),
        _ => Err(ApiError::BadRequest(
            "通话类型必须是 audio 或 video".to_string(),
        )),
    }
}

async fn ensure_space_member(
    state: &AppState,
    space_id: Uuid,
    user_id: &str,
) -> Result<String, ApiError> {
    let space_svc = ChatSpaceService::new(state.infra.db.clone());
    let role = space_svc
        .get_member_role(space_id, user_id)
        .await?
        .ok_or(ApiError::Forbidden)?;
    if role == "banned" {
        Err(ApiError::Forbidden)
    } else {
        Ok(role)
    }
}

async fn ensure_space_chat_access(
    state: &AppState,
    _campus_id: Uuid,
    space_id: Uuid,
    user_id: &str,
) -> Result<String, ApiError> {
    let space_svc = ChatSpaceService::new(state.infra.db.clone());
    let existing_role = space_svc.get_member_role(space_id, user_id).await?;
    if let Some(role) = existing_role {
        if role == "banned" {
            return Err(ApiError::Forbidden);
        }
        return Ok(role);
    }
    ensure_space_member(state, space_id, user_id).await
}

async fn ensure_space_admin(
    state: &AppState,
    space_id: Uuid,
    user_id: &str,
) -> Result<(), ApiError> {
    let role = ensure_space_member(state, space_id, user_id).await?;
    if role == "owner" {
        Ok(())
    } else {
        Err(ApiError::Forbidden)
    }
}

async fn load_space_campus(state: &AppState, space_id: Uuid) -> Result<Uuid, ApiError> {
    let space_svc = ChatSpaceService::new(state.infra.db.clone());
    space_svc.load_space_campus(space_id).await
}

async fn verified_space_user(
    state: &AppState,
    headers: &HeaderMap,
    space_id: Uuid,
) -> Result<(String, Uuid), ApiError> {
    let session = authenticated_session(state, headers)?;
    let tenant = crate::services::campus::CampusService::new(state.infra.db.clone())
        .require_tenant_context_for_session(&session.user_id, session.campus_id)
        .await?;
    if load_space_campus(state, space_id).await? != tenant.campus_id {
        return Err(ApiError::CampusScopeMismatch);
    }
    Ok((session.user_id, tenant.campus_id))
}

async fn broadcast_space_event(
    state: &AppState,
    space_id: Uuid,
    event: &str,
) -> Result<(), ApiError> {
    let space_svc = ChatSpaceService::new(state.infra.db.clone());
    let rows = space_svc.list_broadcast_user_ids(space_id).await?;
    let payload = serde_json::json!({
        "event": event,
        "space_id": space_id,
    })
    .to_string();
    for user_id in rows {
        state
            .infra
            .ws_hub
            .broadcast_to_user(user_id.as_str(), &payload);
    }

    Ok(())
}

async fn load_active_realtime_conversation(
    state: &AppState,
    conversation_id: Uuid,
    user_id: &str,
) -> Result<(String, String), ApiError> {
    let space_svc = ChatSpaceService::new(state.infra.db.clone());
    let (initiator_id, recipient_id) = space_svc
        .load_active_realtime_conversation(conversation_id)
        .await?;
    if user_id == initiator_id || user_id == recipient_id {
        Ok((initiator_id, recipient_id))
    } else {
        Err(ApiError::Forbidden)
    }
}

#[cfg(test)]
mod tests {
    use super::normalize_space_kind;

    #[test]
    fn only_group_spaces_can_be_created() {
        assert_eq!(normalize_space_kind("group").unwrap(), "group");
        assert!(normalize_space_kind("channel").is_err());
        assert!(normalize_space_kind(" group ").is_ok());
    }
}
