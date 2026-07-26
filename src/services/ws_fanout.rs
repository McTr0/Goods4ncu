//! Redis pub/sub fan-out for WebSocket delivery across replicas (Phase 4).
//!
//! With a single instance, `ws::broadcast_to_user` delivers straight to the
//! local socket registry. With multiple replicas, the user's socket may be
//! held by a different instance than the one producing the event (the outbox
//! worker on replica B pushes a notification for a user connected to replica
//! A). This module routes every broadcast through a Redis channel; each
//! replica subscribes and delivers to whatever sockets it holds locally.
//!
//! Delivery semantics: the publishing instance does NOT deliver locally on
//! publish — it receives its own message back through the subscription like
//! every other replica, so each instance delivers exactly once regardless of
//! topology. If publishing fails, the caller falls back to local-only delivery
//! (degraded but correct for single-instance deployments); messages and
//! notifications are persisted first, so missed realtime pushes are always
//! recoverable through HTTP pulls.
//!
//! Compiled only with the `redis` cargo feature (enabled by default); at
//! runtime it activates only when `REDIS_URL` is configured.

use redis::AsyncCommands;
use serde::{Deserialize, Serialize};

use crate::lifecycle::ShutdownSignal;

/// Redis channel carrying all user-directed WS payloads.
const CHANNEL: &str = "goods4ncu:ws:fanout";

#[derive(Serialize, Deserialize)]
struct FanoutMessage {
    user_id: String,
    payload: String,
}

/// Publish a payload for a user via Redis. Returns Err when Redis is
/// unavailable so the caller can fall back to local delivery.
pub async fn publish(
    conn: &mut redis::aio::ConnectionManager,
    user_id: &str,
    payload: &str,
) -> anyhow::Result<()> {
    let message = serde_json::to_string(&FanoutMessage {
        user_id: user_id.to_string(),
        payload: payload.to_string(),
    })?;
    let _: () = conn.publish(CHANNEL, message).await?;
    Ok(())
}

/// Start the fan-out: registers a publisher with the WS layer and runs the
/// subscription loop until shutdown. On any subscription failure it retries
/// with backoff — a replica that silently stops subscribing would look healthy
/// while dropping every realtime push for its connected users.
pub async fn run(redis_url: String, shutdown: ShutdownSignal) {
    let client = match redis::Client::open(redis_url.as_str()) {
        Ok(client) => client,
        Err(error) => {
            tracing::error!(%error, "WS fanout disabled: invalid REDIS_URL");
            return;
        }
    };

    // Publisher connection: auto-reconnecting manager handed to the WS layer.
    match redis::aio::ConnectionManager::new(client.clone()).await {
        Ok(manager) => {
            crate::api::ws::install_fanout_publisher(manager);
            tracing::info!("WS fanout publisher installed (Redis)");
        }
        Err(error) => {
            tracing::error!(%error, "WS fanout disabled: cannot connect publisher");
            return;
        }
    }

    let mut backoff_secs = 1u64;
    loop {
        if shutdown.is_draining() {
            break;
        }
        match subscribe_loop(&client, &shutdown).await {
            Ok(()) => break, // clean shutdown
            Err(error) => {
                tracing::warn!(%error, backoff_secs, "WS fanout subscription lost; reconnecting");
                if !crate::lifecycle::sleep_or_shutdown(
                    std::time::Duration::from_secs(backoff_secs),
                    &shutdown,
                )
                .await
                .should_continue()
                {
                    break;
                }
                backoff_secs = (backoff_secs * 2).min(30);
            }
        }
    }

    tracing::info!("WS fanout subscriber stopped");
}

async fn subscribe_loop(client: &redis::Client, shutdown: &ShutdownSignal) -> anyhow::Result<()> {
    let mut pubsub = client.get_async_pubsub().await?;
    pubsub.subscribe(CHANNEL).await?;
    tracing::info!(channel = CHANNEL, "WS fanout subscribed");

    use futures_util::StreamExt;
    let mut stream = pubsub.on_message();
    loop {
        tokio::select! {
            biased;
            _ = shutdown.wait() => return Ok(()),
            message = stream.next() => {
                let Some(message) = message else {
                    anyhow::bail!("fanout pubsub stream ended");
                };
                let raw: String = match message.get_payload() {
                    Ok(raw) => raw,
                    Err(error) => {
                        tracing::warn!(%error, "WS fanout: undecodable payload");
                        continue;
                    }
                };
                match serde_json::from_str::<FanoutMessage>(&raw) {
                    Ok(fanout) => {
                        crate::api::ws::deliver_local(&fanout.user_id, &fanout.payload);
                    }
                    Err(error) => {
                        tracing::warn!(%error, "WS fanout: malformed message");
                    }
                }
            }
        }
    }
}
