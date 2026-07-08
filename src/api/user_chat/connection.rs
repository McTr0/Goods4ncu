use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use uuid::Uuid;

use crate::api::auth::extract_user_id_from_token_with_fallback;
use crate::api::error::ApiError;
use crate::api::{ws, AppState};
use crate::services::chat_conversation::{
    ChatConversationService, ConversationMode, ConversationView, CreateConversationInput,
    CreateConversationResult,
};

use super::{
    ArchiveConversationBody, BlockListResponse, BlockUserBody, BlockedUserEntry,
    ConversationListQuery, ConversationListResponse, CreateConversationBody, ReadPreferenceBody,
    RespondConversationBody, ThreadDetailResponse, ThreadListQuery, ThreadListResponse,
};

pub async fn create_conversation(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<CreateConversationBody>,
) -> Result<Json<CreateConversationResult>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let content = body.content.trim().to_string();
    moderate_text(&state, &content)?;
    let subject = body
        .subject
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    if let Some(subject) = subject.as_deref() {
        moderate_text(&state, subject)?;
    }

    let service = ChatConversationService::new(state.infra.db.clone());
    let result = service
        .create_conversation(CreateConversationInput {
            client_request_id: body.client_request_id,
            initiator_id: user_id,
            recipient_id: body.recipient_id,
            listing_id: body.listing_id,
            mode: body.mode,
            subject,
            content,
        })
        .await?;

    if result.created {
        let notification_title = match result.conversation.mode {
            crate::services::chat_conversation::ConversationMode::Realtime => "有人想现在聊聊",
            crate::services::chat_conversation::ConversationMode::Mail => "收到一封新留言",
        };
        let notification_body = result
            .conversation
            .subject
            .as_deref()
            .unwrap_or("打开消息查看内容");
        if let Err(error) = state
            .infra
            .notification
            .create_for_conversation(
                &result.conversation.recipient_id,
                "conversation_created",
                notification_title,
                notification_body,
                result.conversation.listing_id.as_deref(),
                &result.conversation.id,
            )
            .await
        {
            tracing::warn!(%error, "failed to persist conversation notification");
        }
    }

    broadcast_conversation("conversation_created", &result.conversation);
    Ok(Json(result))
}

pub async fn list_conversations(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<ConversationListQuery>,
) -> Result<Json<ConversationListResponse>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let service = ChatConversationService::new(state.infra.db.clone());
    let (items, next_cursor) = service
        .list_conversations(
            &user_id,
            query.mode,
            query.cursor,
            query.limit.unwrap_or(30),
        )
        .await?;
    Ok(Json(ConversationListResponse { items, next_cursor }))
}

pub async fn list_threads(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<ThreadListQuery>,
) -> Result<Json<ThreadListResponse>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let mode = parse_thread_mode(query.mode.as_deref())?;
    let service = ChatConversationService::new(state.infra.db.clone());
    let items = service
        .list_threads(&user_id, mode, query.limit.unwrap_or(50))
        .await?;
    Ok(Json(ThreadListResponse { items }))
}

pub async fn get_thread(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(peer_user_id): Path<String>,
    Query(query): Query<ThreadListQuery>,
) -> Result<Json<ThreadDetailResponse>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let mode = parse_thread_mode(query.mode.as_deref())?;
    let service = ChatConversationService::new(state.infra.db.clone());
    Ok(Json(
        service
            .get_thread(&user_id, &peer_user_id, mode)
            .await?
            .into(),
    ))
}

pub async fn get_conversation(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(conversation_id): Path<Uuid>,
) -> Result<Json<ConversationView>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let service = ChatConversationService::new(state.infra.db.clone());
    Ok(Json(
        service.get_conversation(conversation_id, &user_id).await?,
    ))
}

fn parse_thread_mode(value: Option<&str>) -> Result<Option<ConversationMode>, ApiError> {
    match value.unwrap_or("all") {
        "" | "all" => Ok(None),
        "realtime" => Ok(Some(ConversationMode::Realtime)),
        "mail" => Ok(Some(ConversationMode::Mail)),
        _ => Err(ApiError::BadRequest("invalid thread mode".to_string())),
    }
}

pub async fn respond_conversation(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(conversation_id): Path<Uuid>,
    Json(body): Json<RespondConversationBody>,
) -> Result<Json<ConversationView>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let service = ChatConversationService::new(state.infra.db.clone());
    let conversation = service
        .respond(conversation_id, &user_id, body.decision)
        .await?;
    broadcast_conversation("conversation_state_changed", &conversation);
    Ok(Json(conversation))
}

pub async fn acknowledge_conversation(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(conversation_id): Path<Uuid>,
) -> Result<Json<ConversationView>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let service = ChatConversationService::new(state.infra.db.clone());
    let conversation = service.acknowledge(conversation_id, &user_id).await?;
    broadcast_conversation("conversation_state_changed", &conversation);
    Ok(Json(conversation))
}

pub async fn close_conversation(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(conversation_id): Path<Uuid>,
) -> Result<Json<ConversationView>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let service = ChatConversationService::new(state.infra.db.clone());
    let conversation = service.close(conversation_id, &user_id).await?;
    broadcast_conversation("conversation_state_changed", &conversation);
    Ok(Json(conversation))
}

pub async fn archive_conversation(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(conversation_id): Path<Uuid>,
    Json(body): Json<ArchiveConversationBody>,
) -> Result<Json<ConversationView>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let service = ChatConversationService::new(state.infra.db.clone());
    Ok(Json(
        service
            .set_archived(conversation_id, &user_id, body.archived)
            .await?,
    ))
}

pub async fn set_read_preference(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(conversation_id): Path<Uuid>,
    Json(body): Json<ReadPreferenceBody>,
) -> Result<Json<ConversationView>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let service = ChatConversationService::new(state.infra.db.clone());
    Ok(Json(
        service
            .set_read_preference(conversation_id, &user_id, body.mode.as_str())
            .await?,
    ))
}

pub async fn list_blocks(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<BlockListResponse>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let service = ChatConversationService::new(state.infra.db.clone());
    let items = service
        .list_blocks(&user_id)
        .await?
        .into_iter()
        .map(|(user_id, username)| BlockedUserEntry { user_id, username })
        .collect();
    Ok(Json(BlockListResponse { items }))
}

pub async fn block_user(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<BlockUserBody>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let service = ChatConversationService::new(state.infra.db.clone());
    service.block_user(&user_id, &body.user_id).await?;
    Ok(Json(serde_json::json!({ "blocked": true })))
}

pub async fn unblock_user(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(blocked_id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let service = ChatConversationService::new(state.infra.db.clone());
    service.unblock_user(&user_id, &blocked_id).await?;
    Ok(Json(serde_json::json!({ "blocked": false })))
}

pub(crate) fn authenticated_user(
    state: &AppState,
    headers: &HeaderMap,
) -> Result<String, ApiError> {
    extract_user_id_from_token_with_fallback(
        headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)
}

pub(crate) fn moderate_text(state: &AppState, content: &str) -> Result<(), ApiError> {
    let result = state.infra.moderation.check_text(content);
    if result.passed {
        Ok(())
    } else {
        Err(ApiError::ContentViolation(
            result.reason.unwrap_or_default(),
        ))
    }
}

pub(super) fn broadcast_conversation(event: &str, conversation: &ConversationView) {
    let payload = serde_json::json!({
        "event": event,
        "conversation_id": conversation.id,
        "mode": conversation.mode,
        "state": conversation.state,
        "expires_at": conversation.expires_at,
        "version": conversation.version,
    })
    .to_string();
    ws::broadcast_to_user(&conversation.initiator_id, &payload);
    ws::broadcast_to_user(&conversation.recipient_id, &payload);
}
