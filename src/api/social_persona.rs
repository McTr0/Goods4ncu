//! User-controlled role presentation.
//!
//! A social persona is an explicit presentation layer for a user in one
//! verified campus. It is deliberately separate from identity proof, Agent
//! authority, and attention/presence signals.

use axum::{
    extract::{Path, State},
    Json,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::api::session::{OptionalSession, VerifiedTenant};
use crate::api::{user::resolve_public_request_campus, AppState};
use crate::services::social_persona::{
    image_header_matches, CompleteSocialPersonaAssetInput, CreateSocialPersonaAssetInput,
    PublicSocialPersonaView, SocialPersonaAssetView, SocialPersonaInput, SocialPersonaService,
    SocialPersonaView,
};

#[derive(Debug, Deserialize)]
pub struct UpsertSocialPersonaRequest {
    pub representation_mode: String,
    pub style_version: Option<String>,
    pub appearance_config: Value,
    #[serde(default)]
    pub self_descriptions: Vec<String>,
    pub contact_posture: String,
}

#[derive(Debug, Serialize)]
pub struct SocialPersonaResponse {
    pub persona: Option<SocialPersonaView>,
}

/// System-owned role and skin choices.  This endpoint intentionally contains
/// tokens only; there is no user-provided image, URL, or prompt field.
pub async fn get_catalog() -> Json<crate::services::social_persona::SocialPersonaCatalogView> {
    Json(SocialPersonaService::catalog())
}

#[derive(Debug, Serialize)]
pub struct PublicSocialPersonaResponse {
    pub persona: Option<PublicSocialPersonaView>,
}

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct CreateSocialPersonaAssetRequest {
    pub asset_type: String,
    pub declared_mime_type: String,
    pub declared_size_bytes: i64,
}

#[derive(Debug, Serialize)]
#[allow(dead_code)]
pub struct SocialPersonaAssetsResponse {
    pub assets: Vec<SocialPersonaAssetView>,
}

#[derive(Debug, Serialize)]
#[allow(dead_code)]
pub struct SocialPersonaAssetResponse {
    pub asset: SocialPersonaAssetView,
}

#[derive(Debug, Serialize)]
#[allow(dead_code)]
pub struct SocialPersonaAssetUploadTargetResponse {
    pub asset_id: String,
    pub upload_key: String,
    /// Present when private media signing is configured.  A null value keeps
    /// local/public-bucket deployments on the existing STS fallback path.
    pub upload_url: Option<String>,
    pub expires_in_seconds: Option<u32>,
}

/// GET /api/user/persona
pub async fn get_persona(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
) -> Result<Json<SocialPersonaResponse>, ApiError> {
    let persona = SocialPersonaService::new(state.infra.db.clone())
        .get_for_user(&tenant.session.user_id, tenant.campus_id)
        .await?;
    Ok(Json(SocialPersonaResponse { persona }))
}

/// PUT /api/user/persona — save a private draft.
pub async fn upsert_persona(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Json(body): Json<UpsertSocialPersonaRequest>,
) -> Result<Json<SocialPersonaResponse>, ApiError> {
    let persona = SocialPersonaService::new(state.infra.db.clone())
        .upsert_draft(
            &tenant.session.user_id,
            tenant.campus_id,
            SocialPersonaInput {
                representation_mode: body.representation_mode,
                style_version: body.style_version,
                appearance_config: body.appearance_config,
                self_descriptions: body.self_descriptions,
                contact_posture: body.contact_posture,
            },
        )
        .await?;
    Ok(Json(SocialPersonaResponse {
        persona: Some(persona),
    }))
}

/// POST /api/user/persona/publish — make the saved presentation visible.
pub async fn publish_persona(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
) -> Result<Json<SocialPersonaResponse>, ApiError> {
    let persona = SocialPersonaService::new(state.infra.db.clone())
        .publish(&tenant.session.user_id, tenant.campus_id)
        .await?;
    Ok(Json(SocialPersonaResponse {
        persona: Some(persona),
    }))
}

/// POST /api/user/persona/archive — stop publishing the role presentation.
pub async fn archive_persona(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
) -> Result<Json<SocialPersonaResponse>, ApiError> {
    let persona = SocialPersonaService::new(state.infra.db.clone())
        .archive(&tenant.session.user_id, tenant.campus_id)
        .await?;
    Ok(Json(SocialPersonaResponse {
        persona: Some(persona),
    }))
}

/// GET /api/users/:id/persona — published presentation in the viewer's
/// currently resolved public campus only.
pub async fn get_public_persona(
    State(state): State<AppState>,
    OptionalSession(session): OptionalSession,
    Path(user_id): Path<String>,
) -> Result<Json<PublicSocialPersonaResponse>, ApiError> {
    let campus_id = resolve_public_request_campus(&state, session.as_ref()).await?;
    let mut persona = SocialPersonaService::new(state.infra.db.clone())
        .get_published_for_user(&user_id, campus_id)
        .await?;
    if let Some(persona) = persona.as_mut() {
        decorate_public_persona_media(&state, persona);
    }
    Ok(Json(PublicSocialPersonaResponse { persona }))
}

/// Legacy asset adapters retained for migration/rollback code only.  These
/// handlers are intentionally not registered in `create_router`; no current
/// client can create, upload, select, or revoke a user-owned role asset.
/// GET /api/user/persona/assets — private upload/moderation state for the owner.
#[allow(dead_code)]
pub async fn list_assets(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
) -> Result<Json<SocialPersonaAssetsResponse>, ApiError> {
    let assets = SocialPersonaService::new(state.infra.db.clone())
        .list_assets(&tenant.session.user_id, tenant.campus_id)
        .await?;
    Ok(Json(SocialPersonaAssetsResponse { assets }))
}

/// POST /api/user/persona/assets — create a server-keyed pending upload.
#[allow(dead_code)]
pub async fn create_asset(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Json(body): Json<CreateSocialPersonaAssetRequest>,
) -> Result<Json<SocialPersonaAssetResponse>, ApiError> {
    let asset = SocialPersonaService::new(state.infra.db.clone())
        .create_asset(
            &tenant.session.user_id,
            tenant.campus_id,
            CreateSocialPersonaAssetInput {
                asset_type: body.asset_type,
                declared_mime_type: body.declared_mime_type,
                declared_size_bytes: body.declared_size_bytes,
            },
        )
        .await?;
    Ok(Json(SocialPersonaAssetResponse { asset }))
}

/// POST /api/user/persona/assets/:id/upload-target — issue a PUT URL scoped
/// to the server-generated key.  The target is owner- and campus-scoped; a
/// client cannot choose a different object key or reuse it for another asset.
#[allow(dead_code)]
pub async fn upload_target(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(asset_id): Path<Uuid>,
) -> Result<Json<SocialPersonaAssetUploadTargetResponse>, ApiError> {
    let asset = SocialPersonaService::new(state.infra.db.clone())
        .get_asset(&tenant.session.user_id, tenant.campus_id, asset_id)
        .await?;
    if asset.status != "pending_upload" {
        return Err(ApiError::Conflict("角色图片当前不可上传".to_string()));
    }
    let upload_key = asset.upload_key.ok_or(ApiError::NotFound)?;
    let (upload_url, expires_in_seconds) = match state.infra.media_signer.as_ref() {
        Some(signer) => {
            let url = signer
                .sign_put_key(&upload_key)
                .ok_or_else(|| ApiError::Internal(anyhow::anyhow!("invalid persona upload key")))?;
            (Some(url), Some(signer.ttl_secs))
        }
        None => (None, None),
    };
    Ok(Json(SocialPersonaAssetUploadTargetResponse {
        asset_id: asset.id,
        upload_key,
        upload_url,
        expires_in_seconds,
    }))
}

/// POST /api/user/persona/assets/:id/complete — probe the platform object and
/// move it to active or the moderation quarantine.
#[allow(dead_code)]
pub async fn complete_asset(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(asset_id): Path<Uuid>,
) -> Result<Json<SocialPersonaAssetResponse>, ApiError> {
    let service = SocialPersonaService::new(state.infra.db.clone());
    let existing = service
        .get_asset(&tenant.session.user_id, tenant.campus_id, asset_id)
        .await?;
    let key = existing.upload_key.as_deref().ok_or(ApiError::NotFound)?;
    if existing.status == "pending_review" {
        // The object was already verified. A retry also repairs the narrow
        // window where the DB commit succeeded but the moderation enqueue did
        // not, without probing or reclassifying the uploaded bytes.
        ensure_persona_asset_moderation_job(&state, &existing).await?;
        return Ok(Json(SocialPersonaAssetResponse { asset: existing }));
    }
    if existing.status != "pending_upload" {
        return Ok(Json(SocialPersonaAssetResponse { asset: existing }));
    }
    let metadata = state.probe_platform_object(key).await?;
    let uploaded_mime_type = metadata.mime_type.ok_or(ApiError::CodedConflict {
        code: "persona_asset_mime_missing",
        message: "平台没有返回图片类型".to_string(),
    })?;
    if !image_header_matches(&uploaded_mime_type, &metadata.prefix_bytes) {
        return Err(ApiError::CodedConflict {
            code: "persona_asset_header_mismatch",
            message: "图片文件头与类型不一致".to_string(),
        });
    }
    let completed = service
        .complete_asset(
            &tenant.session.user_id,
            tenant.campus_id,
            asset_id,
            CompleteSocialPersonaAssetInput {
                uploaded_size_bytes: metadata.size_bytes,
                uploaded_mime_type,
                moderation_required: state.infra.moderation.is_image_enabled(),
            },
        )
        .await?;
    if completed.status == "pending_review" {
        ensure_persona_asset_moderation_job(&state, &completed).await?;
    }
    Ok(Json(SocialPersonaAssetResponse { asset: completed }))
}

/// POST /api/user/persona/assets/:id/select — explicit owner selection.
#[allow(dead_code)]
pub async fn select_asset(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(asset_id): Path<Uuid>,
) -> Result<Json<SocialPersonaResponse>, ApiError> {
    let persona = SocialPersonaService::new(state.infra.db.clone())
        .select_asset(&tenant.session.user_id, tenant.campus_id, asset_id)
        .await?;
    Ok(Json(SocialPersonaResponse {
        persona: Some(persona),
    }))
}

/// POST /api/user/persona/assets/:id/revoke — remove the asset from future
/// public projections and enqueue durable remote cleanup.
#[allow(dead_code)]
pub async fn revoke_asset(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(asset_id): Path<Uuid>,
) -> Result<Json<SocialPersonaAssetResponse>, ApiError> {
    let asset = SocialPersonaService::new(state.infra.db.clone())
        .revoke_asset(&tenant.session.user_id, tenant.campus_id, asset_id)
        .await?;
    Ok(Json(SocialPersonaAssetResponse { asset }))
}

pub fn decorate_public_persona_media(state: &AppState, persona: &mut PublicSocialPersonaView) {
    if let Some(asset) = persona.asset.as_mut() {
        asset.url = asset
            .storage_key
            .as_deref()
            .and_then(|key| state.public_platform_media_url(key));
        asset.storage_key = None;
    }
}

#[allow(dead_code)]
async fn ensure_persona_asset_moderation_job(
    state: &AppState,
    asset: &SocialPersonaAssetView,
) -> Result<(), ApiError> {
    let asset_id = Uuid::parse_str(&asset.id).map_err(|error| {
        ApiError::Internal(anyhow::anyhow!("invalid persona asset id: {error}"))
    })?;
    let mut tx = state
        .infra
        .db
        .begin()
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {error}")))?;
    let row = sqlx::query(
        "SELECT status, moderation_status, storage_key, campus_id
         FROM social_persona_assets WHERE id = $1 FOR UPDATE",
    )
    .bind(asset_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {error}")))?
    .ok_or(ApiError::NotFound)?;
    let status: String = sqlx::Row::try_get(&row, "status")
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB row error: {error}")))?;
    if status != "pending_review" {
        tx.commit()
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB commit error: {error}")))?;
        return Ok(());
    }
    let moderation_status: String = sqlx::Row::try_get(&row, "moderation_status")
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB row error: {error}")))?;
    if moderation_status != "pending" {
        return Err(ApiError::Conflict("角色图片审核状态已变化".to_string()));
    }
    let pending: bool = sqlx::query_scalar(
        "SELECT EXISTS(
             SELECT 1 FROM moderation_jobs
             WHERE resource_type = 'social_persona_asset'
               AND resource_id = $1
               AND status IN ('pending', 'processing')
         )",
    )
    .bind(asset.id.as_str())
    .fetch_one(&mut *tx)
    .await
    .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {error}")))?;
    if !pending {
        let key: String = sqlx::Row::try_get(&row, "storage_key")
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB row error: {error}")))?;
        let media_url = state
            .public_platform_media_url(&key)
            .ok_or_else(|| ApiError::NotImplemented("平台文件服务未配置".to_string()))?;
        let campus_id: Uuid = sqlx::Row::try_get(&row, "campus_id")
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB row error: {error}")))?;
        state
            .infra
            .moderation
            .submit_image_job_in_tx_with_storage_key(
                &mut tx,
                campus_id,
                asset.id.as_str(),
                &media_url,
                Some(&key),
                "social_persona_asset",
            )
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("enqueue moderation: {error}")))?;
    }
    tx.commit()
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB commit error: {error}")))?;
    Ok(())
}
