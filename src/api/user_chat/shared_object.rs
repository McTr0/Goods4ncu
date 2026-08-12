use axum::{
    extract::{Path, State},
    http::HeaderMap,
    Json,
};
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::api::{ws, AppState};
use crate::services::chat_conversation::{
    ChatConversationService, CompleteSharedObjectInput, CreateSharedObjectInput, SharedObjectKind,
};

use super::{
    authenticated_session, ensure_active_campus, ensure_conversation_campus,
    CompleteSharedObjectBody, CreateSharedObjectBody, SharedObjectResponse,
};

pub async fn create_shared_object(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(conversation_id): Path<Uuid>,
    Json(body): Json<CreateSharedObjectBody>,
) -> Result<Json<SharedObjectResponse>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    ensure_conversation_campus(&state, conversation_id, &session).await?;
    let campus_id = ensure_active_campus(&state, &session)
        .await?
        .ok_or(ApiError::CampusVerificationRequired)?;
    let object = ChatConversationService::new(state.infra.db.clone())
        .create_shared_object(CreateSharedObjectInput {
            conversation_id,
            campus_id,
            created_by: session.user_id,
            kind: body.kind,
            title: body.title,
            mime_type: body.mime_type,
            size_bytes: body.size_bytes,
            canonical_url: body.canonical_url,
        })
        .await?;
    broadcast_shared_object(&state, &object, "shared_object_created").await?;
    Ok(Json(shared_object_response(object)))
}

pub async fn complete_shared_object(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(object_id): Path<Uuid>,
    Json(_body): Json<CompleteSharedObjectBody>,
) -> Result<Json<SharedObjectResponse>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let campus_id = ensure_active_campus(&state, &session).await?;
    let service = ChatConversationService::new(state.infra.db.clone());
    let object = service
        .get_shared_object(object_id, &session.user_id)
        .await?;
    if campus_id.is_some_and(|campus| campus.to_string() != object.campus_id) {
        return Err(ApiError::CampusScopeMismatch);
    }
    if object.kind != SharedObjectKind::File.as_str() {
        return Err(ApiError::BadRequest(
            "只有文件对象需要上传完成确认".to_string(),
        ));
    }
    if object.status == "revoked" {
        return Err(ApiError::Conflict("shared_object_revoked".to_string()));
    }
    // Completion is intentionally idempotent. Once storage was verified, a
    // retry must not re-probe a deleted/expired URL or regress a moderation
    // decision; the persisted object row is the authoritative response.
    if object.status != "pending_upload"
        && !(object.status == "pending_review" && object.storage_verified_at.is_none())
    {
        return Ok(Json(shared_object_response(object)));
    }
    let key = object.upload_key.as_deref().ok_or(ApiError::NotFound)?;
    let metadata = state.probe_platform_object(key).await?;
    let effective_mime = metadata
        .mime_type
        .clone()
        .or_else(|| object.mime_type.clone());
    if effective_mime
        .as_deref()
        .is_none_or(|mime| mime.trim().is_empty())
    {
        return Err(ApiError::CodedConflict {
            code: "shared_object_mime_missing",
            message: "平台没有返回文件类型".to_string(),
        });
    }
    let moderation_required = state.infra.moderation.is_image_enabled()
        && effective_mime
            .as_deref()
            .is_some_and(|mime| mime.to_ascii_lowercase().starts_with("image/"));
    let completed = service
        .complete_shared_object(CompleteSharedObjectInput {
            object_id,
            user_id: session.user_id.clone(),
            uploaded_size_bytes: metadata.size_bytes,
            uploaded_mime_type: effective_mime,
            storage_etag: metadata.etag,
            moderation_required,
        })
        .await?;

    if moderation_required && completed.status == "pending_review" {
        ensure_shared_object_moderation_job(&state, &completed).await?;
    }
    broadcast_shared_object(&state, &completed, "shared_object_updated").await?;
    Ok(Json(shared_object_response(completed)))
}

pub async fn get_shared_object(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(object_id): Path<Uuid>,
) -> Result<Json<SharedObjectResponse>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let campus_id = ensure_active_campus(&state, &session).await?;
    let object = ChatConversationService::new(state.infra.db.clone())
        .get_shared_object(object_id, &session.user_id)
        .await?;
    if campus_id.is_some_and(|campus| campus.to_string() != object.campus_id) {
        return Err(ApiError::CampusScopeMismatch);
    }
    Ok(Json(shared_object_response(object)))
}

pub async fn get_shared_object_media(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(object_id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let campus_id = ensure_active_campus(&state, &session).await?;
    let object = ChatConversationService::new(state.infra.db.clone())
        .get_shared_object(object_id, &session.user_id)
        .await?;
    if campus_id.is_some_and(|campus| campus.to_string() != object.campus_id) {
        return Err(ApiError::CampusScopeMismatch);
    }
    if object.kind != SharedObjectKind::File.as_str()
        || object.status != "active"
        || !matches!(
            object.moderation_status.as_str(),
            "approved" | "not_required"
        )
    {
        return Err(ApiError::NotFound);
    }
    let key = object.upload_key.as_deref().ok_or(ApiError::NotFound)?;
    let url = state
        .public_platform_media_url(key)
        .ok_or_else(|| ApiError::NotImplemented("平台文件服务未配置".to_string()))?;
    Ok(Json(serde_json::json!({
        "object_id": object.id,
        "url": url,
        "expires_in_seconds": state.infra.media_signer.as_ref().map(|signer| signer.ttl_secs),
    })))
}

pub async fn revoke_shared_object(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(object_id): Path<Uuid>,
) -> Result<Json<SharedObjectResponse>, ApiError> {
    let session = authenticated_session(&state, &headers)?;
    let campus_id = ensure_active_campus(&state, &session).await?;
    let object = ChatConversationService::new(state.infra.db.clone())
        .revoke_shared_object(object_id, &session.user_id)
        .await?;
    if campus_id.is_some_and(|campus| campus.to_string() != object.campus_id) {
        return Err(ApiError::CampusScopeMismatch);
    }
    broadcast_shared_object(&state, &object, "shared_object_revoked").await?;
    Ok(Json(shared_object_response(object)))
}

async fn broadcast_shared_object(
    state: &AppState,
    object: &crate::services::chat_conversation::ChatSharedObjectView,
    event: &str,
) -> Result<(), ApiError> {
    let (initiator_id, recipient_id): (String, String) =
        sqlx::query_as(
            "SELECT initiator_id, recipient_id
         FROM chat_conversations
         WHERE id = $1",
        )
        .bind(Uuid::parse_str(&object.conversation_id).map_err(|error| {
            ApiError::Internal(anyhow::anyhow!("invalid conversation id: {error}"))
        })?)
        .fetch_optional(&state.infra.db)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {error}")))?
        .ok_or(ApiError::NotFound)?;
    let payload = serde_json::json!({
        "event": event,
        "object_id": object.id,
        "conversation_id": object.conversation_id,
        "kind": object.kind,
        "status": object.status,
    })
    .to_string();
    let campus_id = Uuid::parse_str(&object.campus_id)
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("invalid campus id: {error}")))?;
    ws::broadcast_to_user_in_campus(&initiator_id, campus_id, &payload);
    ws::broadcast_to_user_in_campus(&recipient_id, campus_id, &payload);
    Ok(())
}

async fn ensure_shared_object_moderation_job(
    state: &AppState,
    object: &crate::services::chat_conversation::ChatSharedObjectView,
) -> Result<(), ApiError> {
    let object_id = Uuid::parse_str(&object.id)
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("invalid object id: {error}")))?;
    let mut tx = state
        .infra
        .db
        .begin()
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {error}")))?;
    let status: Option<String> =
        sqlx::query_scalar("SELECT status FROM chat_shared_objects WHERE id = $1 FOR UPDATE")
            .bind(object_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {error}")))?;
    if status.as_deref() != Some("pending_review") {
        tx.commit()
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB commit error: {error}")))?;
        return Ok(());
    }
    let pending: bool = sqlx::query_scalar(
        "SELECT EXISTS(
             SELECT 1 FROM moderation_jobs
             WHERE resource_type = 'chat_shared_object'
               AND resource_id = $1
               AND status IN ('pending', 'processing')
         )",
    )
    .bind(&object.id)
    .fetch_one(&mut *tx)
    .await
    .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {error}")))?;
    if pending {
        tx.commit()
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB commit error: {error}")))?;
        return Ok(());
    }
    let key = object.upload_key.as_deref().ok_or(ApiError::NotFound)?;
    let media_url = state
        .public_platform_media_url(key)
        .ok_or_else(|| ApiError::NotImplemented("平台文件服务未配置".to_string()))?;
    state
        .infra
        .moderation
        .submit_image_job_in_tx(
            &mut tx,
            Uuid::parse_str(&object.campus_id).map_err(|error| {
                ApiError::Internal(anyhow::anyhow!("invalid campus id: {error}"))
            })?,
            &object.id,
            &media_url,
            "chat_shared_object",
        )
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("enqueue moderation: {error}")))?;
    tx.commit()
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB commit error: {error}")))?;
    Ok(())
}

fn shared_object_response(
    object: crate::services::chat_conversation::ChatSharedObjectView,
) -> SharedObjectResponse {
    let download_path = (object.kind == SharedObjectKind::File.as_str())
        .then(|| format!("/api/chat/shared-objects/{}/media", object.id));
    SharedObjectResponse {
        object,
        download_path,
    }
}
