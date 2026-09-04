use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::api::{normalize_platform_media_url, AppState};
use crate::services::chat_conversation::{
    ChatConversationService, ConversationMessageRecord, RelationshipSpacePinView,
    SendConversationMessageInput,
};

use super::{
    authenticated_session, ensure_conversation_campus, ensure_message_campus, moderate_text,
    EditMessageBody, HideMessageResponse, MessageAcknowledgementBody, MessageListQuery,
    MessageListResponse, MessageReactionBody, RelationshipPinResponse, ReportMessageBody,
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
    let session = authenticated_session(&state, &headers)?;
    ensure_conversation_campus(&state, conversation_id, &session).await?;
    let user_id = session.user_id;
    let service = ChatConversationService::new(state.infra.db.clone());
    let (messages, total) = service
        .get_messages(
            conversation_id,
            &user_id,
            query.limit.unwrap_or(50),
            query.offset.unwrap_or(0),
        )
        .await?;
    let messages = messages
        .into_iter()
        .map(|message| present_message(&state, message))
        .collect();
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
    let session = authenticated_session(&state, &headers)?;
    ensure_conversation_campus(&state, conversation_id, &session).await?;
    let user_id = session.user_id;
    let content = body.content.trim().to_string();
    moderate_text(&state, &content)?;
    let image_url = normalize_platform_media_url(&state, body.image_url, "image_url")?;
    let audio_url = normalize_platform_media_url(&state, body.audio_url, "audio_url")?;

    let service = ChatConversationService::new(state.infra.db.clone());
    let message = service
        .send_message(SendConversationMessageInput {
            client_message_id: body.client_message_id,
            conversation_id,
            sender_id: user_id.clone(),
            content: content.clone(),
            reply_to_message_id: body.reply_to_message_id,
            quote: body.quote,
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

    let presented_message = present_message(&state, message.clone());

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
        "image_url": presented_message.image_url,
        "audio_url": presented_message.audio_url,
        "kind": message.kind,
        "reply_to_message_id": message.reply_to_message_id,
        "reply_preview": message.reply_preview,
        "quote": message.quote,
        "reactions": message.reactions,
    })
    .to_string();
    state
        .infra
        .ws_hub
        .broadcast_to_user_in_campus(other_user_id, conversation.campus_id, &payload);
    state.infra.metrics.record_chat_message();
    if image_url.is_some() || audio_url.is_some() {
        state.infra.metrics.record_chat_media_url_message();
    }
    Ok(Json(presented_message))
}

pub async fn set_message_acknowledgement(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(message_id): Path<i64>,
    Json(body): Json<MessageAcknowledgementBody>,
) -> Result<Json<ConversationMessageRecord>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let _ = ensure_message_campus(&state, message_id, &session).await?;
    let user_id = session.user_id;
    let service = ChatConversationService::new(state.infra.db.clone());
    let message = service
        .set_message_acknowledgement(message_id, &user_id, body.kind)
        .await?;
    broadcast_acknowledgement(&state.infra.ws_hub, &service, &user_id, &message).await?;
    Ok(Json(present_message(&state, message)))
}

pub async fn delete_message_acknowledgement(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(message_id): Path<i64>,
) -> Result<Json<ConversationMessageRecord>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let _ = ensure_message_campus(&state, message_id, &session).await?;
    let user_id = session.user_id;
    let service = ChatConversationService::new(state.infra.db.clone());
    let message = service
        .delete_message_acknowledgement(message_id, &user_id)
        .await?;
    broadcast_acknowledgement(&state.infra.ws_hub, &service, &user_id, &message).await?;
    Ok(Json(present_message(&state, message)))
}

pub async fn edit_message(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(message_id): Path<i64>,
    Json(body): Json<EditMessageBody>,
) -> Result<Json<ConversationMessageRecord>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let _ = ensure_message_campus(&state, message_id, &session).await?;
    let user_id = session.user_id;
    let content = body.content.trim().to_string();
    moderate_text(&state, &content)?;
    let service = ChatConversationService::new(state.infra.db.clone());
    let message = service.edit_message(message_id, &user_id, &content).await?;
    Ok(Json(present_message(&state, message)))
}

pub async fn set_message_reaction(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(message_id): Path<i64>,
    Json(body): Json<MessageReactionBody>,
) -> Result<Json<ConversationMessageRecord>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let _ = ensure_message_campus(&state, message_id, &session).await?;
    let user_id = session.user_id;
    let service = ChatConversationService::new(state.infra.db.clone());
    let message = service
        .set_reaction(message_id, &user_id, &body.emoji)
        .await?;
    broadcast_message_update(
        &state.infra.ws_hub,
        &service,
        &user_id,
        &message,
        "message_reaction_changed",
    )
    .await?;
    Ok(Json(present_message(&state, message)))
}

pub async fn delete_message_reaction(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(message_id): Path<i64>,
) -> Result<Json<ConversationMessageRecord>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let _ = ensure_message_campus(&state, message_id, &session).await?;
    let user_id = session.user_id;
    let service = ChatConversationService::new(state.infra.db.clone());
    let message = service.delete_reaction(message_id, &user_id).await?;
    broadcast_message_update(
        &state.infra.ws_hub,
        &service,
        &user_id,
        &message,
        "message_reaction_changed",
    )
    .await?;
    Ok(Json(present_message(&state, message)))
}

pub async fn hide_message(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(message_id): Path<i64>,
) -> Result<Json<HideMessageResponse>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let campus_id = ensure_message_campus(&state, message_id, &session).await?;
    let user_id = session.user_id;
    let service = ChatConversationService::new(state.infra.db.clone());
    service.hide_message(message_id, &user_id).await?;
    let payload = serde_json::json!({
        "event": "message_hidden",
        "message_id": message_id,
    })
    .to_string();
    match campus_id {
        Some(campus_id) => state
            .infra
            .ws_hub
            .broadcast_to_user_in_campus(&user_id, campus_id, &payload),
        None => state.infra.ws_hub.broadcast_to_user(&user_id, &payload),
    }
    Ok(Json(HideMessageResponse {
        message_id,
        hidden: true,
    }))
}

pub async fn pin_message(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(message_id): Path<i64>,
) -> Result<Json<RelationshipSpacePinView>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let _ = ensure_message_campus(&state, message_id, &session).await?;
    let user_id = session.user_id;
    let service = ChatConversationService::new(state.infra.db.clone());
    let pin = service.pin_message(message_id, &user_id).await?;
    broadcast_relationship_pin(&state.infra.ws_hub, &service, &pin, true).await?;
    Ok(Json(pin))
}

pub async fn unpin_message(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(message_id): Path<i64>,
) -> Result<Json<RelationshipPinResponse>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let _ = ensure_message_campus(&state, message_id, &session).await?;
    let user_id = session.user_id;
    let service = ChatConversationService::new(state.infra.db.clone());
    let removed = service.unpin_message(message_id, &user_id).await?;
    if let Some(pin) = removed.as_ref() {
        broadcast_relationship_pin(&state.infra.ws_hub, &service, pin, false).await?;
    }
    Ok(Json(RelationshipPinResponse {
        message_id,
        pinned: false,
    }))
}

pub async fn report_message(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(message_id): Path<i64>,
    Json(body): Json<ReportMessageBody>,
) -> Result<Json<ReportMessageResponse>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let campus_id = ensure_message_campus(&state, message_id, &session).await?;
    let user_id = session.user_id;
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
    match campus_id {
        Some(campus_id) => state
            .infra
            .ws_hub
            .broadcast_to_user_in_campus(&user_id, campus_id, &payload),
        None => state.infra.ws_hub.broadcast_to_user(&user_id, &payload),
    }
    Ok(Json(ReportMessageResponse {
        report_id: report_id.to_string(),
    }))
}

async fn broadcast_acknowledgement(
    ws_hub: &crate::api::ws::WsHub,
    service: &ChatConversationService,
    actor_id: &str,
    message: &ConversationMessageRecord,
) -> Result<(), ApiError> {
    let conversation_id = Uuid::parse_str(&message.conversation_id)
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("invalid conversation id: {error}")))?;
    let conversation = service.get_conversation(conversation_id, actor_id).await?;
    let payload = serde_json::json!({
        "event": "message_acknowledgement_changed",
        "conversation_id": conversation_id,
        "message_id": message.id,
        "acknowledgements": message.acknowledgements,
    })
    .to_string();
    ws_hub.broadcast_to_user_in_campus(
        &conversation.initiator_id,
        conversation.campus_id,
        &payload,
    );
    if conversation.recipient_id != conversation.initiator_id {
        ws_hub.broadcast_to_user_in_campus(
            &conversation.recipient_id,
            conversation.campus_id,
            &payload,
        );
    }
    Ok(())
}

async fn broadcast_message_update(
    ws_hub: &crate::api::ws::WsHub,
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
    ws_hub.broadcast_to_user_in_campus(
        &conversation.initiator_id,
        conversation.campus_id,
        &payload,
    );
    ws_hub.broadcast_to_user_in_campus(
        &conversation.recipient_id,
        conversation.campus_id,
        &payload,
    );
    Ok(())
}

async fn broadcast_relationship_pin(
    ws_hub: &crate::api::ws::WsHub,
    service: &ChatConversationService,
    pin: &RelationshipSpacePinView,
    pinned: bool,
) -> Result<(), ApiError> {
    let conversation_id = Uuid::parse_str(&pin.conversation_id)
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("invalid conversation id: {error}")))?;
    let conversation = service
        .get_conversation(conversation_id, &pin.actor_id)
        .await?;
    let payload = serde_json::json!({
        "event": "relationship_pin_changed",
        "conversation_id": conversation_id,
        "message_id": pin.message_id,
        "pin_id": pin.id,
        "actor_id": pin.actor_id,
        "pinned": pinned,
        "created_at": pin.created_at,
    })
    .to_string();
    ws_hub.broadcast_to_user_in_campus(
        &conversation.initiator_id,
        conversation.campus_id,
        &payload,
    );
    ws_hub.broadcast_to_user_in_campus(
        &conversation.recipient_id,
        conversation.campus_id,
        &payload,
    );
    Ok(())
}

fn present_message(
    state: &AppState,
    mut message: ConversationMessageRecord,
) -> ConversationMessageRecord {
    message.image_url = state.public_chat_media_url(message.image_url);
    message.audio_url = state.public_chat_media_url(message.audio_url);
    message
}
