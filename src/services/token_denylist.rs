use crate::lifecycle::{tick_or_shutdown, ShutdownSignal};
use dashmap::DashMap;
use moka::sync::Cache;
use sqlx::PgPool;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::time::{interval, MissedTickBehavior};

/// In-memory denylist for revoked JWT access tokens and short-lived auth caches.
///
/// - `denied`: Keyed by `jti` (JWT ID), stores the token's expiry timestamp.
/// - `verified_jti_cache`: Short-lived cache for verified active JTIs to avoid repeat DB queries.
/// - `user_status_cache`: Short-lived cache for user status (`active`, `banned`) to reduce DB round-trips.
#[derive(Clone)]
pub struct TokenDenylist {
    denied: Arc<DashMap<String, u64>>,
    verified_jti_cache: Cache<String, ()>,
    user_status_cache: Cache<String, String>,
}

impl TokenDenylist {
    pub fn new() -> Self {
        Self {
            denied: Arc::new(DashMap::new()),
            verified_jti_cache: Cache::builder()
                .max_capacity(50_000)
                .time_to_live(Duration::from_secs(30))
                .build(),
            user_status_cache: Cache::builder()
                .max_capacity(50_000)
                .time_to_live(Duration::from_secs(15))
                .build(),
        }
    }

    /// Add a token to the denylist. It will be auto-cleaned after `expires_at`.
    /// Also invalidates the verified cache for this JTI.
    pub fn deny(&self, jti: &str, expires_at: u64) {
        self.denied.insert(jti.to_string(), expires_at);
        self.verified_jti_cache.invalidate(jti);
    }

    /// Check if a token's jti is on the denylist.
    pub fn is_denied(&self, jti: &str) -> bool {
        self.denied.contains_key(jti)
    }

    /// Check if a token's jti was recently verified as active/not-revoked.
    pub fn is_verified(&self, jti: &str) -> bool {
        self.verified_jti_cache.contains_key(jti)
    }

    /// Mark a token's jti as verified active.
    pub fn mark_verified(&self, jti: &str) {
        self.verified_jti_cache.insert(jti.to_string(), ());
    }

    /// Invalidate verified status for a token jti.
    #[allow(dead_code)]
    pub fn invalidate_verified(&self, jti: &str) {
        self.verified_jti_cache.invalidate(jti);
    }

    /// Get cached user status if present.
    pub fn get_user_status(&self, user_id: &str) -> Option<String> {
        self.user_status_cache.get(user_id)
    }

    /// Set cached user status with TTL.
    pub fn set_user_status(&self, user_id: &str, status: &str) {
        self.user_status_cache
            .insert(user_id.to_string(), status.to_string());
    }

    /// Invalidate cached user status (e.g. on ban or unban).
    pub fn invalidate_user_status(&self, user_id: &str) {
        self.user_status_cache.invalidate(user_id);
    }

    /// Remove expired entries from the denylist.
    pub fn cleanup_expired(&self) {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        self.denied.retain(|_, exp| *exp > now);
    }

    #[cfg(test)]
    pub fn is_empty(&self) -> bool {
        self.denied.is_empty()
    }

    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.denied.len()
    }
}

impl Default for TokenDenylist {
    fn default() -> Self {
        Self::new()
    }
}

/// Periodically removes expired rows from persisted revoked token table.
pub async fn run_cleanup_worker(db: PgPool, shutdown: ShutdownSignal) {
    let mut ticker = interval(Duration::from_secs(60 * 60));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);

    while tick_or_shutdown(&mut ticker, &shutdown)
        .await
        .should_continue()
    {
        match sqlx::query("DELETE FROM revoked_access_tokens WHERE expires_at <= NOW()")
            .execute(&db)
            .await
        {
            Ok(result) => {
                if result.rows_affected() > 0 {
                    tracing::debug!(
                        rows = result.rows_affected(),
                        "Pruned expired revoked tokens"
                    );
                }
            }
            Err(sqlx::Error::Database(db_err)) if db_err.code().as_deref() == Some("42P01") => {
                // Migration not applied yet; keep running and retry next cycle.
            }
            Err(e) => {
                tracing::warn!(%e, "Failed to prune revoked token table");
            }
        }
    }

    tracing::info!("Revoked token cleanup worker stopped");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_deny_and_check() {
        let dl = TokenDenylist::new();
        assert!(dl.is_empty());
        let future = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs()
            + 3600;
        dl.deny("jti-abc", future);
        assert!(!dl.is_empty());
        assert!(dl.is_denied("jti-abc"));
        assert!(!dl.is_denied("jti-xyz"));
    }

    #[test]
    fn test_cleanup_expired() {
        let dl = TokenDenylist::new();
        // Already expired
        dl.deny("old", 1);
        // Far future
        let future = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs()
            + 3600;
        dl.deny("fresh", future);
        assert_eq!(dl.len(), 2);
        dl.cleanup_expired();
        assert_eq!(dl.len(), 1);
        assert!(!dl.is_empty());
        assert!(!dl.is_denied("old"));
        assert!(dl.is_denied("fresh"));
    }

    #[test]
    fn test_verified_jti_cache() {
        let dl = TokenDenylist::new();
        assert!(!dl.is_verified("jti-123"));

        dl.mark_verified("jti-123");
        assert!(dl.is_verified("jti-123"));

        // When denied, verified status is invalidated
        dl.deny("jti-123", 9999999999);
        assert!(dl.is_denied("jti-123"));
        assert!(!dl.is_verified("jti-123"));
    }

    #[test]
    fn test_user_status_cache() {
        let dl = TokenDenylist::new();
        assert_eq!(dl.get_user_status("user-1"), None);

        dl.set_user_status("user-1", "active");
        assert_eq!(dl.get_user_status("user-1"), Some("active".to_string()));

        dl.invalidate_user_status("user-1");
        assert_eq!(dl.get_user_status("user-1"), None);

        dl.set_user_status("user-1", "banned");
        assert_eq!(dl.get_user_status("user-1"), Some("banned".to_string()));
    }
}
