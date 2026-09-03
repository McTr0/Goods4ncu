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

/// Redis channel carrying all user-directed WS payloads.
pub const CHANNEL: &str = "goods4ncu:ws:fanout";

#[derive(Serialize, Deserialize)]
struct FanoutMessage {
    user_id: String,
    #[serde(default)]
    campus_id: Option<uuid::Uuid>,
    payload: String,
}

/// Publish a payload for a user via Redis. Returns Err when Redis is
/// unavailable so the caller can fall back to local delivery.
#[allow(dead_code)] // retained for callers that publish unscoped notifications
pub async fn publish(
    conn: &mut redis::aio::ConnectionManager,
    user_id: &str,
    payload: &str,
) -> anyhow::Result<()> {
    publish_scoped(conn, user_id, None, payload).await
}

pub async fn publish_scoped(
    conn: &mut redis::aio::ConnectionManager,
    user_id: &str,
    campus_id: Option<uuid::Uuid>,
    payload: &str,
) -> anyhow::Result<()> {
    let message = serde_json::to_string(&FanoutMessage {
        user_id: user_id.to_string(),
        campus_id,
        payload: payload.to_string(),
    })?;
    let _: () = conn.publish(CHANNEL, message).await?;
    Ok(())
}

pub fn handle_fanout_payload(raw: &str) {
    match serde_json::from_str::<FanoutMessage>(raw) {
        Ok(fanout) => {
            if let Some(campus_id) = fanout.campus_id {
                crate::api::ws::deliver_local_for_campus(
                    &fanout.user_id,
                    campus_id,
                    &fanout.payload,
                );
            } else {
                crate::api::ws::deliver_local(&fanout.user_id, &fanout.payload);
            }
        }
        Err(error) => {
            tracing::warn!(%error, "WS fanout: malformed message");
        }
    }
}
