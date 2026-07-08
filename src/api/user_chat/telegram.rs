use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::api::{ws, AppState};

use super::{authenticated_user, moderate_text};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct CreateSpaceBody {
    pub kind: String,
    pub name: String,
    pub description: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct SpaceView {
    pub id: String,
    pub kind: String,
    pub name: String,
    pub description: Option<String>,
    pub owner_id: String,
    pub my_role: String,
    pub member_count: i64,
    pub created_at: String,
    pub updated_at: String,
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

#[derive(Debug, Serialize)]
pub struct SpaceMessageView {
    pub id: i64,
    pub space_id: String,
    pub sender_id: String,
    pub sender_username: Option<String>,
    pub content: String,
    pub reply_to_message_id: Option<i64>,
    pub created_at: String,
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

#[derive(Debug, Serialize)]
pub struct CallView {
    pub id: String,
    pub conversation_id: String,
    pub caller_id: String,
    pub callee_id: String,
    pub media: String,
    pub state: String,
    pub offer_sdp: String,
    pub answer_sdp: Option<String>,
    pub created_at: String,
}

#[derive(Debug, Deserialize)]
pub struct CreateSecretSessionBody {
    pub recipient_id: String,
    pub initiator_key_fingerprint: String,
    pub recipient_key_fingerprint: String,
    pub expires_at: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct SecretSessionView {
    pub id: String,
    pub initiator_id: String,
    pub recipient_id: String,
    pub status: String,
    pub expires_at: Option<String>,
    pub created_at: String,
}

#[derive(Debug, Deserialize)]
pub struct SendSecretMessageBody {
    pub client_message_id: Uuid,
    pub ciphertext: String,
    pub nonce: String,
    pub key_fingerprint: String,
    pub expires_at: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct SecretMessageView {
    pub id: i64,
    pub session_id: String,
    pub sender_id: String,
    pub ciphertext: String,
    pub nonce: String,
    pub key_fingerprint: String,
    pub expires_at: Option<String>,
    pub created_at: String,
}

pub async fn create_space(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<CreateSpaceBody>,
) -> Result<Json<SpaceView>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
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
    let mut tx = state.infra.db.begin().await.map_err(db_error)?;
    let row = sqlx::query(
        "INSERT INTO chat_spaces (kind, name, description, owner_id)
         VALUES ($1, $2, $3, $4)
         RETURNING id",
    )
    .bind(kind)
    .bind(name)
    .bind(description)
    .bind(&user_id)
    .fetch_one(&mut *tx)
    .await
    .map_err(db_error)?;
    let space_id: Uuid = row.get("id");
    sqlx::query(
        "INSERT INTO chat_space_members (space_id, user_id, role)
         VALUES ($1, $2, 'owner')",
    )
    .bind(space_id)
    .bind(&user_id)
    .execute(&mut *tx)
    .await
    .map_err(db_error)?;
    tx.commit().await.map_err(db_error)?;
    Ok(Json(load_space_view(&state, space_id, &user_id).await?))
}

pub async fn list_spaces(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<SpaceListQuery>,
) -> Result<Json<SpaceListResponse>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let kind = query
        .kind
        .as_deref()
        .map(normalize_space_kind)
        .transpose()?;
    let rows = sqlx::query(
        "SELECT s.id
         FROM chat_spaces s
         JOIN chat_space_members m ON m.space_id = s.id AND m.user_id = $1
         WHERE s.status = 'active'
           AND m.role <> 'banned'
           AND ($2::TEXT IS NULL OR s.kind = $2)
         ORDER BY s.updated_at DESC
         LIMIT $3 OFFSET $4",
    )
    .bind(&user_id)
    .bind(kind)
    .bind(query.limit.unwrap_or(30).clamp(1, 100))
    .bind(query.offset.unwrap_or(0).max(0))
    .fetch_all(&state.infra.db)
    .await
    .map_err(db_error)?;
    let mut items = Vec::with_capacity(rows.len());
    for row in rows {
        items.push(load_space_view(&state, row.get("id"), &user_id).await?);
    }
    Ok(Json(SpaceListResponse { items }))
}

pub async fn get_space(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(space_id): Path<Uuid>,
) -> Result<Json<SpaceView>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    ensure_space_member(&state, space_id, &user_id).await?;
    Ok(Json(load_space_view(&state, space_id, &user_id).await?))
}

pub async fn add_space_member(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(space_id): Path<Uuid>,
    Json(body): Json<AddSpaceMemberBody>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    ensure_space_admin(&state, space_id, &user_id).await?;
    let role = normalize_member_role(body.role.as_deref().unwrap_or("member"))?;
    sqlx::query(
        "INSERT INTO chat_space_members (space_id, user_id, role)
         VALUES ($1, $2, $3)
         ON CONFLICT (space_id, user_id)
         DO UPDATE SET role = EXCLUDED.role, joined_at = NOW()",
    )
    .bind(space_id)
    .bind(&body.user_id)
    .bind(role)
    .execute(&state.infra.db)
    .await
    .map_err(db_error)?;
    broadcast_space_event(&state, space_id, "space_member_changed").await?;
    Ok(Json(serde_json::json!({ "added": true })))
}

pub async fn remove_space_member(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((space_id, target_user_id)): Path<(Uuid, String)>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let my_role = ensure_space_member(&state, space_id, &user_id).await?;
    if user_id != target_user_id && !matches!(my_role.as_str(), "owner" | "admin") {
        return Err(ApiError::Forbidden);
    }
    sqlx::query("DELETE FROM chat_space_members WHERE space_id = $1 AND user_id = $2")
        .bind(space_id)
        .bind(&target_user_id)
        .execute(&state.infra.db)
        .await
        .map_err(db_error)?;
    broadcast_space_event(&state, space_id, "space_member_changed").await?;
    Ok(Json(serde_json::json!({ "removed": true })))
}

pub async fn send_space_message(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(space_id): Path<Uuid>,
    Json(body): Json<SendSpaceMessageBody>,
) -> Result<Json<SpaceMessageView>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let role = ensure_space_member(&state, space_id, &user_id).await?;
    let space_kind = load_space_kind(&state, space_id).await?;
    if space_kind == "channel" && !matches!(role.as_str(), "owner" | "admin") {
        return Err(ApiError::Forbidden);
    }
    let content = body.content.trim();
    moderate_text(&state, content)?;
    if content.is_empty() || content.chars().count() > 4000 {
        return Err(ApiError::BadRequest(
            "消息长度必须为 1 到 4000 字".to_string(),
        ));
    }
    if let Some(reply_to) = body.reply_to_message_id {
        let exists: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM chat_space_messages WHERE id = $1 AND space_id = $2)",
        )
        .bind(reply_to)
        .bind(space_id)
        .fetch_one(&state.infra.db)
        .await
        .map_err(db_error)?;
        if !exists {
            return Err(ApiError::BadRequest("引用的消息不属于当前空间".to_string()));
        }
    }
    let row = sqlx::query(
        "WITH saved AS (
             INSERT INTO chat_space_messages (
                 space_id, client_message_id, sender_id, content, reply_to_message_id
             )
             VALUES ($1, $2, $3, $4, $5)
             ON CONFLICT (space_id, sender_id, client_message_id)
             DO UPDATE SET content = chat_space_messages.content
             RETURNING id, space_id, sender_id, content, reply_to_message_id, created_at
         )
         SELECT saved.id, saved.space_id, saved.sender_id, u.username AS sender_username,
                saved.content, saved.reply_to_message_id, saved.created_at
         FROM saved
         LEFT JOIN users u ON u.id = saved.sender_id",
    )
    .bind(space_id)
    .bind(body.client_message_id)
    .bind(&user_id)
    .bind(content)
    .bind(body.reply_to_message_id)
    .fetch_one(&state.infra.db)
    .await
    .map_err(db_error)?;
    sqlx::query("UPDATE chat_spaces SET updated_at = NOW() WHERE id = $1")
        .bind(space_id)
        .execute(&state.infra.db)
        .await
        .map_err(db_error)?;
    let view = row_to_space_message(row);
    broadcast_space_event(&state, space_id, "space_message_created").await?;
    Ok(Json(view))
}

pub async fn list_space_messages(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(space_id): Path<Uuid>,
    Query(query): Query<MessagePageQuery>,
) -> Result<Json<SpaceMessageListResponse>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    ensure_space_member(&state, space_id, &user_id).await?;
    let rows = sqlx::query(
        "SELECT m.id, m.space_id, m.sender_id, u.username AS sender_username,
                m.content, m.reply_to_message_id, m.created_at
         FROM chat_space_messages m
         LEFT JOIN users u ON u.id = m.sender_id
         WHERE m.space_id = $1
         ORDER BY m.created_at DESC, m.id DESC
         LIMIT $2 OFFSET $3",
    )
    .bind(space_id)
    .bind(query.limit.unwrap_or(50).clamp(1, 100))
    .bind(query.offset.unwrap_or(0).max(0))
    .fetch_all(&state.infra.db)
    .await
    .map_err(db_error)?;
    Ok(Json(SpaceMessageListResponse {
        items: rows.into_iter().map(row_to_space_message).collect(),
    }))
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
    let row = sqlx::query(
        "INSERT INTO chat_calls (conversation_id, caller_id, callee_id, media, offer_sdp)
         VALUES ($1, $2, $3, $4, $5)
         RETURNING id, conversation_id, caller_id, callee_id, media, state, offer_sdp, answer_sdp, created_at",
    )
    .bind(body.conversation_id)
    .bind(&user_id)
    .bind(&callee_id)
    .bind(media)
    .bind(&body.offer_sdp)
    .fetch_one(&state.infra.db)
    .await
    .map_err(db_error)?;
    let view = row_to_call(row);
    ws::broadcast_to_user(
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
    let row = sqlx::query(
        "UPDATE chat_calls
         SET state = 'accepted', answer_sdp = $1, answered_at = NOW()
         WHERE id = $2 AND callee_id = $3 AND state = 'ringing'
         RETURNING id, conversation_id, caller_id, callee_id, media, state, offer_sdp, answer_sdp, created_at",
    )
    .bind(&body.answer_sdp)
    .bind(call_id)
    .bind(&user_id)
    .fetch_optional(&state.infra.db)
    .await
    .map_err(db_error)?
    .ok_or(ApiError::NotFound)?;
    let view = row_to_call(row);
    ws::broadcast_to_user(
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
    let row = sqlx::query(
        "UPDATE chat_calls
         SET state = 'ended', ended_reason = $1, ended_at = NOW()
         WHERE id = $2 AND (caller_id = $3 OR callee_id = $3) AND state <> 'ended'
         RETURNING id, conversation_id, caller_id, callee_id, media, state, offer_sdp, answer_sdp, created_at",
    )
    .bind(body.reason.as_deref().unwrap_or("ended"))
    .bind(call_id)
    .bind(&user_id)
    .fetch_optional(&state.infra.db)
    .await
    .map_err(db_error)?
    .ok_or(ApiError::NotFound)?;
    let view = row_to_call(row);
    let other = if user_id == view.caller_id {
        &view.callee_id
    } else {
        &view.caller_id
    };
    ws::broadcast_to_user(
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

pub async fn create_secret_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<CreateSecretSessionBody>,
) -> Result<Json<SecretSessionView>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    if user_id == body.recipient_id {
        return Err(ApiError::BadRequest("不能和自己创建加密聊天".to_string()));
    }
    let row = sqlx::query(
        "INSERT INTO chat_secret_sessions (
            initiator_id, recipient_id, initiator_key_fingerprint,
            recipient_key_fingerprint, expires_at
         )
         VALUES ($1, $2, $3, $4, $5::TIMESTAMPTZ)
         RETURNING id, initiator_id, recipient_id, status, expires_at, created_at",
    )
    .bind(&user_id)
    .bind(&body.recipient_id)
    .bind(&body.initiator_key_fingerprint)
    .bind(&body.recipient_key_fingerprint)
    .bind(body.expires_at.as_deref())
    .fetch_one(&state.infra.db)
    .await
    .map_err(db_error)?;
    Ok(Json(row_to_secret_session(row)))
}

pub async fn send_secret_message(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(session_id): Path<Uuid>,
    Json(body): Json<SendSecretMessageBody>,
) -> Result<Json<SecretMessageView>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    ensure_secret_member(&state, session_id, &user_id).await?;
    let row = sqlx::query(
        "INSERT INTO chat_secret_messages (
            session_id, sender_id, client_message_id, ciphertext, nonce,
            key_fingerprint, expires_at
         )
         VALUES ($1, $2, $3, $4, $5, $6, $7::TIMESTAMPTZ)
         ON CONFLICT (session_id, sender_id, client_message_id)
         DO UPDATE SET ciphertext = chat_secret_messages.ciphertext
         RETURNING id, session_id, sender_id, ciphertext, nonce, key_fingerprint, expires_at, created_at",
    )
    .bind(session_id)
    .bind(&user_id)
    .bind(body.client_message_id)
    .bind(&body.ciphertext)
    .bind(&body.nonce)
    .bind(&body.key_fingerprint)
    .bind(body.expires_at.as_deref())
    .fetch_one(&state.infra.db)
    .await
    .map_err(db_error)?;
    Ok(Json(row_to_secret_message(row)))
}

pub async fn list_secret_messages(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(session_id): Path<Uuid>,
    Query(query): Query<MessagePageQuery>,
) -> Result<Json<Vec<SecretMessageView>>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    ensure_secret_member(&state, session_id, &user_id).await?;
    let rows = sqlx::query(
        "SELECT id, session_id, sender_id, ciphertext, nonce, key_fingerprint, expires_at, created_at
         FROM chat_secret_messages
         WHERE session_id = $1
           AND (expires_at IS NULL OR expires_at > NOW())
         ORDER BY created_at DESC, id DESC
         LIMIT $2 OFFSET $3",
    )
    .bind(session_id)
    .bind(query.limit.unwrap_or(50).clamp(1, 100))
    .bind(query.offset.unwrap_or(0).max(0))
    .fetch_all(&state.infra.db)
    .await
    .map_err(db_error)?;
    Ok(Json(rows.into_iter().map(row_to_secret_message).collect()))
}

fn normalize_space_kind(kind: &str) -> Result<&str, ApiError> {
    match kind.trim() {
        "group" => Ok("group"),
        "channel" => Ok("channel"),
        _ => Err(ApiError::BadRequest(
            "空间类型必须是 group 或 channel".to_string(),
        )),
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

async fn load_space_view(
    state: &AppState,
    space_id: Uuid,
    user_id: &str,
) -> Result<SpaceView, ApiError> {
    let row = sqlx::query(
        "SELECT s.id, s.kind, s.name, s.description, s.owner_id,
                m.role AS my_role,
                (SELECT COUNT(*)::BIGINT FROM chat_space_members sm WHERE sm.space_id = s.id AND sm.role <> 'banned') AS member_count,
                s.created_at, s.updated_at
         FROM chat_spaces s
         JOIN chat_space_members m ON m.space_id = s.id AND m.user_id = $2
         WHERE s.id = $1",
    )
    .bind(space_id)
    .bind(user_id)
    .fetch_optional(&state.infra.db)
    .await
    .map_err(db_error)?
    .ok_or(ApiError::NotFound)?;
    Ok(SpaceView {
        id: row.get::<Uuid, _>("id").to_string(),
        kind: row.get("kind"),
        name: row.get("name"),
        description: row.get("description"),
        owner_id: row.get("owner_id"),
        my_role: row.get("my_role"),
        member_count: row.get("member_count"),
        created_at: row
            .get::<chrono::DateTime<chrono::Utc>, _>("created_at")
            .to_rfc3339(),
        updated_at: row
            .get::<chrono::DateTime<chrono::Utc>, _>("updated_at")
            .to_rfc3339(),
    })
}

async fn ensure_space_member(
    state: &AppState,
    space_id: Uuid,
    user_id: &str,
) -> Result<String, ApiError> {
    let role = sqlx::query_scalar::<_, String>(
        "SELECT role FROM chat_space_members WHERE space_id = $1 AND user_id = $2",
    )
    .bind(space_id)
    .bind(user_id)
    .fetch_optional(&state.infra.db)
    .await
    .map_err(db_error)?
    .ok_or(ApiError::Forbidden)?;
    if role == "banned" {
        Err(ApiError::Forbidden)
    } else {
        Ok(role)
    }
}

async fn ensure_space_admin(
    state: &AppState,
    space_id: Uuid,
    user_id: &str,
) -> Result<(), ApiError> {
    let role = ensure_space_member(state, space_id, user_id).await?;
    if matches!(role.as_str(), "owner" | "admin") {
        Ok(())
    } else {
        Err(ApiError::Forbidden)
    }
}

async fn load_space_kind(state: &AppState, space_id: Uuid) -> Result<String, ApiError> {
    sqlx::query_scalar("SELECT kind FROM chat_spaces WHERE id = $1")
        .bind(space_id)
        .fetch_optional(&state.infra.db)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::NotFound)
}

async fn broadcast_space_event(
    state: &AppState,
    space_id: Uuid,
    event: &str,
) -> Result<(), ApiError> {
    let rows = sqlx::query(
        "SELECT user_id FROM chat_space_members WHERE space_id = $1 AND role <> 'banned'",
    )
    .bind(space_id)
    .fetch_all(&state.infra.db)
    .await
    .map_err(db_error)?;
    let payload = serde_json::json!({
        "event": event,
        "space_id": space_id,
    })
    .to_string();
    for row in rows {
        ws::broadcast_to_user(row.get::<String, _>("user_id").as_str(), &payload);
    }
    Ok(())
}

async fn load_active_realtime_conversation(
    state: &AppState,
    conversation_id: Uuid,
    user_id: &str,
) -> Result<(String, String), ApiError> {
    let row = sqlx::query(
        "SELECT initiator_id, recipient_id
         FROM chat_conversations
         WHERE id = $1 AND mode = 'realtime' AND state = 'active'",
    )
    .bind(conversation_id)
    .fetch_optional(&state.infra.db)
    .await
    .map_err(db_error)?
    .ok_or(ApiError::Conflict(
        "call_requires_active_realtime".to_string(),
    ))?;
    let initiator_id: String = row.get("initiator_id");
    let recipient_id: String = row.get("recipient_id");
    if user_id == initiator_id || user_id == recipient_id {
        Ok((initiator_id, recipient_id))
    } else {
        Err(ApiError::Forbidden)
    }
}

async fn ensure_secret_member(
    state: &AppState,
    session_id: Uuid,
    user_id: &str,
) -> Result<(), ApiError> {
    let exists: bool = sqlx::query_scalar(
        "SELECT EXISTS(
            SELECT 1 FROM chat_secret_sessions
            WHERE id = $1
              AND status = 'active'
              AND (expires_at IS NULL OR expires_at > NOW())
              AND (initiator_id = $2 OR recipient_id = $2)
         )",
    )
    .bind(session_id)
    .bind(user_id)
    .fetch_one(&state.infra.db)
    .await
    .map_err(db_error)?;
    if exists {
        Ok(())
    } else {
        Err(ApiError::Forbidden)
    }
}

fn row_to_space_message(row: sqlx::postgres::PgRow) -> SpaceMessageView {
    SpaceMessageView {
        id: row.get("id"),
        space_id: row.get::<Uuid, _>("space_id").to_string(),
        sender_id: row.get("sender_id"),
        sender_username: row.try_get("sender_username").ok(),
        content: row.get("content"),
        reply_to_message_id: row.get("reply_to_message_id"),
        created_at: row
            .get::<chrono::DateTime<chrono::Utc>, _>("created_at")
            .to_rfc3339(),
    }
}

fn row_to_call(row: sqlx::postgres::PgRow) -> CallView {
    CallView {
        id: row.get::<Uuid, _>("id").to_string(),
        conversation_id: row.get::<Uuid, _>("conversation_id").to_string(),
        caller_id: row.get("caller_id"),
        callee_id: row.get("callee_id"),
        media: row.get("media"),
        state: row.get("state"),
        offer_sdp: row.get("offer_sdp"),
        answer_sdp: row.get("answer_sdp"),
        created_at: row
            .get::<chrono::DateTime<chrono::Utc>, _>("created_at")
            .to_rfc3339(),
    }
}

fn row_to_secret_session(row: sqlx::postgres::PgRow) -> SecretSessionView {
    SecretSessionView {
        id: row.get::<Uuid, _>("id").to_string(),
        initiator_id: row.get("initiator_id"),
        recipient_id: row.get("recipient_id"),
        status: row.get("status"),
        expires_at: row
            .get::<Option<chrono::DateTime<chrono::Utc>>, _>("expires_at")
            .map(|value| value.to_rfc3339()),
        created_at: row
            .get::<chrono::DateTime<chrono::Utc>, _>("created_at")
            .to_rfc3339(),
    }
}

fn row_to_secret_message(row: sqlx::postgres::PgRow) -> SecretMessageView {
    SecretMessageView {
        id: row.get("id"),
        session_id: row.get::<Uuid, _>("session_id").to_string(),
        sender_id: row.get("sender_id"),
        ciphertext: row.get("ciphertext"),
        nonce: row.get("nonce"),
        key_fingerprint: row.get("key_fingerprint"),
        expires_at: row
            .get::<Option<chrono::DateTime<chrono::Utc>>, _>("expires_at")
            .map(|value| value.to_rfc3339()),
        created_at: row
            .get::<chrono::DateTime<chrono::Utc>, _>("created_at")
            .to_rfc3339(),
    }
}

fn db_error(error: sqlx::Error) -> ApiError {
    ApiError::Internal(anyhow::anyhow!(error))
}
