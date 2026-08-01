//! Agent ActionPlan endpoints: list pending plans, confirm, cancel.
//!
//! This is the human half of the ActionPlan protocol. The confirmation token
//! only ever leaves the server through these authenticated responses — the
//! agent's chat text names the plan but cannot confirm it, so a prompt-injected
//! model has no path to execute its own proposal.

use axum::{
    extract::{Path, State},
    Json,
};
use serde::Deserialize;
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::api::session::Session;
use crate::api::AppState;
use crate::services::agent_plan::{AgentPlanService, AgentPlanView, ConfirmOutcome};

/// GET /api/agent/plans — the caller's pending plans (with confirmation tokens).
pub async fn list_plans(
    State(state): State<AppState>,
    Session(session): Session,
) -> Result<Json<serde_json::Value>, ApiError> {
    let plans: Vec<AgentPlanView> = AgentPlanService::new(state.infra.db.clone())
        .list_pending(&session.user_id)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(serde_json::json!({ "items": plans })))
}

#[derive(Deserialize)]
pub struct ConfirmPlanRequest {
    pub confirmation_token: String,
}

/// POST /api/agent/plans/{id}/confirm — execute a proposed action.
pub async fn confirm_plan(
    State(state): State<AppState>,
    Session(session): Session,
    Path(plan_id): Path<Uuid>,
    Json(payload): Json<ConfirmPlanRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    // Execution reuses the exact tool context an agent run would have used, so
    // ownership/campus/state validation inside the execute bodies applies
    // unchanged.
    let ctx = crate::agents::tools::ToolContext {
        db_pool: state.infra.db.clone(),
        current_user_id: Some(session.user_id.clone()),
        current_campus_id: session.campus_id,
        notification: state.infra.notification.clone(),
    };

    let outcome = AgentPlanService::new(state.infra.db.clone())
        .confirm(&ctx, &session.user_id, plan_id, &payload.confirmation_token)
        .await
        .map_err(ApiError::Internal)?;

    match outcome {
        ConfirmOutcome::Executed(result) => Ok(Json(serde_json::json!({
            "status": "executed",
            "result": result,
        }))),
        ConfirmOutcome::NeedsSecondConfirmation => Ok(Json(serde_json::json!({
            "status": "needs_second_confirmation",
        }))),
        // Idempotent re-confirm: same terminal answer, no second execution.
        ConfirmOutcome::AlreadyExecuted(result) => Ok(Json(serde_json::json!({
            "status": "executed",
            "result": result,
        }))),
        ConfirmOutcome::Failed(message) => {
            Err(ApiError::Conflict(format!("操作执行失败：{}", message)))
        }
        ConfirmOutcome::Expired => Err(ApiError::Conflict(
            "该操作已过期，请重新向小帮发起".to_string(),
        )),
        ConfirmOutcome::NotConfirmable(status) => Err(ApiError::Conflict(format!(
            "该操作当前状态为 {}，无法确认",
            status
        ))),
        ConfirmOutcome::NotFound => Err(ApiError::NotFound),
    }
}

/// POST /api/agent/plans/{id}/cancel — discard a proposed action.
pub async fn cancel_plan(
    State(state): State<AppState>,
    Session(session): Session,
    Path(plan_id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let cancelled = AgentPlanService::new(state.infra.db.clone())
        .cancel(&session.user_id, plan_id)
        .await
        .map_err(ApiError::Internal)?;
    if !cancelled {
        return Err(ApiError::NotFound);
    }
    Ok(Json(serde_json::json!({ "status": "cancelled" })))
}
