//! Transactional outbox: durable async side effects.
//!
//! The in-process event channel loses events when the process dies between a
//! committed business transaction and the consumer running. The outbox closes
//! that gap: producers enqueue in the same database transaction as their state
//! change, and [`run_outbox_worker`] dispatches later with retries, exponential
//! backoff and a dead-letter state for events that keep failing.
//!
//! Dispatch is at-least-once — a worker crash after dispatching but before
//! marking processed re-delivers on lease expiry — so every consumer MUST be
//! idempotent. That is a deliberate trade: exactly-once between a database and
//! an external effect does not exist, and at-most-once means silent loss.

use async_trait::async_trait;
use sqlx::{PgPool, Postgres, Row, Transaction};
use std::sync::Arc;
use std::time::Duration;

use crate::lifecycle::{sleep_or_shutdown, ShutdownSignal};

/// Topic for pushing a persisted notification over WebSocket.
pub const TOPIC_NOTIFICATION_PUSH: &str = "notification.push";

/// Interval between claim attempts when the table is drained. Short enough to
/// keep single-instance notification delivery well under the 1s p95 target.
const POLL_INTERVAL: Duration = Duration::from_millis(500);
/// How long a claim holds before other workers may retry the event.
const LEASE_SECS: i64 = 60;
/// Events processed per claim round.
const BATCH_SIZE: i64 = 32;

/// Handles one event. Implementations MUST be idempotent (see module docs).
#[async_trait]
pub trait OutboxDispatcher: Send + Sync {
    async fn dispatch(&self, topic: &str, payload: &serde_json::Value) -> anyhow::Result<()>;
}

/// Enqueue an event inside the caller's transaction, so the event exists if
/// and only if the business change commits.
pub async fn enqueue_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    topic: &str,
    payload: &serde_json::Value,
) -> anyhow::Result<i64> {
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO outbox_events (topic, payload) VALUES ($1, $2) RETURNING id",
    )
    .bind(topic)
    .bind(payload)
    .fetch_one(&mut **tx)
    .await?;
    Ok(id)
}

#[derive(Debug, Clone)]
struct ClaimedEvent {
    id: i64,
    topic: String,
    payload: serde_json::Value,
    attempts: i32,
    max_attempts: i32,
}

/// Claim up to `BATCH_SIZE` due events for this worker.
async fn claim_batch(pool: &PgPool, worker_id: &str) -> anyhow::Result<Vec<ClaimedEvent>> {
    let rows = sqlx::query(
        r#"
        WITH due AS (
            SELECT id FROM outbox_events
            WHERE processed_at IS NULL
              AND dead_lettered_at IS NULL
              AND available_at <= NOW()
              AND (locked_until IS NULL OR locked_until < NOW())
            ORDER BY id
            LIMIT $1
            FOR UPDATE SKIP LOCKED
        )
        UPDATE outbox_events o
        SET locked_by = $2, locked_until = NOW() + make_interval(secs => $3)
        FROM due
        WHERE o.id = due.id
        RETURNING o.id, o.topic, o.payload, o.attempts, o.max_attempts
        "#,
    )
    .bind(BATCH_SIZE)
    .bind(worker_id)
    .bind(LEASE_SECS as f64)
    .fetch_all(pool)
    .await?;

    Ok(rows
        .into_iter()
        .map(|row| ClaimedEvent {
            id: row.get("id"),
            topic: row.get("topic"),
            payload: row.get("payload"),
            attempts: row.get("attempts"),
            max_attempts: row.get("max_attempts"),
        })
        .collect())
}

async fn mark_processed(pool: &PgPool, id: i64) -> anyhow::Result<()> {
    sqlx::query(
        "UPDATE outbox_events
         SET processed_at = NOW(), locked_by = NULL, locked_until = NULL
         WHERE id = $1",
    )
    .bind(id)
    .execute(pool)
    .await?;
    Ok(())
}

/// Record a failure: exponential backoff, or dead-letter once attempts are
/// exhausted. Dead-lettered events stay in the table for audited replay —
/// deleting them would erase the evidence of what was never delivered.
async fn mark_failed(pool: &PgPool, event: &ClaimedEvent, error: &str) -> anyhow::Result<()> {
    let next_attempts = event.attempts + 1;
    if next_attempts >= event.max_attempts {
        sqlx::query(
            "UPDATE outbox_events
             SET attempts = $2, dead_lettered_at = NOW(), last_error = $3,
                 locked_by = NULL, locked_until = NULL
             WHERE id = $1",
        )
        .bind(event.id)
        .bind(next_attempts)
        .bind(error)
        .execute(pool)
        .await?;
        tracing::error!(
            event_id = event.id,
            topic = %event.topic,
            attempts = next_attempts,
            error,
            "Outbox event dead-lettered"
        );
    } else {
        // 2^attempts seconds, capped at 5 minutes.
        let backoff_secs = 2i64.saturating_pow(next_attempts as u32).min(300);
        sqlx::query(
            "UPDATE outbox_events
             SET attempts = $2, available_at = NOW() + make_interval(secs => $3),
                 last_error = $4, locked_by = NULL, locked_until = NULL
             WHERE id = $1",
        )
        .bind(event.id)
        .bind(next_attempts)
        .bind(backoff_secs as f64)
        .bind(error)
        .execute(pool)
        .await?;
        tracing::warn!(
            event_id = event.id,
            topic = %event.topic,
            attempts = next_attempts,
            backoff_secs,
            error,
            "Outbox dispatch failed, backing off"
        );
    }
    Ok(())
}

/// Claim and dispatch one batch. Returns how many events were claimed.
/// Extracted from the loop so tests can drive processing deterministically.
pub async fn process_batch(
    pool: &PgPool,
    worker_id: &str,
    dispatcher: &dyn OutboxDispatcher,
) -> anyhow::Result<usize> {
    let batch = claim_batch(pool, worker_id).await?;
    let claimed = batch.len();
    for event in batch {
        match dispatcher.dispatch(&event.topic, &event.payload).await {
            Ok(()) => mark_processed(pool, event.id).await?,
            Err(error) => mark_failed(pool, &event, &format!("{error:#}")).await?,
        }
    }
    Ok(claimed)
}

/// Reset a dead-lettered event for another delivery attempt. Intended for
/// operator-audited replay after the underlying failure is fixed.
#[allow(dead_code)] // exercised via the lib crate by integration tests and ops tooling
pub async fn replay_dead_lettered(pool: &PgPool, id: i64) -> anyhow::Result<bool> {
    let updated = sqlx::query(
        "UPDATE outbox_events
         SET dead_lettered_at = NULL, attempts = 0, available_at = NOW(),
             locked_by = NULL, locked_until = NULL
         WHERE id = $1 AND dead_lettered_at IS NOT NULL",
    )
    .bind(id)
    .execute(pool)
    .await?;
    Ok(updated.rows_affected() > 0)
}

/// Long-running worker loop. Polls while idle, drains eagerly while busy, and
/// finishes the batch in hand before honouring shutdown — leases make a
/// mid-batch crash safe anyway, but stopping at a batch boundary avoids
/// needless duplicate deliveries on every deploy.
pub async fn run_outbox_worker(
    pool: PgPool,
    dispatcher: Arc<dyn OutboxDispatcher>,
    shutdown: ShutdownSignal,
) {
    let worker_id = format!("outbox-{}", uuid::Uuid::new_v4());
    tracing::info!(worker_id, "Outbox worker started");

    loop {
        let claimed = match process_batch(&pool, &worker_id, dispatcher.as_ref()).await {
            Ok(claimed) => claimed,
            Err(error) => {
                // Missing table (fresh env mid-migration) or transient DB error:
                // stay alive and retry — the worker dying silently would stop
                // all async delivery.
                tracing::warn!(%error, "Outbox batch failed");
                0
            }
        };

        if claimed == 0 {
            if !sleep_or_shutdown(POLL_INTERVAL, &shutdown)
                .await
                .should_continue()
            {
                break;
            }
        } else if shutdown.is_draining() {
            break;
        }
    }

    tracing::info!(worker_id, "Outbox worker stopped");
}
