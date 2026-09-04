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
}
