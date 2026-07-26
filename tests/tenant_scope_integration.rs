//! Database-level tenant constraints for core marketplace facts.

use goods4ncu::services::notification::{NewNotification, NotificationService};
use goods4ncu::test_infra::with_test_pool;
use uuid::Uuid;

#[tokio::test]
async fn notification_reads_and_read_state_are_campus_scoped() {
    with_test_pool(|pool| async move {
        let user_id = Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO users (id, username, password_hash)
             VALUES ($1, $2, 'hash')",
        )
        .bind(&user_id)
        .bind(format!("notification_user_{}", Uuid::new_v4()))
        .execute(&pool)
        .await
        .unwrap();

        let ncu_id: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
            .fetch_one(&pool)
            .await
            .unwrap();
        let other_campus_id = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO campuses (id, slug, name_zh, name_en, email_domains)
             VALUES ($1, $2, '通知测试大学', 'Notification Test University', ARRAY['notify.test'])",
        )
        .bind(other_campus_id)
        .bind(format!("notify-{}", &other_campus_id.to_string()[..8]))
        .execute(&pool)
        .await
        .unwrap();

        for campus_id in [ncu_id, other_campus_id] {
            sqlx::query(
                "INSERT INTO campus_memberships (
                    campus_id, user_id, status, verification_method, verified_at
                 ) VALUES ($1, $2, 'verified', 'test_fixture', NOW())",
            )
            .bind(campus_id)
            .bind(&user_id)
            .execute(&pool)
            .await
            .unwrap();
        }

        let service = NotificationService::new(pool.clone());
        let ncu_notification = service
            .create(NewNotification {
                campus_id: ncu_id,
                user_id: &user_id,
                event_type: "ncu_event",
                title: "NCU notice",
                body: "NCU only",
                related_order_id: None,
                related_listing_id: None,
                related_conversation_id: None,
                related_space_id: None,
            })
            .await
            .unwrap();
        let other_notification = service
            .create(NewNotification {
                campus_id: other_campus_id,
                user_id: &user_id,
                event_type: "other_event",
                title: "Other notice",
                body: "Other campus only",
                related_order_id: None,
                related_listing_id: None,
                related_conversation_id: None,
                related_space_id: None,
            })
            .await
            .unwrap();

        let (ncu_items, ncu_total) = service.list_all(&user_id, ncu_id, 20, 0).await.unwrap();
        assert_eq!(ncu_total, 1);
        assert_eq!(ncu_items[0].id, ncu_notification);
        assert_eq!(service.count_unread(&user_id, ncu_id).await.unwrap(), 1);
        assert_eq!(
            service
                .count_unread(&user_id, other_campus_id)
                .await
                .unwrap(),
            1
        );

        assert!(!service
            .mark_read(&other_notification, &user_id, ncu_id)
            .await
            .unwrap());
        assert_eq!(service.mark_all_read(&user_id, ncu_id).await.unwrap(), 1);
        assert_eq!(service.count_unread(&user_id, ncu_id).await.unwrap(), 0);
        assert_eq!(
            service
                .count_unread(&user_id, other_campus_id)
                .await
                .unwrap(),
            1
        );
    })
    .await;
}

#[tokio::test]
async fn child_facts_cannot_reference_a_listing_from_another_campus() {
    with_test_pool(|pool| async move {
        let other_campus_id = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO campuses (id, slug, name_zh, name_en, email_domains)
             VALUES ($1, $2, '测试大学', 'Test University', ARRAY['test.edu.cn'])",
        )
        .bind(other_campus_id)
        .bind(format!("test-{}", &other_campus_id.to_string()[..8]))
        .execute(&pool)
        .await
        .unwrap();

        for (id, username) in [
            ("tenant-seller", "tenant_seller"),
            ("tenant-buyer", "tenant_buyer"),
        ] {
            sqlx::query(
                "INSERT INTO users (id, username, password_hash)
                 VALUES ($1, $2, 'hash')",
            )
            .bind(id)
            .bind(username)
            .execute(&pool)
            .await
            .unwrap();
        }

        let listing_id = Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO inventory (
                id, campus_id, title, category, brand, condition_score,
                suggested_price_cny, defects, owner_id, status
             ) VALUES ($1, $2, 'Other campus item', 'misc', 'Brand', 8,
                       10000, '[]', 'tenant-seller', 'active')",
        )
        .bind(&listing_id)
        .bind(other_campus_id)
        .execute(&pool)
        .await
        .unwrap();

        let order_error = sqlx::query(
            "INSERT INTO orders (
                id, listing_id, buyer_id, seller_id, final_price, status
             ) VALUES ($1, $2, 'tenant-buyer', 'tenant-seller', 10000, 'intent_pending')",
        )
        .bind(Uuid::new_v4().to_string())
        .bind(&listing_id)
        .execute(&pool)
        .await
        .expect_err("default NCU order must not reference another-campus listing");

        assert_eq!(
            order_error
                .as_database_error()
                .and_then(|error| error.constraint()),
            Some("orders_listing_campus_fk")
        );
    })
    .await;
}

#[tokio::test]
async fn legacy_core_rows_are_backfilled_to_the_default_campus() {
    with_test_pool(|pool| async move {
        let ncu_id: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
            .fetch_one(&pool)
            .await
            .unwrap();
        let missing: i64 = sqlx::query_scalar(
            "SELECT
                (SELECT COUNT(*) FROM inventory WHERE campus_id IS DISTINCT FROM $1) +
                (SELECT COUNT(*) FROM orders WHERE campus_id IS DISTINCT FROM $1) +
                (SELECT COUNT(*) FROM hitl_requests WHERE campus_id IS DISTINCT FROM $1) +
                (SELECT COUNT(*) FROM chat_conversations WHERE campus_id IS DISTINCT FROM $1)",
        )
        .bind(ncu_id)
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(missing, 0);
    })
    .await;
}

#[tokio::test]
async fn upgraded_money_columns_use_bigint_consistently() {
    with_test_pool(|pool| async move {
        let rows: Vec<(String, String, String)> = sqlx::query_as(
            "SELECT table_name, column_name, data_type
             FROM information_schema.columns
             WHERE table_schema = 'public'
               AND (table_name, column_name) IN (
                   ('inventory', 'suggested_price_cny'),
                   ('orders', 'final_price'),
                   ('hitl_requests', 'proposed_price'),
                   ('hitl_requests', 'counter_price')
               )
             ORDER BY table_name, column_name",
        )
        .fetch_all(&pool)
        .await
        .unwrap();

        assert_eq!(rows.len(), 4);
        assert!(rows.iter().all(|(_, _, data_type)| data_type == "bigint"));
    })
    .await;
}

#[tokio::test]
async fn moderation_jobs_require_campus_and_allow_worker_processing_state() {
    with_test_pool(|pool| async move {
        let ncu_id: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
            .fetch_one(&pool)
            .await
            .unwrap();
        let missing_job_id = format!("missing-campus-{}", Uuid::new_v4());
        let processing_job_id = format!("processing-{}", Uuid::new_v4());

        let missing_campus = sqlx::query(
            "INSERT INTO moderation_jobs (
                id, resource_type, resource_id, image_url, status
             ) VALUES ($1, 'avatar', 'user', 'https://example.test/a.jpg', 'pending')",
        )
        .bind(&missing_job_id)
        .execute(&pool)
        .await
        .expect_err("moderation jobs must always inherit a campus");
        assert_eq!(
            missing_campus
                .as_database_error()
                .and_then(|error| error.code()),
            Some(std::borrow::Cow::Borrowed("23502"))
        );

        sqlx::query(
            "INSERT INTO moderation_jobs (
                id, campus_id, resource_type, resource_id, image_url, status
             ) VALUES ($1, $2, 'avatar', 'user', 'https://example.test/a.jpg', 'processing')",
        )
        .bind(&processing_job_id)
        .bind(ncu_id)
        .execute(&pool)
        .await
        .expect("worker processing state should satisfy the status constraint");

        let campus_id: Uuid =
            sqlx::query_scalar("SELECT campus_id FROM moderation_jobs WHERE id = $1")
                .bind(&processing_job_id)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(campus_id, ncu_id);
    })
    .await;
}
