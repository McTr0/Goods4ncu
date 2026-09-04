use axum::{
    extract::{Path, State},
    http::HeaderMap,
    Json,
};

use crate::api::error::ApiError;
use crate::api::AppState;
use crate::services::campus::CampusService;
use crate::services::chat_conversation::{
    AvatarInteractionContactPreferencesView, AvatarInteractionPreferencesView,
    ChatConversationService, ConversationMessageRecord, SendAvatarInteractionInput,
};

use super::{
    authenticated_session, ensure_conversation_campus, AvatarInteractionContactPreferencesBody,
    AvatarInteractionPreferencesBody, SendAvatarInteractionBody,
};

pub async fn get_preferences(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<AvatarInteractionPreferencesView>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let tenant = CampusService::new(state.infra.db.clone())
        .require_tenant_context_for_session(&session.user_id, session.campus_id)
        .await?;
    let view = ChatConversationService::new(state.infra.db.clone())
        .get_avatar_interaction_preferences(&session.user_id, tenant.campus_id)
        .await?;
    Ok(Json(view))
}

pub async fn set_preferences(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<AvatarInteractionPreferencesBody>,
) -> Result<Json<AvatarInteractionPreferencesView>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let tenant = CampusService::new(state.infra.db.clone())
        .require_tenant_context_for_session(&session.user_id, session.campus_id)
        .await?;
    let view = ChatConversationService::new(state.infra.db.clone())
        .set_avatar_interaction_preferences(&session.user_id, tenant.campus_id, body.policies)
        .await?;
    Ok(Json(view))
}

pub async fn get_contact_preferences(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(peer_user_id): Path<String>,
) -> Result<Json<AvatarInteractionContactPreferencesView>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let tenant = CampusService::new(state.infra.db.clone())
        .require_shared_verified_campus_for_session(
            &session.user_id,
            &peer_user_id,
            session.campus_id,
        )
        .await?;
    let view = ChatConversationService::new(state.infra.db.clone())
        .get_avatar_interaction_contact_preferences(
            &session.user_id,
            &peer_user_id,
            tenant.campus_id,
        )
        .await?;
    Ok(Json(view))
}

pub async fn set_contact_preferences(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(peer_user_id): Path<String>,
    Json(body): Json<AvatarInteractionContactPreferencesBody>,
) -> Result<Json<AvatarInteractionContactPreferencesView>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let tenant = CampusService::new(state.infra.db.clone())
        .require_shared_verified_campus_for_session(
            &session.user_id,
            &peer_user_id,
            session.campus_id,
        )
        .await?;
    let view = ChatConversationService::new(state.infra.db.clone())
        .set_avatar_interaction_contact_preferences(
            &session.user_id,
            &peer_user_id,
            tenant.campus_id,
            body.policies,
        )
        .await?;
    Ok(Json(view))
}

pub async fn delete_contact_preferences(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(peer_user_id): Path<String>,
) -> Result<Json<AvatarInteractionContactPreferencesView>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let tenant = CampusService::new(state.infra.db.clone())
        .require_shared_verified_campus_for_session(
            &session.user_id,
            &peer_user_id,
            session.campus_id,
        )
        .await?;
    let view = ChatConversationService::new(state.infra.db.clone())
        .delete_avatar_interaction_contact_preferences(
            &session.user_id,
            &peer_user_id,
            tenant.campus_id,
        )
        .await?;
    Ok(Json(view))
}

pub async fn send_interaction(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(conversation_id): Path<uuid::Uuid>,
    Json(body): Json<SendAvatarInteractionBody>,
) -> Result<Json<ConversationMessageRecord>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    ensure_conversation_campus(&state, conversation_id, &session).await?;
    let service = ChatConversationService::new(state.infra.db.clone());
    let message = service
        .send_avatar_interaction(SendAvatarInteractionInput {
            client_interaction_id: body.client_interaction_id,
            conversation_id,
            sender_id: session.user_id.clone(),
            action: body.action,
        })
        .await?;
    let conversation = service
        .get_conversation(conversation_id, &session.user_id)
        .await?;

    let payload = serde_json::json!({
        "event": "new_message",
        "conversation_id": conversation_id,
        "message_id": message.id,
        "client_message_id": message.client_message_id,
        "sender": message.sender,
        "content": message.content,
        "timestamp": message.timestamp,
        "kind": message.kind,
        "interaction": message.interaction,
    })
    .to_string();
    state.infra.ws_hub.broadcast_to_user_in_campus(
        &conversation.initiator_id,
        conversation.campus_id,
        &payload,
    );
    state.infra.ws_hub.broadcast_to_user_in_campus(
        &conversation.recipient_id,
        conversation.campus_id,
        &payload,
    );

    state.infra.metrics.record_chat_message();
    Ok(Json(message))
}
