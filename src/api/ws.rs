//! WebSocket real-time notification push.
//!
//! Clients connect to GET /api/ws and authenticate with:
//! - Authorization: Bearer <jwt>
//!
//! The JWT is validated server-side
//! to associate the WebSocket connection with a user_id. When a notification is
//! created via NotificationService.create(), it is immediately pushed to all
//! connected clients for that user via the global WS_CONNECTIONS map.
//!
//! Multi-connection support: each user can have multiple active connections
//! (e.g., iPhone + iPad simultaneously). Each connection is independently
//! heartbeated via ping/pong. Dead connections are cleaned up automatically.

use axum::extract::ws::Message as WsMsg;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::response::Response;
use dashmap::DashMap;
use futures_util::{SinkExt, StreamExt};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};
use tokio::time::interval;

use crate::api::error::ApiError;
use crate::api::session::Session;
use crate::api::AppState;
use crate::services::campus::CampusService;

/// Connection table: user_id → list of device-scoped channels.
/// DashMap handles concurrent access from multiple tokio tasks.
/// Dead senders are pruned on broadcast or heartbeat timeout.
pub type WsConnections = DashMap<String, Vec<WsConnection>>;

#[derive(Clone)]
pub struct WsConnection {
    sender: mpsc::Sender<Message>,
    campus_id: Option<uuid::Uuid>,
}

#[cfg(feature = "redis")]
pub type FanoutMessage = (String, Option<uuid::Uuid>, String);
#[cfg(feature = "redis")]
pub type FanoutSender = tokio::sync::mpsc::Sender<FanoutMessage>;
#[cfg(feature = "redis")]
type FanoutPublisher = Arc<std::sync::RwLock<Option<FanoutSender>>>;

#[derive(Clone)]
pub struct WsHub {
    pub connections: Arc<WsConnections>,
    #[cfg(feature = "redis")]
    fanout_tx: FanoutPublisher,
}

impl Default for WsHub {
    fn default() -> Self {
        Self::new()
    }
}

impl WsHub {
    pub fn new() -> Self {
        Self {
            connections: Arc::new(DashMap::new()),
            #[cfg(feature = "redis")]
            fanout_tx: Arc::new(std::sync::RwLock::new(None)),
        }
    }

    #[cfg(feature = "redis")]
    pub fn set_fanout_publisher(
        &self,
        tx: tokio::sync::mpsc::Sender<(String, Option<uuid::Uuid>, String)>,
    ) {
        if let Ok(mut lock) = self.fanout_tx.write() {
            *lock = Some(tx);
        }
    }

    pub fn broadcast_to_user(&self, user_id: &str, payload: &str) {
        self.broadcast_to_user_scoped(user_id, None, payload);
    }

    pub fn broadcast_to_user_in_campus(&self, user_id: &str, campus_id: uuid::Uuid, payload: &str) {
        self.broadcast_to_user_scoped(user_id, Some(campus_id), payload);
    }

    fn broadcast_to_user_scoped(
        &self,
        user_id: &str,
        campus_id: Option<uuid::Uuid>,
        payload: &str,
    ) {
        #[cfg(feature = "redis")]
        if let Ok(lock) = self.fanout_tx.read() {
            if let Some(ref tx) = *lock {
                match tx.try_send((user_id.to_string(), campus_id, payload.to_string())) {
                    Ok(_) => return,
                    Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {
                        tracing::warn!(
                            user_id = %user_id,
                            "WS fanout publisher buffer full; falling back to local delivery"
                        );
                    }
                    Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => {
                        tracing::error!(
                            user_id = %user_id,
                            "WS fanout publisher channel closed; falling back to local delivery"
                        );
                    }
                }
            }
        }
        self.deliver_local_scoped(user_id, campus_id, payload);
    }

    pub fn deliver_local_scoped(
        &self,
        user_id: &str,
        campus_id: Option<uuid::Uuid>,
        payload: &str,
    ) {
        deliver_local_scoped_internal(&self.connections, user_id, campus_id, payload);
    }
}

/// Global WebSocket hub instance.
static GLOBAL_WS_HUB: std::sync::LazyLock<Arc<WsHub>> =
    std::sync::LazyLock::new(|| Arc::new(WsHub::new()));

#[allow(dead_code)]
pub fn global_ws_hub() -> Arc<WsHub> {
    Arc::clone(&GLOBAL_WS_HUB)
}

pub fn new_ws_state() -> Arc<WsConnections> {
    Arc::clone(&GLOBAL_WS_HUB.connections)
}

/// Install the Redis-backed fanout publisher sender into the global hub.
#[cfg(feature = "redis")]
pub fn install_fanout_publisher(
    tx: tokio::sync::mpsc::Sender<(String, Option<uuid::Uuid>, String)>,
) {
    GLOBAL_WS_HUB.set_fanout_publisher(tx);
}

/// Broadcast a payload to a user. With the fanout installed this publishes to
/// Redis and delivery happens on every replica (including this one) through
/// the subscription; without it, it delivers to local sockets directly.
pub fn broadcast_to_user(user_id: &str, payload: &str) {
    GLOBAL_WS_HUB.broadcast_to_user(user_id, payload);
}

/// Broadcast a chat event only to sockets authenticated for the conversation's
/// active campus.
pub fn broadcast_to_user_in_campus(user_id: &str, campus_id: uuid::Uuid, payload: &str) {
    GLOBAL_WS_HUB.broadcast_to_user_in_campus(user_id, campus_id, payload);
}

/// Register a bare connection sender for a user — the same registration the
/// upgrade handler performs. Exposed so integration tests can observe local
/// delivery without a real socket.
#[doc(hidden)]
#[allow(dead_code)] // used from the lib crate by integration tests
pub fn register_test_connection(user_id: &str) -> mpsc::Receiver<Message> {
    register_test_connection_for_campus(user_id, None)
}

#[doc(hidden)]
pub fn register_test_connection_for_campus(
    user_id: &str,
    campus_id: Option<uuid::Uuid>,
) -> mpsc::Receiver<Message> {
    let (tx, rx) = mpsc::channel(16);
    GLOBAL_WS_HUB
        .connections
        .entry(user_id.to_string())
        .or_default()
        .push(WsConnection {
            sender: tx,
            campus_id,
        });
    rx
}

/// Deliver a payload to this instance's active connections for a user.
/// Automatically removes dead senders (channel closed).
#[allow(dead_code)]
pub fn deliver_local(user_id: &str, payload: &str) {
    deliver_local_scoped(user_id, None, payload);
}

#[allow(dead_code)]
pub fn deliver_local_for_campus(user_id: &str, campus_id: uuid::Uuid, payload: &str) {
    deliver_local_scoped(user_id, Some(campus_id), payload);
}

fn deliver_local_scoped_internal(
    connections_map: &WsConnections,
    user_id: &str,
    campus_id: Option<uuid::Uuid>,
    payload: &str,
) {
    let metrics = crate::api::metrics::GLOBAL_METRICS.get().cloned();

    if let Some(connections) = connections_map.get(user_id) {
        let mut dead_indices = vec![];
        for (i, connection) in connections.value().iter().enumerate() {
            if campus_id.is_some() && connection.campus_id != campus_id {
                continue;
            }
            match connection.sender.try_send(Message::Text(payload.into())) {
                Ok(_) => {}
                Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => {
                    dead_indices.push(i);
                    if let Some(metrics) = metrics.as_ref() {
                        metrics.record_ws_message_dropped();
                    }
                }
                Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {
                    if let Some(metrics) = metrics.as_ref() {
                        metrics.record_ws_message_dropped();
                    }
                    tracing::warn!(
                        user_id = %user_id,
                        connection_index = i,
                        "WS outbound buffer full; dropping message"
                    );
                }
            }
        }
        drop(connections);
        // Remove dead connections (reverse order to preserve indices).
        if !dead_indices.is_empty() {
            let pruned = dead_indices.len();
            if let Some(mut connections) = connections_map.get_mut(user_id) {
                for i in dead_indices.into_iter().rev() {
                    connections.value_mut().remove(i);
                }
                if let Some(metrics) = metrics.as_ref() {
                    metrics.record_ws_stale_pruned(pruned);
                }
                if connections.value().is_empty() {
                    drop(connections);
                    connections_map.remove(user_id);
                }
            }
        }
    }
}

pub(crate) fn deliver_local_scoped(user_id: &str, campus_id: Option<uuid::Uuid>, payload: &str) {
    deliver_local_scoped_internal(&GLOBAL_WS_HUB.connections, user_id, campus_id, payload);
}

// ---------------------------------------------------------------------------
// Axum handler
// ---------------------------------------------------------------------------

/// GET /api/ws — WebSocket upgrade endpoint.
///
/// Authentication is extracted from the Authorization header via [`Session`].
pub async fn ws_handler(
    axum::extract::State(state): axum::extract::State<AppState>,
    Session(session): Session,
    ws: WebSocketUpgrade,
) -> Result<Response, ApiError> {
    if let Some(campus_id) = session.campus_id {
        CampusService::new(state.infra.db.clone())
            .require_tenant_context_for_session(&session.user_id, Some(campus_id))
            .await?;
    }

    Ok(ws.on_upgrade(move |socket| async move {
        handle_socket(socket, session.user_id, session.campus_id).await;
    }))
}

/// Handle a single WebSocket connection for its lifetime.
///
/// Uses `futures_util::StreamExt::split` to divide the WebSocket into independent
/// send and receive halves that run concurrently in separate spawned tasks:
///
/// - Send task: pulls from `rx` mpsc channel and sends over the wire.
///   Also drives heartbeat pings every 30s. Handles pong relay from recv task.
/// - Recv task: receives from the wire, forwards ping data to sender task via mpsc.
///   Detects connection death and signals sender to exit.
/// - A oneshot channel signals the sender when the receiver closes.
/// - On close, this specific connection tx is removed from WS_CONNECTIONS.
async fn handle_socket(socket: WebSocket, user_id: String, campus_id: Option<uuid::Uuid>) {
    let (ws_sender, mut ws_receiver) = socket.split();

    // Channel for relaying ping data from recv task to sender task.
    let (ping_tx, mut ping_rx) = mpsc::channel::<Vec<u8>>(8);

    // Create a channel for this connection — buffer up to 64 pending messages.
    let (tx, rx) = mpsc::channel::<Message>(64);

    // Register this connection.
    GLOBAL_WS_HUB
        .connections
        .entry(user_id.clone())
        .or_default()
        .push(WsConnection {
            sender: tx.clone(),
            campus_id,
        });

    tracing::debug!(
        user_id = %user_id,
        total_connections = GLOBAL_WS_HUB.connections.get(&user_id).map(|c| c.value().len()).unwrap_or(0),
        "WS connection registered"
    );

    // Signal sender when recv task exits.
    let (close_tx, close_rx) = oneshot::channel::<()>();

    // Spawn sender task: drives ws_sender, sends pings, handles rx and ping_rx.
    tokio::spawn(async move {
        let mut ws_sender = ws_sender;
        let mut rx = rx;
        let mut close_rx = close_rx;
        let mut heartbeat = interval(Duration::from_secs(30));
        heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        loop {
            tokio::select! {
                msg = rx.recv() => {
                    match msg {
                        Some(msg) => {
                            if ws_sender.send(msg).await.is_err() {
                                break;
                            }
                        }
                        None => break,
                    }
                }
                ping_data = ping_rx.recv() => {
                    // Forward a pong response from the recv task.
                    if let Some(data) = ping_data {
                        let _ = ws_sender.send(Message::Pong(data.into())).await;
                    }
                }
                _ = heartbeat.tick() => {
                    // Send heartbeat ping. If the connection is dead, the send will fail.
                    if ws_sender.send(Message::Ping(vec![].into())).await.is_err() {
                        break;
                    }
                }
                _ = &mut close_rx => {
                    // Receiver closed — graceful shutdown.
                    let _ = ws_sender.close().await;
                    break;
                }
            }
        }
    });

    // Recv task (main): drives ws_receiver, forwards ping data.
    loop {
        match ws_receiver.next().await {
            Some(Ok(WsMsg::Close(_))) | None => break,
            Some(Ok(WsMsg::Ping(data))) => {
                // Relay ping data to sender task for pong response.
                // If the channel is full (sender stalled), just drop and continue.
                if ping_tx.try_send(data.to_vec()).is_err() {
                    if let Some(metrics) = crate::api::metrics::GLOBAL_METRICS.get() {
                        metrics.record_ws_message_dropped();
                    }
                }
            }
            Some(Ok(_)) => {} // Ignore other client→server messages.
            Some(Err(e)) => {
                tracing::warn!(%e, "WS receive error");
                break;
            }
        }
    }

    // Socket closed. Clean up: remove this specific tx from the user's connection list.
    if let Some(mut connections) = GLOBAL_WS_HUB.connections.get_mut(&user_id) {
        let before = connections.value().len();
        connections
            .value_mut()
            .retain(|connection| !connection.sender.is_closed());
        let pruned = before.saturating_sub(connections.value().len());
        if pruned > 0 {
            if let Some(metrics) = crate::api::metrics::GLOBAL_METRICS.get() {
                metrics.record_ws_stale_pruned(pruned);
            }
        }
        if connections.value().is_empty() {
            drop(connections);
            GLOBAL_WS_HUB.connections.remove(&user_id);
            tracing::debug!(%user_id, "WS: last connection closed, user removed");
        } else {
            tracing::debug!(%user_id, remaining = connections.value().len(), "WS: connection cleaned up");
        }
    }
    let _ = close_tx.send(());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ws_connections_type_compiles() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<WsConnections>();
        assert_send_sync::<Arc<WsConnections>>();
    }

    #[tokio::test]
    async fn campus_scoped_broadcast_does_not_cross_device_tenants() {
        let user_id = format!("ws-scope-{}", uuid::Uuid::new_v4().simple());
        let campus_a = uuid::Uuid::new_v4();
        let campus_b = uuid::Uuid::new_v4();
        let mut campus_a_rx = register_test_connection_for_campus(&user_id, Some(campus_a));
        let mut campus_b_rx = register_test_connection_for_campus(&user_id, Some(campus_b));
        let payload = "{\"event\":\"message_acknowledgement_changed\"}";

        broadcast_to_user_in_campus(&user_id, campus_a, payload);

        let received = campus_a_rx.recv().await.expect("campus A receives event");
        assert!(matches!(received, Message::Text(text) if text.as_str() == payload));
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), campus_b_rx.recv())
                .await
                .is_err()
        );
    }
}
