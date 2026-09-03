//! Local (in-memory) rate limiter using moka.
//!
//! Suitable for single-node deployments. Each instance maintains its own
//! token bucket state. Not safe for multi-node deployments.

use moka::sync::Cache;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::middleware::rate_limit::traits::RateLimiter;
use crate::middleware::rate_limit::RateLimitResult;
use async_trait::async_trait;

const WHITELISTED_PATHS: &[&str] = &[
    // Orchestrator probes poll every few seconds from a small set of source
    // addresses. Rate limiting them would report the instance as unhealthy and
    // trigger a restart loop under exactly the load the limiter exists to
    // survive.
    "/api/livez",
    "/api/readyz",
    "/api/stats",
    "/api/categories",
    "/api/chat/connections",
    "/api/chat/conversations",
    "/api/chat/messages",
];

/// Token bucket rate limiter using moka cache.
/// Each IP gets a token bucket that refills over time.
#[derive(Clone)]
pub struct LocalRateLimiter {
    buckets: Cache<u64, (Instant, u64)>,
    max_tokens: u64,
    refill_duration: Duration,
}

impl LocalRateLimiter {
    pub fn new(max_requests: u64, window_secs: u64) -> Self {
        Self {
            buckets: Cache::builder()
                .max_capacity(100_000)
                .time_to_live(Duration::from_secs(window_secs * 2))
                .build(),
            max_tokens: max_requests,
            refill_duration: Duration::from_secs(window_secs),
        }
    }

    fn hash_ip(&self, ip: &str) -> u64 {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};
        use std::net::SocketAddr;

        let ip_only = ip
            .parse::<SocketAddr>()
            .map(|addr| addr.ip().to_string())
            .unwrap_or_else(|_| ip.to_string());
        let mut hasher = DefaultHasher::new();
        ip_only.hash(&mut hasher);
        hasher.finish()
    }

    fn check(&self, ip: &str) -> bool {
        let ip_hash = self.hash_ip(ip);
        let now = Instant::now();

        if let Some((last_reset, tokens)) = self.buckets.get(&ip_hash) {
            // moka::sync::Cache::get() returns Option<V> (owned copy), not Option<&V>
            // so last_reset and tokens are owned values here
            let elapsed = now.duration_since(last_reset);
            if elapsed < self.refill_duration {
                if tokens > 0 {
                    self.buckets.insert(ip_hash, (now, tokens - 1));
                    return true;
                }
                return false;
            }
        }

        self.buckets.insert(ip_hash, (now, self.max_tokens - 1));
        true
    }

    #[allow(dead_code)]
    fn reset_ip(&self, ip: &str) {
        let ip_hash = self.hash_ip(ip);
        self.buckets.remove(&ip_hash);
    }
}

#[async_trait]
impl RateLimiter for LocalRateLimiter {
    async fn check_rate_limit(&self, ip: &str) -> RateLimitResult<bool> {
        // moka operations are synchronous and fast; no need to spawn_blocking
        Ok(self.check(ip))
    }

    async fn reset(&self, ip: &str) -> RateLimitResult<()> {
        self.reset_ip(ip);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    // -----------------------------------------------------------------------
    // Failure direction
    //
    // This wrapper used to return `false` when the limiter errored, which
    // sounds cautious and is not: Redis stopped accepting writes after a failed
    // snapshot, every check errored, and every request in the deployment got a
    // 429. The component whose job is keeping the service usable under load took
    // it down completely.
    // -----------------------------------------------------------------------

    struct BrokenLimiter;

    #[async_trait::async_trait]
    impl RateLimiter for BrokenLimiter {
        async fn check_rate_limit(
            &self,
            _ip: &str,
        ) -> crate::middleware::rate_limit::RateLimitResult<bool> {
            Err(
                crate::middleware::rate_limit::RateLimitError::Serialization(
                    serde_json::from_str::<i32>("not json").unwrap_err(),
                ),
            )
        }
        async fn reset(&self, _ip: &str) -> crate::middleware::rate_limit::RateLimitResult<()> {
            Ok(())
        }
    }

    struct AlwaysLimited;

    #[async_trait::async_trait]
    impl RateLimiter for AlwaysLimited {
        async fn check_rate_limit(
            &self,
            _ip: &str,
        ) -> crate::middleware::rate_limit::RateLimitResult<bool> {
            Ok(false)
        }
        async fn reset(&self, _ip: &str) -> crate::middleware::rate_limit::RateLimitResult<()> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn an_unavailable_limiter_allows_traffic_rather_than_denying_everyone() {
        let handle = RateLimitStateHandle::new(BrokenLimiter);
        assert!(
            handle.check_rate_limit("1.2.3.4").await,
            "a broken rate limiter must not become a total outage",
        );
    }

    #[tokio::test]
    async fn a_working_limiter_that_says_no_is_still_obeyed() {
        // Failing open must not become never enforcing: a definite Ok(false) is
        // a decision, not an error, and has to be respected.
        let handle = RateLimitStateHandle::new(AlwaysLimited);
        assert!(!handle.check_rate_limit("1.2.3.4").await);
    }

    use super::*;

    #[tokio::test]
    async fn test_allows_requests_under_limit() {
        let limiter = LocalRateLimiter::new(5, 60);
        for _ in 0..5 {
            assert!(limiter.check_rate_limit("192.168.1.1").await.unwrap());
        }
    }

    #[tokio::test]
    async fn test_blocks_requests_over_limit() {
        let limiter = LocalRateLimiter::new(3, 60);
        assert!(limiter.check_rate_limit("10.0.0.1").await.unwrap());
        assert!(limiter.check_rate_limit("10.0.0.1").await.unwrap());
        assert!(limiter.check_rate_limit("10.0.0.1").await.unwrap());
        assert!(!limiter.check_rate_limit("10.0.0.1").await.unwrap());
    }

    #[tokio::test]
    async fn test_per_ip_isolation() {
        let limiter = LocalRateLimiter::new(2, 60);
        assert!(limiter.check_rate_limit("1.1.1.1").await.unwrap());
        assert!(limiter.check_rate_limit("1.1.1.1").await.unwrap());
        assert!(!limiter.check_rate_limit("1.1.1.1").await.unwrap());
        assert!(limiter.check_rate_limit("2.2.2.2").await.unwrap());
        assert!(limiter.check_rate_limit("2.2.2.2").await.unwrap());
        assert!(!limiter.check_rate_limit("2.2.2.2").await.unwrap());
    }

    #[tokio::test]
    async fn test_reset_clears_bucket() {
        let limiter = LocalRateLimiter::new(2, 60);
        assert!(limiter.check_rate_limit("10.0.0.1").await.unwrap());
        assert!(limiter.check_rate_limit("10.0.0.1").await.unwrap());
        assert!(!limiter.check_rate_limit("10.0.0.1").await.unwrap());
        limiter.reset("10.0.0.1").await.unwrap();
        assert!(limiter.check_rate_limit("10.0.0.1").await.unwrap());
    }

    #[test]
    fn test_ws_endpoint_is_not_whitelisted() {
        assert!(!is_whitelisted("/api/ws"));
        assert!(is_whitelisted("/api/readyz"));
    }
}

// ---------------------------------------------------------------------------
// Backward-compatible wrappers (used by AppState)
// ---------------------------------------------------------------------------

/// Handle to a [`RateLimiter`] that implements [`Clone`] and can be shared across
/// request handlers. The underlying limiter can be local (moka) or distributed (Redis).
/// Exposes an async `check_rate_limit` API compatible with the [`RateLimiter`] trait.
#[derive(Clone)]
pub struct RateLimitStateHandle(pub Arc<dyn RateLimiter>);

impl RateLimitStateHandle {
    pub fn new(limiter: impl RateLimiter + 'static) -> Self {
        Self(Arc::new(limiter))
    }

    /// Whether this caller may proceed.
    ///
    /// **Fails open**, and the direction is deliberate. A rate limiter exists to
    /// blunt abuse; when it is unavailable the cost of allowing traffic is a
    /// window of reduced protection, while the cost of denying it is that nobody
    /// can use the product at all. Turning a dependency wobble into a total
    /// outage is a much worse failure than the one being mitigated.
    ///
    /// This was `unwrap_or(false)`. Redis lost the ability to write its snapshot,
    /// so it rejected every write command, so every rate-limit check errored,
    /// so **every request in the deployment returned 429** — a full outage caused
    /// by the component whose only job is to keep the service available under
    /// load.
    ///
    /// Note this is the opposite choice from the interruption budget, which fails
    /// closed. The asymmetry is not inconsistency: there, failing closed means
    /// "do not push a notification", which harms nobody; here it means "serve
    /// nobody".
    ///
    /// The error is logged at WARN rather than swallowed, because silently
    /// unprotected is its own kind of bad.
    pub async fn check_rate_limit(&self, ip: &str) -> bool {
        let check_future = self.0.check_rate_limit(ip);
        match tokio::time::timeout(std::time::Duration::from_millis(250), check_future).await {
            Ok(Ok(allowed)) => allowed,
            Ok(Err(error)) => {
                tracing::warn!(
                    %error,
                    "rate limiter unavailable — allowing the request; abuse \
                     protection is degraded until it recovers",
                );
                true
            }
            Err(_) => {
                tracing::warn!(
                    "rate limiter timed out after 250ms — allowing the request; abuse \
                     protection is degraded until it recovers",
                );
                true
            }
        }
    }
}

/// Returns `true` if the given path is whitelisted from rate limiting.
pub fn is_whitelisted(path: &str) -> bool {
    WHITELISTED_PATHS.contains(&path)
}
