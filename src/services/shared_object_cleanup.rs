//! Durable cleanup for remote files referenced by shared chat objects and
//! revoked SocialPersona assets.
//!
//! Database revocation is the user-visible authority. The object-store DELETE
//! is deliberately asynchronous so a slow provider cannot hold the revoke
//! request open. Claims are leased in Postgres, failures are retried with
//! backoff, and a missing remote object is treated as an idempotent success.

use std::time::Duration;

use sqlx::{PgPool, Row};
use uuid::Uuid;

use crate::lifecycle::{sleep_or_shutdown, ShutdownSignal};
use crate::services::storage::PrivateBucket;

const POLL_INTERVAL_SECS: u64 = 30;
const MAX_CLAIMS_PER_CYCLE: i64 = 32;
const CLAIM_LEASE_SECS: i64 = 300;
const MAX_BACKOFF_SECS: i64 = 3600;
/// A client may resume an upload for a while, but an abandoned server-keyed
/// candidate must not retain a bucket object forever.  Expiry only applies to
/// `pending_upload`; verified/reviewing assets remain governed by moderation.
const PENDING_UPLOAD_TTL_SECS: i64 = 24 * 60 * 60;

#[derive(Clone)]
pub struct SharedObjectCleanupConfig {
    /// `None` means storage deletion is not configured in this deployment.
    /// The worker remains idle and never marks a row as cleaned in that case.
    pub bucket: Option<PrivateBucket>,
    pub request_timeout_secs: u64,
}

#[derive(Debug, sqlx::FromRow)]
struct CleanupClaim {
    id: Uuid,
    storage_key: String,
    cleanup_attempts: i32,
}

/// Run until the shared process shutdown signal fires.
pub async fn run(db: PgPool, config: SharedObjectCleanupConfig, shutdown: ShutdownSignal) {
    if config.bucket.is_none() {
        tracing::warn!(
            "shared-object cleanup worker is idle: object-store delete credentials are not configured"
        );
    } else {
        tracing::info!("shared-object cleanup worker started");
    }

    let mut backoff_secs = POLL_INTERVAL_SECS;
    loop {
        if config.bucket.is_some() {
            match process_cycle(&db, &config).await {
                Ok(count) => {
                    if count > 0 {
                        tracing::debug!(count, "shared-object cleanup claims processed");
                    }
                    backoff_secs = POLL_INTERVAL_SECS;
                }
                Err(error) => {
                    tracing::error!(%error, "shared-object cleanup cycle failed");
                    backoff_secs = (backoff_secs * 2).min(MAX_BACKOFF_SECS as u64);
                }
            }
        }

        if !sleep_or_shutdown(Duration::from_secs(backoff_secs), &shutdown)
            .await
            .should_continue()
        {
            break;
        }
    }

    tracing::info!("shared-object cleanup worker stopped");
}

pub async fn process_cycle(db: &PgPool, config: &SharedObjectCleanupConfig) -> anyhow::Result<i64> {
    let expired_persona_assets = expire_stale_persona_uploads(db).await?;
    let shared_objects = process_shared_object_cycle(db, config).await?;
    let persona_assets = process_persona_asset_cycle(db, config).await?;
    Ok(expired_persona_assets + shared_objects + persona_assets)
}

/// Move abandoned `pending_upload` rows into the normal revoked/cleanup
/// lifecycle.  This is deliberately separate from object deletion: the
/// database transition is durable first, and the following cleanup cycle can
/// retry the remote signed DELETE without making the asset selectable.
pub async fn expire_stale_persona_uploads(db: &PgPool) -> anyhow::Result<i64> {
    let mut tx = db.begin().await?;
    let rows = sqlx::query(
        "WITH candidates AS (
             SELECT id
             FROM social_persona_assets
             WHERE status = 'pending_upload'
               AND cleanup_requested_at IS NULL
               AND created_at <= NOW() - ($1 * INTERVAL '1 second')
             ORDER BY created_at ASC, id ASC
             LIMIT $2
             FOR UPDATE SKIP LOCKED
         )
         UPDATE social_persona_assets asset
         SET status = 'revoked',
             revoked_at = COALESCE(asset.revoked_at, NOW()),
             cleanup_requested_at = NOW(),
             cleanup_next_attempt_at = NULL,
             updated_at = NOW()
         FROM candidates
         WHERE asset.id = candidates.id
         RETURNING asset.id, asset.persona_id, asset.user_id, asset.campus_id,
                   asset.asset_type, asset.status, asset.moderation_status",
    )
    .bind(PENDING_UPLOAD_TTL_SECS)
    .bind(MAX_CLAIMS_PER_CYCLE)
    .fetch_all(&mut *tx)
    .await?;

    for row in &rows {
        let snapshot = serde_json::json!({
            "asset_id": row.get::<Uuid, _>("id"),
            "asset_type": row.get::<String, _>("asset_type"),
            "status": row.get::<String, _>("status"),
            "moderation_status": row.get::<String, _>("moderation_status"),
            "reason": "upload_timeout",
            "expiry_seconds": PENDING_UPLOAD_TTL_SECS,
        });
        sqlx::query(
            "INSERT INTO social_persona_audits
                (persona_id, user_id, campus_id, action, snapshot)
             VALUES ($1, $2, $3, 'asset_expired', $4)",
        )
        .bind(row.get::<Uuid, _>("persona_id"))
        .bind(row.get::<String, _>("user_id"))
        .bind(row.get::<Uuid, _>("campus_id"))
        .bind(snapshot)
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await?;
    if !rows.is_empty() {
        tracing::info!(count = rows.len(), "stale persona uploads revoked");
    }
    Ok(rows.len() as i64)
}

async fn process_shared_object_cycle(
    db: &PgPool,
    config: &SharedObjectCleanupConfig,
) -> anyhow::Result<i64> {
    let bucket = config
        .bucket
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("shared-object cleanup storage is disabled"))?;
    let claims = sqlx::query_as::<_, CleanupClaim>(
        "WITH candidates AS (
             SELECT id
             FROM chat_shared_objects
             WHERE kind = 'file'
               AND status IN ('revoked', 'deleted')
               AND storage_key IS NOT NULL
               AND cleanup_requested_at IS NOT NULL
               AND cleanup_completed_at IS NULL
               AND (
                   cleanup_next_attempt_at IS NULL
                   OR cleanup_next_attempt_at <= NOW()
               )
             ORDER BY cleanup_requested_at ASC, id ASC
             LIMIT $1
             FOR UPDATE SKIP LOCKED
         )
         UPDATE chat_shared_objects object
         SET cleanup_attempts = object.cleanup_attempts + 1,
             cleanup_next_attempt_at = NOW() + ($2 * INTERVAL '1 second'),
             cleanup_last_error = NULL,
             updated_at = NOW()
         FROM candidates
         WHERE object.id = candidates.id
         RETURNING object.id, object.storage_key, object.cleanup_attempts",
    )
    .bind(MAX_CLAIMS_PER_CYCLE)
    .bind(CLAIM_LEASE_SECS)
    .fetch_all(db)
    .await?;

    let count = claims.len() as i64;
    for claim in claims {
        let result =
            delete_remote_object(bucket, &claim.storage_key, config.request_timeout_secs).await;
        match result {
            Ok(()) => {
                sqlx::query(
                    "UPDATE chat_shared_objects
                     SET cleanup_completed_at = NOW(),
                         cleanup_next_attempt_at = NULL,
                         cleanup_last_error = NULL,
                         updated_at = NOW()
                     WHERE id = $1
                       AND cleanup_completed_at IS NULL",
                )
                .bind(claim.id)
                .execute(db)
                .await?;
                tracing::info!(object_id = %claim.id, "shared-object remote cleanup completed");
            }
            Err(error) => {
                let delay_secs = retry_delay_secs(claim.cleanup_attempts);
                let message = truncate_error(&error);
                sqlx::query(
                    "UPDATE chat_shared_objects
                     SET cleanup_next_attempt_at = NOW() + ($2 * INTERVAL '1 second'),
                         cleanup_last_error = $3,
                         updated_at = NOW()
                     WHERE id = $1
                       AND cleanup_completed_at IS NULL",
                )
                .bind(claim.id)
                .bind(delay_secs)
                .bind(&message)
                .execute(db)
                .await?;
                tracing::warn!(
                    object_id = %claim.id,
                    retry_after_secs = delay_secs,
                    error = %message,
                    "shared-object remote cleanup will retry"
                );
            }
        }
    }

    Ok(count)
}

async fn process_persona_asset_cycle(
    db: &PgPool,
    config: &SharedObjectCleanupConfig,
) -> anyhow::Result<i64> {
    let bucket = config
        .bucket
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("persona asset cleanup storage is disabled"))?;
    let claims = sqlx::query_as::<_, CleanupClaim>(
        "WITH candidates AS (
             SELECT id
             FROM social_persona_assets
             WHERE status IN ('revoked', 'deleted')
               AND cleanup_requested_at IS NOT NULL
               AND cleanup_completed_at IS NULL
               AND (
                   cleanup_next_attempt_at IS NULL
                   OR cleanup_next_attempt_at <= NOW()
               )
             ORDER BY cleanup_requested_at ASC, id ASC
             LIMIT $1
             FOR UPDATE SKIP LOCKED
         )
         UPDATE social_persona_assets asset
         SET cleanup_attempts = asset.cleanup_attempts + 1,
             cleanup_next_attempt_at = NOW() + ($2 * INTERVAL '1 second'),
             cleanup_last_error = NULL,
             updated_at = NOW()
         FROM candidates c
         WHERE asset.id = c.id
         RETURNING asset.id, asset.storage_key, asset.cleanup_attempts",
    )
    .bind(MAX_CLAIMS_PER_CYCLE)
    .bind(CLAIM_LEASE_SECS)
    .fetch_all(db)
    .await?;

    let count = claims.len() as i64;
    for claim in claims {
        let result = if is_valid_persona_asset_key(&claim.storage_key) {
            delete_remote_object(bucket, &claim.storage_key, config.request_timeout_secs).await
        } else {
            Err("拒绝删除不符合 persona asset 约束的 storage key".to_string())
        };
        match result {
            Ok(()) => {
                sqlx::query(
                    "UPDATE social_persona_assets
                     SET status = 'deleted', cleanup_completed_at = NOW(),
                         cleanup_next_attempt_at = NULL, cleanup_last_error = NULL,
                         updated_at = NOW()
                     WHERE id = $1 AND cleanup_completed_at IS NULL",
                )
                .bind(claim.id)
                .execute(db)
                .await?;
                tracing::info!(asset_id = %claim.id, "persona asset remote cleanup completed");
            }
            Err(error) => {
                let delay_secs = retry_delay_secs(claim.cleanup_attempts);
                let message = truncate_error(&error);
                sqlx::query(
                    "UPDATE social_persona_assets
                     SET cleanup_next_attempt_at = NOW() + ($2 * INTERVAL '1 second'),
                         cleanup_last_error = $3, updated_at = NOW()
                     WHERE id = $1 AND cleanup_completed_at IS NULL",
                )
                .bind(claim.id)
                .bind(delay_secs)
                .bind(&message)
                .execute(db)
                .await?;
                tracing::warn!(
                    asset_id = %claim.id,
                    retry_after_secs = delay_secs,
                    error = %message,
                    "persona asset remote cleanup will retry"
                );
            }
        }
    }
    Ok(count)
}

async fn delete_remote_object(
    bucket: &PrivateBucket,
    object_key: &str,
    timeout_secs: u64,
) -> Result<(), String> {
    if !is_valid_shared_object_key(object_key) {
        return Err("拒绝删除不符合 shared object 约束的 storage key".to_string());
    }
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(timeout_secs.max(1)))
        .build()
        .map_err(|error| format!("创建对象存储客户端失败: {error}"))?;
    let response = client
        .delete(bucket.presigned_delete(object_key, 300))
        .send()
        .await
        .map_err(|error| format!("对象存储 DELETE 请求失败: {error}"))?;
    if response.status().is_success() || response.status() == reqwest::StatusCode::NOT_FOUND {
        return Ok(());
    }
    Err(format!("对象存储 DELETE 返回 {}", response.status()))
}

fn is_valid_shared_object_key(object_key: &str) -> bool {
    let mut parts = object_key.split('/');
    matches!(parts.next(), Some("chat"))
        && parts
            .next()
            .and_then(|value| Uuid::parse_str(value).ok())
            .is_some()
        && parts
            .next()
            .and_then(|value| Uuid::parse_str(value).ok())
            .is_some()
        && parts.next().is_none()
}

fn is_valid_persona_asset_key(object_key: &str) -> bool {
    let mut parts = object_key.split('/');
    matches!(parts.next(), Some("persona"))
        && parts
            .next()
            .and_then(|value| Uuid::parse_str(value).ok())
            .is_some()
        && parts
            .next()
            .and_then(|value| Uuid::parse_str(value).ok())
            .is_some()
        && parts
            .next()
            .and_then(|value| Uuid::parse_str(value).ok())
            .is_some()
        && parts.next().is_none()
}

fn retry_delay_secs(attempts: i32) -> i64 {
    let exponent = attempts.saturating_sub(1).clamp(0, 7) as u32;
    (30_i64.saturating_mul(1_i64 << exponent)).min(MAX_BACKOFF_SECS)
}

fn truncate_error(error: &str) -> String {
    error.chars().take(500).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shared_object_keys_are_strictly_scoped() {
        let campus = Uuid::new_v4();
        let object = Uuid::new_v4();
        assert!(is_valid_shared_object_key(&format!(
            "chat/{campus}/{object}"
        )));
        assert!(!is_valid_shared_object_key("chat/../../secrets"));
        assert!(!is_valid_shared_object_key(&format!(
            "chat/{campus}/{object}/extra"
        )));
        assert!(!is_valid_shared_object_key("https://evil.example/object"));
    }

    #[test]
    fn persona_asset_keys_are_strictly_scoped() {
        let campus = Uuid::new_v4();
        let persona = Uuid::new_v4();
        let asset = Uuid::new_v4();
        assert!(is_valid_persona_asset_key(&format!(
            "persona/{campus}/{persona}/{asset}"
        )));
        assert!(!is_valid_persona_asset_key("persona/../../secrets"));
        assert!(!is_valid_persona_asset_key(&format!(
            "persona/{campus}/{persona}/{asset}/extra"
        )));
        assert!(!is_valid_persona_asset_key("https://evil.example/object"));
    }

    #[test]
    fn retry_backoff_is_bounded() {
        assert_eq!(retry_delay_secs(1), 30);
        assert_eq!(retry_delay_secs(2), 60);
        assert_eq!(retry_delay_secs(7), 1920);
        assert_eq!(retry_delay_secs(8), MAX_BACKOFF_SECS);
        assert_eq!(retry_delay_secs(100), MAX_BACKOFF_SECS);
    }

    #[test]
    fn errors_are_truncated_before_database_persistence() {
        let error = "x".repeat(600);
        assert_eq!(truncate_error(&error).chars().count(), 500);
    }
}
