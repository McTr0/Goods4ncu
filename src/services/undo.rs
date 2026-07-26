//! Undo window for immediately-executed (L2) agent actions.
//!
//! The trade this implements: an up-front confirmation dialog taxes every
//! action to catch the rare wrong one. An undo window charges nothing on the
//! common path and stays recoverable on the rare one. Money and identity (L3)
//! keep their up-front confirmation — see [`crate::services::agent_plan`].
//!
//! Undo is a *conditional* revert. Each registration records `expected_state`
//! (what the action wrote) alongside `prior_state` (what to put back). The
//! revert applies only while the target still holds `expected_state`; once
//! anyone — the owner, a buyer, a moderator — has moved it on, undo refuses
//! with an explanation instead of overwriting newer state with an older
//! snapshot. A blind snapshot restore would silently destroy those changes.
//!
//! Undo is deliberately not an agent tool. It is reachable only through the
//! authenticated API, so a prompt-injected model cannot revert actions the
//! user actually wanted, and there is no undo secret to leak into model
//! context.

use anyhow::Result;
use sqlx::{PgPool, Postgres, Row, Transaction};
use uuid::Uuid;

/// How long an executed L2 action stays undoable.
pub const UNDO_WINDOW_MINUTES: i64 = 5;

/// Action kinds that can be registered. Keeping these as constants (rather
/// than free strings at call sites) means adding a kind without teaching
/// [`apply_inverse`] about it is a compile error away from being caught.
pub mod kinds {
    /// A listing was published. Inverse: retract it.
    pub const LISTING_CREATE: &str = "listing.create";
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct UndoableAction {
    pub id: Uuid,
    pub action_kind: String,
    pub target_type: String,
    pub target_id: String,
    pub summary: String,
    pub undo_deadline: chrono::DateTime<chrono::Utc>,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum UndoOutcome {
    /// The revert applied; contains user-facing text.
    Undone(String),
    /// Already undone; returns the originally recorded result so repeat calls
    /// are indistinguishable from the first.
    AlreadyUndone(String),
    /// The undo window closed.
    Expired,
    /// The target moved on since the action, so reverting would clobber newer
    /// state. Contains the reason to show the user.
    Conflict(String),
    /// Unknown action, or it belongs to someone else. One variant so responses
    /// don't reveal which.
    NotFound,
    /// The revert itself failed.
    Failed(String),
}

pub struct UndoService {
    db: PgPool,
}

impl UndoService {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    /// Record an executed action as undoable.
    ///
    /// Called after the action commits, so a crash in between loses the undo
    /// affordance but never the action — failing towards "it happened and
    /// stands", which is the direction the user already saw confirmed.
    #[allow(clippy::too_many_arguments)]
    pub async fn register(
        &self,
        campus_id: Uuid,
        actor_user_id: &str,
        action_kind: &str,
        target_type: &str,
        target_id: &str,
        summary: &str,
        expected_state: serde_json::Value,
        prior_state: serde_json::Value,
    ) -> Result<Uuid> {
        let id: Uuid = sqlx::query_scalar(
            "INSERT INTO reversible_actions (
                 campus_id, actor_user_id, action_kind, target_type, target_id,
                 summary, expected_state, prior_state, undo_deadline
             ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8,
                       NOW() + make_interval(mins => $9::int))
             RETURNING id",
        )
        .bind(campus_id)
        .bind(actor_user_id)
        .bind(action_kind)
        .bind(target_type)
        .bind(target_id)
        .bind(summary)
        .bind(expected_state)
        .bind(prior_state)
        .bind(UNDO_WINDOW_MINUTES as i32)
        .fetch_one(&self.db)
        .await?;
        Ok(id)
    }

    /// Actions this user can still undo, most recent first.
    pub async fn list_undoable(&self, actor_user_id: &str) -> Result<Vec<UndoableAction>> {
        let rows = sqlx::query(
            "SELECT id, action_kind, target_type, target_id, summary,
                    undo_deadline, created_at
             FROM reversible_actions
             WHERE actor_user_id = $1 AND undone_at IS NULL AND undo_deadline > NOW()
             ORDER BY created_at DESC
             LIMIT 20",
        )
        .bind(actor_user_id)
        .fetch_all(&self.db)
        .await?;

        Ok(rows
            .into_iter()
            .map(|row| UndoableAction {
                id: row.get("id"),
                action_kind: row.get("action_kind"),
                target_type: row.get("target_type"),
                target_id: row.get("target_id"),
                summary: row.get("summary"),
                undo_deadline: row.get("undo_deadline"),
                created_at: row.get("created_at"),
            })
            .collect())
    }

    /// Revert an action.
    ///
    /// The row is locked with `FOR UPDATE` for the whole transaction, so
    /// concurrent undos of the same action serialise: the first applies the
    /// revert, the rest block and then observe `undone_at` set, returning
    /// [`UndoOutcome::AlreadyUndone`]. The revert and the bookkeeping commit
    /// together, so a failed revert leaves the action undoable rather than
    /// marked-undone-but-unchanged.
    pub async fn undo(&self, actor_user_id: &str, action_id: Uuid) -> Result<UndoOutcome> {
        let mut tx = self.db.begin().await?;

        let row = sqlx::query(
            "SELECT action_kind, target_id, undo_deadline, undone_at, undo_result,
                    expected_state, prior_state
             FROM reversible_actions
             WHERE id = $1 AND actor_user_id = $2
             FOR UPDATE",
        )
        .bind(action_id)
        .bind(actor_user_id)
        .fetch_optional(&mut *tx)
        .await?;

        let Some(row) = row else {
            tx.rollback().await?;
            return Ok(UndoOutcome::NotFound);
        };

        let undone_at: Option<chrono::DateTime<chrono::Utc>> = row.get("undone_at");
        if undone_at.is_some() {
            let result: Option<String> = row.get("undo_result");
            tx.rollback().await?;
            return Ok(UndoOutcome::AlreadyUndone(result.unwrap_or_default()));
        }

        let deadline: chrono::DateTime<chrono::Utc> = row.get("undo_deadline");
        if deadline <= chrono::Utc::now() {
            tx.rollback().await?;
            return Ok(UndoOutcome::Expired);
        }

        let action_kind: String = row.get("action_kind");
        let target_id: String = row.get("target_id");
        let expected_state: serde_json::Value = row.get("expected_state");
        let prior_state: serde_json::Value = row.get("prior_state");

        let applied = apply_inverse(
            &mut tx,
            &action_kind,
            actor_user_id,
            &target_id,
            &expected_state,
            &prior_state,
        )
        .await;

        let message = match applied {
            Ok(InverseResult::Applied(message)) => message,
            Ok(InverseResult::Conflict(reason)) => {
                tx.rollback().await?;
                return Ok(UndoOutcome::Conflict(reason));
            }
            Err(error) => {
                tx.rollback().await?;
                return Ok(UndoOutcome::Failed(error.to_string()));
            }
        };

        sqlx::query(
            "UPDATE reversible_actions
             SET undone_at = NOW(), undo_result = $2
             WHERE id = $1",
        )
        .bind(action_id)
        .bind(&message)
        .execute(&mut *tx)
        .await?;

        tx.commit().await?;
        Ok(UndoOutcome::Undone(message))
    }

    /// Drop records past their window. Undone rows are kept for the same
    /// retention as open ones so "I undid that" stays auditable for a while.
    pub async fn prune(&self, retain_days: i64) -> Result<u64> {
        let deleted = sqlx::query(
            "DELETE FROM reversible_actions
             WHERE created_at < NOW() - make_interval(days => $1::int)",
        )
        .bind(retain_days as i32)
        .execute(&self.db)
        .await?;
        Ok(deleted.rows_affected())
    }
}

/// How long undo records are kept after their window closes, so "I undid
/// that" stays answerable for a while.
const RETAIN_DAYS: i64 = 7;

/// Hourly retention sweep for [`reversible_actions`].
///
/// Stops between sweeps rather than being aborted, so a delete is never cut
/// off partway through.
pub async fn run_prune_worker(db_pool: PgPool, shutdown: crate::lifecycle::ShutdownSignal) {
    tracing::info!("Undo retention worker started (interval: 1 h)");
    let mut ticker = tokio::time::interval(std::time::Duration::from_secs(60 * 60));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    let service = UndoService::new(db_pool);
    while crate::lifecycle::tick_or_shutdown(&mut ticker, &shutdown)
        .await
        .should_continue()
    {
        match service.prune(RETAIN_DAYS).await {
            Ok(0) => {}
            Ok(pruned) => tracing::debug!(pruned, "Pruned expired undo records"),
            Err(e) => tracing::error!(%e, "Undo retention sweep failed"),
        }
    }

    tracing::info!("Undo retention worker stopped");
}

enum InverseResult {
    Applied(String),
    Conflict(String),
}

/// Route an action kind to its conditional revert.
///
/// Every arm must guard on `expected_state` before writing. An arm that
/// unconditionally restores `prior_state` is a bug: it would erase whatever
/// happened to the target after the action.
async fn apply_inverse(
    tx: &mut Transaction<'_, Postgres>,
    action_kind: &str,
    actor_user_id: &str,
    target_id: &str,
    expected_state: &serde_json::Value,
    _prior_state: &serde_json::Value,
) -> Result<InverseResult> {
    match action_kind {
        kinds::LISTING_CREATE => {
            // Retract only while the listing is still exactly as published and
            // still owned by the actor. If it sold, was edited into a
            // different state, or was already removed, the guard fails.
            let expected_status = expected_state
                .get("status")
                .and_then(|v| v.as_str())
                .unwrap_or("active");

            let updated = sqlx::query(
                "UPDATE inventory
                 SET status = 'deleted', updated_at = NOW()
                 WHERE id = $1 AND owner_id = $2 AND status = $3",
            )
            .bind(target_id)
            .bind(actor_user_id)
            .bind(expected_status)
            .execute(&mut **tx)
            .await?;

            if updated.rows_affected() == 0 {
                return Ok(InverseResult::Conflict(
                    "这条发布已经有了新的变化（已售出、已修改或已下架），撤销可能覆盖新的改动，因此没有执行。".to_string(),
                ));
            }

            // Keep the vector store consistent so retracted listings stop
            // surfacing in retrieval, mirroring the delete path.
            sqlx::query("DELETE FROM documents WHERE id = $1")
                .bind(target_id)
                .execute(&mut **tx)
                .await?;

            Ok(InverseResult::Applied(format!(
                "已撤销发布，商品 {} 已下架。",
                target_id
            )))
        }
        other => Ok(InverseResult::Conflict(format!(
            "不支持撤销的操作类型: {}",
            other
        ))),
    }
}
