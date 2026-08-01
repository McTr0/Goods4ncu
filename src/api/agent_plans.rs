//! Agent ActionPlan endpoints: list pending plans, confirm, cancel.
//!
//! This is the human half of the ActionPlan protocol. The confirmation token
//! only ever leaves the server through these authenticated responses — the
//! agent's chat text names the plan but cannot confirm it, so a prompt-injected
//! model has no path to execute its own proposal.

use axum::{
    extract::{Path, State},
    http::{
        header::{CACHE_CONTROL, PRAGMA},
        HeaderValue,
    },
    response::{IntoResponse, Response},
    Json,
};
use serde::Deserialize;
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::api::session::VerifiedTenant;
use crate::api::AppState;
use crate::services::agent_plan::{AgentPlanService, AgentPlanView, ConfirmOutcome};

/// GET /api/agent/plans — the caller's pending plans (with confirmation tokens).
pub async fn list_plans(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
) -> Result<Response, ApiError> {
    let plans: Vec<AgentPlanView> = AgentPlanService::new(state.infra.db.clone())
        .list_pending(&tenant.session.user_id, tenant.campus_id)
        .await
        .map_err(ApiError::Internal)?;
    Ok(no_store_json(serde_json::json!({ "items": plans })))
}

#[derive(Deserialize)]
pub struct ConfirmPlanRequest {
    pub confirmation_token: String,
}

/// POST /api/agent/plans/{id}/confirm — execute a proposed action.
pub async fn confirm_plan(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(plan_id): Path<Uuid>,
    Json(payload): Json<ConfirmPlanRequest>,
) -> Result<Response, ApiError> {
    // Execution reuses the exact tool context an agent run would have used, so
    // ownership/campus/state validation inside the execute bodies applies
    // unchanged.
    let ctx = crate::agents::tools::ToolContext {
        db_pool: state.infra.db.clone(),
        current_user_id: Some(tenant.session.user_id.clone()),
        current_campus_id: Some(tenant.campus_id),
        notification: state.infra.notification.clone(),
    };

    let outcome = AgentPlanService::new(state.infra.db.clone())
        .confirm(
            &ctx,
            &tenant.session.user_id,
            tenant.campus_id,
            plan_id,
            &payload.confirmation_token,
        )
        .await
        .map_err(ApiError::Internal)?;

    match outcome {
        ConfirmOutcome::Executed(result) => Ok(no_store_json(serde_json::json!({
            "status": "executed",
            "result": result,
        }))),
        ConfirmOutcome::NeedsSecondConfirmation { confirmation_token } => {
            Ok(no_store_json(serde_json::json!({
                "status": "needs_second_confirmation",
                "confirmation_token": confirmation_token,
            })))
        }
        // Idempotent re-confirm: same terminal answer, no second execution.
        ConfirmOutcome::AlreadyExecuted(result) => Ok(no_store_json(serde_json::json!({
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

fn no_store_json(value: serde_json::Value) -> Response {
    let mut response = Json(value).into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response
        .headers_mut()
        .insert(PRAGMA, HeaderValue::from_static("no-cache"));
    response
}

/// POST /api/agent/plans/{id}/cancel — discard a proposed action.
pub async fn cancel_plan(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(plan_id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let cancelled = AgentPlanService::new(state.infra.db.clone())
        .cancel(&tenant.session.user_id, tenant.campus_id, plan_id)
        .await
        .map_err(ApiError::Internal)?;
    if !cancelled {
        return Err(ApiError::NotFound);
    }
    Ok(Json(serde_json::json!({ "status": "cancelled" })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_bearing_responses_are_not_cacheable() {
        let response = no_store_json(serde_json::json!({
            "confirmation_token": "secret"
        }));

        assert_eq!(response.headers()[CACHE_CONTROL], "no-store");
        assert_eq!(response.headers()[PRAGMA], "no-cache");
    }
}
