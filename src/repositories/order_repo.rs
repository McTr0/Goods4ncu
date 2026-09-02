//! PostgreSQL implementation of the OrderRepository trait.

use crate::api::error::ApiError;
use crate::repositories::traits::{Order, OrderRepository, OrderSummary};
use sqlx::{PgPool, Postgres, Row, Transaction};
use uuid::Uuid;

#[derive(Debug, Clone, Copy)]
#[allow(dead_code)]
pub enum OrderTimestampField {
    Paid,
    Shipped,
    Completed,
    Cancelled,
}

#[allow(dead_code)]
impl OrderTimestampField {
    fn as_sql(self) -> &'static str {
        match self {
            Self::Paid => "paid_at",
            Self::Shipped => "shipped_at",
            Self::Completed => "completed_at",
            Self::Cancelled => "cancelled_at",
        }
    }
}

#[derive(Clone)]
pub struct PostgresOrderRepository {
    pool: PgPool,
}

impl PostgresOrderRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
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
        let order_uuid = Uuid::parse_str(id).map_err(|e| {
            ApiError::Internal(anyhow::anyhow!("Order id must be UUID-compatible: {}", e))
        })?;

        sqlx::query(
            r#"
            INSERT INTO orders (
                id, new_id, campus_id,
                listing_id, buyer_id, seller_id,
                final_price, status
            )
            VALUES ($1, $2, (SELECT campus_id FROM inventory WHERE id = $3),
                    $3, $4, $5, $6, 'intent_pending')
            "#,
        )
        .bind(id)
        .bind(order_uuid)
        .bind(listing_id)
        .bind(buyer_id)
        .bind(seller_id)
        .bind(final_price)
        .execute(&mut **tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(())
    }

    #[allow(dead_code)]
    pub async fn update_status_in_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        order_id: &str,
        expected_current: &str,
        new_status: &str,
        timestamp_field: OrderTimestampField,
        cancellation_reason: Option<&str>,
    ) -> Result<Option<String>, ApiError> {
        let timestamp_field = timestamp_field.as_sql();

        let row = if let Some(reason) = cancellation_reason {
            sqlx::query(&format!(
                "UPDATE orders SET status = $1, {} = NOW(), cancellation_reason = $2 WHERE id = $3 AND status = $4 RETURNING listing_id",
                timestamp_field
            ))
            .bind(new_status)
            .bind(reason)
            .bind(order_id)
            .bind(expected_current)
            .fetch_optional(&mut **tx)
            .await
        } else {
            sqlx::query(&format!(
                "UPDATE orders SET status = $1, {} = NOW() WHERE id = $2 AND status = $3 RETURNING listing_id",
                timestamp_field
            ))
            .bind(new_status)
            .bind(order_id)
            .bind(expected_current)
            .fetch_optional(&mut **tx)
            .await
        }
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(row.map(|row| row.get("listing_id")))
    }
}

impl OrderRepository for PostgresOrderRepository {
    async fn create(
        &self,
        id: &str,
        listing_id: &str,
        buyer_id: &str,
        seller_id: &str,
        final_price: i64,
    ) -> Result<(), ApiError> {
        let order_uuid = Uuid::parse_str(id).map_err(|e| {
            ApiError::Internal(anyhow::anyhow!("Order id must be UUID-compatible: {}", e))
        })?;
        sqlx::query(
            r#"
            INSERT INTO orders (
                id, new_id, campus_id,
                listing_id, buyer_id, seller_id,
                final_price, status
            )
            VALUES (
                $1, $2,
                (SELECT campus_id FROM inventory WHERE id = $3),
                $3, $4, $5, $6, 'intent_pending'
            )
            "#,
        )
        .bind(id)
        .bind(order_uuid)
        .bind(listing_id)
        .bind(buyer_id)
        .bind(seller_id)
        .bind(final_price)
        .execute(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(())
    }

    async fn find_by_id(&self, id: &str) -> Result<Option<Order>, ApiError> {
        let row = sqlx::query_as::<_, Order>("SELECT * FROM orders WHERE id = $1")
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(row)
    }

    async fn find_with_details(&self, id: &str) -> Result<Option<OrderSummary>, ApiError> {
        let row = sqlx::query(
            r#"
            SELECT o.id, o.listing_id, o.buyer_id, o.seller_id, o.final_price,
                   o.status, o.created_at,
                   i.title as listing_title,
                   buyer.username as buyer_username,
                   seller.username as seller_username
            FROM orders o
            JOIN inventory i ON i.id = o.listing_id
            JOIN users buyer ON buyer.id = o.buyer_id
            JOIN users seller ON seller.id = o.seller_id
            WHERE o.id = $1
            "#,
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(row.map(|r| OrderSummary {
            id: r.get("id"),
            listing_id: r.get("listing_id"),
            listing_title: r.get("listing_title"),
            buyer_id: r.get("buyer_id"),
            buyer_username: r.get("buyer_username"),
            seller_id: r.get("seller_id"),
            seller_username: r.get("seller_username"),
            final_price: r.get("final_price"),
            status: r.get("status"),
            created_at: r.get("created_at"),
        }))
    }

    async fn list_orders(
        &self,
        user_id: Option<&str>,
        role: Option<&str>,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<OrderSummary>, i64), ApiError> {
        let total: i64 = sqlx::query_scalar(
            r#"SELECT COUNT(*)
            FROM orders o
            WHERE $1::text IS NULL
               OR ($2::text = 'buyer' AND o.buyer_id = $1)
               OR ($2::text = 'seller' AND o.seller_id = $1)
               OR (($2::text IS NULL OR $2::text NOT IN ('buyer', 'seller'))
                   AND (o.buyer_id = $1 OR o.seller_id = $1))"#,
        )
        .bind(user_id)
        .bind(role)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let rows = sqlx::query(
            r#"
            SELECT o.id, o.listing_id, o.buyer_id, o.seller_id, o.final_price,
                   o.status, o.created_at,
                   i.title as listing_title,
                   buyer.username as buyer_username,
                   seller.username as seller_username
            FROM orders o
            JOIN inventory i ON i.id = o.listing_id
            JOIN users buyer ON buyer.id = o.buyer_id
            JOIN users seller ON seller.id = o.seller_id
            WHERE $1::text IS NULL
               OR ($2::text = 'buyer' AND o.buyer_id = $1)
               OR ($2::text = 'seller' AND o.seller_id = $1)
               OR (($2::text IS NULL OR $2::text NOT IN ('buyer', 'seller'))
                   AND (o.buyer_id = $1 OR o.seller_id = $1))
            ORDER BY o.created_at DESC
            LIMIT $3 OFFSET $4
            "#,
        )
        .bind(user_id)
        .bind(role)
        .bind(limit)
        .bind(offset)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let items = rows
            .iter()
            .map(|r| OrderSummary {
                id: r.get("id"),
                listing_id: r.get("listing_id"),
                listing_title: r.get("listing_title"),
                buyer_id: r.get("buyer_id"),
                buyer_username: r.get("buyer_username"),
                seller_id: r.get("seller_id"),
                seller_username: r.get("seller_username"),
                final_price: r.get("final_price"),
                status: r.get("status"),
                created_at: r.get("created_at"),
            })
            .collect();

        Ok((items, total))
    }

    async fn update_status(
        &self,
        order_id: &str,
        new_status: &str,
        timestamp_field: &str,
        cancellation_reason: Option<&str>,
    ) -> Result<bool, ApiError> {
        let db_result = if let Some(reason) = cancellation_reason {
            sqlx::query(&format!(
                "UPDATE orders SET status = $1, {} = NOW(), cancellation_reason = $2 WHERE id = $3",
                timestamp_field
            ))
            .bind(new_status)
            .bind(reason)
            .bind(order_id)
            .execute(&self.pool)
            .await
        } else {
            sqlx::query(&format!(
                "UPDATE orders SET status = $1, {} = NOW() WHERE id = $2",
                timestamp_field
            ))
            .bind(new_status)
            .bind(order_id)
            .execute(&self.pool)
            .await
        };

        let rows = db_result
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
            .rows_affected();
        Ok(rows > 0)
    }

    async fn count(&self) -> Result<i64, ApiError> {
        let total: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM orders")
            .fetch_one(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(total)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_infra::with_test_pool;

    #[tokio::test]
    async fn create_dual_writes_shadow_uuid_columns() {
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

            let repo = PostgresOrderRepository::new(pool.clone());
            let order_id = Uuid::new_v4().to_string();
            repo.create(&order_id, "listing-1", "buyer-1", "seller-1", 10000)
                .await
                .expect("create order");
            let order_uuid = Uuid::parse_str(&order_id).expect("uuid id");

            let listing_uuid: Uuid =
                sqlx::query_scalar("SELECT new_id FROM inventory WHERE id = 'listing-1'")
                    .fetch_one(&pool)
                    .await
                    .expect("listing uuid");
            let buyer_uuid: Uuid =
                sqlx::query_scalar("SELECT new_id FROM users WHERE id = 'buyer-1'")
                    .fetch_one(&pool)
                    .await
                    .expect("buyer uuid");
            let seller_uuid: Uuid =
                sqlx::query_scalar("SELECT new_id FROM users WHERE id = 'seller-1'")
                    .fetch_one(&pool)
                    .await
                    .expect("seller uuid");

            let row = sqlx::query(
                "SELECT new_id, new_listing_id, new_buyer_id, new_seller_id FROM orders WHERE id = $1",
            )
            .bind(&order_id)
            .fetch_one(&pool)
            .await
            .expect("select order");

            assert_eq!(row.get::<Uuid, _>("new_id"), order_uuid);
            assert_eq!(row.get::<Uuid, _>("new_listing_id"), listing_uuid);
            assert_eq!(row.get::<Uuid, _>("new_buyer_id"), buyer_uuid);
            assert_eq!(row.get::<Uuid, _>("new_seller_id"), seller_uuid);

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
            let pending_order_uuid = Uuid::parse_str(&pending_order_id).expect("uuid id");

            let pending_row = sqlx::query(
                "SELECT new_id, new_listing_id, new_buyer_id, new_seller_id FROM orders WHERE id = $1",
            )
            .bind(&pending_order_id)
            .fetch_one(&pool)
            .await
            .expect("select pending order");

            assert_eq!(pending_row.get::<Uuid, _>("new_id"), pending_order_uuid);
            assert_eq!(pending_row.get::<Uuid, _>("new_listing_id"), listing_uuid);
            assert_eq!(pending_row.get::<Uuid, _>("new_buyer_id"), buyer_uuid);
            assert_eq!(pending_row.get::<Uuid, _>("new_seller_id"), seller_uuid);
        })
        .await;
    }
}
