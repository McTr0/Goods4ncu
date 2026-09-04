//! Redis-backed distributed rate limiter.
//!
//! Uses atomic INCR + EXPIRE fixed-window rate limiting
//! that works correctly across multiple application nodes.
//!
//! Requires the `redis` feature to be enabled.

use async_trait::async_trait;
use redis::aio::ConnectionManager;
use redis::Client;

use crate::middleware::rate_limit::traits::RateLimiter;
use crate::middleware::rate_limit::{RateLimitError, RateLimitResult};

/// Redis-backed distributed rate limiter.
///
/// Uses an atomic fixed-window counter with ConnectionManager:
/// - First request in window initializes key with EXPIRE
/// - Subsequent requests atomically increment
/// - Checks against max_tokens without per-second clobbering
pub struct RedisRateLimiter {
    conn: ConnectionManager,
    max_tokens: u64,
    window_secs: u64,
}

impl RedisRateLimiter {
    pub async fn new(
        redis_url: &str,
        max_requests: u64,
        window_secs: u64,
    ) -> Result<Self, redis::RedisError> {
        let client = Client::open(redis_url)?;
        let conn = ConnectionManager::new(client).await?;
        Ok(Self {
            conn,
            max_tokens: max_requests,
            window_secs,
        })
    }

    fn key(&self, ip: &str) -> String {
        format!("ratelimit:{}", ip)
    }
}

#[async_trait]
impl RateLimiter for RedisRateLimiter {
    async fn check_rate_limit(&self, ip: &str) -> RateLimitResult<bool> {
        let key = self.key(ip);
        let mut conn = self.conn.clone();

        let script = r#"
            local current = redis.call('INCR', KEYS[1])
            if current == 1 then
                redis.call('EXPIRE', KEYS[1], ARGV[1])
            end
            if current <= tonumber(ARGV[2]) then
                return 1
            else
                return 0
            end
        "#;

        let result: i32 = redis::Script::new(script)
            .key(&key)
            .arg(self.window_secs)
            .arg(self.max_tokens)
            .invoke_async(&mut conn)
            .await
            .map_err(RateLimitError::Redis)?;

        Ok(result == 1)
    }

    async fn reset(&self, ip: &str) -> RateLimitResult<()> {
        let mut conn = self.conn.clone();
        let key = self.key(ip);
        let mut cmd = redis::cmd("DEL");
        cmd.arg(&key);
        cmd.query_async::<()>(&mut conn)
            .await
            .map_err(RateLimitError::Redis)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::middleware::rate_limit::RateLimitStateHandle;
    use uuid::Uuid;

    fn redis_test_url() -> Option<String> {
        match std::env::var("REDIS_TEST_URL") {
            Ok(url) if !url.trim().is_empty() => Some(url),
            _ => None,
        }
    }

    #[tokio::test]
    async fn invalid_redis_url_fails_construction() {
        assert!(RedisRateLimiter::new("invalid_url_scheme://foo", 10, 60)
            .await
            .is_err());
    }

    #[test]
    fn redis_key_format() {
        let ip = "192.168.1.100";
        let expected = format!("ratelimit:{ip}");
        assert_eq!(expected, "ratelimit:192.168.1.100");
    }

    #[tokio::test]
    async fn redis_rate_limiter_e2e_under_and_over_limit() {
        let Some(url) = redis_test_url() else {
            return;
        };

        let limiter = RedisRateLimiter::new(&url, 2, 60)
            .await
            .expect("connect to test redis");
        let ip = format!("test-ip-{}", Uuid::new_v4().simple());

        // First two requests succeed
        assert!(limiter.check_rate_limit(&ip).await.unwrap());
        assert!(limiter.check_rate_limit(&ip).await.unwrap());

        // Third request exceeds limit
        assert!(!limiter.check_rate_limit(&ip).await.unwrap());

        // Reset clears bucket
        limiter.reset(&ip).await.unwrap();
        assert!(limiter.check_rate_limit(&ip).await.unwrap());

        // Test with RateLimitStateHandle to verify strict enforcement of Ok(false)
        let handle = RateLimitStateHandle::new(
            RedisRateLimiter::new(&url, 1, 60)
                .await
                .expect("connect to test redis"),
        );
        let handle_ip = format!("handle-ip-{}", Uuid::new_v4().simple());
        assert!(handle.check_rate_limit(&handle_ip).await);
        assert!(
            !handle.check_rate_limit(&handle_ip).await,
            "working redis limiter saying no must be obeyed"
        );
    }

    #[tokio::test]
    async fn redis_rate_limiter_burst_in_same_second() {
        let Some(url) = redis_test_url() else {
            return;
        };

        let max_requests = 5;
        let limiter = std::sync::Arc::new(
            RedisRateLimiter::new(&url, max_requests, 60)
                .await
                .expect("connect to test redis"),
        );
        let ip = format!("burst-ip-{}", Uuid::new_v4().simple());

        // Spawn 10 concurrent requests simultaneously in the same second
        let mut handles = Vec::new();
        for _ in 0..10 {
            let lim = limiter.clone();
            let test_ip = ip.clone();
            handles.push(tokio::spawn(async move {
                lim.check_rate_limit(&test_ip).await.unwrap()
            }));
        }

        let mut allowed = 0;
        let mut rejected = 0;
        for handle in handles {
            if handle.await.expect("task join") {
                allowed += 1;
            } else {
                rejected += 1;
            }
        }

        assert_eq!(allowed, 5, "exactly max_requests should succeed in burst");
        assert_eq!(
            rejected, 5,
            "requests beyond max_requests should be rejected"
        );

        // Clean up
        limiter.reset(&ip).await.unwrap();
    }

    #[tokio::test]
    async fn redis_rate_limiter_window_expiry_resets_quota() {
        let Some(url) = redis_test_url() else {
            return;
        };

        // 1-second window, limit 2
        let limiter = RedisRateLimiter::new(&url, 2, 1)
            .await
            .expect("connect to test redis");
        let ip = format!("expiry-ip-{}", Uuid::new_v4().simple());

        // Fill window
        assert!(limiter.check_rate_limit(&ip).await.unwrap());
        assert!(limiter.check_rate_limit(&ip).await.unwrap());
        assert!(
            !limiter.check_rate_limit(&ip).await.unwrap(),
            "3rd request exceeds limit"
        );

        // Wait for 1-second TTL window to expire
        tokio::time::sleep(std::time::Duration::from_millis(1200)).await;

        // In new window, requests succeed again
        assert!(
            limiter.check_rate_limit(&ip).await.unwrap(),
            "request in new window must succeed"
        );
        assert!(limiter.check_rate_limit(&ip).await.unwrap());
        assert!(
            !limiter.check_rate_limit(&ip).await.unwrap(),
            "quota enforced in new window"
        );

        // Clean up
        limiter.reset(&ip).await.unwrap();
    }

    #[tokio::test]
    async fn redis_rate_limiter_independent_keys_isolation() {
        let Some(url) = redis_test_url() else {
            return;
        };

        // Limit 1 per key
        let limiter = RedisRateLimiter::new(&url, 1, 60)
            .await
            .expect("connect to test redis");
        let ip_a = format!("ip-a-{}", Uuid::new_v4().simple());
        let ip_b = format!("ip-b-{}", Uuid::new_v4().simple());
        let ip_c = format!("ip-c-{}", Uuid::new_v4().simple());

        // IP A exhausts quota
        assert!(limiter.check_rate_limit(&ip_a).await.unwrap());
        assert!(!limiter.check_rate_limit(&ip_a).await.unwrap());

        // IP B and C are completely unaffected
        assert!(limiter.check_rate_limit(&ip_b).await.unwrap());
        assert!(!limiter.check_rate_limit(&ip_b).await.unwrap());

        assert!(limiter.check_rate_limit(&ip_c).await.unwrap());
        assert!(!limiter.check_rate_limit(&ip_c).await.unwrap());

        // Clean up
        limiter.reset(&ip_a).await.unwrap();
        limiter.reset(&ip_b).await.unwrap();
        limiter.reset(&ip_c).await.unwrap();
    }

    struct HangingRateLimiter;
    #[async_trait]
    impl RateLimiter for HangingRateLimiter {
        async fn check_rate_limit(&self, _ip: &str) -> RateLimitResult<bool> {
            // Sleep longer than RateLimitStateHandle's 250ms timeout
            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
            Ok(false)
        }
        async fn reset(&self, _ip: &str) -> RateLimitResult<()> {
            Ok(())
        }
    }

    struct FailingRateLimiter;
    #[async_trait]
    impl RateLimiter for FailingRateLimiter {
        async fn check_rate_limit(&self, _ip: &str) -> RateLimitResult<bool> {
            Err(RateLimitError::Redis(redis::RedisError::from((
                redis::ErrorKind::IoError,
                "simulated redis error",
            ))))
        }
        async fn reset(&self, _ip: &str) -> RateLimitResult<()> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn rate_limit_timeout_and_error_fails_open() {
        // Test timeout fail-open
        let hanging_handle = RateLimitStateHandle::new(HangingRateLimiter);
        let ip = "test-failopen-ip";
        let start = std::time::Instant::now();
        let allowed_on_timeout = hanging_handle.check_rate_limit(ip).await;
        assert!(
            allowed_on_timeout,
            "timeout must fail open to prevent total outage"
        );
        assert!(
            start.elapsed() >= std::time::Duration::from_millis(240),
            "should have waited ~250ms before timing out"
        );
        assert!(
            start.elapsed() < std::time::Duration::from_millis(450),
            "should not wait full 500ms of the hanging future"
        );

        // Test error fail-open
        let failing_handle = RateLimitStateHandle::new(FailingRateLimiter);
        let allowed_on_error = failing_handle.check_rate_limit(ip).await;
        assert!(
            allowed_on_error,
            "error must fail open to prevent total outage"
        );
    }
}
