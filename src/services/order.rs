use anyhow::Result;
use chrono::{DateTime, Utc};
use sqlx::{PgPool, Postgres, Row, Transaction};

use crate::api::metrics::GLOBAL_METRICS;
use crate::repositories::{
    OrderTimestampField, PostgresListingRepository, PostgresOrderRepository,
};

#[derive(Clone)]
pub struct OrderService {
    db: PgPool,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum OrderStatus {
    Pending,
    Paid,
    Shipped,
    Completed,
    Cancelled,
}

impl std::fmt::Display for OrderStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            OrderStatus::Pending => write!(f, "pending"),
            OrderStatus::Paid => write!(f, "paid"),
            OrderStatus::Shipped => write!(f, "shipped"),
            OrderStatus::Completed => write!(f, "completed"),
            OrderStatus::Cancelled => write!(f, "cancelled"),
        }
    }
}

impl OrderStatus {
    pub fn parse_status(s: &str) -> Option<Self> {
        match s {
            "pending" => Some(Self::Pending),
            "paid" => Some(Self::Paid),
            "shipped" => Some(Self::Shipped),
            "completed" => Some(Self::Completed),
            "cancelled" => Some(Self::Cancelled),
            _ => None,
        }
    }

    /// Valid transitions: pending→paid, paid→shipped, shipped→completed, pending→cancelled, paid→cancelled
    pub fn can_transition_to(&self, next: &OrderStatus) -> bool {
        matches!(
            (self, next),
            (OrderStatus::Pending, OrderStatus::Paid)
                | (OrderStatus::Pending, OrderStatus::Cancelled)
                | (OrderStatus::Paid, OrderStatus::Shipped)
                | (OrderStatus::Paid, OrderStatus::Cancelled)
                | (OrderStatus::Shipped, OrderStatus::Completed)
        )
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
    #[error("Database error: {0}")]
    Db(#[from] sqlx::Error),
    #[error("Repository error: {0}")]
    Repo(#[from] crate::api::error::ApiError),
}

// sqlx row types — use FromRow derive + column name aliases
pub type OrderSummaryRow = SqlxOrderSummaryRow;

impl OrderService {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    /// Create a new order. Returns the order ID.
    pub async fn create_order(
        &self,
        listing_id: &str,
        buyer_id: &str,
        seller_id: &str,
        final_price: i64,
    ) -> Result<String, OrderError> {
        let mut tx: sqlx::Transaction<'_, sqlx::Postgres> = sqlx::Acquire::begin(&self.db)
            .await
            .map_err(OrderError::Db)?;

        let order_id = self
            .create_order_in_tx(&mut tx, listing_id, buyer_id, seller_id, final_price)
            .await?;

        tx.commit().await.map_err(OrderError::Db)?;

        if let Some(metrics) = GLOBAL_METRICS.get() {
            metrics.record_order_created();
        }

        Ok(order_id)
    }

    /// Create a pending order inside an existing transaction.
    ///
    /// Callers that own additional state transitions can use this to keep the
    /// listing active->sold mutation, order insert, and their own writes atomic.
    pub async fn create_order_in_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        listing_id: &str,
        buyer_id: &str,
        seller_id: &str,
        final_price: i64,
    ) -> Result<String, OrderError> {
        let listing_repo = PostgresListingRepository::new(self.db.clone());
        let order_repo = PostgresOrderRepository::new(self.db.clone());

        if !listing_repo
            .mark_sold_if_active_in_tx(tx, listing_id)
            .await
            .map_err(OrderError::Repo)?
        {
            return Err(OrderError::AlreadySold);
        }

        let order_id = uuid::Uuid::new_v4().to_string();

        order_repo
            .create_pending_in_tx(tx, &order_id, listing_id, buyer_id, seller_id, final_price)
            .await
            .map_err(OrderError::Repo)?;

        Ok(order_id)
    }

    /// Get order with buyer/seller info using a direct joined query.
    pub async fn get_order_with_details(
        &self,
        order_id: &str,
    ) -> Result<Option<SqlxOrderRow>, OrderError> {
        let row = sqlx::query_as::<_, SqlxOrderRow>(
            r#"
            SELECT o.id, o.listing_id, o.buyer_id, o.seller_id, o.final_price,
                   o.status, o.cancellation_reason,
                   o.paid_at, o.shipped_at, o.completed_at, o.cancelled_at, o.created_at,
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
        .bind(order_id)
        .fetch_optional(&self.db)
        .await
        .map_err(OrderError::Db)?;

        Ok(row)
    }

    /// Get paginated orders for a user.
    pub async fn list_orders(
        &self,
        user_id: &str,
        role: Option<&str>,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<OrderSummaryRow>, i64), OrderError> {
        let (where_clause, total): (String, i64) = match role {
            Some("buyer") => {
                let count: i64 =
                    sqlx::query_scalar("SELECT COUNT(*) FROM orders WHERE buyer_id = $1")
                        .bind(user_id)
                        .fetch_one(&self.db)
                        .await
                        .map_err(OrderError::Db)?;
                ("WHERE o.buyer_id = $1".to_string(), count)
            }
            Some("seller") => {
                let count: i64 =
                    sqlx::query_scalar("SELECT COUNT(*) FROM orders WHERE seller_id = $1")
                        .bind(user_id)
                        .fetch_one(&self.db)
                        .await
                        .map_err(OrderError::Db)?;
                ("WHERE o.seller_id = $1".to_string(), count)
            }
            _ => {
                let count: i64 = sqlx::query_scalar(
                    "SELECT COUNT(*) FROM orders WHERE buyer_id = $1 OR seller_id = $1",
                )
                .bind(user_id)
                .fetch_one(&self.db)
                .await
                .map_err(OrderError::Db)?;
                (
                    "WHERE (o.buyer_id = $1 OR o.seller_id = $1)".to_string(),
                    count,
                )
            }
        };

        let rows = sqlx::query_as::<_, SqlxOrderSummaryRow>(&format!(
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
            {}
            ORDER BY o.created_at DESC
            LIMIT $2 OFFSET $3
            "#,
            where_clause
        ))
        .bind(user_id)
        .bind(limit)
        .bind(offset)
        .fetch_all(&self.db)
        .await
        .map_err(OrderError::Db)?;

        Ok((rows, total))
    }

    /// Admin: Get all orders across the platform.
    pub async fn admin_list_orders(
        &self,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<OrderSummaryRow>, i64), OrderError> {
        let total: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM orders")
            .fetch_one(&self.db)
            .await
            .map_err(OrderError::Db)?;

        let rows = sqlx::query_as::<_, SqlxOrderSummaryRow>(
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
            ORDER BY o.created_at DESC
            LIMIT $1 OFFSET $2
            "#,
        )
        .bind(limit)
        .bind(offset)
        .fetch_all(&self.db)
        .await
        .map_err(OrderError::Db)?;

        Ok((rows, total))
    }

    /// Transition order to a new status atomically.
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

        let timestamp_field = match next {
            OrderStatus::Paid => OrderTimestampField::Paid,
            OrderStatus::Shipped => OrderTimestampField::Shipped,
            OrderStatus::Completed => OrderTimestampField::Completed,
            OrderStatus::Cancelled => OrderTimestampField::Cancelled,
            OrderStatus::Pending => return Ok(false),
        };

        let listing_repo = PostgresListingRepository::new(self.db.clone());
        let order_repo = PostgresOrderRepository::new(self.db.clone());
        let mut tx = self.db.begin().await.map_err(OrderError::Db)?;

        let updated_listing_id = order_repo
            .update_status_in_tx(
                &mut tx,
                order_id,
                expected_current,
                new_status,
                timestamp_field,
                cancellation_reason,
            )
            .await
            .map_err(OrderError::Repo)?;

        let Some(listing_id) = updated_listing_id else {
            tx.rollback().await.map_err(OrderError::Db)?;
            return Ok(false);
        };

        if next == OrderStatus::Cancelled {
            let _ = listing_repo
                .relist_if_no_open_orders_in_tx(&mut tx, &listing_id)
                .await
                .map_err(OrderError::Repo)?;
        }

        tx.commit().await.map_err(OrderError::Db)?;

        if let Some(metrics) = GLOBAL_METRICS.get() {
            match next {
                OrderStatus::Paid => metrics.record_order_paid(),
                OrderStatus::Shipped => metrics.record_order_shipped(),
                OrderStatus::Completed => metrics.record_order_completed(),
                OrderStatus::Cancelled => metrics.record_order_cancelled(),
                OrderStatus::Pending => {}
            }
        }

        Ok(true)
    }

    /// Verify user is buyer or seller of the order.
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

    /// Get order status and price.
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

// sqlx row types — use FromRow derive + column name aliases
#[derive(sqlx::FromRow)]
pub struct SqlxOrderRow {
    pub id: String,
    pub listing_id: String,
    pub buyer_id: String,
    pub seller_id: String,
    pub final_price: i64,
    pub status: String,
    pub cancellation_reason: Option<String>,
    pub paid_at: Option<DateTime<Utc>>,
    pub shipped_at: Option<DateTime<Utc>>,
    pub completed_at: Option<DateTime<Utc>>,
    pub cancelled_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub buyer_username: String,
    pub seller_username: String,
    pub listing_title: String,
}

#[derive(sqlx::FromRow)]
pub struct SqlxOrderSummaryRow {
    pub id: String,
    pub listing_id: String,
    pub buyer_id: String,
    pub seller_id: String,
    pub final_price: i64,
    pub status: String,
    pub created_at: DateTime<Utc>,
    pub buyer_username: String,
    pub seller_username: String,
    pub listing_title: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_order_status_display() {
        assert_eq!(OrderStatus::Pending.to_string(), "pending");
        assert_eq!(OrderStatus::Paid.to_string(), "paid");
        assert_eq!(OrderStatus::Shipped.to_string(), "shipped");
        assert_eq!(OrderStatus::Completed.to_string(), "completed");
        assert_eq!(OrderStatus::Cancelled.to_string(), "cancelled");
    }

    #[test]
    fn test_order_status_from_str() {
        assert_eq!(
            OrderStatus::parse_status("pending"),
            Some(OrderStatus::Pending)
        );
        assert_eq!(OrderStatus::parse_status("paid"), Some(OrderStatus::Paid));
        assert_eq!(OrderStatus::parse_status("invalid"), None);
    }

    #[test]
    fn test_order_status_valid_transitions() {
        assert!(OrderStatus::Pending.can_transition_to(&OrderStatus::Paid));
        assert!(OrderStatus::Pending.can_transition_to(&OrderStatus::Cancelled));
        assert!(OrderStatus::Paid.can_transition_to(&OrderStatus::Shipped));
        assert!(OrderStatus::Paid.can_transition_to(&OrderStatus::Cancelled));
        assert!(OrderStatus::Shipped.can_transition_to(&OrderStatus::Completed));
    }

    #[test]
    fn test_order_status_invalid_transitions() {
        assert!(!OrderStatus::Pending.can_transition_to(&OrderStatus::Shipped));
        assert!(!OrderStatus::Pending.can_transition_to(&OrderStatus::Completed));
        assert!(!OrderStatus::Shipped.can_transition_to(&OrderStatus::Cancelled));
        assert!(!OrderStatus::Completed.can_transition_to(&OrderStatus::Cancelled));
        assert!(!OrderStatus::Cancelled.can_transition_to(&OrderStatus::Paid));
    }
}
