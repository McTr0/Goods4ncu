use anyhow::Result;
use chrono::{DateTime, Utc};
use sqlx::{PgPool, Postgres, Row, Transaction};

use crate::api::metrics::GLOBAL_METRICS;
use crate::repositories::PostgresOrderRepository;

#[derive(Clone)]
pub struct OrderService {
    db: PgPool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OrderStatus {
    IntentPending,
    Confirmed,
    Cancelled,
}

impl std::fmt::Display for OrderStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            OrderStatus::IntentPending => write!(f, "intent_pending"),
            OrderStatus::Confirmed => write!(f, "confirmed"),
            OrderStatus::Cancelled => write!(f, "cancelled"),
        }
    }
}

impl OrderStatus {
    pub fn parse_status(s: &str) -> Option<Self> {
        match s {
            "intent_pending" | "pending" => Some(Self::IntentPending),
            "confirmed" | "completed" | "paid" | "shipped" => Some(Self::Confirmed),
            "cancelled" => Some(Self::Cancelled),
            _ => None,
        }
    }

    pub fn can_transition_to(&self, next: &OrderStatus) -> bool {
        matches!(
            (self, next),
            (OrderStatus::IntentPending, OrderStatus::Confirmed)
                | (OrderStatus::IntentPending, OrderStatus::Cancelled)
                | (OrderStatus::Confirmed, OrderStatus::Cancelled)
        )
    }

    pub fn canonical(self) -> &'static str {
        match self {
            OrderStatus::IntentPending => "intent_pending",
            OrderStatus::Confirmed => "confirmed",
            OrderStatus::Cancelled => "cancelled",
        }
    }
}

#[derive(Debug, thiserror::Error)]
#[allow(dead_code)]
pub enum OrderError {
    #[error("Order not found")]
    NotFound,
    #[error("Invalid status transition: {0}")]
    InvalidTransition(String),
    #[error("Unauthorized")]
    Unauthorized,
    #[error("Forbidden")]
    Forbidden,
    #[error("Listing already sold")]
    AlreadySold,
    #[error("Idempotency key was reused with different confirmation data")]
    IdempotencyConflict,
    #[error("Database error: {0}")]
    Db(#[from] sqlx::Error),
    #[error("Repository error: {0}")]
    Repo(#[from] crate::api::error::ApiError),
}

pub type OrderSummaryRow = SqlxOrderSummaryRow;

impl OrderService {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    /// Create an offline deal intent. This intentionally does not mark the
    /// listing as sold; only seller confirmation can do that.
    pub async fn create_order(
        &self,
        listing_id: &str,
        buyer_id: &str,
        seller_id: &str,
        final_price: i64,
    ) -> Result<String, OrderError> {
        let mut tx = self.db.begin().await.map_err(OrderError::Db)?;

        let order_id = self
            .create_order_in_tx(&mut tx, listing_id, buyer_id, seller_id, final_price)
            .await?;

        tx.commit().await.map_err(OrderError::Db)?;

        if let Some(metrics) = GLOBAL_METRICS.get() {
            metrics.record_deal_intent_created();
        }

        Ok(order_id)
    }

    pub async fn create_order_in_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        listing_id: &str,
        buyer_id: &str,
        seller_id: &str,
        final_price: i64,
    ) -> Result<String, OrderError> {
        let listing_status: Option<String> =
            sqlx::query_scalar("SELECT status FROM inventory WHERE id = $1 FOR UPDATE")
                .bind(listing_id)
                .fetch_optional(&mut **tx)
                .await
                .map_err(OrderError::Db)?;

        match listing_status.as_deref() {
            Some("active") => {}
            Some(_) => return Err(OrderError::AlreadySold),
            None => return Err(OrderError::NotFound),
        }

        if let Some(existing_id) = sqlx::query_scalar::<_, String>(
            r#"
            SELECT id
            FROM orders
            WHERE listing_id = $1
              AND buyer_id = $2
              AND status = 'intent_pending'
            ORDER BY created_at DESC
            LIMIT 1
            "#,
        )
        .bind(listing_id)
        .bind(buyer_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(OrderError::Db)?
        {
            return Ok(existing_id);
        }

        let order_id = uuid::Uuid::new_v4().to_string();
        let order_repo = PostgresOrderRepository::new(self.db.clone());
        order_repo
            .create_pending_in_tx(tx, &order_id, listing_id, buyer_id, seller_id, final_price)
            .await
            .map_err(OrderError::Repo)?;

        Ok(order_id)
    }

    pub async fn confirm_order(
        &self,
        order_id: &str,
        actor_id: &str,
        auto_delist: bool,
        allow_admin: bool,
    ) -> Result<bool, OrderError> {
        self.confirm_order_with_idempotency(
            order_id,
            actor_id,
            auto_delist,
            allow_admin,
            None,
            None,
        )
        .await
    }

    pub async fn confirm_order_with_idempotency(
        &self,
        order_id: &str,
        actor_id: &str,
        auto_delist: bool,
        allow_admin: bool,
        idempotency_key: Option<&str>,
        request_hash: Option<&str>,
    ) -> Result<bool, OrderError> {
        let mut tx = self.db.begin().await.map_err(OrderError::Db)?;
        let row = sqlx::query(
            r#"
            SELECT status, listing_id, seller_id,
                   confirm_idempotency_key, confirm_request_hash
            FROM orders
            WHERE id = $1
            FOR UPDATE
            "#,
        )
        .bind(order_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(OrderError::Db)?
        .ok_or(OrderError::NotFound)?;

        let current_status: String = row.get("status");
        let listing_id: String = row.get("listing_id");
        let seller_id: String = row.get("seller_id");
        let stored_key: Option<String> = row.get("confirm_idempotency_key");
        let stored_hash: Option<String> = row.get("confirm_request_hash");

        if !allow_admin && seller_id != actor_id {
            return Err(OrderError::Forbidden);
        }

        if let (Some(key), Some(hash)) = (idempotency_key, request_hash) {
            if stored_key.as_deref() == Some(key) {
                if stored_hash.as_deref() != Some(hash) {
                    return Err(OrderError::IdempotencyConflict);
                }
                return Ok(current_status == OrderStatus::Confirmed.canonical());
            }

            let key_used_elsewhere: bool = sqlx::query_scalar(
                "SELECT EXISTS(
                    SELECT 1 FROM orders
                    WHERE seller_id = $1
                      AND confirm_idempotency_key = $2
                      AND id <> $3
                )",
            )
            .bind(&seller_id)
            .bind(key)
            .bind(order_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(OrderError::Db)?;
            if key_used_elsewhere {
                return Err(OrderError::IdempotencyConflict);
            }
        }

        let current = OrderStatus::parse_status(&current_status)
            .ok_or_else(|| OrderError::InvalidTransition(current_status.clone()))?;
        if !current.can_transition_to(&OrderStatus::Confirmed) {
            return Ok(false);
        }

        if auto_delist {
            let updated = sqlx::query(
                "UPDATE inventory SET status = 'sold' WHERE id = $1 AND status = 'active'",
            )
            .bind(&listing_id)
            .execute(&mut *tx)
            .await
            .map_err(OrderError::Db)?;

            if updated.rows_affected() == 0 {
                return Err(OrderError::AlreadySold);
            }
        }

        let confirmed_by = if actor_id.is_empty() {
            None
        } else {
            Some(actor_id)
        };
        let updated = sqlx::query(
            r#"
            UPDATE orders
            SET status = 'confirmed',
                confirmed_at = NOW(),
                confirmed_by = $2,
                auto_delist = $3,
                auto_delisted_at = CASE WHEN $3 THEN NOW() ELSE NULL END,
                confirm_idempotency_key = $4,
                confirm_request_hash = $5
            WHERE id = $1
              AND status IN ('intent_pending', 'pending')
            "#,
        )
        .bind(order_id)
        .bind(confirmed_by)
        .bind(auto_delist)
        .bind(idempotency_key)
        .bind(request_hash)
        .execute(&mut *tx)
        .await
        .map_err(OrderError::Db)?;

        if updated.rows_affected() == 0 {
            tx.rollback().await.map_err(OrderError::Db)?;
            return Ok(false);
        }

        tx.commit().await.map_err(OrderError::Db)?;

        if let Some(metrics) = GLOBAL_METRICS.get() {
            metrics.record_deal_confirmed();
        }

        Ok(true)
    }

    pub async fn cancel_order(
        &self,
        order_id: &str,
        actor_id: &str,
        reason: Option<&str>,
        allow_confirmed: bool,
        allow_admin: bool,
    ) -> Result<bool, OrderError> {
        let mut tx = self.db.begin().await.map_err(OrderError::Db)?;
        let row = sqlx::query(
            r#"
            SELECT status, buyer_id, seller_id
            FROM orders
            WHERE id = $1
            FOR UPDATE
            "#,
        )
        .bind(order_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(OrderError::Db)?
        .ok_or(OrderError::NotFound)?;

        let current_status: String = row.get("status");
        let buyer_id: String = row.get("buyer_id");
        let seller_id: String = row.get("seller_id");
        if !allow_admin && buyer_id != actor_id && seller_id != actor_id {
            return Err(OrderError::Forbidden);
        }

        let current = OrderStatus::parse_status(&current_status)
            .ok_or_else(|| OrderError::InvalidTransition(current_status.clone()))?;
        if current == OrderStatus::Confirmed && !allow_confirmed {
            return Ok(false);
        }
        if !current.can_transition_to(&OrderStatus::Cancelled) {
            return Ok(false);
        }

        let updated = sqlx::query(
            r#"
            UPDATE orders
            SET status = 'cancelled',
                cancelled_at = NOW(),
                cancellation_reason = $2
            WHERE id = $1
              AND status <> 'cancelled'
            "#,
        )
        .bind(order_id)
        .bind(reason)
        .execute(&mut *tx)
        .await
        .map_err(OrderError::Db)?;

        tx.commit().await.map_err(OrderError::Db)?;

        if updated.rows_affected() > 0 {
            if let Some(metrics) = GLOBAL_METRICS.get() {
                metrics.record_deal_cancelled();
            }
        }

        Ok(updated.rows_affected() > 0)
    }

    pub async fn get_order_with_details(
        &self,
        order_id: &str,
    ) -> Result<Option<SqlxOrderRow>, OrderError> {
        let row = sqlx::query_as::<_, SqlxOrderRow>(
            r#"
            SELECT o.id, o.listing_id, o.buyer_id, o.seller_id, o.final_price,
                   o.status, o.cancellation_reason, o.auto_delist,
                   o.confirmed_at, o.confirmed_by, o.auto_delisted_at,
                   o.paid_at, o.shipped_at, o.completed_at, o.cancelled_at, o.created_at,
                   i.title as listing_title,
                   i.status as listing_status,
                   buyer.username as buyer_username,
                   seller.username as seller_username
            FROM orders o
            JOIN inventory i ON i.id = o.listing_id
            JOIN users buyer ON buyer.id = o.buyer_id
            JOIN users seller ON seller.id = o.seller_id
            WHERE o.id = $1
            "#,
        )
        .bind(order_id)
        .fetch_optional(&self.db)
        .await
        .map_err(OrderError::Db)?;

        Ok(row)
    }

    pub async fn list_orders(
        &self,
        user_id: &str,
        role: Option<&str>,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<OrderSummaryRow>, i64), OrderError> {
        let role_filter = match role {
            Some("buyer") | Some("seller") => role,
            _ => None,
        };

        let total: i64 = sqlx::query_scalar(
            r#"
            SELECT COUNT(*)
            FROM orders o
            WHERE ($2::text = 'buyer' AND o.buyer_id = $1)
               OR ($2::text = 'seller' AND o.seller_id = $1)
               OR ($2::text IS NULL AND (o.buyer_id = $1 OR o.seller_id = $1))
            "#,
        )
        .bind(user_id)
        .bind(role_filter)
        .fetch_one(&self.db)
        .await
        .map_err(OrderError::Db)?;

        let rows = sqlx::query_as::<_, SqlxOrderSummaryRow>(
            r#"
            SELECT o.id, o.listing_id, o.buyer_id, o.seller_id, o.final_price,
                   o.status, o.auto_delist, o.confirmed_at, o.auto_delisted_at, o.created_at,
                   i.title as listing_title,
                   i.status as listing_status,
                   buyer.username as buyer_username,
                   seller.username as seller_username
            FROM orders o
            JOIN inventory i ON i.id = o.listing_id
            JOIN users buyer ON buyer.id = o.buyer_id
            JOIN users seller ON seller.id = o.seller_id
            WHERE ($2::text = 'buyer' AND o.buyer_id = $1)
               OR ($2::text = 'seller' AND o.seller_id = $1)
               OR ($2::text IS NULL AND (o.buyer_id = $1 OR o.seller_id = $1))
            ORDER BY o.created_at DESC
            LIMIT $3 OFFSET $4
            "#,
        )
        .bind(user_id)
        .bind(role_filter)
        .bind(limit)
        .bind(offset)
        .fetch_all(&self.db)
        .await
        .map_err(OrderError::Db)?;

        Ok((rows, total))
    }

    pub async fn admin_list_orders(
        &self,
        campus_id: uuid::Uuid,
        status: Option<&str>,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<OrderSummaryRow>, i64), OrderError> {
        let normalized_status = status
            .and_then(OrderStatus::parse_status)
            .map(|s| s.canonical());
        let total: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM orders
                 WHERE campus_id = $1 AND ($2::text IS NULL OR status = $2)",
        )
        .bind(campus_id)
        .bind(normalized_status)
        .fetch_one(&self.db)
        .await
        .map_err(OrderError::Db)?;

        let rows = sqlx::query_as::<_, SqlxOrderSummaryRow>(
            r#"
            SELECT o.id, o.listing_id, o.buyer_id, o.seller_id, o.final_price,
                   o.status, o.auto_delist, o.confirmed_at, o.auto_delisted_at, o.created_at,
                   i.title as listing_title,
                   i.status as listing_status,
                   buyer.username as buyer_username,
                   seller.username as seller_username
            FROM orders o
            JOIN inventory i ON i.id = o.listing_id
            JOIN users buyer ON buyer.id = o.buyer_id
            JOIN users seller ON seller.id = o.seller_id
            WHERE o.campus_id = $1 AND ($2::text IS NULL OR o.status = $2)
            ORDER BY o.created_at DESC
            LIMIT $3 OFFSET $4
            "#,
        )
        .bind(campus_id)
        .bind(normalized_status)
        .bind(limit)
        .bind(offset)
        .fetch_all(&self.db)
        .await
        .map_err(OrderError::Db)?;

        Ok((rows, total))
    }

    /// Legacy transition shim kept for older tests and callers. New public code
    /// should use confirm_order/cancel_order so payment/logistics language does
    /// not leak back into the product.
    #[allow(dead_code)]
    pub async fn transition_order_status(
        &self,
        order_id: &str,
        expected_current: &str,
        new_status: &str,
        cancellation_reason: Option<&str>,
    ) -> Result<bool, OrderError> {
        let current = OrderStatus::parse_status(expected_current).ok_or_else(|| {
            OrderError::InvalidTransition(format!("unknown current status: {expected_current}"))
        })?;
        let next = OrderStatus::parse_status(new_status).ok_or_else(|| {
            OrderError::InvalidTransition(format!("unknown new status: {new_status}"))
        })?;

        if !current.can_transition_to(&next) {
            return Ok(false);
        }

        match next {
            OrderStatus::Confirmed => self.confirm_order(order_id, "", true, true).await,
            OrderStatus::Cancelled => {
                self.cancel_order(order_id, "", cancellation_reason, true, true)
                    .await
            }
            OrderStatus::IntentPending => Ok(false),
        }
    }

    pub async fn verify_order_access(
        &self,
        order_id: &str,
        user_id: &str,
    ) -> Result<bool, OrderError> {
        let row = sqlx::query("SELECT buyer_id, seller_id FROM orders WHERE id = $1")
            .bind(order_id)
            .fetch_optional(&self.db)
            .await
            .map_err(OrderError::Db)?;
        match row {
            Some(r) => {
                let buyer_id: String = r.get("buyer_id");
                let seller_id: String = r.get("seller_id");
                Ok(buyer_id == user_id || seller_id == user_id)
            }
            None => Ok(false),
        }
    }

    #[allow(dead_code)]
    pub async fn get_order_meta(
        &self,
        order_id: &str,
    ) -> Result<Option<(String, i64)>, OrderError> {
        let row = sqlx::query("SELECT status, final_price FROM orders WHERE id = $1")
            .bind(order_id)
            .fetch_optional(&self.db)
            .await
            .map_err(OrderError::Db)?;
        Ok(row.map(|r| {
            let status: String = r.get("status");
            let final_price: i64 = r.get("final_price");
            (status, final_price)
        }))
    }
}

#[derive(sqlx::FromRow)]
pub struct SqlxOrderRow {
    pub id: String,
    pub listing_id: String,
    pub buyer_id: String,
    pub seller_id: String,
    pub final_price: i64,
    pub status: String,
    pub cancellation_reason: Option<String>,
    pub auto_delist: bool,
    pub confirmed_at: Option<DateTime<Utc>>,
    pub confirmed_by: Option<String>,
    pub auto_delisted_at: Option<DateTime<Utc>>,
    pub paid_at: Option<DateTime<Utc>>,
    pub shipped_at: Option<DateTime<Utc>>,
    pub completed_at: Option<DateTime<Utc>>,
    pub cancelled_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub buyer_username: String,
    pub seller_username: String,
    pub listing_title: String,
    pub listing_status: String,
}

#[derive(sqlx::FromRow)]
pub struct SqlxOrderSummaryRow {
    pub id: String,
    pub listing_id: String,
    pub buyer_id: String,
    pub seller_id: String,
    pub final_price: i64,
    pub status: String,
    pub auto_delist: bool,
    pub confirmed_at: Option<DateTime<Utc>>,
    pub auto_delisted_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub buyer_username: String,
    pub seller_username: String,
    pub listing_title: String,
    pub listing_status: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_infra::with_test_pool;
    use uuid::Uuid;

    #[test]
    fn test_order_status_display() {
        assert_eq!(OrderStatus::IntentPending.to_string(), "intent_pending");
        assert_eq!(OrderStatus::Confirmed.to_string(), "confirmed");
        assert_eq!(OrderStatus::Cancelled.to_string(), "cancelled");
    }

    #[test]
    fn test_order_status_from_str_keeps_legacy_aliases() {
        assert_eq!(
            OrderStatus::parse_status("pending"),
            Some(OrderStatus::IntentPending)
        );
        assert_eq!(
            OrderStatus::parse_status("intent_pending"),
            Some(OrderStatus::IntentPending)
        );
        assert_eq!(
            OrderStatus::parse_status("paid"),
            Some(OrderStatus::Confirmed)
        );
        assert_eq!(
            OrderStatus::parse_status("shipped"),
            Some(OrderStatus::Confirmed)
        );
        assert_eq!(
            OrderStatus::parse_status("completed"),
            Some(OrderStatus::Confirmed)
        );
        assert_eq!(OrderStatus::parse_status("invalid"), None);
    }

    #[test]
    fn test_order_status_valid_transitions() {
        assert!(OrderStatus::IntentPending.can_transition_to(&OrderStatus::Confirmed));
        assert!(OrderStatus::IntentPending.can_transition_to(&OrderStatus::Cancelled));
        assert!(OrderStatus::Confirmed.can_transition_to(&OrderStatus::Cancelled));
    }

    #[test]
    fn test_order_status_invalid_transitions() {
        assert!(!OrderStatus::Confirmed.can_transition_to(&OrderStatus::IntentPending));
        assert!(!OrderStatus::Cancelled.can_transition_to(&OrderStatus::Confirmed));
        assert!(!OrderStatus::Cancelled.can_transition_to(&OrderStatus::IntentPending));
    }

    #[tokio::test]
    async fn confirm_order_is_idempotent_and_rejects_key_reuse() {
        with_test_pool(|pool| async move {
            let seller_id = Uuid::new_v4().to_string();
            let buyer_id = Uuid::new_v4().to_string();
            let listing_id = Uuid::new_v4().to_string();
            let order_id = Uuid::new_v4().to_string();

            for (id, username) in [
                (&seller_id, "confirm_idempotent_seller"),
                (&buyer_id, "confirm_idempotent_buyer"),
            ] {
                sqlx::query(
                    "INSERT INTO users (id, username, password_hash, role, status)
                     VALUES ($1, $2, 'test-hash', 'user', 'active')",
                )
                .bind(id)
                .bind(format!("{}_{}", username, &id[..8]))
                .execute(&pool)
                .await
                .expect("insert order idempotency user");
            }

            sqlx::query(
                "INSERT INTO inventory (
                    id, title, category, brand, condition_score,
                    suggested_price_cny, defects, description, owner_id, status
                 ) VALUES ($1, 'Idempotent listing', 'other', 'Test', 8,
                    10000, '[]', 'Test listing', $2, 'active')",
            )
            .bind(&listing_id)
            .bind(&seller_id)
            .execute(&pool)
            .await
            .expect("insert order idempotency listing");

            sqlx::query(
                "INSERT INTO orders (
                    id, listing_id, buyer_id, seller_id, final_price, status
                 ) VALUES ($1, $2, $3, $4, 9000, 'intent_pending')",
            )
            .bind(&order_id)
            .bind(&listing_id)
            .bind(&buyer_id)
            .bind(&seller_id)
            .execute(&pool)
            .await
            .expect("insert order idempotency order");

            let service = OrderService::new(pool.clone());
            let request_hash = "a".repeat(64);
            assert!(service
                .confirm_order_with_idempotency(
                    &order_id,
                    &seller_id,
                    true,
                    false,
                    Some("confirm-attempt-1"),
                    Some(&request_hash),
                )
                .await
                .expect("first confirmation"));

            assert!(service
                .confirm_order_with_idempotency(
                    &order_id,
                    &seller_id,
                    true,
                    false,
                    Some("confirm-attempt-1"),
                    Some(&request_hash),
                )
                .await
                .expect("replayed confirmation"));

            let listing_status: String =
                sqlx::query_scalar("SELECT status FROM inventory WHERE id = $1")
                    .bind(&listing_id)
                    .fetch_one(&pool)
                    .await
                    .expect("listing status");
            assert_eq!(listing_status, "sold");

            let conflict = service
                .confirm_order_with_idempotency(
                    &order_id,
                    &seller_id,
                    false,
                    false,
                    Some("confirm-attempt-1"),
                    Some(&"b".repeat(64)),
                )
                .await
                .expect_err("changed request must conflict");
            assert!(matches!(conflict, OrderError::IdempotencyConflict));
        })
        .await;
    }
}
