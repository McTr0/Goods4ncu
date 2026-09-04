//! PostgreSQL implementation of the AuthRepository trait.

use crate::api::error::ApiError;
use crate::repositories::{AuthRepository, RefreshTokenRecord, User};
use chrono::{DateTime, Utc};
use sqlx::{PgPool, Row};
use uuid::Uuid;

#[derive(Clone)]
#[allow(dead_code)]
pub struct PostgresAuthRepository {
    pool: PgPool,
}

impl PostgresAuthRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

impl AuthRepository for PostgresAuthRepository {
    async fn find_user_by_username(&self, username: &str) -> Result<Option<User>, ApiError> {
        let row = sqlx::query_as::<_, User>("SELECT * FROM users WHERE username = $1")
            .bind(username)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(row)
    }

    async fn find_user_by_email(&self, email: &str) -> Result<Option<User>, ApiError> {
        let row = sqlx::query_as::<_, User>("SELECT * FROM users WHERE email = $1")
            .bind(email)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(row)
    }

    async fn create_user(
        &self,
        username: &str,
        email: Option<&str>,
        password_hash: &str,
    ) -> Result<String, ApiError> {
        let user_id = uuid::Uuid::new_v4().to_string();
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let result = if let Some(e) = email {
            sqlx::query(
                "INSERT INTO users (id, username, email, password_hash, role) VALUES ($1, $2, $3, $4, $5)",
            )
            .bind(&user_id)
            .bind(username)
            .bind(e)
            .bind(password_hash)
            .bind("user")
            .execute(&mut *tx)
            .await
        } else {
            sqlx::query(
                "INSERT INTO users (id, username, password_hash, role) VALUES ($1, $2, $3, $4)",
            )
            .bind(&user_id)
            .bind(username)
            .bind(password_hash)
            .bind("user")
            .execute(&mut *tx)
            .await
        };

        match result {
            Ok(_) => {
                // Route the initial pending membership by the registration
                // email's domain (second-campus onboarding); fall back to the
                // NCU default for email-less or unmatched registrations.
                let membership = sqlx::query(
                    "WITH matched AS (
                        SELECT c.id
                        FROM campuses c
                        WHERE c.status = 'active'
                          AND $2::text IS NOT NULL
                          AND EXISTS (
                              SELECT 1 FROM unnest(c.email_domains) AS d
                              WHERE lower($2) LIKE '%@' || lower(d)
                          )
                        ORDER BY (c.slug = 'ncu') DESC, c.created_at ASC
                        LIMIT 1
                     )
                     INSERT INTO campus_memberships (
                        campus_id, user_id, status, role, verification_method
                     )
                     SELECT COALESCE(
                                (SELECT id FROM matched),
                                (SELECT id FROM campuses
                                 WHERE slug = 'ncu' AND status = 'active')
                            ),
                            $1, 'pending', 'member', 'registration'
                     ON CONFLICT (campus_id, user_id) DO NOTHING",
                )
                .bind(&user_id)
                .bind(email)
                .execute(&mut *tx)
                .await
                .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

                if membership.rows_affected() != 1 {
                    return Err(ApiError::Internal(anyhow::anyhow!(
                        "Default campus is missing or inactive"
                    )));
                }

                tx.commit()
                    .await
                    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
                Ok(user_id)
            }
            Err(e) => {
                // PostgreSQL unique violation code = "23505"
                if let sqlx::Error::Database(db_err) = &e {
                    if db_err.code().as_deref() == Some("23505") {
                        return Err(ApiError::Conflict(
                            "用户名或邮箱已被使用，请换一个".to_string(),
                        ));
                    }
                }
                Err(ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))
            }
        }
    }

    async fn store_refresh_token(
        &self,
        user_id: &str,
        token_hash: &str,
        expires_at: DateTime<Utc>,
        campus_id: Option<Uuid>,
    ) -> Result<(), ApiError> {
        sqlx::query(
            "INSERT INTO refresh_tokens (user_id, token_hash, expires_at, campus_id)
             VALUES ($1, $2, $3, $4)",
        )
        .bind(user_id)
        .bind(token_hash)
        .bind(expires_at)
        .bind(campus_id)
        .execute(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(())
    }

    async fn find_refresh_token(
        &self,
        token_hash: &str,
    ) -> Result<Option<RefreshTokenRecord>, ApiError> {
        let row = sqlx::query(
            "SELECT user_id, revoked_at, expires_at, campus_id
             FROM refresh_tokens WHERE token_hash = $1",
        )
        .bind(token_hash)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(row.map(|r| RefreshTokenRecord {
            user_id: r.get("user_id"),
            revoked_at: r.get("revoked_at"),
            expires_at: r.get("expires_at"),
            campus_id: r.get("campus_id"),
        }))
    }

    async fn revoke_refresh_token(&self, token_hash: &str) -> Result<(), ApiError> {
        let result = sqlx::query(
            "UPDATE refresh_tokens SET revoked_at = NOW() WHERE token_hash = $1 AND revoked_at IS NULL",
        )
            .bind(token_hash)
            .execute(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        if result.rows_affected() == 0 {
            return Err(ApiError::Unauthorized);
        }

        Ok(())
    }

    async fn revoke_all_user_tokens(&self, user_id: &str) -> Result<(), ApiError> {
        sqlx::query("UPDATE refresh_tokens SET revoked_at = NOW() WHERE user_id = $1 AND revoked_at IS NULL")
            .bind(user_id)
            .execute(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(())
    }

    async fn revoke_access_token_jti(
        &self,
        jti: &str,
        expires_at: chrono::DateTime<chrono::Utc>,
    ) -> Result<(), ApiError> {
        sqlx::query(
            r#"INSERT INTO revoked_access_tokens (jti, expires_at)
               VALUES ($1, $2)
               ON CONFLICT (jti)
               DO UPDATE SET expires_at = GREATEST(revoked_access_tokens.expires_at, EXCLUDED.expires_at)"#,
        )
        .bind(jti)
        .bind(expires_at)
        .execute(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(())
    }

    async fn get_revoked_token_expiry(&self, jti: &str) -> Result<Option<i64>, ApiError> {
        let persisted_exp = sqlx::query_scalar::<_, i64>(
            "SELECT EXTRACT(EPOCH FROM expires_at)::bigint
             FROM revoked_access_tokens
             WHERE jti = $1 AND expires_at > NOW()",
        )
        .bind(jti)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(persisted_exp)
    }
}
