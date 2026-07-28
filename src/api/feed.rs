use axum::{extract::State, Json};
use serde::Deserialize;

use crate::api::error::ApiError;
use crate::api::session::VerifiedTenant;
use crate::api::AppState;
use crate::services::feed::{FeedFeedbackAction, FeedResourceType, FeedService};

#[derive(Deserialize)]
pub struct SubmitFeedFeedbackRequest {
    pub resource_type: FeedResourceType,
    pub resource_id: String,
    pub action: FeedFeedbackAction,
}

#[derive(Deserialize)]
pub struct UpdateFeedPreferencesRequest {
    pub personalization_enabled: bool,
}

/// POST /api/feed/feedback
pub async fn submit_feedback(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Json(payload): Json<SubmitFeedFeedbackRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let receipt = FeedService::new(state.infra.db.clone())
        .submit_feedback(
            tenant.campus_id,
            &tenant.session.user_id,
            payload.resource_type,
            &payload.resource_id,
            payload.action,
        )
        .await?;
    Ok(Json(serde_json::to_value(receipt).map_err(|error| {
        ApiError::Internal(anyhow::anyhow!("serialize feed feedback: {error}"))
    })?))
}

/// GET /api/feed/preferences
pub async fn get_preferences(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
) -> Result<Json<serde_json::Value>, ApiError> {
    let preferences = FeedService::new(state.infra.db.clone())
        .preferences(tenant.campus_id, &tenant.session.user_id)
        .await?;
    Ok(Json(serde_json::to_value(preferences).map_err(
        |error| ApiError::Internal(anyhow::anyhow!("serialize feed preferences: {error}")),
    )?))
}

/// PUT /api/feed/preferences
pub async fn update_preferences(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Json(payload): Json<UpdateFeedPreferencesRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let preferences = FeedService::new(state.infra.db.clone())
        .update_preferences(
            tenant.campus_id,
            &tenant.session.user_id,
            payload.personalization_enabled,
        )
        .await?;
    Ok(Json(serde_json::to_value(preferences).map_err(
        |error| ApiError::Internal(anyhow::anyhow!("serialize feed preferences: {error}")),
    )?))
}

/// POST /api/feed/personalization/clear
pub async fn clear_personalization(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
) -> Result<Json<serde_json::Value>, ApiError> {
    let preferences = FeedService::new(state.infra.db.clone())
        .clear_personalization(tenant.campus_id, &tenant.session.user_id)
        .await?;
    Ok(Json(serde_json::to_value(preferences).map_err(
        |error| ApiError::Internal(anyhow::anyhow!("serialize feed preferences: {error}")),
    )?))
}
