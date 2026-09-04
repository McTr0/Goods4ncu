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
    ws_hub: Arc<crate::api::ws::WsHub>,
    subscriber_handle: tokio::sync::Mutex<Option<tokio::task::JoinHandle<()>>>,
    publisher_handle: tokio::sync::Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl ReplicatedRuntime {
    /// Start the complete replicated dependency graph (rate limiter, publisher, subscriber).
    /// Bounded by `startup_timeout`: if any handshake hangs or fails, returns Err immediately.
    pub async fn start(
        redis_url: &str,
        ws_hub: Arc<crate::api::ws::WsHub>,
        rate_limit_max: u64,
        rate_limit_window_secs: u64,
        shutdown: &ShutdownSignal,
        startup_timeout: Duration,
    ) -> Result<Arc<Self>, ReplicatedRuntimeError> {
        tokio::time::timeout(
            startup_timeout,
            Self::start_inner(
                redis_url,
                ws_hub,
                rate_limit_max,
                rate_limit_window_secs,
                shutdown,
            ),
        )
        .await
        .map_err(|_| ReplicatedRuntimeError::Timeout(startup_timeout))?
    }

    async fn start_inner(
        redis_url: &str,
        ws_hub: Arc<crate::api::ws::WsHub>,
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

        // Install bounded fanout publisher into ws_hub
        let (tx, mut rx) = tokio::sync::mpsc::channel::<(String, Option<uuid::Uuid>, String)>(4096);
        ws_hub.set_fanout_publisher(tx);
        tracing::info!("WS fanout publisher installed (Redis)");

        let mut p_worker_conn = publisher.clone();
        let pub_shutdown = shutdown.clone();
        let pub_ws_hub = ws_hub.clone();
        let publisher_handle = tokio::spawn(async move {
            loop {
                tokio::select! {
                    biased;
                    _ = pub_shutdown.wait() => {
                        break;
                    }
                    msg = rx.recv() => {
                        let Some((user_id, campus_id, payload)) = msg else {
                            break;
                        };
                        let pub_future = crate::services::ws_fanout::publish_scoped(
                            &mut p_worker_conn,
                            &user_id,
                            campus_id,
                            &payload,
                        );
                        let pub_result = tokio::time::timeout(
                            std::time::Duration::from_millis(500),
                            pub_future,
                        )
                        .await;
                        match pub_result {
                            Ok(Ok(())) => {}
                            Ok(Err(error)) => {
                                tracing::error!(
                                    %error,
                                    user_id = %user_id,
                                    "WS fanout publish failed; falling back to local delivery"
                                );
                                pub_ws_hub.deliver_local_scoped(&user_id, campus_id, &payload);
                            }
                            Err(_) => {
                                tracing::error!(
                                    user_id = %user_id,
                                    "WS fanout publish timed out after 500ms; falling back to local delivery"
                                );
                                pub_ws_hub.deliver_local_scoped(&user_id, campus_id, &payload);
                            }
                        }
                    }
                }
            }
            while let Ok((user_id, campus_id, payload)) = rx.try_recv() {
                let pub_future = crate::services::ws_fanout::publish_scoped(
                    &mut p_worker_conn,
                    &user_id,
                    campus_id,
                    &payload,
                );
                let pub_result =
                    tokio::time::timeout(std::time::Duration::from_millis(500), pub_future).await;
                if !matches!(pub_result, Ok(Ok(()))) {
                    pub_ws_hub.deliver_local_scoped(&user_id, campus_id, &payload);
                }
            }
            pub_ws_hub.clear_fanout_publisher();
            tracing::info!("WS fanout publisher stopped");
        });

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

        let sub_ws_hub = ws_hub.clone();
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
                        crate::services::ws_fanout::handle_fanout_payload(&sub_ws_hub, &raw);
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
            ws_hub,
            subscriber_handle: tokio::sync::Mutex::new(Some(subscriber_handle)),
            publisher_handle: tokio::sync::Mutex::new(Some(publisher_handle)),
        }))
    }

    /// Gracefully wait for subscriber and publisher tasks to shut down.
    pub async fn shutdown(&self) {
        self.ws_hub.clear_fanout_publisher();
        let sub = self.subscriber_handle.lock().await.take();
        if let Some(handle) = sub {
            let _ = handle.await;
        }
        let pub_h = self.publisher_handle.lock().await.take();
        if let Some(handle) = pub_h {
            let _ = handle.await;
        }
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
        let ping_result: Result<Result<String, redis::RedisError>, _> = tokio::time::timeout(
            std::time::Duration::from_millis(500),
            redis::cmd("PING").query_async::<String>(&mut conn),
        )
        .await;
        match ping_result {
            Ok(Ok(s)) if s == "PONG" => Ok(()),
            Ok(Ok(_)) => {
                tracing::error!("Readiness check failed: unexpected Redis PING response");
                Err(ApiError::ServiceUnavailable("redis_unreachable"))
            }
            Ok(Err(error)) => {
                tracing::error!(%error, "Readiness check failed: Redis publisher PING failed");
                Err(ApiError::ServiceUnavailable("redis_unreachable"))
            }
            Err(_) => {
                tracing::error!(
                    "Readiness check failed: Redis publisher PING timed out after 500ms"
                );
                Err(ApiError::ServiceUnavailable("redis_unreachable"))
            }
        }
    }
}

impl Drop for ReplicatedRuntime {
    fn drop(&mut self) {
        self.ws_hub.clear_fanout_publisher();
    }
}
