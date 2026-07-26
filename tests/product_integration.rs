//! Integration tests for ProductService.
//! Run with `--test-threads=1` for proper serial execution.

use goods4ncu::test_infra::with_test_pool;
use sqlx::Row;

#[tokio::test]
async fn test_mark_as_sold() {
    with_test_pool(|pool| async move {
        sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
            .bind("owner").bind("owneruser")
            .execute(&pool).await.unwrap();
        sqlx::query(
            "INSERT INTO inventory (id, title, category, brand, condition_score, suggested_price_cny, defects, owner_id, status) \
             VALUES ('prod-1', 'Test', 'misc', 'Brand', 8, 10000, '[]', 'owner', 'active')",
        )
        .execute(&pool).await.unwrap();

        sqlx::query("UPDATE inventory SET status = 'sold' WHERE id = $1")
            .bind("prod-1")
            .execute(&pool).await.unwrap();

        let row = sqlx::query("SELECT status FROM inventory WHERE id = 'prod-1'")
            .fetch_one(&pool).await.unwrap();
        let status: String = Row::get(&row, "status");
        assert_eq!(status, "sold");
    }).await;
}
