//! Integration tests for staged UUID shadow-column migration.

use goods4ncu::db::assert_uuid_shadow_drift_zero;
use goods4ncu::test_infra::with_test_pool;
use sqlx::Row;
use uuid::Uuid;

async fn assert_no_uuid_shadow_drift(pool: &sqlx::PgPool) {
    let rows = sqlx::query(
        "SELECT relation_name, missing_shadow_ids, fk_drift_rows FROM uuid_shadow_divergence ORDER BY relation_name",
    )
    .fetch_all(pool)
    .await
    .expect("query uuid_shadow_divergence");

    for row in rows {
        let relation_name: String = row.get("relation_name");
        let missing_shadow_ids: i64 = row.get("missing_shadow_ids");
        let fk_drift_rows: i64 = row.get("fk_drift_rows");
        assert_eq!(
            missing_shadow_ids, 0,
            "{relation_name} should not have missing shadow UUIDs"
        );
        assert_eq!(fk_drift_rows, 0, "{relation_name} should not have FK drift");
    }
}

#[tokio::test]
async fn legacy_text_writes_fill_uuid_shadow_columns_without_drift() {
    with_test_pool(|pool| async move {
        for (id, username) in [
            ("seller-1", "seller"),
            ("buyer-1", "buyer"),
            ("buyer-2", "buyer2"),
        ] {
            sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
                .bind(id)
                .bind(username)
                .execute(&pool)
                .await
                .unwrap();
        }

        sqlx::query(
            "INSERT INTO inventory (id, title, category, brand, condition_score, suggested_price_cny, defects, owner_id, status) \
             VALUES ('listing-1', 'Desk', 'misc', 'Brand', 8, 10000, '[]', 'seller-1', 'active')",
        )
        .execute(&pool)
        .await
        .unwrap();

        sqlx::query(
            "INSERT INTO orders (id, listing_id, buyer_id, seller_id, final_price, status) \
             VALUES ('order-1', 'listing-1', 'buyer-1', 'seller-1', 10000, 'pending')",
        )
        .execute(&pool)
        .await
        .unwrap();

        let seller_uuid: Uuid = sqlx::query_scalar("SELECT new_id FROM users WHERE id = 'seller-1'")
            .fetch_one(&pool)
            .await
            .unwrap();
        let listing_row = sqlx::query(
            "SELECT new_id, new_owner_id FROM inventory WHERE id = 'listing-1'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        let listing_uuid: Uuid = listing_row.get("new_id");
        let listing_owner_uuid: Uuid = listing_row.get("new_owner_id");
        assert_eq!(listing_owner_uuid, seller_uuid);

        let order_row = sqlx::query(
            "SELECT new_id, new_listing_id, new_buyer_id, new_seller_id FROM orders WHERE id = 'order-1'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        let order_uuid: Uuid = order_row.get("new_id");
        let order_listing_uuid: Uuid = order_row.get("new_listing_id");
        let order_buyer_uuid: Uuid = order_row.get("new_buyer_id");
        let order_seller_uuid: Uuid = order_row.get("new_seller_id");

        assert_ne!(listing_uuid, order_uuid);
        assert_eq!(order_listing_uuid, listing_uuid);
        assert_eq!(order_seller_uuid, seller_uuid);
        assert_ne!(order_buyer_uuid, seller_uuid);

        assert_no_uuid_shadow_drift(&pool).await;
        assert_uuid_shadow_drift_zero(&pool).await.unwrap();
    })
    .await;
}

#[tokio::test]
async fn updating_legacy_foreign_keys_resyncs_shadow_columns() {
    with_test_pool(|pool| async move {
        for (id, username) in [
            ("seller-1", "seller1"),
            ("seller-2", "seller2"),
            ("buyer-1", "buyer1"),
            ("buyer-2", "buyer2"),
        ] {
            sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
                .bind(id)
                .bind(username)
                .execute(&pool)
                .await
                .unwrap();
        }

        sqlx::query(
            "INSERT INTO inventory (id, title, category, brand, condition_score, suggested_price_cny, defects, owner_id, status) VALUES \
             ('listing-1', 'Desk', 'misc', 'Brand', 8, 10000, '[]', 'seller-1', 'active'), \
             ('listing-2', 'Chair', 'misc', 'Brand', 7, 8000, '[]', 'seller-2', 'active')",
        )
        .execute(&pool)
        .await
        .unwrap();

        sqlx::query(
            "INSERT INTO orders (id, listing_id, buyer_id, seller_id, final_price, status) \
             VALUES ('order-1', 'listing-1', 'buyer-1', 'seller-1', 10000, 'pending')",
        )
        .execute(&pool)
        .await
        .unwrap();

        sqlx::query("UPDATE inventory SET owner_id = 'seller-2' WHERE id = 'listing-1'")
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query(
            "UPDATE orders SET listing_id = 'listing-2', buyer_id = 'buyer-2', seller_id = 'seller-2' WHERE id = 'order-1'",
        )
        .execute(&pool)
        .await
        .unwrap();

        let seller_2_uuid: Uuid =
            sqlx::query_scalar("SELECT new_id FROM users WHERE id = 'seller-2'")
                .fetch_one(&pool)
                .await
                .unwrap();
        let buyer_2_uuid: Uuid =
            sqlx::query_scalar("SELECT new_id FROM users WHERE id = 'buyer-2'")
                .fetch_one(&pool)
                .await
                .unwrap();
        let listing_2_uuid: Uuid =
            sqlx::query_scalar("SELECT new_id FROM inventory WHERE id = 'listing-2'")
                .fetch_one(&pool)
                .await
                .unwrap();

        let inventory_owner_uuid: Uuid =
            sqlx::query_scalar("SELECT new_owner_id FROM inventory WHERE id = 'listing-1'")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(inventory_owner_uuid, seller_2_uuid);

        let order_row = sqlx::query(
            "SELECT new_listing_id, new_buyer_id, new_seller_id FROM orders WHERE id = 'order-1'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(order_row.get::<Uuid, _>("new_listing_id"), listing_2_uuid);
        assert_eq!(order_row.get::<Uuid, _>("new_buyer_id"), buyer_2_uuid);
        assert_eq!(order_row.get::<Uuid, _>("new_seller_id"), seller_2_uuid);

        assert_no_uuid_shadow_drift(&pool).await;
        assert_uuid_shadow_drift_zero(&pool).await.unwrap();
    })
    .await;
}

#[tokio::test]
async fn explicit_matching_shadow_ids_are_accepted_for_dual_write_inserts() {
    with_test_pool(|pool| async move {
        let seller_uuid = Uuid::new_v4();
        let buyer_uuid = Uuid::new_v4();
        let listing_uuid = Uuid::new_v4();
        let order_uuid = Uuid::new_v4();

        sqlx::query(
            "INSERT INTO users (id, new_id, username, password_hash) VALUES ($1, $2, $3, 'hash')",
        )
        .bind("seller-1")
        .bind(seller_uuid)
        .bind("seller")
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO users (id, new_id, username, password_hash) VALUES ($1, $2, $3, 'hash')",
        )
        .bind("buyer-1")
        .bind(buyer_uuid)
        .bind("buyer")
        .execute(&pool)
        .await
        .unwrap();

        sqlx::query(
            "INSERT INTO inventory (id, new_id, title, category, brand, condition_score, suggested_price_cny, defects, owner_id, new_owner_id, status) \
             VALUES ($1, $2, 'Desk', 'misc', 'Brand', 8, 10000, '[]', $3, $4, 'active')",
        )
        .bind("listing-1")
        .bind(listing_uuid)
        .bind("seller-1")
        .bind(seller_uuid)
        .execute(&pool)
        .await
        .unwrap();

        sqlx::query(
            "INSERT INTO orders (id, new_id, listing_id, new_listing_id, buyer_id, new_buyer_id, seller_id, new_seller_id, final_price, status) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 10000, 'pending')",
        )
        .bind("order-1")
        .bind(order_uuid)
        .bind("listing-1")
        .bind(listing_uuid)
        .bind("buyer-1")
        .bind(buyer_uuid)
        .bind("seller-1")
        .bind(seller_uuid)
        .execute(&pool)
        .await
        .unwrap();

        let stored_inventory_uuid: Uuid =
            sqlx::query_scalar("SELECT new_id FROM inventory WHERE id = 'listing-1'")
                .fetch_one(&pool)
                .await
                .unwrap();
        let stored_order_uuid: Uuid =
            sqlx::query_scalar("SELECT new_id FROM orders WHERE id = 'order-1'")
                .fetch_one(&pool)
                .await
                .unwrap();

        assert_eq!(stored_inventory_uuid, listing_uuid);
        assert_eq!(stored_order_uuid, order_uuid);

        assert_no_uuid_shadow_drift(&pool).await;
        assert_uuid_shadow_drift_zero(&pool).await.unwrap();
    })
    .await;
}

#[tokio::test]
async fn startup_guard_fails_when_uuid_shadow_view_reports_drift() {
    with_test_pool(|pool| async move {
        for (id, username) in [("seller-1", "seller1"), ("seller-2", "seller2")] {
            sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
                .bind(id)
                .bind(username)
                .execute(&pool)
                .await
                .unwrap();
        }

        sqlx::query(
            "INSERT INTO inventory (id, title, category, brand, condition_score, suggested_price_cny, defects, owner_id, status) \
             VALUES ('listing-1', 'Desk', 'misc', 'Brand', 8, 10000, '[]', 'seller-1', 'active')",
        )
        .execute(&pool)
        .await
        .unwrap();

        let seller_2_uuid: Uuid =
            sqlx::query_scalar("SELECT new_id FROM users WHERE id = 'seller-2'")
                .fetch_one(&pool)
                .await
                .unwrap();

        sqlx::query("ALTER TABLE inventory DISABLE TRIGGER trg_sync_inventory_uuid_shadow")
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("UPDATE inventory SET new_owner_id = $1 WHERE id = 'listing-1'")
            .bind(seller_2_uuid)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("ALTER TABLE inventory ENABLE TRIGGER trg_sync_inventory_uuid_shadow")
            .execute(&pool)
            .await
            .unwrap();

        let error = assert_uuid_shadow_drift_zero(&pool).await.unwrap_err();
        let message = error.to_string();
        assert!(message.contains("uuid shadow drift detected"));
        assert!(message.contains("inventory"));
    })
    .await;
}
