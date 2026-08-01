//! Durable listing-to-document projection worker.

use std::sync::Arc;
use std::time::Duration as StdDuration;

use chrono::{Duration, Utc};
use futures::future::join_all;
use sha2::{Digest, Sha256};
use sqlx::PgPool;

use crate::lifecycle::{sleep_or_shutdown, ShutdownSignal};
use crate::llm::{EmbeddingGenerator, EmbeddingModelMetadata};
use crate::services::embedding_jobs::{
    self, ClaimedEmbeddingJob, CompletionOutcome, FailureOutcome,
};

// Every claimed job starts immediately. Claiming more work than this worker
// can run would consume lease time while jobs wait behind provider I/O.
const CLAIM_LIMIT: i64 = 4;
const LEASE_SECONDS: i64 = 120;

#[derive(sqlx::FromRow)]
struct ListingProjection {
    id: String,
    campus_id: uuid::Uuid,
    title: String,
    category: String,
    brand: String,
    direction: String,
    condition_score: i32,
    defects: String,
    description: String,
    status: String,
    content_revision: i64,
}

/// Stable public representation embedded for marketplace retrieval.
pub fn canonical_listing_text(
    title: &str,
    category: &str,
    brand: &str,
    direction: &str,
    condition_score: i32,
    defects: &str,
    description: &str,
) -> String {
    let defects = serde_json::from_str::<Vec<String>>(defects)
        .ok()
        .and_then(|values| serde_json::to_string(&values).ok())
        .unwrap_or_else(|| defects.trim().to_string());
    format!(
        "title: {title}\ncategory: {category}\nbrand: {brand}\ndirection: {direction}\ncondition: {condition_score}/10\ndefects: {defects}\ndescription: {description}"
    )
}

fn canonical(row: &ListingProjection) -> String {
    canonical_listing_text(
        &row.title,
        &row.category,
        &row.brand,
        &row.direction,
        row.condition_score,
        &row.defects,
        &row.description,
    )
}

async fn load_listing(
    pool: &PgPool,
    id: &str,
) -> anyhow::Result<Option<(ListingProjection, bool)>> {
    let row = sqlx::query_as::<_, ListingProjection>(
        "SELECT id, campus_id, title, category, COALESCE(brand, '') AS brand,
                direction, condition_score, defects, COALESCE(description, '') AS description,
                status, content_revision
         FROM inventory WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await?;
    let Some(row) = row else { return Ok(None) };
    let restricted = sqlx::query_scalar("SELECT listing_has_active_restriction($1)")
        .bind(id)
        .fetch_one(pool)
        .await?;
    Ok(Some((row, restricted)))
}

async fn finalize_projection(
    pool: &PgPool,
    job: &ClaimedEmbeddingJob,
    expected_text: Option<&str>,
    vector: Option<&[f64]>,
    metadata: &EmbeddingModelMetadata,
) -> anyhow::Result<()> {
    let mut tx = pool.begin().await?;
    let row = sqlx::query_as::<_, ListingProjection>(
        "SELECT id, campus_id, title, category, COALESCE(brand, '') AS brand,
                direction, condition_score, defects, COALESCE(description, '') AS description,
                status, content_revision
         FROM inventory WHERE id = $1 FOR UPDATE",
    )
    .bind(&job.listing_id)
    .fetch_optional(&mut *tx)
    .await?;

    let restricted = if row.is_some() {
        sqlx::query_scalar("SELECT listing_has_active_restriction($1)")
            .bind(&job.listing_id)
            .fetch_one(&mut *tx)
            .await?
    } else {
        false
    };

    match row {
        None => {
            sqlx::query("DELETE FROM documents WHERE id = $1")
                .bind(&job.listing_id)
                .execute(&mut *tx)
                .await?;
        }
        Some(row) if row.content_revision == job.desired_revision => {
            let current_text = canonical(&row);
            if row.status != "active" || restricted {
                sqlx::query("DELETE FROM documents WHERE id = $1")
                    .bind(&job.listing_id)
                    .execute(&mut *tx)
                    .await?;
            } else {
                let expected_text = expected_text.ok_or_else(|| {
                    anyhow::anyhow!(
                        "active listing {} reached finalize without canonical text",
                        job.listing_id
                    )
                })?;
                anyhow::ensure!(
                    expected_text == current_text,
                    "listing {} content changed without advancing revision {}",
                    job.listing_id,
                    job.desired_revision
                );
                let vector = vector.ok_or_else(|| {
                    anyhow::anyhow!(
                        "active listing {} reached finalize without an embedding",
                        job.listing_id
                    )
                })?;
                let hash = hex::encode(Sha256::digest(current_text.as_bytes()));
                let document = serde_json::json!({ "id": row.id, "content": current_text });
                let version = format!("listing-canonical-v1:dim-{}", metadata.dimensions);
                sqlx::query(
                    "INSERT INTO documents (
                            id, document, embedded_text, embedding, campus_id, source_revision,
                            content_hash, embedding_provider, embedding_model, embedding_version, embedded_at
                         ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NOW())
                         ON CONFLICT (id) DO UPDATE SET
                            document = EXCLUDED.document, embedded_text = EXCLUDED.embedded_text,
                            embedding = EXCLUDED.embedding, campus_id = EXCLUDED.campus_id,
                            source_revision = EXCLUDED.source_revision, content_hash = EXCLUDED.content_hash,
                            embedding_provider = EXCLUDED.embedding_provider,
                            embedding_model = EXCLUDED.embedding_model,
                            embedding_version = EXCLUDED.embedding_version, embedded_at = EXCLUDED.embedded_at
                         WHERE documents.source_revision IS NULL
                            OR documents.source_revision <= EXCLUDED.source_revision",
                )
                .bind(&job.listing_id)
                .bind(document)
                .bind(&current_text)
                .bind(vector)
                .bind(row.campus_id)
                .bind(row.content_revision)
                .bind(hash)
                .bind(metadata.provider)
                .bind(metadata.model)
                .bind(version)
                .execute(&mut *tx)
                .await?;
            }
        }
        Some(_) => {}
    }
    tx.commit().await?;
    Ok(())
}

pub async fn process_claimed_job(
    pool: &PgPool,
    worker_id: &str,
    job: &ClaimedEmbeddingJob,
    generator: &dyn EmbeddingGenerator,
    metadata: &EmbeddingModelMetadata,
) -> anyhow::Result<()> {
    let work = async {
        match load_listing(pool, &job.listing_id).await? {
            None => finalize_projection(pool, job, None, None, metadata).await?,
            Some((row, restricted)) if row.status != "active" || restricted => {
                finalize_projection(pool, job, None, None, metadata).await?
            }
            Some((row, _)) => {
                let text = canonical(&row);
                let vector = generator.generate(&text).await?;
                anyhow::ensure!(
                    vector.len() == metadata.dimensions,
                    "embedding dimension mismatch"
                );
                finalize_projection(pool, job, Some(&text), Some(&vector), metadata).await?;
            }
        }
        Ok::<_, anyhow::Error>(())
    }
    .await;
    let completed_at = Utc::now();

    match work {
        Ok(()) => match embedding_jobs::mark_succeeded(
            pool,
            &job.listing_id,
            worker_id,
            job.desired_revision,
            completed_at,
        )
        .await?
        {
            CompletionOutcome::Completed => {
                tracing::info!(listing_id = %job.listing_id, revision = job.desired_revision, "embedding projection completed")
            }
            CompletionOutcome::Superseded { desired_revision } => {
                tracing::info!(listing_id = %job.listing_id, claimed_revision = job.desired_revision, desired_revision, "embedding projection superseded and requeued")
            }
            CompletionOutcome::LostLease => {
                tracing::warn!(listing_id = %job.listing_id, "embedding projection completion lost lease")
            }
        },
        Err(error) => match embedding_jobs::mark_failed(
            pool,
            &job.listing_id,
            worker_id,
            job.desired_revision,
            completed_at,
            &error.to_string(),
        )
        .await?
        {
            FailureOutcome::RetryAt(retry_at) => {
                tracing::warn!(listing_id = %job.listing_id, %retry_at, %error, "embedding projection failed; retry scheduled")
            }
            FailureOutcome::DeadLettered => {
                tracing::error!(listing_id = %job.listing_id, %error, "embedding projection dead-lettered")
            }
            FailureOutcome::Superseded { desired_revision } => {
                tracing::info!(listing_id = %job.listing_id, desired_revision, %error, "failed embedding projection was superseded")
            }
            FailureOutcome::LostLease => {
                tracing::warn!(listing_id = %job.listing_id, %error, "failed embedding projection lost lease")
            }
        },
    }
    Ok(())
}

pub async fn run_embedding_worker(
    pool: PgPool,
    generator: Arc<dyn EmbeddingGenerator>,
    metadata: EmbeddingModelMetadata,
    shutdown: ShutdownSignal,
) {
    let worker_id = format!("embedding-{}", uuid::Uuid::new_v4());
    loop {
        match embedding_jobs::claim_batch(
            &pool,
            &worker_id,
            CLAIM_LIMIT,
            Utc::now(),
            Duration::seconds(LEASE_SECONDS),
        )
        .await
        {
            Ok(jobs) => {
                let outcomes = join_all(jobs.iter().map(|job| {
                    process_claimed_job(&pool, &worker_id, job, generator.as_ref(), &metadata)
                }))
                .await;
                for (job, outcome) in jobs.iter().zip(outcomes) {
                    if let Err(error) = outcome {
                        tracing::error!(listing_id = %job.listing_id, %error, "embedding worker bookkeeping failed");
                    }
                }
            }
            Err(error) => tracing::error!(%error, "embedding worker claim failed"),
        }
        if !sleep_or_shutdown(StdDuration::from_secs(1), &shutdown)
            .await
            .should_continue()
        {
            break;
        }
    }
}
