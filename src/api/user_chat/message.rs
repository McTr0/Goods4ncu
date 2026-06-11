use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use sqlx::Row;

use crate::api::auth::extract_user_id_from_token_with_fallback;
use crate::api::error::ApiError;
use crate::api::ws;
use crate::api::AppState;

use super::{
    context::{
        is_special_conversation, load_conversation_access, load_direct_message_access,
        ConversationAccess,
    },
    EditMessageBody, EditMessageResponse, MarkReadResponse, MessageEntry, MessageListQuery,
    MessageListResponse, SendMessageBody, SendMessageResponse, TypingBody, WsMessageReadEvent,
    WsNewMessageEvent, WsTypingEvent,
};

/// GET /api/chat/conversations/{connection_id}/messages — fetch messages in a connection.
pub async fn get_connection_messages(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(connection_id): Path<String>,
    Query(params): Query<MessageListQuery>,
) -> Result<Json<MessageListResponse>, ApiError> {
    let user_id = extract_user_id_from_token_with_fallback(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)?;

    let limit = params.limit.unwrap_or(50).clamp(1, 200);
    let offset = params.offset.unwrap_or(0).max(0);

    if !is_special_conversation(&connection_id) && uuid::Uuid::parse_str(&connection_id).is_err() {
        return Err(ApiError::BadRequest(
            "Invalid conversation ID format".to_string(),
        ));
    }

    let _access = load_conversation_access(&state.infra.db, &connection_id, &user_id).await?;

    let (rows, total) = state
        .chat_repo
        .list_user_chat_messages(&connection_id, limit, offset)
        .await?;

    let sender_ids: Vec<String> = rows
        .iter()
        .filter_map(|row| {
            if row.sender == "assistant" {
                None
            } else {
                Some(row.sender.clone())
            }
        })
        .collect();
    let sender_usernames: std::collections::HashMap<String, String> = if sender_ids.is_empty() {
        std::collections::HashMap::new()
    } else {
        sqlx::query("SELECT id, username FROM users WHERE id = ANY($1)")
            .bind(&sender_ids)
            .fetch_all(&state.infra.db)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
            .into_iter()
            .map(|row| {
                let id: String = row.get("id");
                let username: String = row.get("username");
                (id, username)
            })
            .collect()
    };

    let messages: Vec<MessageEntry> = rows
        .into_iter()
        .map(|row| {
            let sender_username = if row.sender == "assistant" {
                None
            } else {
                sender_usernames.get(&row.sender).cloned()
            };
            MessageEntry {
                id: row.id,
                sender: row.sender,
                sender_username,
                content: row.content,
                is_agent: row.is_agent,
                timestamp: row.timestamp.to_rfc3339(),
                read_at: row.read_at.map(|dt| dt.to_rfc3339()),
                read_by: row.read_by,
                image_data: row.image_data,
                audio_data: row.audio_data,
                image_url: row.image_url,
                audio_url: row.audio_url,
                edited_at: row.edited_at.map(|dt| dt.to_rfc3339()),
                status: row.status,
            }
        })
        .collect();

    Ok(Json(MessageListResponse {
        conversation_id: connection_id,
        messages,
        total,
    }))
}

/// POST /api/chat/conversations/{connection_id}/messages — send a message in a connection.
pub async fn send_connection_message(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(connection_id): Path<String>,
    Json(body): Json<SendMessageBody>,
) -> Result<Json<SendMessageResponse>, ApiError> {
    let sender_id = extract_user_id_from_token_with_fallback(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)?;

    if body.content.is_empty() {
        return Err(ApiError::BadRequest("消息内容不能为空".to_string()));
    }
    if body.content.len() > 2000 {
        return Err(ApiError::BadRequest("消息内容不能超过2000字符".to_string()));
    }

    let normalized_image_url = body
        .image_url
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(|v| v.to_string());
    if let Some(image_url) = normalized_image_url.as_deref() {
        if !image_url.starts_with("http://") && !image_url.starts_with("https://") {
            return Err(ApiError::BadRequest("image_url格式无效".to_string()));
        }
    }

    // Text content moderation — block prohibited content before persisting.
    let mod_result = state.infra.moderation.check_text(&body.content);
    if !mod_result.passed {
        return Err(ApiError::ContentViolation(
            mod_result.reason.unwrap_or_default(),
        ));
    }

    let access = load_conversation_access(&state.infra.db, &connection_id, &sender_id).await?;
    let (receiver, connection_uuid) = match access {
        ConversationAccess::Special => (None, None),
        ConversationAccess::Direct(connection) => {
            connection.ensure_connected()?;
            (
                Some(connection.other_user_id(&sender_id)?),
                Some(connection.connection_uuid),
            )
        }
    };

    let read_at = None;
    let (message_id, timestamp, persisted_read_at) = state
        .chat_repo
        .create_direct_message(
            &connection_id,
            connection_uuid,
            &sender_id,
            receiver.as_deref(),
            &body.content,
            body.image_base64.as_deref(),
            body.audio_base64.as_deref(),
            normalized_image_url.as_deref(),
            body.audio_url.as_deref(),
            read_at,
        )
        .await?;
    let read_at_str = persisted_read_at.map(|dt| dt.to_rfc3339());

    state.infra.metrics.record_chat_message();
    if normalized_image_url.is_some() || body.audio_url.is_some() {
        state.infra.metrics.record_chat_media_url_message();
    }
    if body.image_base64.is_some() || body.audio_base64.is_some() {
        state.infra.metrics.record_chat_media_base64_message();
    }

    if let Some(image_url) = normalized_image_url.as_deref() {
        if let Err(e) = state
            .infra
            .moderation
            .submit_image_job(
                &state.infra.db,
                &message_id.to_string(),
                image_url,
                "chat_image",
            )
            .await
        {
            tracing::warn!(
                %e,
                message_id,
                "Failed to enqueue chat image moderation job"
            );
        }
    }

    let sender_username: Option<String> = sqlx::query("SELECT username FROM users WHERE id = $1")
        .bind(&sender_id)
        .fetch_optional(&state.infra.db)
        .await
        .ok()
        .flatten()
        .map(|row| row.get("username"));

    let ws_event = WsNewMessageEvent {
        event: "new_message".to_string(),
        message_id,
        conversation_id: connection_id.clone(),
        sender: sender_id.clone(),
        sender_username,
        content: body.content.clone(),
        timestamp: timestamp.to_rfc3339(),
        read_at: read_at_str.clone(),
        image_data: body.image_base64.clone(),
        audio_data: body.audio_base64.clone(),
        image_url: normalized_image_url.clone(),
        audio_url: body.audio_url.clone(),
    };
    let payload = serde_json::to_string(&ws_event).unwrap_or_default();
    if let Some(ref recv) = receiver {
        ws::broadcast_to_user(recv, &payload);
    }

    Ok(Json(SendMessageResponse {
        message_id,
        sender: sender_id,
        content: body.content,
        conversation_id: connection_id,
        sent_at: timestamp.to_rfc3339(),
        read_at: read_at_str,
        image_data: body.image_base64,
        audio_data: body.audio_base64,
        image_url: normalized_image_url,
        audio_url: body.audio_url,
        status: "sent".to_string(),
    }))
}

/// POST /api/chat/messages/{id}/read — mark a message as read.
pub async fn mark_message_read(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(message_id): Path<i64>,
) -> Result<Json<MarkReadResponse>, ApiError> {
    let user_id = extract_user_id_from_token_with_fallback(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)?;

    let message = load_direct_message_access(&state.infra.db, message_id).await?;

    if message.connection_status != "connected" {
        return Err(ApiError::BadRequest(format!(
            "连接状态不是 connected，无法标记已读: {}",
            message.connection_status
        )));
    }

    let Some(recv) = message.receiver else {
        return Err(ApiError::Forbidden);
    };
    if recv != user_id {
        return Err(ApiError::Forbidden);
    }

    if let Some(read_at) = message.read_at {
        let read_at_str = read_at.to_rfc3339();
        return Ok(Json(MarkReadResponse {
            message_id,
            read_at: read_at_str,
        }));
    }

    let read_at = chrono::Utc::now();
    let read_at_str = read_at.to_rfc3339();

    let connection_uuid = uuid::Uuid::parse_str(&message.conversation_id).ok();
    state
        .chat_repo
        .mark_direct_message_read(
            message_id,
            &message.conversation_id,
            connection_uuid,
            &user_id,
            read_at,
        )
        .await?;

    let ws_event = WsMessageReadEvent {
        event: "message_read".to_string(),
        message_id,
        read_at: read_at_str.clone(),
        read_by: user_id.clone(),
    };
    let payload = serde_json::to_string(&ws_event).unwrap_or_default();
    ws::broadcast_to_user(&message.sender, &payload);

    Ok(Json(MarkReadResponse {
        message_id,
        read_at: read_at_str,
    }))
}

/// PATCH /api/chat/messages/:id — edit a message within 15 minutes of sending.
pub async fn edit_message(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(message_id): Path<i64>,
    Json(body): Json<EditMessageBody>,
) -> Result<Json<EditMessageResponse>, ApiError> {
    let user_id = extract_user_id_from_token_with_fallback(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)?;

    // Text content moderation — block prohibited content before any DB operation.
    let mod_result = state.infra.moderation.check_text(&body.content);
    if !mod_result.passed {
        return Err(ApiError::ContentViolation(
            mod_result.reason.unwrap_or_default(),
        ));
    }

    if body.content.is_empty() {
        return Err(ApiError::BadRequest("消息内容不能为空".to_string()));
    }
    if body.content.len() > 2000 {
        return Err(ApiError::BadRequest("消息内容不能超过2000字符".to_string()));
    }

    let message = load_direct_message_access(&state.infra.db, message_id).await?;

    if message.sender != user_id {
        return Err(ApiError::Forbidden);
    }

    if message.connection_status != "connected" {
        return Err(ApiError::BadRequest(format!(
            "连接状态不是 connected，无法编辑: {}",
            message.connection_status
        )));
    }

    // Only allow editing within 15 minutes
    let fifteen_minutes = chrono::Duration::minutes(15);
    let now = chrono::Utc::now();
    if now.signed_duration_since(message.timestamp) > fifteen_minutes {
        return Err(ApiError::BadRequest(
            "消息已超过15分钟，无法编辑".to_string(),
        ));
    }

    let edited_at = chrono::Utc::now();
    let edited_at_str = edited_at.to_rfc3339();

    state
        .chat_repo
        .update_direct_message_content(message_id, &body.content, edited_at)
        .await?;

    Ok(Json(EditMessageResponse {
        message_id,
        content: body.content,
        edited_at: edited_at_str,
    }))
}

/// POST /api/chat/typing — broadcast a typing indicator to the other party.
pub async fn typing_indicator(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<TypingBody>,
) -> Result<(), ApiError> {
    let user_id = extract_user_id_from_token_with_fallback(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)?;

    let access = load_conversation_access(&state.infra.db, &body.conversation_id, &user_id).await?;

    let username: Option<String> = sqlx::query("SELECT username FROM users WHERE id = $1")
        .bind(&user_id)
        .fetch_optional(&state.infra.db)
        .await
        .ok()
        .flatten()
        .map(|row| row.get("username"));

    let ws_event = WsTypingEvent {
        event: "typing".to_string(),
        conversation_id: body.conversation_id.clone(),
        user_id: user_id.clone(),
        username,
    };
    let payload = serde_json::to_string(&ws_event).unwrap_or_default();

    // Broadcast to the other party
    let recipient = match access {
        ConversationAccess::Special => "assistant".to_string(),
        ConversationAccess::Direct(connection) => {
            connection.ensure_connected()?;
            connection.other_user_id(&user_id)?
        }
    };
    ws::broadcast_to_user(&recipient, &payload);

    Ok(())
}

/// POST /api/chat/connection/{id}/read — batch mark all messages in a connection as read.
///
/// Replaces the N+1 pattern where the client fetches 50 messages then marks each one read
/// individually. One SQL UPDATE + one unread_count reset.
pub async fn mark_connection_read(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(connection_id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let user_id = extract_user_id_from_token_with_fallback(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)?;

    let access = load_conversation_access(&state.infra.db, &connection_id, &user_id).await?;
    let connection_uuid = match access {
        ConversationAccess::Special => None,
        ConversationAccess::Direct(connection) => Some(connection.connection_uuid),
    };

    let now = chrono::Utc::now();

    // Batch UPDATE: mark all unread messages sent TO this user as read
    let marked_count = state
        .chat_repo
        .mark_connection_read_with_count(&connection_id, connection_uuid, &user_id, now)
        .await?;

    Ok(Json(serde_json::json!({
        "marked_count": marked_count,
        "read_at": now.to_rfc3339()
    })))
}
