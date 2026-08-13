//! Tenant-scoped AgentRun observability.
//!
//! AgentRun is deliberately a safe envelope, not a transcript store.  It ties
//! a request's route, provider/version metadata, bounded retrieval facts and
//! typed outcome to the request trace ID.  Prompt text, model transcripts,
//! confirmation tokens, full tool arguments and provider error bodies never
//! enter this service.

use chrono::{DateTime, Utc};
use serde::Serialize;
use sqlx::{PgPool, Row};
use uuid::Uuid;

pub const PROMPT_TEMPLATE_VERSION: &str = "marketplace-prompt-v1";
pub const TOOL_SCHEMA_VERSION: &str = "marketplace-tools-v1";

#[derive(Clone)]
pub struct AgentRunService {
    db: PgPool,
}

#[derive(Debug, Clone, Serialize)]
pub struct AgentRunView {
    pub id: Uuid,
    pub trace_id: String,
    pub conversation_id: String,
    pub route: String,
    pub route_confidence: Option<f32>,
    pub provider: Option<String>,
    pub model: Option<String>,
    pub prompt_template_version: String,
    pub tool_schema_version: String,
    pub status: String,
    pub outcome_code: Option<String>,
    pub retrieval_count: Option<i32>,
    pub retrieval_filtered_count: Option<i32>,
    pub tool_call_count: i32,
    pub final_resource_ids: serde_json::Value,
    pub ttft_ms: Option<i32>,
    pub duration_ms: Option<i32>,
    pub created_at: DateTime<Utc>,
    pub completed_at: Option<DateTime<Utc>>,
}

impl AgentRunService {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    /// Start one run per server request trace.  A retry that somehow reuses a
    /// trace ID receives the original run instead of creating a duplicate.
    #[allow(clippy::too_many_arguments)]
    pub async fn start(
        &self,
        trace_id: &str,
        campus_id: Uuid,
        user_id: &str,
        conversation_id: &str,
        route: &str,
        route_confidence: f32,
        provider: Option<&str>,
        model: Option<&str>,
    ) -> anyhow::Result<Uuid> {
        let mut tx = self.db.begin().await?;
        let inserted: Option<Uuid> = sqlx::query_scalar(
            "INSERT INTO agent_runs (
                trace_id, campus_id, user_id, conversation_id, route,
                route_confidence, provider, model,
                prompt_template_version, tool_schema_version
             ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
             ON CONFLICT (trace_id) DO NOTHING
             RETURNING id",
        )
        .bind(trace_id)
        .bind(campus_id)
        .bind(user_id)
        .bind(conversation_id)
        .bind(route)
        .bind(route_confidence)
        .bind(provider)
        .bind(model)
        .bind(PROMPT_TEMPLATE_VERSION)
        .bind(TOOL_SCHEMA_VERSION)
        .fetch_optional(&mut *tx)
        .await?;

        if let Some(run_id) = inserted {
            insert_event(
                &mut tx,
                EventRecord {
                    run_id,
                    trace_id,
                    campus_id,
                    user_id,
                    event_type: "route",
                    tool_name: None,
                    risk_level: None,
                    outcome_code: Some(route),
                    duration_ms: None,
                    result_count: None,
                    filtered_count: None,
                    resource_ids: serde_json::json!([]),
                    metadata: serde_json::json!({
                        "route_confidence": route_confidence,
                    }),
                },
            )
            .await?;
            tx.commit().await?;
            return Ok(run_id);
        }

        let existing: Option<Uuid> = sqlx::query_scalar(
            "SELECT id
             FROM agent_runs
             WHERE trace_id = $1 AND campus_id = $2 AND user_id = $3",
        )
        .bind(trace_id)
        .bind(campus_id)
        .bind(user_id)
        .fetch_optional(&mut *tx)
        .await?;
        let Some(run_id) = existing else {
            anyhow::bail!("AgentRun trace collision");
        };
        tx.commit().await?;
        Ok(run_id)
    }

    /// Record a bounded retrieval result and the IDs of the resources exposed
    /// by that retrieval.  A missing run is non-fatal for legacy/direct tool
    /// calls, so callers can keep the business path available during rollout.
    #[allow(clippy::too_many_arguments)]
    pub async fn record_retrieval(
        &self,
        trace_id: &str,
        campus_id: Uuid,
        user_id: &str,
        tool_name: &str,
        result_count: i32,
        filtered_count: Option<i32>,
        resource_ids: Vec<String>,
    ) -> anyhow::Result<bool> {
        let mut tx = self.db.begin().await?;
        let run_id: Option<Uuid> = sqlx::query_scalar(
            "SELECT id FROM agent_runs
             WHERE trace_id = $1 AND campus_id = $2 AND user_id = $3
             FOR UPDATE",
        )
        .bind(trace_id)
        .bind(campus_id)
        .bind(user_id)
        .fetch_optional(&mut *tx)
        .await?;
        let Some(run_id) = run_id else {
            tx.commit().await?;
            return Ok(false);
        };

        let resource_ids = serde_json::Value::Array(
            resource_ids
                .into_iter()
                .map(serde_json::Value::String)
                .collect(),
        );
        let updated = sqlx::query(
            "UPDATE agent_runs
             SET retrieval_count = COALESCE(retrieval_count, 0) + $2,
                 retrieval_filtered_count = CASE
                     WHEN $3::int IS NULL THEN retrieval_filtered_count
                     ELSE COALESCE(retrieval_filtered_count, 0) + $3
                 END,
                 final_resource_ids = $4,
                 updated_at = NOW()
             WHERE id = $1 AND status = 'started'",
        )
        .bind(run_id)
        .bind(result_count)
        .bind(filtered_count)
        .bind(&resource_ids)
        .execute(&mut *tx)
        .await?;
        if updated.rows_affected() == 0 {
            tx.commit().await?;
            return Ok(false);
        }
        insert_event(
            &mut tx,
            EventRecord {
                run_id,
                trace_id,
                campus_id,
                user_id,
                event_type: "retrieval",
                tool_name: Some(tool_name),
                risk_level: Some("L1"),
                outcome_code: Some("retrieved"),
                duration_ms: None,
                result_count: Some(result_count),
                filtered_count,
                resource_ids,
                metadata: serde_json::json!({}),
            },
        )
        .await?;
        tx.commit().await?;
        Ok(true)
    }

    /// Record a safe tool event without copying the tool's arguments or
    /// response.  ActionPlan writes remain additionally covered by their
    /// stronger transactional action audit.
    pub async fn record_tool(
        &self,
        trace_id: &str,
        campus_id: Uuid,
        user_id: &str,
        tool_name: &str,
        risk_level: Option<&str>,
        outcome_code: &str,
    ) -> anyhow::Result<bool> {
        let mut tx = self.db.begin().await?;
        let run_id: Option<Uuid> = sqlx::query_scalar(
            "SELECT id FROM agent_runs
             WHERE trace_id = $1 AND campus_id = $2 AND user_id = $3
             FOR UPDATE",
        )
        .bind(trace_id)
        .bind(campus_id)
        .bind(user_id)
        .fetch_optional(&mut *tx)
        .await?;
        let Some(run_id) = run_id else {
            tx.commit().await?;
            return Ok(false);
        };
        let updated = sqlx::query(
            "UPDATE agent_runs
             SET tool_call_count = tool_call_count + 1, updated_at = NOW()
             WHERE id = $1 AND status = 'started'",
        )
        .bind(run_id)
        .execute(&mut *tx)
        .await?;
        if updated.rows_affected() == 0 {
            tx.commit().await?;
            return Ok(false);
        }
        insert_event(
            &mut tx,
            EventRecord {
                run_id,
                trace_id,
                campus_id,
                user_id,
                event_type: "tool",
                tool_name: Some(tool_name),
                risk_level,
                outcome_code: Some(outcome_code),
                duration_ms: None,
                result_count: None,
                filtered_count: None,
                resource_ids: serde_json::json!([]),
                metadata: serde_json::json!({}),
            },
        )
        .await?;
        tx.commit().await?;
        Ok(true)
    }

    /// Record the time until the first streamed token becomes available.  The
    /// value is intentionally write-once: retries or later chunks cannot
    /// replace the first-token measurement, and a run that has already
    /// reached a terminal state cannot be mutated by a late stream callback.
    pub async fn record_ttft(
        &self,
        trace_id: &str,
        campus_id: Uuid,
        user_id: &str,
        ttft_ms: i32,
    ) -> anyhow::Result<bool> {
        let updated = sqlx::query(
            "UPDATE agent_runs
             SET ttft_ms = $4, updated_at = NOW()
             WHERE trace_id = $1 AND campus_id = $2 AND user_id = $3
               AND status = 'started' AND ttft_ms IS NULL",
        )
        .bind(trace_id)
        .bind(campus_id)
        .bind(user_id)
        .bind(ttft_ms.max(0))
        .execute(&self.db)
        .await?;
        Ok(updated.rows_affected() == 1)
    }

    /// Finish a run with a stable outcome category.  Full provider errors are
    /// logged server-side by the caller, while only a bounded error code is
    /// persisted here.
    #[allow(clippy::too_many_arguments)]
    pub async fn finish(
        &self,
        trace_id: &str,
        campus_id: Uuid,
        user_id: &str,
        status: &str,
        outcome_code: &str,
        error_code: Option<&str>,
        duration_ms: Option<i32>,
    ) -> anyhow::Result<bool> {
        self.finish_with_usage(
            trace_id,
            campus_id,
            user_id,
            status,
            outcome_code,
            error_code,
            None,
            None,
            duration_ms,
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn finish_with_usage(
        &self,
        trace_id: &str,
        campus_id: Uuid,
        user_id: &str,
        status: &str,
        outcome_code: &str,
        error_code: Option<&str>,
        token_input: Option<i32>,
        token_output: Option<i32>,
        duration_ms: Option<i32>,
    ) -> anyhow::Result<bool> {
        let mut tx = self.db.begin().await?;
        let run_id: Option<Uuid> = sqlx::query_scalar(
            "UPDATE agent_runs
             SET status = $4, outcome_code = $5, error_code = $6,
                 token_input = $7, token_output = $8,
                 duration_ms = $9,
                 completed_at = CASE WHEN $4 IN ('completed', 'failed', 'cancelled')
                                     THEN NOW() ELSE completed_at END,
                 updated_at = NOW()
             WHERE trace_id = $1 AND campus_id = $2 AND user_id = $3
               AND status = 'started'
             RETURNING id",
        )
        .bind(trace_id)
        .bind(campus_id)
        .bind(user_id)
        .bind(status)
        .bind(outcome_code)
        .bind(error_code)
        .bind(token_input)
        .bind(token_output)
        .bind(duration_ms)
        .fetch_optional(&mut *tx)
        .await?;
        let Some(run_id) = run_id else {
            tx.commit().await?;
            return Ok(false);
        };
        insert_event(
            &mut tx,
            EventRecord {
                run_id,
                trace_id,
                campus_id,
                user_id,
                event_type: "outcome",
                tool_name: None,
                risk_level: None,
                outcome_code: Some(outcome_code),
                duration_ms,
                result_count: None,
                filtered_count: None,
                resource_ids: serde_json::json!([]),
                metadata: serde_json::json!({
                    "error": error_code.is_some(),
                }),
            },
        )
        .await?;
        tx.commit().await?;
        Ok(true)
    }

    /// Close a run that no longer has a live streaming consumer.  This is a
    /// narrow semantic wrapper around `finish` so callers cannot accidentally
    /// turn a disconnect reconciliation into a successful outcome.
    pub async fn cancel_started(
        &self,
        trace_id: &str,
        campus_id: Uuid,
        user_id: &str,
        error_code: Option<&str>,
        duration_ms: Option<i32>,
    ) -> anyhow::Result<bool> {
        self.finish(
            trace_id,
            campus_id,
            user_id,
            "cancelled",
            "cancelled",
            error_code,
            duration_ms,
        )
        .await
    }

    /// Reconcile abandoned runs after a process restart or a lost request
    /// task. The caller supplies a cutoff so the worker can keep a generous
    /// grace period; row locks and `SKIP LOCKED` make this safe across replicas.
    pub async fn reconcile_stale_started(
        &self,
        cutoff: DateTime<Utc>,
        limit: i64,
    ) -> anyhow::Result<usize> {
        let mut tx = self.db.begin().await?;
        let rows = sqlx::query(
            "WITH candidates AS (
                 SELECT id
                 FROM agent_runs
                 WHERE status = 'started' AND updated_at < $1
                 ORDER BY updated_at ASC
                 LIMIT $2
                 FOR UPDATE SKIP LOCKED
             )
             UPDATE agent_runs AS run
             SET status = 'cancelled',
                 outcome_code = 'cancelled',
                 error_code = 'stale_reconciliation',
                 duration_ms = GREATEST(
                     0,
                     LEAST(
                         2147483647,
                         (EXTRACT(EPOCH FROM (NOW() - run.created_at)) * 1000)::bigint
                     )
                 )::int,
                 completed_at = NOW(),
                 updated_at = NOW()
             FROM candidates
             WHERE run.id = candidates.id
             RETURNING run.id, run.trace_id, run.campus_id, run.user_id,
                       run.duration_ms",
        )
        .bind(cutoff)
        .bind(limit.clamp(1, 500))
        .fetch_all(&mut *tx)
        .await?;

        for row in &rows {
            let run_id: Uuid = row.get("id");
            let trace_id: String = row.get("trace_id");
            let campus_id: Uuid = row.get("campus_id");
            let user_id: String = row.get("user_id");
            let duration_ms: Option<i32> = row.get("duration_ms");
            insert_event(
                &mut tx,
                EventRecord {
                    run_id,
                    trace_id: &trace_id,
                    campus_id,
                    user_id: &user_id,
                    event_type: "outcome",
                    tool_name: None,
                    risk_level: None,
                    outcome_code: Some("cancelled"),
                    duration_ms,
                    result_count: None,
                    filtered_count: None,
                    resource_ids: serde_json::json!([]),
                    metadata: serde_json::json!({ "reconciled": true }),
                },
            )
            .await?;
        }
        tx.commit().await?;
        Ok(rows.len())
    }

    pub async fn list_recent(
        &self,
        user_id: &str,
        campus_id: Uuid,
        limit: i64,
    ) -> anyhow::Result<Vec<AgentRunView>> {
        let limit = limit.clamp(1, 50);
        let rows = sqlx::query(
            "SELECT id, trace_id, conversation_id, route, route_confidence,
                    provider, model, prompt_template_version,
                    tool_schema_version, status, outcome_code,
                    retrieval_count, retrieval_filtered_count, tool_call_count,
                    final_resource_ids, ttft_ms, duration_ms, created_at,
                    completed_at
             FROM agent_runs
             WHERE user_id = $1 AND campus_id = $2
             ORDER BY created_at DESC
             LIMIT $3",
        )
        .bind(user_id)
        .bind(campus_id)
        .bind(limit)
        .fetch_all(&self.db)
        .await?;
        Ok(rows.into_iter().map(row_to_view).collect())
    }
}

struct EventRecord<'a> {
    run_id: Uuid,
    trace_id: &'a str,
    campus_id: Uuid,
    user_id: &'a str,
    event_type: &'a str,
    tool_name: Option<&'a str>,
    risk_level: Option<&'a str>,
    outcome_code: Option<&'a str>,
    duration_ms: Option<i32>,
    result_count: Option<i32>,
    filtered_count: Option<i32>,
    resource_ids: serde_json::Value,
    metadata: serde_json::Value,
}

async fn insert_event(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    event: EventRecord<'_>,
) -> anyhow::Result<()> {
    sqlx::query(
        "INSERT INTO agent_run_events (
            run_id, trace_id, campus_id, user_id, event_type, tool_name,
            risk_level, outcome_code, duration_ms, result_count,
            filtered_count, resource_ids, metadata
         ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)",
    )
    .bind(event.run_id)
    .bind(event.trace_id)
    .bind(event.campus_id)
    .bind(event.user_id)
    .bind(event.event_type)
    .bind(event.tool_name)
    .bind(event.risk_level)
    .bind(event.outcome_code)
    .bind(event.duration_ms)
    .bind(event.result_count)
    .bind(event.filtered_count)
    .bind(event.resource_ids)
    .bind(event.metadata)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

fn row_to_view(row: sqlx::postgres::PgRow) -> AgentRunView {
    AgentRunView {
        id: row.get("id"),
        trace_id: row.get("trace_id"),
        conversation_id: row.get("conversation_id"),
        route: row.get("route"),
        route_confidence: row.get("route_confidence"),
        provider: row.get("provider"),
        model: row.get("model"),
        prompt_template_version: row.get("prompt_template_version"),
        tool_schema_version: row.get("tool_schema_version"),
        status: row.get("status"),
        outcome_code: row.get("outcome_code"),
        retrieval_count: row.get("retrieval_count"),
        retrieval_filtered_count: row.get("retrieval_filtered_count"),
        tool_call_count: row.get("tool_call_count"),
        final_resource_ids: row.get("final_resource_ids"),
        ttft_ms: row.get("ttft_ms"),
        duration_ms: row.get("duration_ms"),
        created_at: row.get("created_at"),
        completed_at: row.get("completed_at"),
    }
}
