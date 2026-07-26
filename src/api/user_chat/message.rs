use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use sqlx::Row;
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::api::{ws, AppState};
use crate::services::chat_conversation::{
    ChatConversationService, ConversationMessageRecord, ConversationMode, ConversationState,
    SendConversationMessageInput,
};

use super::{
    authenticated_user, moderate_text, EditMessageBody, HideMessageResponse, MarkReadResponse,
    MessageListQuery, MessageListResponse, MessageReactionBody, ReportMessageBody,
    ReportMessageResponse, SendMessageBody,
};

async fn conversation_campus_id(state: &AppState, conversation_id: Uuid) -> Result<Uuid, ApiError> {
    sqlx::query_scalar("SELECT campus_id FROM chat_conversations WHERE id = $1")
        .bind(conversation_id)
        .fetch_optional(&state.infra.db)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?
        .ok_or(ApiError::NotFound)
}

pub async fn get_conversation_messages(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(conversation_id): Path<Uuid>,
    Query(query): Query<MessageListQuery>,
) -> Result<Json<MessageListResponse>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let service = ChatConversationService::new(state.infra.db.clone());
    let (messages, total) = service
        .get_messages(
            conversation_id,
            &user_id,
            query.limit.unwrap_or(50),
            query.offset.unwrap_or(0),
        )
        .await?;
    Ok(Json(MessageListResponse {
        conversation_id: conversation_id.to_string(),
        messages,
        total,
    }))
}

pub async fn send_conversation_message(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(conversation_id): Path<Uuid>,
    Json(body): Json<SendMessageBody>,
) -> Result<Json<ConversationMessageRecord>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let content = body.content.trim().to_string();
    moderate_text(&state, &content)?;
    let image_url = normalize_media_url(body.image_url, "image_url")?;
    let audio_url = normalize_media_url(body.audio_url, "audio_url")?;
    let has_url_media = image_url.is_some() || audio_url.is_some();
    let has_base64_media = body
        .image_base64
        .as_deref()
        .is_some_and(|value| !value.trim().is_empty())
        || body
            .audio_base64
            .as_deref()
            .is_some_and(|value| !value.trim().is_empty());

    let service = ChatConversationService::new(state.infra.db.clone());
    let message = service
        .send_message(SendConversationMessageInput {
            client_message_id: body.client_message_id,
            conversation_id,
            sender_id: user_id.clone(),
            content: content.clone(),
            reply_to_message_id: body.reply_to_message_id,
            quote: body.quote,
            image_data: body.image_base64,
            audio_data: body.audio_base64,
            image_url: image_url.clone(),
            audio_url: audio_url.clone(),
        })
        .await?;
    let conversation = service.get_conversation(conversation_id, &user_id).await?;

    if let Some(image_url) = image_url.as_deref() {
        if let Err(error) = state
            .infra
            .moderation
            .submit_image_job(
                &state.infra.db,
                conversation_campus_id(&state, conversation_id).await?,
                &message.id.to_string(),
                image_url,
                "chat_image",
            )
            .await
        {
            tracing::warn!(%error, message_id = message.id, "failed to enqueue chat moderation");
        }
    }

    let other_user_id = if user_id == conversation.initiator_id {
        &conversation.recipient_id
    } else {
        &conversation.initiator_id
    };
    let payload = serde_json::json!({
        "event": "new_message",
        "conversation_id": conversation_id,
        "message_id": message.id,
        "sender": user_id,
        "content": content,
        "timestamp": message.timestamp,
        "image_url": image_url,
        "audio_url": audio_url,
        "kind": message.kind,
        "reply_to_message_id": message.reply_to_message_id,
        "reply_preview": message.reply_preview,
        "quote": message.quote,
        "reactions": message.reactions,
    })
    .to_string();
    ws::broadcast_to_user(other_user_id, &payload);
    state.infra.metrics.record_chat_message();
    if has_url_media {
        state.infra.metrics.record_chat_media_url_message();
    }
    if has_base64_media {
        state.infra.metrics.record_chat_media_base64_message();
    }
    Ok(Json(message))
}

pub async fn mark_conversation_read(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(conversation_id): Path<Uuid>,
) -> Result<Json<MarkReadResponse>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let service = ChatConversationService::new(state.infra.db.clone());
    let marked_count = service.mark_read(conversation_id, &user_id).await?;
    let conversation = service.get_conversation(conversation_id, &user_id).await?;
    if conversation.mode == ConversationMode::Realtime
        && conversation.state == ConversationState::Active
    {
        let other_user_id = if user_id == conversation.initiator_id {
            &conversation.recipient_id
        } else {
            &conversation.initiator_id
        };
        let payload = serde_json::json!({
            "event": "message_read",
            "conversation_id": conversation_id,
            "read_by": user_id,
        })
        .to_string();
        ws::broadcast_to_user(other_user_id, &payload);
    }
    Ok(Json(MarkReadResponse {
        conversation_id: conversation_id.to_string(),
        marked_count,
    }))
}

pub async fn edit_message(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(message_id): Path<i64>,
    Json(body): Json<EditMessageBody>,
) -> Result<Json<ConversationMessageRecord>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let content = body.content.trim().to_string();
    moderate_text(&state, &content)?;
    let service = ChatConversationService::new(state.infra.db.clone());
    let message = service.edit_message(message_id, &user_id, &content).await?;
    Ok(Json(message))
}

pub async fn set_message_reaction(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(message_id): Path<i64>,
    Json(body): Json<MessageReactionBody>,
) -> Result<Json<ConversationMessageRecord>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let service = ChatConversationService::new(state.infra.db.clone());
    let message = service
        .set_reaction(message_id, &user_id, &body.emoji)
        .await?;
    broadcast_message_update(&service, &user_id, &message, "message_reaction_changed").await?;
    Ok(Json(message))
}

pub async fn delete_message_reaction(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(message_id): Path<i64>,
) -> Result<Json<ConversationMessageRecord>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let service = ChatConversationService::new(state.infra.db.clone());
    let message = service.delete_reaction(message_id, &user_id).await?;
    broadcast_message_update(&service, &user_id, &message, "message_reaction_changed").await?;
    Ok(Json(message))
}

pub async fn hide_message(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(message_id): Path<i64>,
) -> Result<Json<HideMessageResponse>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let service = ChatConversationService::new(state.infra.db.clone());
    service.hide_message(message_id, &user_id).await?;
    let payload = serde_json::json!({
        "event": "message_hidden",
        "message_id": message_id,
    })
    .to_string();
    ws::broadcast_to_user(&user_id, &payload);
    Ok(Json(HideMessageResponse {
        message_id,
        hidden: true,
    }))
}

pub async fn report_message(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(message_id): Path<i64>,
    Json(body): Json<ReportMessageBody>,
) -> Result<Json<ReportMessageResponse>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let service = ChatConversationService::new(state.infra.db.clone());
    let report_id = service
        .report_message(message_id, &user_id, &body.reason, body.details.as_deref())
        .await?;
    let payload = serde_json::json!({
        "event": "message_reported",
        "message_id": message_id,
        "report_id": report_id,
    })
    .to_string();
    ws::broadcast_to_user(&user_id, &payload);
    Ok(Json(ReportMessageResponse {
        report_id: report_id.to_string(),
    }))
}

pub async fn typing_indicator(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(conversation_id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let service = ChatConversationService::new(state.infra.db.clone());
    let conversation = service.get_conversation(conversation_id, &user_id).await?;
    if conversation.mode != ConversationMode::Realtime
        || conversation.state != ConversationState::Active
        || conversation.is_blocked
    {
        return Err(ApiError::Conflict(
            "typing_unavailable_for_conversation".to_string(),
        ));
    }
    let other_user_id = if user_id == conversation.initiator_id {
        &conversation.recipient_id
    } else {
        &conversation.initiator_id
    };
    let username = sqlx::query("SELECT username FROM users WHERE id = $1")
        .bind(&user_id)
        .fetch_optional(&state.infra.db)
        .await
        .ok()
        .flatten()
        .map(|row| row.get::<String, _>("username"));
    let payload = serde_json::json!({
        "event": "typing",
        "conversation_id": conversation_id,
        "user_id": user_id,
        "username": username,
    })
    .to_string();
    ws::broadcast_to_user(other_user_id, &payload);
    Ok(Json(serde_json::json!({ "sent": true })))
}

async fn broadcast_message_update(
    service: &ChatConversationService,
    actor_id: &str,
    message: &ConversationMessageRecord,
    event: &str,
) -> Result<(), ApiError> {
    let conversation_id = Uuid::parse_str(&message.conversation_id)
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("invalid conversation id: {error}")))?;
    let conversation = service.get_conversation(conversation_id, actor_id).await?;
    let payload = serde_json::json!({
        "event": event,
        "conversation_id": conversation_id,
        "message_id": message.id,
        "reactions": message.reactions,
    })
    .to_string();
    ws::broadcast_to_user(&conversation.initiator_id, &payload);
    ws::broadcast_to_user(&conversation.recipient_id, &payload);
    Ok(())
}

fn normalize_media_url(value: Option<String>, field: &str) -> Result<Option<String>, ApiError> {
    let value = value
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    if value
        .as_deref()
        .is_some_and(|url| !url.starts_with("http://") && !url.starts_with("https://"))
    {
        return Err(ApiError::BadRequest(format!("{field} 格式无效")));
    }
    Ok(value)
}
