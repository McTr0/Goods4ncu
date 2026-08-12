//! Safe user-facing view of recent AgentRun envelopes.
//!
//! The endpoint exposes typed operational metadata only.  It never returns
//! prompts, transcripts, tool arguments, confirmation capabilities or raw
//! provider errors.

use axum::{extract::State, response::Response};
use serde::Deserialize;

use crate::api::agent_plans::no_store_json;
use crate::api::error::ApiError;
use crate::api::session::VerifiedTenant;
use crate::api::AppState;
use crate::services::agent_run::{AgentRunService, AgentRunView};

#[derive(Debug, Deserialize)]
pub struct AgentRunListQuery {
    pub limit: Option<i64>,
}

/// GET /api/agent/runs — recent safe run envelopes for the authenticated user.
pub async fn list_runs(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    axum::extract::Query(query): axum::extract::Query<AgentRunListQuery>,
) -> Result<Response, ApiError> {
    let items: Vec<AgentRunView> = AgentRunService::new(state.infra.db.clone())
        .list_recent(
            &tenant.session.user_id,
            tenant.campus_id,
            query.limit.unwrap_or(20),
        )
        .await
        .map_err(ApiError::Internal)?;
    Ok(no_store_json(serde_json::json!({ "items": items })))
}
