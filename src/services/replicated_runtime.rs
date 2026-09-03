//! Unified replicated deployment runtime.
//!
//! Provides bounded fail-fast startup for multi-node deployments:
//! rate limiter, publisher, and subscriber all initialize within a strict timeout.
//! If any component fails or the timeout expires, startup fails immediately.
//! Exposes health checking for readiness probes without creating connection storms.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use futures_util::StreamExt;

use crate::api::error::ApiError;
use crate::lifecycle::ShutdownSignal;
use crate::middleware::rate_limit::RateLimitStateHandle;

#[derive(Debug, thiserror::Error)]
pub enum ReplicatedRuntimeError {
    #[error("Invalid REDIS_URL: {0}")]
    InvalidUrl(String),
    #[error("Replicated runtime initialization timed out after {0:?}")]
    Timeout(Duration),
    #[error("Redis rate limiter initialization failed: {0}")]
    RateLimiterFailed(String),
    #[error("Redis publisher connection failed: {0}")]
    PublisherFailed(String),
    #[error("Redis subscriber connection failed: {0}")]
    SubscriberFailed(String),
}

pub struct ReplicatedRuntime {
    rate_limiter: RateLimitStateHandle,
    publisher: redis::aio::ConnectionManager,
    is_healthy: Arc<AtomicBool>,
    _subscriber_handle: tokio::task::JoinHandle<()>,
}

impl ReplicatedRuntime {
    /// Start the complete replicated dependency graph (rate limiter, publisher, subscriber).
    /// Bounded by `startup_timeout`: if any handshake hangs or fails, returns Err immediately.
    pub async fn start(
        redis_url: &str,
        rate_limit_max: u64,
        rate_limit_window_secs: u64,
        shutdown: &ShutdownSignal,
        startup_timeout: Duration,
    ) -> Result<Arc<Self>, ReplicatedRuntimeError> {
        tokio::time::timeout(
            startup_timeout,
            Self::start_inner(redis_url, rate_limit_max, rate_limit_window_secs, shutdown),
        )
        .await
        .map_err(|_| ReplicatedRuntimeError::Timeout(startup_timeout))?
    }

    async fn start_inner(
        redis_url: &str,
        rate_limit_max: u64,
        rate_limit_window_secs: u64,
        shutdown: &ShutdownSignal,
    ) -> Result<Arc<Self>, ReplicatedRuntimeError> {
        let client = redis::Client::open(redis_url)
            .map_err(|e| ReplicatedRuntimeError::InvalidUrl(e.to_string()))?;

        // 1. Initialize distributed rate limiter
        let limiter = crate::middleware::rate_limit::redis_backend::RedisRateLimiter::new(
            redis_url,
            rate_limit_max,
            rate_limit_window_secs,
        )
        .await
        .map_err(|e| ReplicatedRuntimeError::RateLimiterFailed(e.to_string()))?;
        let rate_limiter = RateLimitStateHandle::new(limiter);

        // 2. Connect publisher connection manager & verify with PING
        let publisher = redis::aio::ConnectionManager::new(client.clone())
            .await
            .map_err(|e| ReplicatedRuntimeError::PublisherFailed(e.to_string()))?;
        let mut p_conn = publisher.clone();
        let pong: String = redis::cmd("PING")
            .query_async(&mut p_conn)
            .await
            .map_err(|e| ReplicatedRuntimeError::PublisherFailed(format!("PING failed: {e}")))?;
        if pong != "PONG" {
            return Err(ReplicatedRuntimeError::PublisherFailed(format!(
                "Unexpected PING response: {pong}"
            )));
        }

        // Install fanout publisher into api::ws
        crate::api::ws::install_fanout_publisher(publisher.clone());
        tracing::info!("WS fanout publisher installed (Redis)");

        // 3. Connect subscriber pubsub & subscribe to channel
        let mut pubsub = client
            .get_async_pubsub()
            .await
            .map_err(|e| ReplicatedRuntimeError::SubscriberFailed(e.to_string()))?;
        pubsub
            .subscribe(crate::services::ws_fanout::CHANNEL)
            .await
            .map_err(|e| ReplicatedRuntimeError::SubscriberFailed(e.to_string()))?;
        tracing::info!(
            channel = crate::services::ws_fanout::CHANNEL,
            "WS fanout subscribed"
        );

        let is_healthy = Arc::new(AtomicBool::new(true));
        let task_healthy = is_healthy.clone();
        let task_shutdown = shutdown.clone();

        let subscriber_handle = tokio::spawn(async move {
            let mut stream = pubsub.on_message();
            loop {
                tokio::select! {
                    biased;
                    _ = task_shutdown.wait() => {
                        break;
                    }
                    message = stream.next() => {
                        let Some(message) = message else {
                            tracing::warn!("WS fanout pubsub stream ended unexpectedly");
                            task_healthy.store(false, Ordering::SeqCst);
                            break;
                        };
                        let raw: String = match message.get_payload() {
                            Ok(raw) => raw,
                            Err(error) => {
                                tracing::warn!(%error, "WS fanout: undecodable payload");
                                continue;
                            }
                        };
                        crate::services::ws_fanout::handle_fanout_payload(&raw);
                    }
                }
            }
            task_healthy.store(false, Ordering::SeqCst);
            tracing::info!("WS fanout subscriber stopped");
        });

        Ok(Arc::new(Self {
            rate_limiter,
            publisher,
            is_healthy,
            _subscriber_handle: subscriber_handle,
        }))
    }

    /// Obtain handle to the distributed rate limiter.
    pub fn rate_limiter(&self) -> RateLimitStateHandle {
        self.rate_limiter.clone()
    }

    /// Check health of the replicated runtime for readiness probes.
    /// Checks the in-memory liveness flag and sends a quick PING on the existing
    /// multiplexed publisher connection without opening a new connection.
    pub async fn check_health(&self) -> Result<(), ApiError> {
        if !self.is_healthy.load(Ordering::SeqCst) {
            tracing::error!("Readiness check failed: WS fanout subscriber task is unhealthy");
            return Err(ApiError::ServiceUnavailable("ws_subscriber_unhealthy"));
        }
        let mut conn = self.publisher.clone();
        let pong: Result<String, _> = redis::cmd("PING").query_async(&mut conn).await;
        match pong {
            Ok(s) if s == "PONG" => Ok(()),
            Ok(_) => {
                tracing::error!("Readiness check failed: unexpected Redis PING response");
                Err(ApiError::ServiceUnavailable("redis_unreachable"))
            }
            Err(error) => {
                tracing::error!(%error, "Readiness check failed: Redis publisher PING failed");
                Err(ApiError::ServiceUnavailable("redis_unreachable"))
            }
        }
    }
}
