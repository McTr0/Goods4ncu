use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use chrono::{DateTime, Utc};
use uuid::Uuid;

use crate::api::auth::{
    extract_auth_session_from_token_with_fallback, extract_user_id_from_token_with_fallback,
    AuthSessionContext,
};
use crate::api::error::ApiError;
use crate::api::{ws, AppState};
use crate::services::campus::CampusService;
use crate::services::chat_conversation::{
    ChatConversationService, ConversationMode, ConversationView, CreateConversationInput,
    CreateConversationResult, MailExpectation,
};
use crate::services::notification::NewNotification;

use super::{
    ArchiveConversationBody, BlockListResponse, BlockUserBody, BlockedUserEntry,
    ConnectionPreferencesBody, ContactPermissionBody, ConversationListQuery,
    ConversationListResponse, CreateConversationBody, RelationshipSpaceResponse,
    RespondConversationBody, SpaceEventQuery, ThreadDetailResponse, ThreadListQuery,
    ThreadListResponse,
};

pub async fn create_conversation(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<CreateConversationBody>,
) -> Result<Json<CreateConversationResult>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let tenant = CampusService::new(state.infra.db.clone())
        .require_shared_verified_campus_for_session(
            &session.user_id,
            &body.recipient_id,
            session.campus_id,
        )
        .await?;
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
            campus_id: tenant.campus_id,
            initiator_id: session.user_id,
            recipient_id: body.recipient_id,
            listing_id: body.listing_id,
            mode: body.mode,
            mail_expectation: body.mail_expectation.unwrap_or_default(),
            subject,
            content,
        })
        .await?;

    if result.created && result.notify_recipient {
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
            .create(NewNotification {
                campus_id: tenant.campus_id,
                user_id: &result.conversation.recipient_id,
                event_type: "conversation_created",
                title: notification_title,
                body: notification_body,
                related_order_id: None,
                related_listing_id: result.conversation.listing_id.as_deref(),
                related_conversation_id: Some(&result.conversation.id),
                related_space_id: None,
            })
            .await
        {
            tracing::warn!(%error, "failed to persist conversation notification");
        }
    }

    if result.created {
        if result.notify_recipient {
            broadcast_conversation("conversation_created", &result.conversation);
        } else {
            broadcast_conversation_to_user(
                "conversation_created",
                &result.conversation,
                &result.conversation.initiator_id,
            );
        }
    } else if result.mutual_open && result.notify_recipient {
        broadcast_conversation("conversation_state_changed", &result.conversation);
    } else {
        broadcast_conversation_to_user(
            "conversation_state_changed",
            &result.conversation,
            &result.conversation.initiator_id,
        );
    }
    Ok(Json(result))
}

/// Open a mail-mode conversation in answer to an intent.
///
/// Shares the validation and side effects of [`create_conversation`]: campus
/// membership on both sides, text moderation, the recipient's notification, and
/// the realtime broadcast. Duplicating any of those here would mean an
/// intent-answer that skipped moderation or arrived silently.
///
/// Mail mode rather than realtime, because answering someone's standing request
/// is not the same as asking to talk right now — it should wait in their inbox
/// instead of demanding immediate attention.
#[allow(clippy::too_many_arguments)]
pub async fn open_conversation_for_intent(
    state: &AppState,
    initiator_id: &str,
    recipient_id: &str,
    campus_id: uuid::Uuid,
    client_request_id: uuid::Uuid,
    subject: &str,
    content: &str,
) -> Result<String, ApiError> {
    // Re-checked rather than trusted: the caller resolved the author from an
    // intent row, which says nothing about whether these two share a campus
    // *now*.
    let tenant = CampusService::new(state.infra.db.clone())
        .require_shared_verified_campus(initiator_id, recipient_id)
        .await?;
    if tenant.campus_id != campus_id {
        return Err(ApiError::CampusScopeMismatch);
    }
    moderate_text(state, content)?;
    moderate_text(state, subject)?;

    let result = ChatConversationService::new(state.infra.db.clone())
        .create_conversation(CreateConversationInput {
            client_request_id,
            campus_id: tenant.campus_id,
            initiator_id: initiator_id.to_string(),
            recipient_id: recipient_id.to_string(),
            listing_id: None,
            mode: crate::services::chat_conversation::ConversationMode::Mail,
            mail_expectation: MailExpectation::Ordinary,
            subject: Some(subject.to_string()),
            content: content.to_string(),
        })
        .await?;

    if result.created && result.notify_recipient {
        if let Err(error) = state
            .infra
            .notification
            .create(NewNotification {
                campus_id: tenant.campus_id,
                user_id: &result.conversation.recipient_id,
                event_type: "conversation_created",
                title: "有人回应了你想找的东西",
                body: subject,
                related_order_id: None,
                related_listing_id: None,
                related_conversation_id: Some(&result.conversation.id),
                related_space_id: None,
            })
            .await
        {
            tracing::warn!(%error, "failed to persist intent response notification");
        }
    }

    if result.created && result.notify_recipient {
        broadcast_conversation("conversation_created", &result.conversation);
    } else if result.created {
        broadcast_conversation_to_user(
            "conversation_created",
            &result.conversation,
            &result.conversation.initiator_id,
        );
    }
    Ok(result.conversation.id.clone())
}

pub async fn list_conversations(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<ConversationListQuery>,
) -> Result<Json<ConversationListResponse>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let campus_id = ensure_active_campus(&state, &session).await?;
    let service = ChatConversationService::new(state.infra.db.clone());
    let (items, next_cursor) = match campus_id {
        Some(campus_id) => {
            service
                .list_conversations_for_campus(
                    &session.user_id,
                    campus_id,
                    query.mode,
                    query.cursor,
                    query.limit.unwrap_or(30),
                )
                .await?
        }
        None => {
            service
                .list_conversations(
                    &session.user_id,
                    query.mode,
                    query.cursor,
                    query.limit.unwrap_or(30),
                )
                .await?
        }
    };
    Ok(Json(ConversationListResponse { items, next_cursor }))
}

pub async fn list_threads(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<ThreadListQuery>,
) -> Result<Json<ThreadListResponse>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let campus_id = ensure_active_campus(&state, &session).await?;
    let mode = parse_thread_mode(query.mode.as_deref())?;
    let service = ChatConversationService::new(state.infra.db.clone());
    let items = match campus_id {
        Some(campus_id) => {
            service
                .list_threads_for_campus(
                    &session.user_id,
                    campus_id,
                    mode,
                    query.limit.unwrap_or(50),
                )
                .await?
        }
        None => {
            service
                .list_threads(&session.user_id, mode, query.limit.unwrap_or(50))
                .await?
        }
    };
    let mut items = items;
    for item in &mut items {
        if let Some(persona) = item.persona.as_mut() {
            crate::api::social_persona::decorate_public_persona_media(&state, persona);
        }
    }
    Ok(Json(ThreadListResponse { items }))
}

pub async fn get_thread(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(peer_user_id): Path<String>,
    Query(query): Query<ThreadListQuery>,
) -> Result<Json<ThreadDetailResponse>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let campus_id = ensure_active_campus(&state, &session).await?;
    let mode = parse_thread_mode(query.mode.as_deref())?;
    let service = ChatConversationService::new(state.infra.db.clone());
    let mut detail = match campus_id {
        Some(campus_id) => {
            service
                .get_thread_for_campus(&session.user_id, &peer_user_id, campus_id, mode)
                .await?
        }
        None => {
            service
                .get_thread(&session.user_id, &peer_user_id, mode)
                .await?
        }
    };
    if let Some(persona) = detail.thread.persona.as_mut() {
        crate::api::social_persona::decorate_public_persona_media(&state, persona);
    }
    Ok(Json(detail.into()))
}

pub async fn get_relationship_space(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(peer_user_id): Path<String>,
    Query(query): Query<SpaceEventQuery>,
) -> Result<Json<RelationshipSpaceResponse>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let campus_id = ensure_active_campus(&state, &session).await?;
    let service = ChatConversationService::new(state.infra.db.clone());
    let view = service
        .get_relationship_space(
            &session.user_id,
            &peer_user_id,
            campus_id,
            query.cursor.as_deref(),
            query.limit.unwrap_or(50),
        )
        .await?;
    Ok(Json(view.into()))
}

pub async fn get_conversation(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(conversation_id): Path<Uuid>,
) -> Result<Json<ConversationView>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    ensure_conversation_campus(&state, conversation_id, &session).await?;
    let service = ChatConversationService::new(state.infra.db.clone());
    Ok(Json(
        service
            .get_conversation(conversation_id, &session.user_id)
            .await?,
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
    let session = authenticated_session(&state, &headers)?;
    ensure_conversation_campus(&state, conversation_id, &session).await?;
    let service = ChatConversationService::new(state.infra.db.clone());
    let conversation = service
        .respond(conversation_id, &session.user_id, body.decision)
        .await?;
    broadcast_conversation("conversation_state_changed", &conversation);
    Ok(Json(conversation))
}

pub async fn acknowledge_conversation(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(conversation_id): Path<Uuid>,
) -> Result<Json<ConversationView>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    ensure_conversation_campus(&state, conversation_id, &session).await?;
    let service = ChatConversationService::new(state.infra.db.clone());
    let conversation = service
        .acknowledge(conversation_id, &session.user_id)
        .await?;
    broadcast_conversation("conversation_state_changed", &conversation);
    Ok(Json(conversation))
}

pub async fn close_conversation(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(conversation_id): Path<Uuid>,
) -> Result<Json<ConversationView>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    ensure_conversation_campus(&state, conversation_id, &session).await?;
    let service = ChatConversationService::new(state.infra.db.clone());
    let conversation = service.close(conversation_id, &session.user_id).await?;
    broadcast_conversation("conversation_state_changed", &conversation);
    Ok(Json(conversation))
}

pub async fn archive_conversation(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(conversation_id): Path<Uuid>,
    Json(body): Json<ArchiveConversationBody>,
) -> Result<Json<ConversationView>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    ensure_conversation_campus(&state, conversation_id, &session).await?;
    let service = ChatConversationService::new(state.infra.db.clone());
    Ok(Json(
        service
            .set_archived(conversation_id, &session.user_id, body.archived)
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

pub async fn get_connection_preferences(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<crate::services::chat_conversation::ConnectionPreferencesView>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let service = ChatConversationService::new(state.infra.db.clone());
    Ok(Json(service.get_connection_preferences(&user_id).await?))
}

pub async fn set_connection_preferences(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<ConnectionPreferencesBody>,
) -> Result<Json<crate::services::chat_conversation::ConnectionPreferencesView>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let busy_until = parse_optional_timestamp(body.busy_until, "busy_until")?;
    let service = ChatConversationService::new(state.infra.db.clone());
    Ok(Json(
        service
            .set_connection_preferences(&user_id, body.allow_strangers, busy_until)
            .await?,
    ))
}

pub async fn list_contact_permissions(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<crate::services::chat_conversation::ContactPermissionView>>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    let service = ChatConversationService::new(state.infra.db.clone());
    Ok(Json(service.list_contact_permissions(&user_id).await?))
}

pub async fn set_contact_permission(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(peer_user_id): Path<String>,
    Json(body): Json<ContactPermissionBody>,
) -> Result<Json<crate::services::chat_conversation::ContactPermissionView>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    CampusService::new(state.infra.db.clone())
        .require_shared_verified_campus_for_session(
            &session.user_id,
            &peer_user_id,
            session.campus_id,
        )
        .await?;
    let muted_until = parse_optional_timestamp(body.muted_until, "muted_until")?;
    let service = ChatConversationService::new(state.infra.db.clone());
    Ok(Json(
        service
            .set_contact_permission(
                &session.user_id,
                &peer_user_id,
                body.allow_connection,
                muted_until,
            )
            .await?,
    ))
}

pub async fn delete_contact_permission(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(peer_user_id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let service = CampusService::new(state.infra.db.clone());
    service
        .require_shared_verified_campus_for_session(
            &session.user_id,
            &peer_user_id,
            session.campus_id,
        )
        .await?;
    ChatConversationService::new(state.infra.db.clone())
        .delete_contact_permission(&session.user_id, &peer_user_id)
        .await?;
    Ok(Json(serde_json::json!({ "deleted": true })))
}

fn parse_optional_timestamp(
    value: Option<String>,
    field: &str,
) -> Result<Option<DateTime<Utc>>, ApiError> {
    value
        .filter(|value| !value.trim().is_empty())
        .map(|value| {
            DateTime::parse_from_rfc3339(value.trim())
                .map(|parsed| parsed.with_timezone(&Utc))
                .map_err(|_| ApiError::BadRequest(format!("{field} 必须是 RFC3339 时间")))
        })
        .transpose()
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

pub(crate) fn authenticated_session(
    state: &AppState,
    headers: &HeaderMap,
) -> Result<AuthSessionContext, ApiError> {
    extract_auth_session_from_token_with_fallback(
        headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)
}

/// Active-campus tokens must not be able to read or mutate a conversation
/// created under another campus. Legacy tokens without an active campus keep
/// the pre-migration behavior during the compatibility window.
pub(crate) async fn ensure_active_campus(
    state: &AppState,
    session: &AuthSessionContext,
) -> Result<Option<Uuid>, ApiError> {
    let Some(campus_id) = session.campus_id else {
        return Ok(None);
    };
    CampusService::new(state.infra.db.clone())
        .require_tenant_context_for_session(&session.user_id, Some(campus_id))
        .await?;
    Ok(Some(campus_id))
}

pub(crate) async fn ensure_conversation_campus(
    state: &AppState,
    conversation_id: Uuid,
    session: &AuthSessionContext,
) -> Result<(), ApiError> {
    let Some(campus_id) = ensure_active_campus(state, session).await? else {
        return Ok(());
    };
    let conversation_campus: Option<Uuid> =
        sqlx::query_scalar("SELECT campus_id FROM chat_conversations WHERE id = $1")
            .bind(conversation_id)
            .fetch_optional(&state.infra.db)
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
    match conversation_campus {
        Some(value) if value == campus_id => Ok(()),
        Some(_) => Err(ApiError::CampusScopeMismatch),
        None => Err(ApiError::NotFound),
    }
}

pub(crate) async fn ensure_message_campus(
    state: &AppState,
    message_id: i64,
    session: &AuthSessionContext,
) -> Result<Option<Uuid>, ApiError> {
    let Some(campus_id) = ensure_active_campus(state, session).await? else {
        return Ok(None);
    };
    let message_campus: Option<Uuid> = sqlx::query_scalar(
        "SELECT c.campus_id
         FROM chat_messages m
         JOIN chat_conversations c ON c.id = m.direct_conversation_id
         WHERE m.id = $1",
    )
    .bind(message_id)
    .fetch_optional(&state.infra.db)
    .await
    .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
    match message_campus {
        Some(value) if value == campus_id => Ok(Some(value)),
        Some(_) => Err(ApiError::CampusScopeMismatch),
        None => Err(ApiError::NotFound),
    }
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
    broadcast_conversation_to_user(event, conversation, &conversation.initiator_id);
    broadcast_conversation_to_user(event, conversation, &conversation.recipient_id);
}

fn broadcast_conversation_to_user(event: &str, conversation: &ConversationView, user_id: &str) {
    let payload = serde_json::json!({
        "event": event,
        "conversation_id": conversation.id,
        "mode": conversation.mode,
        "state": conversation.state,
        "expires_at": conversation.expires_at,
        "version": conversation.version,
    })
    .to_string();
    ws::broadcast_to_user_in_campus(user_id, conversation.campus_id, &payload);
}
