//! Agent ActionPlan lifecycle: create, list, confirm-and-execute, cancel.
//!
//! The trust boundary this enforces: the model proposes, the human disposes.
//! A plan's confirmation token travels only through the authenticated plans
//! API — it is never placed in model-visible text — so no amount of prompt
//! injection lets the model confirm the action it just proposed. Execution
//! re-runs the full validation the direct tool path used to run (ownership,
//! campus membership, listing state, price bounds), so a confirmed plan whose
//! world has changed fails safely instead of executing against stale state.

use sqlx::{PgPool, Row};
use uuid::Uuid;

use crate::agents::tools::{
    execute_create_listing, execute_delete_listing, execute_negotiate_item, execute_purchase_item,
    execute_update_listing, ToolContext, ToolError,
};

/// How long a pending plan stays confirmable.
const PLAN_TTL_MINUTES: i64 = 10;

#[derive(Debug, Clone, serde::Serialize)]
pub struct AgentPlanView {
    pub id: Uuid,
    pub action: String,
    pub risk_level: String,
    pub summary: String,
    pub status: String,
    pub args: serde_json::Value,
    /// Single-use secret proving the confirmer saw the plan through the
    /// authenticated API rather than through model output.
    pub confirmation_token: String,
    pub expires_at: chrono::DateTime<chrono::Utc>,
    pub result: Option<String>,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug)]
pub enum ConfirmOutcome {
    /// Plan executed; contains the execution result text.
    Executed(String),
    /// First confirmation of an L3 plan accepted; a second confirmation is
    /// required before execution.
    NeedsSecondConfirmation,
    /// Plan had already been executed; contains the recorded result.
    AlreadyExecuted(String),
    /// The underlying action failed validation or execution.
    Failed(String),
    /// Plan expired before confirmation.
    Expired,
    /// Plan is cancelled, currently executing elsewhere, or otherwise not
    /// confirmable.
    NotConfirmable(String),
    /// Wrong token, wrong user or unknown plan — deliberately one variant so
    /// responses don't reveal which part was wrong.
    NotFound,
}

pub struct AgentPlanService {
    db: PgPool,
}

impl AgentPlanService {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    /// Persist a pending plan and return its id.
    pub async fn create_plan(
        &self,
        campus_id: Uuid,
        user_id: &str,
        action: &str,
        risk_level: &str,
        args: &serde_json::Value,
        summary: &str,
    ) -> anyhow::Result<Uuid> {
        let token = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
        let id: Uuid = sqlx::query_scalar(
            "INSERT INTO agent_action_plans (
                campus_id, user_id, action, risk_level, args, summary,
                confirmation_token, expires_at
             ) VALUES ($1, $2, $3, $4, $5, $6, $7, NOW() + make_interval(mins => $8::int))
             RETURNING id",
        )
        .bind(campus_id)
        .bind(user_id)
        .bind(action)
        .bind(risk_level)
        .bind(args)
        .bind(summary)
        .bind(&token)
        .bind(PLAN_TTL_MINUTES as i32)
        .fetch_one(&self.db)
        .await?;
        Ok(id)
    }

    /// Pending (unexpired) plans for a user, most recent first.
    pub async fn list_pending(&self, user_id: &str) -> anyhow::Result<Vec<AgentPlanView>> {
        let rows = sqlx::query(
            "SELECT id, action, risk_level, summary, status, args, confirmation_token,
                    expires_at, result, created_at
             FROM agent_action_plans
             WHERE user_id = $1 AND status IN ('pending', 'confirmed_once') AND expires_at > NOW()
             ORDER BY created_at DESC
             LIMIT 20",
        )
        .bind(user_id)
        .fetch_all(&self.db)
        .await?;
        Ok(rows.into_iter().map(row_to_view).collect())
    }

    /// Cancel a pending plan. Idempotent-ish: cancelling twice is an error the
    /// caller can surface as "nothing to cancel".
    pub async fn cancel(&self, user_id: &str, plan_id: Uuid) -> anyhow::Result<bool> {
        let updated = sqlx::query(
            "UPDATE agent_action_plans
             SET status = 'cancelled', updated_at = NOW()
             WHERE id = $1 AND user_id = $2 AND status IN ('pending', 'confirmed_once')",
        )
        .bind(plan_id)
        .bind(user_id)
        .execute(&self.db)
        .await?;
        Ok(updated.rows_affected() > 0)
    }

    /// Confirm and execute a plan.
    ///
    /// The pending→executing transition is a conditional UPDATE, so exactly
    /// one of any number of concurrent confirms claims the plan — the action
    /// itself can never run twice.
    pub async fn confirm(
        &self,
        ctx: &ToolContext,
        user_id: &str,
        plan_id: Uuid,
        token: &str,
    ) -> anyhow::Result<ConfirmOutcome> {
        // Read first to distinguish outcomes without leaking other users' plans.
        let row = sqlx::query(
            "SELECT status, risk_level, action, args, confirmation_token, expires_at, result
             FROM agent_action_plans WHERE id = $1 AND user_id = $2",
        )
        .bind(plan_id)
        .bind(user_id)
        .fetch_optional(&self.db)
        .await?;
        let Some(row) = row else {
            return Ok(ConfirmOutcome::NotFound);
        };
        let stored_token: String = row.get("confirmation_token");
        if !constant_time_eq(stored_token.as_bytes(), token.as_bytes()) {
            return Ok(ConfirmOutcome::NotFound);
        }
        let status: String = row.get("status");
        let risk_level: String = row.get("risk_level");
        match status.as_str() {
            "executed" => {
                let result: Option<String> = row.get("result");
                return Ok(ConfirmOutcome::AlreadyExecuted(result.unwrap_or_default()));
            }
            "pending" | "confirmed_once" => {}
            other => {
                return Ok(ConfirmOutcome::NotConfirmable(other.to_string()));
            }
        }
        let expires_at: chrono::DateTime<chrono::Utc> = row.get("expires_at");
        if expires_at <= chrono::Utc::now() {
            sqlx::query(
                "UPDATE agent_action_plans SET status = 'expired', updated_at = NOW()
                 WHERE id = $1 AND status IN ('pending', 'confirmed_once')",
            )
            .bind(plan_id)
            .execute(&self.db)
            .await?;
            return Ok(ConfirmOutcome::Expired);
        }

        // High-risk (L3) actions take two confirmations: the first only arms
        // the plan. Both transitions are conditional updates, so concurrent
        // confirms cannot skip a step or execute twice.
        if risk_level == "L3" && status == "pending" {
            let armed = sqlx::query(
                "UPDATE agent_action_plans
                 SET status = 'confirmed_once', updated_at = NOW()
                 WHERE id = $1 AND status = 'pending' AND expires_at > NOW()",
            )
            .bind(plan_id)
            .execute(&self.db)
            .await?;
            if armed.rows_affected() == 0 {
                return Ok(ConfirmOutcome::NotConfirmable("executing".to_string()));
            }
            return Ok(ConfirmOutcome::NeedsSecondConfirmation);
        }

        // Claim: only one concurrent confirm wins this transition. L2 claims
        // from 'pending'; L3 claims from 'confirmed_once'.
        let claim_from = if risk_level == "L3" {
            "confirmed_once"
        } else {
            "pending"
        };
        let claimed = sqlx::query(
            "UPDATE agent_action_plans
             SET status = 'executing', updated_at = NOW()
             WHERE id = $1 AND status = $2 AND expires_at > NOW()",
        )
        .bind(plan_id)
        .bind(claim_from)
        .execute(&self.db)
        .await?;
        if claimed.rows_affected() == 0 {
            return Ok(ConfirmOutcome::NotConfirmable("executing".to_string()));
        }

        let action: String = row.get("action");
        let args: serde_json::Value = row.get("args");
        let execution = execute_action(ctx, &action, args).await;

        match execution {
            Ok(result) => {
                sqlx::query(
                    "UPDATE agent_action_plans
                     SET status = 'executed', executed_at = NOW(), result = $2, updated_at = NOW()
                     WHERE id = $1",
                )
                .bind(plan_id)
                .bind(&result)
                .execute(&self.db)
                .await?;
                Ok(ConfirmOutcome::Executed(result))
            }
            Err(error) => {
                let message = error.to_string();
                sqlx::query(
                    "UPDATE agent_action_plans
                     SET status = 'failed', result = $2, updated_at = NOW()
                     WHERE id = $1",
                )
                .bind(plan_id)
                .bind(&message)
                .execute(&self.db)
                .await?;
                Ok(ConfirmOutcome::Failed(message))
            }
        }
    }
}

/// Route a confirmed plan to its validated execution body.
async fn execute_action(
    ctx: &ToolContext,
    action: &str,
    args: serde_json::Value,
) -> Result<String, ToolError> {
    fn parse<T: serde::de::DeserializeOwned>(args: serde_json::Value) -> Result<T, ToolError> {
        serde_json::from_value(args).map_err(|e| ToolError(format!("计划参数已失效: {}", e)))
    }
    match action {
        // Still routed so plans created before create_listing became an
        // immediate (undoable) L2 action can finish executing.
        "create_listing" => execute_create_listing(ctx, parse(args)?)
            .await
            .map(|created| created.message),
        "update_listing" => execute_update_listing(ctx, parse(args)?).await,
        "delete_listing" => execute_delete_listing(ctx, parse(args)?).await,
        "purchase_item" => execute_purchase_item(ctx, parse(args)?).await,
        "negotiate_item" => execute_negotiate_item(ctx, parse(args)?).await,
        other => Err(ToolError(format!("未知的计划动作: {}", other))),
    }
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

fn row_to_view(row: sqlx::postgres::PgRow) -> AgentPlanView {
    AgentPlanView {
        id: row.get("id"),
        action: row.get("action"),
        risk_level: row.get("risk_level"),
        summary: row.get("summary"),
        status: row.get("status"),
        args: row.get("args"),
        confirmation_token: row.get("confirmation_token"),
        expires_at: row.get("expires_at"),
        result: row.get("result"),
        created_at: row.get("created_at"),
    }
}
