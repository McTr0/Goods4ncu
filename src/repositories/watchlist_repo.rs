//! Repository for user watchlist persistence operations.

use sqlx::{PgPool, Postgres, Row, Transaction};
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

#[derive(Debug, Clone)]
pub struct WatchlistListingTarget {
    pub owner_id: String,
    pub status: String,
    pub restricted: bool,
}

#[derive(Clone)]
pub struct PostgresWatchlistRepository {
    pool: PgPool,
}

impl PostgresWatchlistRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn list_watchlist(
        &self,
        user_id: &str,
        limit: i64,
        offset: i64,
    ) -> sqlx::Result<(Vec<WatchlistRow>, i64)> {
        let count_row = sqlx::query(
            "SELECT COUNT(*) as cnt FROM watchlist w \
             JOIN inventory i ON w.listing_id = i.id \
             WHERE w.user_id = $1 AND i.status = 'active' \
               AND NOT listing_has_active_restriction(i.id)",
        )
        .bind(user_id)
        .fetch_one(&self.pool)
        .await?;
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
        .await?;

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

    pub async fn get_listing_for_watch(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        listing_id: &str,
        campus_id: Uuid,
    ) -> sqlx::Result<Option<WatchlistListingTarget>> {
        let row = sqlx::query(
            "SELECT owner_id, status FROM inventory
             WHERE id = $1 AND campus_id = $2 FOR UPDATE",
        )
        .bind(listing_id)
        .bind(campus_id)
        .fetch_optional(&mut **tx)
        .await?;

        let Some(row) = row else {
            return Ok(None);
        };

        let owner_id: String = row.get("owner_id");
        let status: String = row.get("status");
        let restricted: bool = sqlx::query_scalar("SELECT listing_has_active_restriction($1)")
            .bind(listing_id)
            .fetch_one(&mut **tx)
            .await?;

        Ok(Some(WatchlistListingTarget {
            owner_id,
            status,
            restricted,
        }))
    }

    pub async fn insert(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        user_id: &str,
        listing_id: &str,
    ) -> sqlx::Result<()> {
        sqlx::query(
            "INSERT INTO watchlist (user_id, listing_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
        )
        .bind(user_id)
        .bind(listing_id)
        .execute(&mut **tx)
        .await?;
        Ok(())
    }

    pub async fn delete(&self, user_id: &str, listing_id: &str) -> sqlx::Result<()> {
        sqlx::query("DELETE FROM watchlist WHERE user_id = $1 AND listing_id = $2")
            .bind(user_id)
            .bind(listing_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn exists(&self, user_id: &str, listing_id: &str) -> sqlx::Result<bool> {
        let row = sqlx::query("SELECT 1 FROM watchlist WHERE user_id = $1 AND listing_id = $2")
            .bind(user_id)
            .bind(listing_id)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.is_some())
    }
}
