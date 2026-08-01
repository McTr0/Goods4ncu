//! Agent ActionPlan lifecycle: create, list, confirm-and-execute, cancel.
//!
//! The trust boundary this enforces: the model proposes, the human disposes.
//! A plan's confirmation token travels only through the authenticated plans
//! API — it is never placed in model-visible text — so no amount of prompt
//! injection lets the model confirm the action it just proposed. Execution
//! re-runs the full validation the direct tool path used to run (ownership,
//! campus membership, listing state, price bounds), so a confirmed plan whose
//! world has changed fails safely instead of executing against stale state.

use sqlx::{Acquire, PgPool, Postgres, Row, Transaction};
use uuid::Uuid;

use crate::agents::tools::{execute_planned_action_in_tx, ToolContext};

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
    /// Active confirmation capability for the plan's current step. An armed L3
    /// view exposes only its independent step-two capability.
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
    NeedsSecondConfirmation { confirmation_token: String },
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
        let token = new_confirmation_token();
        let second_token = (risk_level == "L3").then(new_confirmation_token);
        let id: Uuid = sqlx::query_scalar(
            "INSERT INTO agent_action_plans (
                campus_id, user_id, action, risk_level, args, summary,
                confirmation_token, second_confirmation_token, expires_at
             ) VALUES (
                $1, $2, $3, $4, $5, $6, $7, $8,
                NOW() + make_interval(mins => $9::int)
             )
             RETURNING id",
        )
        .bind(campus_id)
        .bind(user_id)
        .bind(action)
        .bind(risk_level)
        .bind(args)
        .bind(summary)
        .bind(&token)
        .bind(second_token.as_deref())
        .bind(PLAN_TTL_MINUTES as i32)
        .fetch_one(&self.db)
        .await?;
        Ok(id)
    }

    /// Pending (unexpired) plans for a user in the active campus, most recent first.
    pub async fn list_pending(
        &self,
        user_id: &str,
        campus_id: Uuid,
    ) -> anyhow::Result<Vec<AgentPlanView>> {
        let rows = sqlx::query(
            "SELECT id, action, risk_level, summary, status, args,
                    CASE
                        WHEN risk_level = 'L3' AND status = 'confirmed_once'
                            THEN second_confirmation_token
                        ELSE confirmation_token
                    END AS confirmation_token,
                    expires_at, result, created_at
             FROM agent_action_plans
             WHERE user_id = $1 AND campus_id = $2
               AND status IN ('pending', 'confirmed_once') AND expires_at > NOW()
             ORDER BY created_at DESC
             LIMIT 20",
        )
        .bind(user_id)
        .bind(campus_id)
        .fetch_all(&self.db)
        .await?;
        Ok(rows.into_iter().map(row_to_view).collect())
    }

    /// Cancel a pending plan. Idempotent-ish: cancelling twice is an error the
    /// caller can surface as "nothing to cancel".
    pub async fn cancel(
        &self,
        user_id: &str,
        campus_id: Uuid,
        plan_id: Uuid,
    ) -> anyhow::Result<bool> {
        let updated = sqlx::query(
            "UPDATE agent_action_plans
             SET status = 'cancelled', updated_at = NOW()
             WHERE id = $1 AND user_id = $2 AND campus_id = $3
               AND status IN ('pending', 'confirmed_once')",
        )
        .bind(plan_id)
        .bind(user_id)
        .bind(campus_id)
        .execute(&self.db)
        .await?;
        Ok(updated.rows_affected() > 0)
    }

    /// Confirm and execute a plan.
    ///
    /// The plan row stays locked from token validation through the business
    /// mutation and terminal result. Every database side effect therefore
    /// commits atomically with `executed`, or rolls back to the confirmable state
    /// when the request/process is interrupted before commit.
    pub async fn confirm(
        &self,
        ctx: &ToolContext,
        user_id: &str,
        campus_id: Uuid,
        plan_id: Uuid,
        token: &str,
    ) -> anyhow::Result<ConfirmOutcome> {
        let mut tx = self.db.begin().await?;

        // Serialise every confirmation of this plan. A duplicate primary L3
        // request that waited here observes confirmed_once and replays the same
        // second-step challenge instead of accidentally counting as step two.
        let row = sqlx::query(
            "SELECT status, risk_level, action, args, confirmation_token,
                    second_confirmation_token, expires_at <= NOW() AS is_expired,
                    result
             FROM agent_action_plans
             WHERE id = $1 AND user_id = $2 AND campus_id = $3
             FOR UPDATE",
        )
        .bind(plan_id)
        .bind(user_id)
        .bind(campus_id)
        .fetch_optional(&mut *tx)
        .await?;
        let Some(row) = row else {
            return commit_outcome(tx, ConfirmOutcome::NotFound).await;
        };

        let status: String = row.get("status");
        let risk_level: String = row.get("risk_level");
        let stored_token: String = row.get("confirmation_token");
        let second_token: Option<String> = row.get("second_confirmation_token");
        let primary_matches = constant_time_eq(stored_token.as_bytes(), token.as_bytes());
        let second_matches = second_token
            .as_deref()
            .is_some_and(|stored| constant_time_eq(stored.as_bytes(), token.as_bytes()));

        // The undisclosed second token cannot skip the first L3 confirmation.
        // Terminal states accept either capability so a lost success response is
        // safely replayable with whichever step the client last submitted.
        let token_is_valid = if status == "pending" {
            primary_matches
        } else {
            primary_matches || second_matches
        };
        if !token_is_valid {
            return commit_outcome(tx, ConfirmOutcome::NotFound).await;
        }

        match status.as_str() {
            "executed" => {
                let result: Option<String> = row.get("result");
                return commit_outcome(
                    tx,
                    ConfirmOutcome::AlreadyExecuted(result.unwrap_or_default()),
                )
                .await;
            }
            "pending" | "confirmed_once" => {}
            "expired" => return commit_outcome(tx, ConfirmOutcome::Expired).await,
            other => {
                return commit_outcome(tx, ConfirmOutcome::NotConfirmable(other.to_string())).await;
            }
        }

        let is_expired: bool = row.get("is_expired");
        if is_expired {
            sqlx::query(
                "UPDATE agent_action_plans SET status = 'expired', updated_at = NOW()
                 WHERE id = $1 AND user_id = $2 AND campus_id = $3
                   AND status IN ('pending', 'confirmed_once')",
            )
            .bind(plan_id)
            .bind(user_id)
            .bind(campus_id)
            .execute(&mut *tx)
            .await?;
            return commit_outcome(tx, ConfirmOutcome::Expired).await;
        }

        // High-risk actions use independent capabilities for the two steps. The
        // second capability is returned only after the primary token is accepted.
        if risk_level == "L3" && status == "pending" {
            let second_token = second_token.ok_or_else(|| {
                anyhow::anyhow!("L3 action plan {} is missing its second token", plan_id)
            })?;
            sqlx::query(
                "UPDATE agent_action_plans
                 SET status = 'confirmed_once', first_confirmed_at = NOW(), updated_at = NOW()
                 WHERE id = $1 AND user_id = $2 AND campus_id = $3",
            )
            .bind(plan_id)
            .bind(user_id)
            .bind(campus_id)
            .execute(&mut *tx)
            .await?;
            return commit_outcome(
                tx,
                ConfirmOutcome::NeedsSecondConfirmation {
                    confirmation_token: second_token,
                },
            )
            .await;
        }

        if risk_level == "L3" && status == "confirmed_once" && primary_matches {
            let second_token = second_token.ok_or_else(|| {
                anyhow::anyhow!("L3 action plan {} is missing its second token", plan_id)
            })?;
            return commit_outcome(
                tx,
                ConfirmOutcome::NeedsSecondConfirmation {
                    confirmation_token: second_token,
                },
            )
            .await;
        }

        if risk_level == "L3" && status == "confirmed_once" && !second_matches {
            return commit_outcome(tx, ConfirmOutcome::NotFound).await;
        }
        if risk_level != "L3" && status != "pending" {
            return commit_outcome(tx, ConfirmOutcome::NotConfirmable(status)).await;
        }

        sqlx::query(
            "UPDATE agent_action_plans
             SET status = 'executing',
                 second_confirmed_at = CASE
                     WHEN risk_level = 'L3' THEN NOW()
                     ELSE second_confirmed_at
                 END,
                 updated_at = NOW()
             WHERE id = $1 AND user_id = $2 AND campus_id = $3",
        )
        .bind(plan_id)
        .bind(user_id)
        .bind(campus_id)
        .execute(&mut *tx)
        .await?;

        let action: String = row.get("action");
        let args: serde_json::Value = row.get("args");
        let mut action_savepoint = (&mut tx).begin().await?;
        let execution = execute_planned_action_in_tx(
            ctx,
            &mut action_savepoint,
            user_id,
            campus_id,
            &action,
            args,
        )
        .await;

        match execution {
            Ok(result) => {
                action_savepoint.commit().await?;
                sqlx::query(
                    "UPDATE agent_action_plans
                     SET status = 'executed', executed_at = NOW(), result = $2, updated_at = NOW()
                     WHERE id = $1 AND user_id = $3 AND campus_id = $4
                       AND status = 'executing'",
                )
                .bind(plan_id)
                .bind(&result)
                .bind(user_id)
                .bind(campus_id)
                .execute(&mut *tx)
                .await?;
                commit_outcome(tx, ConfirmOutcome::Executed(result)).await
            }
            Err(error) => {
                action_savepoint.rollback().await?;
                let message = error.to_string();
                sqlx::query(
                    "UPDATE agent_action_plans
                     SET status = 'failed', result = $2, updated_at = NOW()
                     WHERE id = $1 AND user_id = $3 AND campus_id = $4
                       AND status = 'executing'",
                )
                .bind(plan_id)
                .bind(&message)
                .bind(user_id)
                .bind(campus_id)
                .execute(&mut *tx)
                .await?;
                commit_outcome(tx, ConfirmOutcome::Failed(message)).await
            }
        }
    }
}

async fn commit_outcome(
    tx: Transaction<'_, Postgres>,
    outcome: ConfirmOutcome,
) -> anyhow::Result<ConfirmOutcome> {
    tx.commit().await?;
    Ok(outcome)
}

fn new_confirmation_token() -> String {
    format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple())
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
