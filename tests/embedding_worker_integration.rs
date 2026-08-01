use async_trait::async_trait;
use chrono::{Duration, Utc};
use goods4ncu::llm::{EmbeddingGenerator, EmbeddingModelMetadata};
use goods4ncu::services::{embedding_jobs, embedding_worker};
use goods4ncu::test_infra::with_test_pool;
use uuid::Uuid;

struct FakeGenerator {
    pool: Option<sqlx::PgPool>,
    mutate_listing: Option<String>,
    fail: bool,
}

#[async_trait]
impl EmbeddingGenerator for FakeGenerator {
    async fn generate(&self, _text: &str) -> anyhow::Result<Vec<f64>> {
        if let (Some(pool), Some(id)) = (&self.pool, &self.mutate_listing) {
            sqlx::query("UPDATE inventory SET title = title || ' changed' WHERE id = $1")
                .bind(id)
                .execute(pool)
                .await?;
        }
        if self.fail {
            anyhow::bail!("forced provider failure");
        }
        Ok(vec![0.25; 768])
    }
}

fn metadata() -> EmbeddingModelMetadata {
    EmbeddingModelMetadata {
        provider: "fake",
        model: "fake-v1",
        dimensions: 768,
    }
}

async fn seed_listing(pool: &sqlx::PgPool, status: &str) -> (String, Uuid, i64) {
    sqlx::query("DELETE FROM embedding_jobs")
        .execute(pool)
        .await
        .unwrap();
    let owner = Uuid::new_v4().to_string();
    sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
        .bind(&owner)
        .bind(format!("embedding-owner-{}", Uuid::new_v4()))
        .execute(pool)
        .await
        .unwrap();
    let campus: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
        .fetch_one(pool)
        .await
        .unwrap();
    let id = Uuid::new_v4().to_string();
    sqlx::query(
        "INSERT INTO inventory (id, campus_id, title, category, brand, direction,
          condition_score, suggested_price_cny, defects, description, owner_id, status)
         VALUES ($1,$2,'Desk','other','Acme','offer',8,10000,'[\"scratch\"]','Solid desk',$3,$4)",
    )
    .bind(&id)
    .bind(campus)
    .bind(owner)
    .bind(status)
    .execute(pool)
    .await
    .unwrap();
    let revision = sqlx::query_scalar("SELECT content_revision FROM inventory WHERE id = $1")
        .bind(&id)
        .fetch_one(pool)
        .await
        .unwrap();
    (id, campus, revision)
}

async fn claim(
    pool: &sqlx::PgPool,
    worker: &str,
    listing_id: &str,
) -> embedding_jobs::ClaimedEmbeddingJob {
    embedding_jobs::claim_batch(pool, worker, 1, Utc::now(), Duration::minutes(2))
        .await
        .unwrap()
        .into_iter()
        .find(|job| job.listing_id == listing_id)
        .expect("embedding job")
}

#[tokio::test]
async fn active_listing_is_upserted_with_projection_metadata() {
    with_test_pool(|pool| async move {
        let (id, campus, revision) = seed_listing(&pool, "active").await;
        let worker = "embedding-active";
        let job = claim(&pool, worker, &id).await;
        embedding_worker::process_claimed_job(
            &pool,
            worker,
            &job,
            &FakeGenerator { pool: None, mutate_listing: None, fail: false },
            &metadata(),
        ).await.unwrap();
        let row = sqlx::query("SELECT campus_id, source_revision, embedded_text, embedding_provider, embedding_model FROM documents WHERE id = $1")
            .bind(&id).fetch_one(&pool).await.unwrap();
        assert_eq!(row.get::<Uuid, _>("campus_id"), campus);
        assert_eq!(row.get::<i64, _>("source_revision"), revision);
        assert!(row.get::<String, _>("embedded_text").contains("title: Desk"));
        assert_eq!(row.get::<String, _>("embedding_provider"), "fake");
        assert_eq!(row.get::<String, _>("embedding_model"), "fake-v1");
    }).await;
}

#[tokio::test]
async fn update_during_provider_call_never_publishes_stale_revision() {
    with_test_pool(|pool| async move {
        let (id, _, old_revision) = seed_listing(&pool, "active").await;
        let worker = "embedding-stale";
        let job = claim(&pool, worker, &id).await;
        embedding_worker::process_claimed_job(
            &pool,
            worker,
            &job,
            &FakeGenerator {
                pool: Some(pool.clone()),
                mutate_listing: Some(id.clone()),
                fail: false,
            },
            &metadata(),
        )
        .await
        .unwrap();
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM documents WHERE id = $1")
            .bind(&id)
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(count, 0);
        let (status, desired): (String, i64) = sqlx::query_as(
            "SELECT status, desired_revision FROM embedding_jobs WHERE listing_id = $1",
        )
        .bind(&id)
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(status, "pending");
        assert!(desired > old_revision);
    })
    .await;
}

#[tokio::test]
async fn inactive_and_restricted_listings_delete_documents() {
    with_test_pool(|pool| async move {
        for restricted in [false, true] {
            let (id, campus, _) = seed_listing(&pool, "active").await;
            sqlx::query("INSERT INTO documents (id, document, embedded_text) VALUES ($1, '{}'::jsonb, 'stale')")
                .bind(&id).execute(&pool).await.unwrap();
            if restricted {
                let case: Uuid = sqlx::query_scalar("INSERT INTO moderation_cases (campus_id, resource_type, resource_id, source_type, source_ref_id, status, reason_category, public_reason) VALUES ($1,'listing',$2,'manual',$3,'actioned','test','restricted') RETURNING id")
                    .bind(campus).bind(&id).bind(format!("embedding-test-{id}")).fetch_one(&pool).await.unwrap();
                sqlx::query("INSERT INTO listing_restriction_effects (case_id, campus_id, listing_id) VALUES ($1,$2,$3)")
                    .bind(case).bind(campus).bind(&id).execute(&pool).await.unwrap();
            } else {
                sqlx::query("UPDATE inventory SET status = 'deleted' WHERE id = $1").bind(&id).execute(&pool).await.unwrap();
            }
            let worker = format!("embedding-delete-{restricted}");
            let job = claim(&pool, &worker, &id).await;
            embedding_worker::process_claimed_job(&pool, &worker, &job, &FakeGenerator { pool: None, mutate_listing: None, fail: false }, &metadata()).await.unwrap();
            let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM documents WHERE id = $1").bind(&id).fetch_one(&pool).await.unwrap();
            assert_eq!(count, 0);
        }
    }).await;
}

#[tokio::test]
async fn provider_failure_schedules_revision_aware_retry() {
    with_test_pool(|pool| async move {
        let (id, _, revision) = seed_listing(&pool, "active").await;
        let worker = "embedding-failure";
        let job = claim(&pool, worker, &id).await;
        embedding_worker::process_claimed_job(&pool, worker, &job, &FakeGenerator { pool: None, mutate_listing: None, fail: true }, &metadata()).await.unwrap();
        let (status, attempts, desired, error): (String, i32, i64, Option<String>) = sqlx::query_as("SELECT status, attempts, desired_revision, last_error FROM embedding_jobs WHERE listing_id = $1")
            .bind(&id).fetch_one(&pool).await.unwrap();
        assert_eq!((status.as_str(), attempts, desired), ("pending", 1, revision));
        assert!(error.unwrap().contains("forced provider failure"));
    }).await;
}

use sqlx::Row;
