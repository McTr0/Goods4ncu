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

use crate::api::error::ApiError;
use crate::api::session::{OptionalSession, VerifiedTenant};
use crate::api::{user::resolve_public_request_campus, AppState};
use crate::services::social_persona::{
    PublicSocialPersonaView, SocialPersonaInput, SocialPersonaService, SocialPersonaView,
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

#[derive(Debug, Serialize)]
pub struct PublicSocialPersonaResponse {
    pub persona: Option<PublicSocialPersonaView>,
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
    let persona = SocialPersonaService::new(state.infra.db.clone())
        .get_published_for_user(&user_id, campus_id)
        .await?;
    Ok(Json(PublicSocialPersonaResponse { persona }))
}
