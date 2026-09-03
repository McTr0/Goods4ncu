//! Redis-backed distributed rate limiter.
//!
//! Uses Redis sorted sets to implement a sliding window rate limiter
//! that works correctly across multiple application nodes.
//!
//! Requires the `redis` feature to be enabled.

use async_trait::async_trait;
use redis::Client;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::middleware::rate_limit::traits::RateLimiter;
use crate::middleware::rate_limit::{RateLimitError, RateLimitResult};

/// Returns the current Unix timestamp in seconds.
fn unix_time_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

/// Redis-backed distributed rate limiter.
///
/// Uses a sliding window algorithm with Redis sorted sets:
/// - Each request adds a timestamp entry to a sorted set keyed by IP
/// - Count entries within the sliding window to check the limit
/// - Old entries are pruned on each request
///
/// This approach is accurate and works across any number of nodes.
pub struct RedisRateLimiter {
    client: Client,
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
        // Test connection
        let conn = client.get_multiplexed_async_connection().await?;
        drop(conn);
        Ok(Self {
            client,
            max_tokens: max_requests,
            window_secs,
        })
    }

    fn key(&self, ip: &str) -> String {
        format!("ratelimit:{}", ip)
    }
}

const REDIS_TIMEOUT: std::time::Duration = std::time::Duration::from_millis(250);

#[async_trait]
impl RateLimiter for RedisRateLimiter {
    async fn check_rate_limit(&self, ip: &str) -> RateLimitResult<bool> {
        let mut conn = tokio::time::timeout(
            REDIS_TIMEOUT,
            self.client.get_multiplexed_async_connection(),
        )
        .await
        .map_err(|_| {
            redis::RedisError::from((redis::ErrorKind::IoError, "Redis connection timeout"))
        })?
        .map_err(RateLimitError::Redis)?;

        let key = self.key(ip);
        let now_secs = unix_time_secs();
        let cutoff = now_secs.saturating_sub(self.window_secs);

        let script = r#"
            redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', ARGV[1])
            local count = redis.call('ZCARD', KEYS[1])
            if count < tonumber(ARGV[3]) then
                redis.call('ZADD', KEYS[1], ARGV[2], ARGV[2])
                redis.call('EXPIRE', KEYS[1], ARGV[4])
                return 1
            else
                return 0
            end
        "#;

        let result: i32 = tokio::time::timeout(
            REDIS_TIMEOUT,
            redis::Script::new(script)
                .key(&key)
                .arg(cutoff)
                .arg(now_secs)
                .arg(self.max_tokens)
                .arg(self.window_secs * 2)
                .invoke_async(&mut conn),
        )
        .await
        .map_err(|_| redis::RedisError::from((redis::ErrorKind::IoError, "Redis script timeout")))?
        .map_err(RateLimitError::Redis)?;

        Ok(result == 1)
    }

    async fn reset(&self, ip: &str) -> RateLimitResult<()> {
        let mut conn = tokio::time::timeout(
            REDIS_TIMEOUT,
            self.client.get_multiplexed_async_connection(),
        )
        .await
        .map_err(|_| {
            redis::RedisError::from((redis::ErrorKind::IoError, "Redis connection timeout"))
        })?
        .map_err(RateLimitError::Redis)?;

        let key = self.key(ip);
        let mut cmd = redis::cmd("DEL");
        cmd.arg(&key);
        let del_result: Result<Result<(), redis::RedisError>, _> =
            tokio::time::timeout(REDIS_TIMEOUT, cmd.query_async::<()>(&mut conn)).await;
        del_result
            .map_err(|_| {
                redis::RedisError::from((redis::ErrorKind::IoError, "Redis command timeout"))
            })?
            .map_err(RateLimitError::Redis)?;
        Ok(())
    }
}
