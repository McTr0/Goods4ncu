//! Durable, version-aware listing embedding projection jobs.
//!
//! Claims are at-least-once. A worker must re-read the authoritative listing
//! and restriction state, then conditionally upsert/delete the document for
//! [`ClaimedEmbeddingJob::desired_revision`]. Completion is revision-aware: a
//! listing changed during provider I/O is returned to pending instead of
//! allowing the stale attempt to complete the newer job.

use chrono::{DateTime, Duration, Utc};
use sqlx::{FromRow, PgPool};

#[derive(Debug, Clone, FromRow, PartialEq, Eq)]
pub struct ClaimedEmbeddingJob {
    pub listing_id: String,
    pub campus_id: uuid::Uuid,
    pub desired_revision: i64,
    pub attempts: i32,
    pub max_attempts: i32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CompletionOutcome {
    Completed,
    Superseded { desired_revision: i64 },
    LostLease,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FailureOutcome {
    RetryAt(DateTime<Utc>),
    DeadLettered,
    Superseded { desired_revision: i64 },
    LostLease,
}

/// Claims due pending jobs and processing jobs whose lease expired.
///
/// `now` and `lease` are explicit so retry and lease behavior is deterministic
/// in tests and can share one clock value across a worker batch.
pub async fn claim_batch(
    pool: &PgPool,
    worker_id: &str,
    limit: i64,
    now: DateTime<Utc>,
    lease: Duration,
) -> anyhow::Result<Vec<ClaimedEmbeddingJob>> {
    anyhow::ensure!(limit > 0, "embedding job claim limit must be positive");
    anyhow::ensure!(
        lease > Duration::zero(),
        "embedding job lease must be positive"
    );
    let lease_seconds = lease.num_seconds();

    let jobs = sqlx::query_as::<_, ClaimedEmbeddingJob>(
        r#"
        WITH due AS (
            SELECT listing_id
            FROM embedding_jobs
            WHERE status IN ('pending', 'processing')
              AND available_at <= $1
              AND (status = 'pending' OR locked_until < $1)
            ORDER BY available_at, requested_at, listing_id
            LIMIT $2
            FOR UPDATE SKIP LOCKED
        )
        UPDATE embedding_jobs AS job
        SET status = 'processing',
            locked_by = $3,
            locked_until = $1 + make_interval(secs => $4),
            completed_at = NULL
        FROM due
        WHERE job.listing_id = due.listing_id
        RETURNING job.listing_id, job.campus_id, job.desired_revision,
                  job.attempts, job.max_attempts
        "#,
    )
    .bind(now)
    .bind(limit)
    .bind(worker_id)
    .bind(lease_seconds as f64)
    .fetch_all(pool)
    .await?;

    Ok(jobs)
}

/// Completes the claimed revision. If a trigger advanced the desired revision
/// while the provider call was running, atomically requeues that newest work.
pub async fn mark_succeeded(
    pool: &PgPool,
    listing_id: &str,
    worker_id: &str,
    claimed_revision: i64,
    now: DateTime<Utc>,
) -> anyhow::Result<CompletionOutcome> {
    let desired_revision = sqlx::query_scalar::<_, i64>(
        r#"
        UPDATE embedding_jobs
        SET status = CASE
                WHEN desired_revision = $3 THEN 'completed'
                ELSE 'pending'
            END,
            attempts = CASE WHEN desired_revision = $3 THEN attempts ELSE 0 END,
            available_at = CASE WHEN desired_revision = $3 THEN available_at ELSE $4 END,
            locked_by = NULL,
            locked_until = NULL,
            last_error = NULL,
            completed_at = CASE WHEN desired_revision = $3 THEN $4 ELSE NULL END,
            dead_lettered_at = NULL
        WHERE listing_id = $1
          AND status = 'processing'
          AND locked_by = $2
        RETURNING desired_revision
        "#,
    )
    .bind(listing_id)
    .bind(worker_id)
    .bind(claimed_revision)
    .bind(now)
    .fetch_optional(pool)
    .await?;

    Ok(match desired_revision {
        None => CompletionOutcome::LostLease,
        Some(revision) if revision == claimed_revision => CompletionOutcome::Completed,
        Some(revision) => CompletionOutcome::Superseded {
            desired_revision: revision,
        },
    })
}

/// Records a failed attempt with exponential backoff capped at five minutes.
/// A failure for an already-superseded revision is not charged to the newer
/// revision and makes that newest work immediately claimable.
pub async fn mark_failed(
    pool: &PgPool,
    listing_id: &str,
    worker_id: &str,
    claimed_revision: i64,
    now: DateTime<Utc>,
    error: &str,
) -> anyhow::Result<FailureOutcome> {
    #[derive(FromRow)]
    struct FailureRow {
        desired_revision: i64,
        attempts: i32,
        max_attempts: i32,
    }

    let mut tx = pool.begin().await?;
    let current = sqlx::query_as::<_, FailureRow>(
        r#"
        SELECT desired_revision, attempts, max_attempts
        FROM embedding_jobs
        WHERE listing_id = $1 AND status = 'processing' AND locked_by = $2
        FOR UPDATE
        "#,
    )
    .bind(listing_id)
    .bind(worker_id)
    .fetch_optional(&mut *tx)
    .await?;

    let Some(current) = current else {
        tx.rollback().await?;
        return Ok(FailureOutcome::LostLease);
    };

    if current.desired_revision != claimed_revision {
        sqlx::query(
            "UPDATE embedding_jobs
             SET status = 'pending', attempts = 0, available_at = $3,
                 locked_by = NULL, locked_until = NULL, last_error = NULL,
                 completed_at = NULL, dead_lettered_at = NULL
             WHERE listing_id = $1 AND status = 'processing' AND locked_by = $2",
        )
        .bind(listing_id)
        .bind(worker_id)
        .bind(now)
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        return Ok(FailureOutcome::Superseded {
            desired_revision: current.desired_revision,
        });
    }

    let attempts = current.attempts + 1;
    if attempts >= current.max_attempts {
        sqlx::query(
            "UPDATE embedding_jobs
             SET status = 'dead_lettered', attempts = $3,
                 locked_by = NULL, locked_until = NULL, last_error = $4,
                 completed_at = NULL, dead_lettered_at = $5
             WHERE listing_id = $1 AND status = 'processing' AND locked_by = $2",
        )
        .bind(listing_id)
        .bind(worker_id)
        .bind(attempts)
        .bind(error)
        .bind(now)
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        return Ok(FailureOutcome::DeadLettered);
    }

    let backoff_seconds = 2_i64.saturating_pow(attempts as u32).min(300);
    let retry_at = now + Duration::seconds(backoff_seconds);
    sqlx::query(
        "UPDATE embedding_jobs
         SET status = 'pending', attempts = $3, available_at = $4,
             locked_by = NULL, locked_until = NULL, last_error = $5,
             completed_at = NULL, dead_lettered_at = NULL
         WHERE listing_id = $1 AND status = 'processing' AND locked_by = $2",
    )
    .bind(listing_id)
    .bind(worker_id)
    .bind(attempts)
    .bind(retry_at)
    .bind(error)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;

    Ok(FailureOutcome::RetryAt(retry_at))
}

/// Replays a dead-lettered job without changing its desired revision.
///
/// This is an operator-facing recovery primitive covered by integration tests;
/// the server binary does not invoke it until an admin endpoint/CLI is added.
#[allow(dead_code)]
pub async fn replay_dead_lettered(
    pool: &PgPool,
    listing_id: &str,
    now: DateTime<Utc>,
) -> anyhow::Result<bool> {
    let result = sqlx::query(
        "UPDATE embedding_jobs
         SET status = 'pending', attempts = 0, available_at = $2,
             locked_by = NULL, locked_until = NULL, last_error = NULL,
             completed_at = NULL, dead_lettered_at = NULL, requested_at = $2
         WHERE listing_id = $1 AND status = 'dead_lettered'",
    )
    .bind(listing_id)
    .bind(now)
    .execute(pool)
    .await?;
    Ok(result.rows_affected() == 1)
}
