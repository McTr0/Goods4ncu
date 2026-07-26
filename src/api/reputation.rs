//! Trust built from what actually happened.
//!
//! Two questions with checkable answers, and no free-text field. A comment box
//! is where the social cost of an honest answer comes straight back in, which is
//! the thing star ratings get wrong on a campus.

use axum::{
    extract::{Path, State},
    Json,
};
use serde::Deserialize;
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::api::session::VerifiedTenant;
use crate::api::AppState;
use crate::services::reputation::ReputationService;

#[derive(Deserialize)]
pub struct ConfirmRequest {
    /// Did the handoff happen.
    pub happened: bool,
    /// Whether they were on time. Required when it happened, meaningless
    /// otherwise.
    #[serde(default)]
    pub on_time: Option<bool>,
}

/// POST /api/handoffs/{agreement_id}/confirm — say what happened.
///
/// Answerable once, by a participant, only after the arrangement was settled.
/// A second answer is refused rather than applied: revising your account after
/// a falling-out is exactly what this must not allow.
pub async fn confirm(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(agreement_id): Path<Uuid>,
    Json(payload): Json<ConfirmRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let recorded = ReputationService::new(state.infra.db.clone())
        .confirm(
            agreement_id,
            &tenant.session.user_id,
            payload.happened,
            payload.on_time,
        )
        .await
        .map_err(|error| ApiError::BadRequest(error.to_string()))?;
    if !recorded {
        // Not a participant, not settled, or already answered — one reply for
        // all three, so this cannot be used to probe someone else's
        // arrangements.
        return Err(ApiError::Conflict("这次约定现在不能确认".to_string()));
    }
    Ok(Json(serde_json::json!({ "status": "recorded" })))
}

/// GET /api/handoffs/pending — arrangements still owed an answer.
pub async fn pending(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
) -> Result<Json<serde_json::Value>, ApiError> {
    let items = ReputationService::new(state.infra.db.clone())
        .awaiting_confirmation(&tenant.session.user_id)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(serde_json::json!({ "items": items })))
}

/// GET /api/users/{id}/reputation — what is known about someone, in facts.
pub async fn of_user(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(user_id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let record = ReputationService::new(state.infra.db.clone())
        .of(tenant.campus_id, &user_id)
        .await
        .map_err(ApiError::Internal)?;
    let weight = record.matching_weight();
    Ok(Json(serde_json::json!({
        "reputation": record,
        // Exposed so ranking is explainable rather than a hidden score. A
        // newcomer sits at neutral, which the client should say rather than
        // render as a low bar.
        "matching_weight": weight,
    })))
}
