//! Versioned embedding projection queue: trigger coverage, coalescing, leases,
//! deterministic retry/dead-letter and replay behavior.

use chrono::{Duration, TimeZone, Utc};
use goods4ncu::services::embedding_jobs::{
    claim_batch, mark_failed, mark_succeeded, replay_dead_lettered, CompletionOutcome,
    FailureOutcome,
};
use goods4ncu::test_infra::with_test_pool;
use sqlx::{PgPool, Row};
use uuid::Uuid;

async fn insert_listing(pool: &PgPool, prefix: &str) -> String {
    // embedding_jobs intentionally has no inventory FK so hard-delete jobs can
    // survive long enough to remove documents. Shared test cleanup therefore
    // cannot cascade into it.
    sqlx::query("DELETE FROM embedding_jobs")
        .execute(pool)
        .await
        .expect("clean embedding jobs");

    let user_id = Uuid::new_v4().to_string();
    let username = format!("embedding-{prefix}-{}", Uuid::new_v4());
    sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'not-used')")
        .bind(&user_id)
        .bind(username)
        .execute(pool)
        .await
        .expect("insert user");

    let listing_id = format!("embedding-{prefix}-{}", Uuid::new_v4());
    sqlx::query(
        "INSERT INTO inventory (
             id, title, category, brand, condition_score,
             suggested_price_cny, defects, description, owner_id, status
         ) VALUES ($1, 'Desk lamp', 'home', 'Acme', 8, 1200, 'none',
                   'warm light', $2, 'active')",
    )
    .bind(&listing_id)
    .bind(user_id)
    .execute(pool)
    .await
    .expect("insert listing");
    listing_id
}

async fn job_state(pool: &PgPool, listing_id: &str) -> (i64, String, i32) {
    let row = sqlx::query(
        "SELECT desired_revision, status, attempts
         FROM embedding_jobs WHERE listing_id = $1",
    )
    .bind(listing_id)
    .fetch_one(pool)
    .await
    .expect("embedding job");
    (
        row.get("desired_revision"),
        row.get("status"),
        row.get("attempts"),
    )
}

#[tokio::test]
async fn inventory_triggers_enqueue_only_projection_changes_and_advance_monotonically() {
    with_test_pool(|pool| async move {
        let listing_id = insert_listing(&pool, "trigger").await;
        assert_eq!(
            job_state(&pool, &listing_id).await,
            (1, "pending".into(), 0)
        );

        // Price does not affect the canonical embedding text.
        sqlx::query("UPDATE inventory SET suggested_price_cny = 1300 WHERE id = $1")
            .bind(&listing_id)
            .execute(&pool)
            .await
            .expect("price update");
        let revision: i64 =
            sqlx::query_scalar("SELECT content_revision FROM inventory WHERE id = $1")
                .bind(&listing_id)
                .fetch_one(&pool)
                .await
                .expect("revision");
        assert_eq!(revision, 1);

        sqlx::query("UPDATE inventory SET description = 'cool light' WHERE id = $1")
            .bind(&listing_id)
            .execute(&pool)
            .await
            .expect("semantic update");
        assert_eq!(
            job_state(&pool, &listing_id).await,
            (2, "pending".into(), 0)
        );

        sqlx::query("UPDATE inventory SET status = 'deleted' WHERE id = $1")
            .bind(&listing_id)
            .execute(&pool)
            .await
            .expect("visibility update");
        assert_eq!(
            job_state(&pool, &listing_id).await,
            (3, "pending".into(), 0)
        );
    })
    .await;
}

#[tokio::test]
async fn update_during_processing_preserves_lease_and_requeues_new_revision() {
    with_test_pool(|pool| async move {
        let listing_id = insert_listing(&pool, "supersede").await;
        let now = Utc.with_ymd_and_hms(2100, 1, 1, 12, 0, 0).unwrap();
        let claimed = claim_batch(&pool, "worker-a", 1, now, Duration::seconds(60))
            .await
            .expect("claim");
        assert_eq!(claimed.len(), 1);
        assert_eq!(claimed[0].desired_revision, 1);

        sqlx::query("UPDATE inventory SET title = 'New desk lamp' WHERE id = $1")
            .bind(&listing_id)
            .execute(&pool)
            .await
            .expect("update during processing");
        let lock_owner: Option<String> =
            sqlx::query_scalar("SELECT locked_by FROM embedding_jobs WHERE listing_id = $1")
                .bind(&listing_id)
                .fetch_one(&pool)
                .await
                .expect("lock owner");
        assert_eq!(lock_owner.as_deref(), Some("worker-a"));

        let outcome = mark_succeeded(&pool, &listing_id, "worker-a", 1, now)
            .await
            .expect("complete old revision");
        assert_eq!(
            outcome,
            CompletionOutcome::Superseded {
                desired_revision: 2
            }
        );
        assert_eq!(
            job_state(&pool, &listing_id).await,
            (2, "pending".into(), 0)
        );
    })
    .await;
}

#[tokio::test]
async fn expired_lease_is_reclaimed_and_old_owner_cannot_complete() {
    with_test_pool(|pool| async move {
        let listing_id = insert_listing(&pool, "lease").await;
        let now = Utc.with_ymd_and_hms(2100, 1, 1, 13, 0, 0).unwrap();
        claim_batch(&pool, "worker-a", 1, now, Duration::seconds(30))
            .await
            .expect("first claim");
        let reclaimed = claim_batch(
            &pool,
            "worker-b",
            1,
            now + Duration::seconds(31),
            Duration::seconds(30),
        )
        .await
        .expect("reclaim");
        assert_eq!(reclaimed.len(), 1);
        assert_eq!(
            mark_succeeded(&pool, &listing_id, "worker-a", 1, now)
                .await
                .expect("stale completion"),
            CompletionOutcome::LostLease
        );
        assert_eq!(
            mark_succeeded(&pool, &listing_id, "worker-b", 1, now)
                .await
                .expect("current completion"),
            CompletionOutcome::Completed
        );
    })
    .await;
}

#[tokio::test]
async fn failures_back_off_dead_letter_and_replay_deterministically() {
    with_test_pool(|pool| async move {
        let listing_id = insert_listing(&pool, "retry").await;
        sqlx::query("UPDATE embedding_jobs SET max_attempts = 2 WHERE listing_id = $1")
            .bind(&listing_id)
            .execute(&pool)
            .await
            .expect("lower attempts");
        let now = Utc.with_ymd_and_hms(2100, 1, 1, 14, 0, 0).unwrap();

        claim_batch(&pool, "worker-a", 1, now, Duration::seconds(60))
            .await
            .expect("first claim");
        assert_eq!(
            mark_failed(&pool, &listing_id, "worker-a", 1, now, "timeout")
                .await
                .expect("first failure"),
            FailureOutcome::RetryAt(now + Duration::seconds(2))
        );
        assert!(claim_batch(
            &pool,
            "worker-b",
            1,
            now + Duration::seconds(1),
            Duration::seconds(60)
        )
        .await
        .expect("early claim")
        .is_empty());

        claim_batch(
            &pool,
            "worker-b",
            1,
            now + Duration::seconds(2),
            Duration::seconds(60),
        )
        .await
        .expect("retry claim");
        assert_eq!(
            mark_failed(
                &pool,
                &listing_id,
                "worker-b",
                1,
                now + Duration::seconds(2),
                "still failing"
            )
            .await
            .expect("second failure"),
            FailureOutcome::DeadLettered
        );
        assert_eq!(
            job_state(&pool, &listing_id).await,
            (1, "dead_lettered".into(), 2)
        );

        let replay_at = now + Duration::minutes(5);
        assert!(replay_dead_lettered(&pool, &listing_id, replay_at)
            .await
            .expect("replay"));
        assert_eq!(
            job_state(&pool, &listing_id).await,
            (1, "pending".into(), 0)
        );
    })
    .await;
}

#[tokio::test]
async fn restriction_impose_and_release_each_request_a_new_projection() {
    with_test_pool(|pool| async move {
        let listing_id = insert_listing(&pool, "restriction").await;
        let listing = sqlx::query("SELECT campus_id, owner_id FROM inventory WHERE id = $1")
            .bind(&listing_id)
            .fetch_one(&pool)
            .await
            .expect("listing tenant and owner");
        let campus_id: Uuid = listing.get("campus_id");
        let owner_id: String = listing.get("owner_id");
        let case_id = Uuid::new_v4();

        sqlx::query(
            "INSERT INTO moderation_cases (
                 id, campus_id, subject_user_id, resource_type, resource_id,
                 source_type, source_ref_id, status, reason_category,
                 public_reason, opened_by
             ) VALUES (
                 $1, $2, $3, 'listing', $4, 'manual', $5, 'open',
                 'embedding_projection_test', 'test restriction', $3
             )",
        )
        .bind(case_id)
        .bind(campus_id)
        .bind(&owner_id)
        .bind(&listing_id)
        .bind(format!("embedding-projection-test:{case_id}"))
        .execute(&pool)
        .await
        .expect("moderation case");

        sqlx::query(
            "INSERT INTO listing_restriction_effects (
                 campus_id, listing_id, case_id, source_kind, imposed_by
             ) VALUES ($1, $2, $3, 'moderation_case', $4)",
        )
        .bind(campus_id)
        .bind(&listing_id)
        .bind(case_id)
        .bind(&owner_id)
        .execute(&pool)
        .await
        .expect("impose restriction");
        assert_eq!(
            job_state(&pool, &listing_id).await,
            (2, "pending".into(), 0)
        );

        sqlx::query(
            "UPDATE listing_restriction_effects
             SET released_at = NOW(), released_by = $2, release_reason = 'test release'
             WHERE case_id = $1",
        )
        .bind(case_id)
        .bind(&owner_id)
        .execute(&pool)
        .await
        .expect("release restriction");
        assert_eq!(
            job_state(&pool, &listing_id).await,
            (3, "pending".into(), 0)
        );
    })
    .await;
}
