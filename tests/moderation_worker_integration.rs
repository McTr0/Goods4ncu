//! Moderation worker leases must prevent duplicate live claims and recover a
//! processing job after the owning worker disappears.

use chrono::{Duration, Utc};
use goods4ncu::services::moderation_worker::{process_pending_jobs_once, ModerationApiConfig};
use goods4ncu::test_infra::with_test_pool;
use sqlx::Row;
use uuid::Uuid;

async fn seed_listing_job(
    pool: &sqlx::PgPool,
    status: &str,
    locked_by: Option<&str>,
    locked_until: Option<chrono::DateTime<Utc>>,
) -> String {
    let campus_id: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
        .fetch_one(pool)
        .await
        .expect("ncu campus");
    let owner_id = format!("moderation-owner-{}", Uuid::new_v4().simple());
    sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
        .bind(&owner_id)
        .bind(format!("moderation_owner_{}", Uuid::new_v4().simple()))
        .execute(pool)
        .await
        .expect("owner");
    let listing_id = format!("moderation-listing-{}", Uuid::new_v4().simple());
    sqlx::query(
        "INSERT INTO inventory (
             id, campus_id, title, category, brand, condition_score,
             suggested_price_cny, defects, description, owner_id, status,
             images_moderation_status
         ) VALUES ($1, $2, 'Desk lamp', 'other', 'Acme', 8, 1200,
                   '[]', 'warm light', $3, 'active', 'pending')",
    )
    .bind(&listing_id)
    .bind(campus_id)
    .bind(&owner_id)
    .execute(pool)
    .await
    .expect("listing");

    let job_id = Uuid::new_v4().to_string();
    sqlx::query(
        "INSERT INTO moderation_jobs (
             id, campus_id, resource_type, resource_id, image_url,
             status, locked_by, locked_until
         ) VALUES ($1, $2, 'listing_image', $3, 'https://media.example.test/image.jpg',
                   $4, $5, $6)",
    )
    .bind(&job_id)
    .bind(campus_id)
    .bind(&listing_id)
    .bind(status)
    .bind(locked_by)
    .bind(locked_until)
    .execute(pool)
    .await
    .expect("moderation job");
    job_id
}

#[tokio::test]
async fn live_moderation_leases_are_not_stolen_but_expired_jobs_are_reclaimed() {
    with_test_pool(|pool| async move {
        sqlx::query("DELETE FROM moderation_jobs")
            .execute(&pool)
            .await
            .expect("clean moderation jobs");

        let live_job = seed_listing_job(
            &pool,
            "processing",
            Some("worker-a"),
            Some(Utc::now() + Duration::minutes(5)),
        )
        .await;
        let expired_job = seed_listing_job(
            &pool,
            "processing",
            Some("worker-gone"),
            Some(Utc::now() - Duration::seconds(1)),
        )
        .await;

        let cfg = ModerationApiConfig::from_parts(false, None, None);
        let processed = process_pending_jobs_once(&pool, &cfg, "worker-b")
            .await
            .expect("process moderation batch");
        assert_eq!(processed, 1);

        let live = sqlx::query(
            "SELECT status, locked_by, locked_until FROM moderation_jobs WHERE id = $1",
        )
        .bind(&live_job)
        .fetch_one(&pool)
        .await
        .expect("live job");
        assert_eq!(live.get::<String, _>("status"), "processing");
        assert_eq!(
            live.get::<Option<String>, _>("locked_by").as_deref(),
            Some("worker-a")
        );
        assert!(live
            .get::<Option<chrono::DateTime<Utc>>, _>("locked_until")
            .is_some_and(|until| until > Utc::now()));

        let expired = sqlx::query(
            "SELECT status, locked_by, locked_until FROM moderation_jobs WHERE id = $1",
        )
        .bind(&expired_job)
        .fetch_one(&pool)
        .await
        .expect("expired job");
        assert_eq!(expired.get::<String, _>("status"), "approved");
        assert_eq!(expired.get::<Option<String>, _>("locked_by"), None);
        assert_eq!(
            expired.get::<Option<chrono::DateTime<Utc>>, _>("locked_until"),
            None
        );
    })
    .await;
}
