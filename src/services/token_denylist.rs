use crate::lifecycle::{tick_or_shutdown, ShutdownSignal};
use dashmap::DashMap;
use sqlx::PgPool;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::time::{interval, Duration, MissedTickBehavior};

/// In-memory denylist for revoked JWT access tokens.
///
/// Keyed by `jti` (JWT ID), stores the token's expiry timestamp.
/// Expired entries are periodically cleaned up to prevent unbounded growth.
#[derive(Clone)]
pub struct TokenDenylist {
    denied: Arc<DashMap<String, u64>>,
}

impl TokenDenylist {
    pub fn new() -> Self {
        Self {
            denied: Arc::new(DashMap::new()),
        }
    }

    /// Add a token to the denylist. It will be auto-cleaned after `expires_at`.
    pub fn deny(&self, jti: &str, expires_at: u64) {
        self.denied.insert(jti.to_string(), expires_at);
    }

    /// Check if a token's jti is on the denylist.
    pub fn is_denied(&self, jti: &str) -> bool {
        self.denied.contains_key(jti)
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
}
