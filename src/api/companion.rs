//! Companion relationship API (goal §13–15).
//!
//! GET  /api/companion/relationship          → current state
//! POST /api/companion/relationship/events   → record one event, get state

use axum::{extract::State, http::StatusCode, response::IntoResponse, Json};
use serde::Deserialize;

use crate::api::session::Session;
use crate::api::{ApiError, AppState};
use crate::services::companion_relationship::RelationshipEvent;

/// GET /api/companion/relationship
pub(crate) async fn get_relationship(
    State(state): State<AppState>,
    Session(session): Session,
) -> Result<Json<serde_json::Value>, ApiError> {
    if !state.agents.agent_enabled {
        return Err(ApiError::ServiceUnavailable(
            "AI assistant is disabled on this server.",
        ));
    }
    let svc = crate::services::companion_relationship::CompanionRelationshipService::new(
        state.infra.db.clone(),
    );
    let state = svc
        .get(&session.user_id)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!(e)))?;
    Ok(Json(serde_json::json!({
        "familiarity": state.familiarity,
        "trust": state.trust,
        "affinity": state.affinity,
        "interactionCount": state.interaction_count,
        "stage": state.relationship_stage,
    })))
}

#[derive(Deserialize)]
pub(crate) struct RecordEventRequest {
    pub event: String,
}

/// POST /api/companion/relationship/events
pub(crate) async fn record_relationship_event(
    State(state): State<AppState>,
    Session(session): Session,
    Json(payload): Json<RecordEventRequest>,
) -> Result<impl IntoResponse, ApiError> {
    if !state.agents.agent_enabled {
        return Err(ApiError::ServiceUnavailable(
            "AI assistant is disabled on this server.",
        ));
    }
    let event = RelationshipEvent::from_wire(&payload.event)
        .ok_or_else(|| ApiError::BadRequest("unknown relationship event".to_string()))?;
    let svc = crate::services::companion_relationship::CompanionRelationshipService::new(
        state.infra.db.clone(),
    );
    let updated = svc
        .record_event(&session.user_id, event)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!(e)))?;
    Ok((
        StatusCode::OK,
        Json(serde_json::json!({
            "familiarity": updated.familiarity,
            "trust": updated.trust,
            "affinity": updated.affinity,
            "interactionCount": updated.interaction_count,
            "stage": updated.relationship_stage,
        })),
    ))
}
