//! Order persistence for the single write path that needs it.
//!
//! The old `OrderRepository` trait (find/list/update/count) was removed:
//! production reads and status transitions live in `OrderService`'s inline
//! transactional SQL, and the trait had zero callers outside its own impl.
//! Only `create_pending_in_tx` is delegated here, composed inside the
//! caller's transaction.

use crate::api::error::ApiError;
use sqlx::{Postgres, Transaction};

#[derive(Clone, Default)]
pub struct PostgresOrderRepository;

impl PostgresOrderRepository {
    pub fn new() -> Self {
        Self
    }

    pub async fn create_pending_in_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        id: &str,
        listing_id: &str,
        buyer_id: &str,
        seller_id: &str,
        final_price: i64,
    ) -> Result<(), ApiError> {
        sqlx::query(
            r#"
            INSERT INTO orders (
                id, campus_id,
                listing_id, buyer_id, seller_id,
                final_price, status
            )
            VALUES ($1, (SELECT campus_id FROM inventory WHERE id = $2),
                    $2, $3, $4, $5, 'intent_pending')
            "#,
        )
        .bind(id)
        .bind(listing_id)
        .bind(buyer_id)
        .bind(seller_id)
        .bind(final_price)
        .execute(&mut **tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_infra::with_test_pool;
    use sqlx::Row;
    use uuid::Uuid;

    #[tokio::test]
    async fn create_pending_in_tx_persists_standard_columns() {
        with_test_pool(|pool| async move {
            for (id, username) in [("seller-1", "seller"), ("buyer-1", "buyer")] {
                sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
                    .bind(id)
                    .bind(username)
                    .execute(&pool)
                    .await
                    .expect("insert user");
            }

            sqlx::query(
                "INSERT INTO inventory (id, title, category, brand, condition_score, suggested_price_cny, defects, owner_id, status) \
                 VALUES ('listing-1', 'Desk', 'other', 'Brand', 8, 10000, '[]', 'seller-1', 'active')",
            )
            .execute(&pool)
            .await
            .expect("insert listing");

            let repo = PostgresOrderRepository::new();
            let mut tx = pool.begin().await.expect("begin tx");
            let pending_order_id = Uuid::new_v4().to_string();
            repo.create_pending_in_tx(
                &mut tx,
                &pending_order_id,
                "listing-1",
                "buyer-1",
                "seller-1",
                12000,
            )
            .await
            .expect("create pending in tx");
            tx.commit().await.expect("commit tx");
            assert!(Uuid::parse_str(&pending_order_id).is_ok());

            let pending_row = sqlx::query(
                "SELECT id, listing_id, buyer_id, seller_id, final_price, status FROM orders WHERE id = $1",
            )
            .bind(&pending_order_id)
            .fetch_one(&pool)
            .await
            .expect("select pending order");

            assert_eq!(pending_row.get::<String, _>("id"), pending_order_id);
            assert_eq!(pending_row.get::<String, _>("listing_id"), "listing-1");
            assert_eq!(pending_row.get::<String, _>("buyer_id"), "buyer-1");
            assert_eq!(pending_row.get::<String, _>("seller_id"), "seller-1");
            assert_eq!(pending_row.get::<i64, _>("final_price"), 12000);
            assert_eq!(pending_row.get::<String, _>("status"), "intent_pending");
        })
        .await;
    }
}
