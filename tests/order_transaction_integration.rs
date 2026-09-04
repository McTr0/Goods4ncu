//! Integration tests for critical order transaction boundaries.

use goods4ncu::services::order::{OrderError, OrderService};
use goods4ncu::test_infra::with_test_pool;
use sqlx::Row;
use uuid::Uuid;

#[tokio::test]
async fn create_order_persists_standard_order_record() {
    with_test_pool(|pool| async move {
        for (id, username) in [("seller-1", "seller"), ("buyer-1", "buyer")] {
            sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
                .bind(id)
                .bind(username)
                .execute(&pool)
                .await
                .unwrap();
        }

        sqlx::query(
            "INSERT INTO inventory (id, title, category, brand, condition_score, suggested_price_cny, defects, owner_id, status) \
             VALUES ('listing-1', 'Test', 'other', 'Brand', 8, 10000, '[]', 'seller-1', 'active')",
        )
        .execute(&pool)
        .await
        .unwrap();

        let service = OrderService::new(pool.clone());
        let order_id = service
            .create_order("listing-1", "buyer-1", "seller-1", 10000)
            .await
            .unwrap();
        assert!(Uuid::parse_str(&order_id).is_ok());

        let order = sqlx::query(
            "SELECT id, listing_id, buyer_id, seller_id, final_price, status FROM orders WHERE id = $1",
        )
        .bind(&order_id)
        .fetch_one(&pool)
        .await
        .unwrap();

        assert_eq!(order.get::<String, _>("id"), order_id);
        assert_eq!(order.get::<String, _>("listing_id"), "listing-1");
        assert_eq!(order.get::<String, _>("buyer_id"), "buyer-1");
        assert_eq!(order.get::<String, _>("seller_id"), "seller-1");
        assert_eq!(order.get::<i64, _>("final_price"), 10000);
        assert_eq!(order.get::<String, _>("status"), "intent_pending");
    })
    .await;
}

#[tokio::test]
async fn create_order_rolls_back_listing_status_when_order_insert_fails() {
    with_test_pool(|pool| async move {
        sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
            .bind("seller-1")
            .bind("seller")
            .execute(&pool)
            .await
            .unwrap();

        sqlx::query(
            "INSERT INTO inventory (id, title, category, brand, condition_score, suggested_price_cny, defects, owner_id, status) \
             VALUES ('listing-1', 'Test', 'misc', 'Brand', 8, 10000, '[]', 'seller-1', 'active')",
        )
        .execute(&pool)
        .await
        .unwrap();

        let service = OrderService::new(pool.clone());
        let result = service
            .create_order("listing-1", "missing-buyer", "seller-1", 10000)
            .await;

        assert!(matches!(result, Err(OrderError::Repo(_))));

        let listing = sqlx::query("SELECT status FROM inventory WHERE id = 'listing-1'")
            .fetch_one(&pool)
            .await
            .unwrap();
        let status: String = listing.get("status");
        assert_eq!(status, "active");

        let order_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM orders")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(order_count, 0);
    })
    .await;
}

#[tokio::test]
async fn cancelling_order_does_not_relist_listing_automatically() {
    with_test_pool(|pool| async move {
        for (id, username) in [("seller-1", "seller"), ("buyer-1", "buyer")] {
            sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
                .bind(id)
                .bind(username)
                .execute(&pool)
                .await
                .unwrap();
        }

        sqlx::query(
            "INSERT INTO inventory (id, title, category, brand, condition_score, suggested_price_cny, defects, owner_id, status) \
             VALUES ('listing-1', 'Test', 'misc', 'Brand', 8, 10000, '[]', 'seller-1', 'sold')",
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

        let service = OrderService::new(pool.clone());
        let updated = service
            .transition_order_status("order-1", "pending", "cancelled", Some("buyer_cancelled"))
            .await
            .unwrap();

        assert!(updated);

        let order = sqlx::query("SELECT status, cancellation_reason FROM orders WHERE id = 'order-1'")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(order.get::<String, _>("status"), "cancelled");
        assert_eq!(
            order.get::<Option<String>, _>("cancellation_reason").as_deref(),
            Some("buyer_cancelled")
        );

        let listing = sqlx::query("SELECT status FROM inventory WHERE id = 'listing-1'")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(listing.get::<String, _>("status"), "sold");
    })
    .await;
}

#[tokio::test]
async fn cancelling_order_keeps_listing_sold_when_other_open_orders_exist() {
    with_test_pool(|pool| async move {
        for (id, username) in [
            ("seller-1", "seller"),
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
            "INSERT INTO inventory (id, title, category, brand, condition_score, suggested_price_cny, defects, owner_id, status) \
             VALUES ('listing-1', 'Test', 'misc', 'Brand', 8, 10000, '[]', 'seller-1', 'sold')",
        )
        .execute(&pool)
        .await
        .unwrap();

        sqlx::query(
            "INSERT INTO orders (id, listing_id, buyer_id, seller_id, final_price, status) VALUES \
             ('order-1', 'listing-1', 'buyer-1', 'seller-1', 10000, 'pending'), \
             ('order-2', 'listing-1', 'buyer-2', 'seller-1', 10000, 'paid')",
        )
        .execute(&pool)
        .await
        .unwrap();

        let service = OrderService::new(pool.clone());
        let updated = service
            .transition_order_status("order-1", "pending", "cancelled", Some("cancelled"))
            .await
            .unwrap();

        assert!(updated);

        let listing = sqlx::query("SELECT status FROM inventory WHERE id = 'listing-1'")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(listing.get::<String, _>("status"), "sold");
    })
    .await;
}
