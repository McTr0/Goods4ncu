//! Camphor leaf (香樟叶) currency: daily login grants + post fertilizing.
//!
//! Mirrors bilibili's coin mechanics: one leaf per UTC day (lazily settled,
//! idempotent via partial unique index), spend one leaf to fertilize a post
//! (once per post per user, irreversible). Balance is the ledger sum.

use sqlx::PgPool;
use uuid::Uuid;

use crate::api::error::ApiError;

#[derive(Debug, Clone)]
pub struct CamphorService {
    pool: PgPool,
}

impl CamphorService {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Settle today's login grant. Idempotent: the partial unique index
    /// swallows duplicate inserts, so calling this on every request is safe.
    /// Returns the balance after settlement.
    pub async fn settle_daily_grant(
        &self,
        campus_id: Uuid,
        user_id: &str,
    ) -> Result<i64, ApiError> {
        let result = sqlx::query(
            "INSERT INTO camphor_ledger (campus_id, user_id, amount, reason)
             VALUES ($1, $2, 1, 'daily_grant')
             ON CONFLICT DO NOTHING",
        )
        .bind(campus_id)
        .bind(user_id)
        .execute(&self.pool)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {error}")))?;
        let _ = result;
        self.balance(user_id).await
    }

    pub async fn balance(&self, user_id: &str) -> Result<i64, ApiError> {
        let balance: i64 = sqlx::query_scalar(
            "SELECT COALESCE(SUM(amount), 0)::bigint FROM camphor_ledger WHERE user_id = $1",
        )
        .bind(user_id)
        .fetch_one(&self.pool)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {error}")))?;
        Ok(balance)
    }

    /// Spend one leaf fertilizing a post. Transactional: ledger insert and
    /// counter bump commit or roll back together.
    pub async fn fertilize(
        &self,
        campus_id: Uuid,
        user_id: &str,
        post_id: Uuid,
    ) -> Result<(i64, i32), ApiError> {
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {error}")))?;

        // Post must be live and cannot be the caller's own.
        let author_id: Option<String> = sqlx::query_scalar(
            "SELECT author_id FROM posts
             WHERE id = $1 AND campus_id = $2 AND status IN ('active', 'locked')",
        )
        .bind(post_id)
        .bind(campus_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {error}")))?;
        let Some(author_id) = author_id else {
            return Err(ApiError::NotFound);
        };
        if author_id == user_id {
            return Err(ApiError::BadRequest("不能给自己的帖子施肥".to_string()));
        }

        let already: bool = sqlx::query_scalar(
            "SELECT EXISTS (
                 SELECT 1 FROM camphor_ledger
                 WHERE reason = 'fertilize' AND post_id = $1 AND user_id = $2
             )",
        )
        .bind(post_id)
        .bind(user_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {error}")))?;
        if already {
            return Err(ApiError::BadRequest("已经给这篇帖子施过肥了".to_string()));
        }

        let balance = self.balance_in_tx(&mut tx, user_id).await?;
        if balance < 1 {
            return Err(ApiError::BadRequest(
                "香樟叶不足，明天登录再来吧".to_string(),
            ));
        }

        sqlx::query(
            "INSERT INTO camphor_ledger (campus_id, user_id, amount, reason, post_id)
             VALUES ($1, $2, -1, 'fertilize', $3)",
        )
        .bind(campus_id)
        .bind(user_id)
        .bind(post_id)
        .execute(&mut *tx)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {error}")))?;

        let new_count: i32 = sqlx::query_scalar(
            "UPDATE posts SET fertilizer_count = fertilizer_count + 1, updated_at = NOW()
             WHERE id = $1 RETURNING fertilizer_count",
        )
        .bind(post_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {error}")))?;

        tx.commit()
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {error}")))?;

        let balance = self.balance(user_id).await?;
        Ok((balance, new_count))
    }

    async fn balance_in_tx(
        &self,
        tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
        user_id: &str,
    ) -> Result<i64, ApiError> {
        let balance: i64 = sqlx::query_scalar(
            "SELECT COALESCE(SUM(amount), 0)::bigint FROM camphor_ledger WHERE user_id = $1",
        )
        .bind(user_id)
        .fetch_one(&mut **tx)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {error}")))?;
        Ok(balance)
    }
}
