//! Interruption budget endpoints: settings, history, and engagement receipts.
//!
//! These make the budget legible to the person it protects. The history
//! deliberately includes withheld attempts as well as delivered ones — silent
//! suppression is indistinguishable from having nothing to say, and a user who
//! cannot see what was held back cannot tell whether their settings are too
//! tight.

use axum::{
    extract::{Path, State},
    Json,
};
use serde::Deserialize;
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::api::session::Session;
use crate::api::AppState;
use crate::services::interruption::{topics, InterruptionService, Preferences};

/// GET /api/interruptions/preferences
pub async fn get_preferences(
    State(state): State<AppState>,
    Session(session): Session,
) -> Result<Json<serde_json::Value>, ApiError> {
    let service = InterruptionService::new(state.infra.db.clone());
    let prefs = service
        .preferences(&session.user_id)
        .await
        .map_err(ApiError::Internal)?;
    let remaining = service
        .remaining_budget(&session.user_id)
        .await
        .map_err(ApiError::Internal)?;

    Ok(Json(serde_json::json!({
        "preferences": prefs,
        "remaining_today": remaining,
        "available_topics": topics::ALL,
    })))
}

#[derive(Deserialize)]
pub struct UpdatePreferencesRequest {
    pub daily_budget: Option<i16>,
    pub muted_topics: Option<Vec<String>>,
    pub quiet_until: Option<chrono::DateTime<chrono::Utc>>,
    /// Explicitly lift a quiet period; distinct from omitting the field, which
    /// leaves it untouched.
    #[serde(default)]
    pub clear_quiet: bool,
}

/// PUT /api/interruptions/preferences
pub async fn update_preferences(
    State(state): State<AppState>,
    Session(session): Session,
    Json(payload): Json<UpdatePreferencesRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let service = InterruptionService::new(state.infra.db.clone());
    let current = service
        .preferences(&session.user_id)
        .await
        .map_err(ApiError::Internal)?;

    let daily_budget = payload.daily_budget.unwrap_or(current.daily_budget);
    // Mirrors the CHECK constraint so the user gets a clear message instead of
    // a database error.
    if !(0..=20).contains(&daily_budget) {
        return Err(ApiError::BadRequest(
            "每日打扰上限需要在 0 到 20 之间".to_string(),
        ));
    }

    let muted_topics = payload.muted_topics.unwrap_or(current.muted_topics);
    if let Some(unknown) = muted_topics
        .iter()
        .find(|t| !topics::ALL.contains(&t.as_str()))
    {
        return Err(ApiError::BadRequest(format!("未知的通知类型：{}", unknown)));
    }

    let quiet_until = if payload.clear_quiet {
        None
    } else {
        payload.quiet_until.or(current.quiet_until)
    };

    let updated = Preferences {
        daily_budget,
        muted_topics,
        quiet_until,
    };
    service
        .set_preferences(&session.user_id, &updated)
        .await
        .map_err(ApiError::Internal)?;

    Ok(Json(serde_json::json!({ "preferences": updated })))
}

/// GET /api/interruptions/history — what reached the user, and what did not.
pub async fn history(
    State(state): State<AppState>,
    Session(session): Session,
) -> Result<Json<serde_json::Value>, ApiError> {
    let items = InterruptionService::new(state.infra.db.clone())
        .recent(&session.user_id, 50)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(serde_json::json!({ "items": items })))
}

/// POST /api/interruptions/{id}/accept — the user engaged with it.
pub async fn accept(
    State(state): State<AppState>,
    Session(session): Session,
    Path(ledger_id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let recorded = InterruptionService::new(state.infra.db.clone())
        .mark_accepted(&session.user_id, ledger_id)
        .await
        .map_err(ApiError::Internal)?;
    if !recorded {
        return Err(ApiError::NotFound);
    }
    Ok(Json(serde_json::json!({ "status": "accepted" })))
}

/// POST /api/interruptions/{id}/dismiss — waved away. Feeds the per-topic
/// threshold, so a category the user keeps dismissing quiets itself without
/// them having to find a settings screen.
pub async fn dismiss(
    State(state): State<AppState>,
    Session(session): Session,
    Path(ledger_id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let recorded = InterruptionService::new(state.infra.db.clone())
        .mark_dismissed(&session.user_id, ledger_id)
        .await
        .map_err(ApiError::Internal)?;
    if !recorded {
        return Err(ApiError::NotFound);
    }
    Ok(Json(serde_json::json!({ "status": "dismissed" })))
}
