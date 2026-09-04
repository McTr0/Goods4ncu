//! Repository for user watchlist operations.

use crate::api::error::ApiError;
use sqlx::{PgPool, Row};
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct WatchlistRow {
    pub listing_id: String,
    pub title: String,
    pub category: String,
    pub brand: String,
    pub condition_score: i32,
    pub suggested_price_cny: i64,
    pub status: String,
    pub owner_id: String,
    pub created_at: Option<chrono::DateTime<chrono::Utc>>,
}

#[derive(Clone)]
pub struct PostgresWatchlistRepository {
    pool: PgPool,
}

impl PostgresWatchlistRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn get_watchlist(
        &self,
        user_id: &str,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<WatchlistRow>, i64), ApiError> {
        let count_row = sqlx::query(
            "SELECT COUNT(*) as cnt FROM watchlist w \
             JOIN inventory i ON w.listing_id = i.id \
             WHERE w.user_id = $1 AND i.status = 'active' \
               AND NOT listing_has_active_restriction(i.id)",
        )
        .bind(user_id)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        let total: i64 = count_row.try_get("cnt").unwrap_or(0);

        let rows = sqlx::query(
            r#"
            SELECT i.id as listing_id, i.title, i.category, i.brand, i.condition_score,
                   i.suggested_price_cny, i.status, i.owner_id, i.created_at
            FROM watchlist w
            JOIN inventory i ON w.listing_id = i.id
            WHERE w.user_id = $1 AND i.status = 'active'
              AND NOT listing_has_active_restriction(i.id)
            ORDER BY w.created_at DESC
            LIMIT $2 OFFSET $3
            "#,
        )
        .bind(user_id)
        .bind(limit)
        .bind(offset)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let items = rows
            .into_iter()
            .map(|row| WatchlistRow {
                listing_id: row.get("listing_id"),
                title: row.get("title"),
                category: row.get("category"),
                brand: row.try_get("brand").ok().flatten().unwrap_or_default(),
                condition_score: row.get("condition_score"),
                suggested_price_cny: row.get("suggested_price_cny"),
                status: row.get("status"),
                owner_id: row.get("owner_id"),
                created_at: row.try_get("created_at").ok(),
            })
            .collect();

        Ok((items, total))
    }

    pub async fn add_to_watchlist(
        &self,
        user_id: &str,
        listing_id: &str,
        campus_id: Uuid,
    ) -> Result<(), ApiError> {
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let listing = sqlx::query(
            "SELECT owner_id, status FROM inventory
             WHERE id = $1 AND campus_id = $2 FOR UPDATE",
        )
        .bind(listing_id)
        .bind(campus_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        .ok_or(ApiError::NotFound)?;

        let owner_id: String = listing.get("owner_id");
        let status: String = listing.get("status");
        let restricted: bool = sqlx::query_scalar("SELECT listing_has_active_restriction($1)")
            .bind(listing_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        if status != "active" || restricted {
            return Err(ApiError::NotFound);
        }
        if owner_id == user_id {
            return Err(ApiError::BadRequest("不能收藏自己的商品".to_string()));
        }

        sqlx::query(
            "INSERT INTO watchlist (user_id, listing_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
        )
        .bind(user_id)
        .bind(listing_id)
        .execute(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        tx.commit()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(())
    }

    pub async fn remove_from_watchlist(
        &self,
        user_id: &str,
        listing_id: &str,
    ) -> Result<(), ApiError> {
        sqlx::query("DELETE FROM watchlist WHERE user_id = $1 AND listing_id = $2")
            .bind(user_id)
            .bind(listing_id)
            .execute(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(())
    }

    pub async fn check_watchlist(&self, user_id: &str, listing_id: &str) -> Result<bool, ApiError> {
        let exists = sqlx::query("SELECT 1 FROM watchlist WHERE user_id = $1 AND listing_id = $2")
            .bind(user_id)
            .bind(listing_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
            .is_some();
        Ok(exists)
    }
}
