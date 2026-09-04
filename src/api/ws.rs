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
    pub fn set_fanout_publisher(&self, tx: FanoutSender) {
        if let Ok(mut lock) = self.fanout_tx.write() {
            *lock = Some(tx);
        }
    }

    #[cfg(feature = "redis")]
    pub fn clear_fanout_publisher(&self) {
        if let Ok(mut lock) = self.fanout_tx.write() {
            *lock = None;
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

    #[allow(dead_code)]
    pub fn register_test_connection(&self, user_id: &str) -> mpsc::Receiver<Message> {
        self.register_test_connection_for_campus(user_id, None)
    }

    #[allow(dead_code)]
    pub fn register_test_connection_for_campus(
        &self,
        user_id: &str,
        campus_id: Option<uuid::Uuid>,
    ) -> mpsc::Receiver<Message> {
        let (tx, rx) = mpsc::channel(16);
        self.connections
            .entry(user_id.to_string())
            .or_default()
            .push(WsConnection {
                sender: tx,
                campus_id,
            });
        rx
    }
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

    let ws_hub = state.infra.ws_hub.clone();
    Ok(ws.on_upgrade(move |socket| async move {
        handle_socket(socket, ws_hub, session.user_id, session.campus_id).await;
    }))
}

/// Handle a single WebSocket connection for its lifetime.
async fn handle_socket(
    socket: WebSocket,
    ws_hub: Arc<WsHub>,
    user_id: String,
    campus_id: Option<uuid::Uuid>,
) {
    let (ws_sender, mut ws_receiver) = socket.split();

    // Channel for relaying ping data from recv task to sender task.
    let (ping_tx, mut ping_rx) = mpsc::channel::<Vec<u8>>(8);

    // Create a channel for this connection — buffer up to 64 pending messages.
    let (tx, rx) = mpsc::channel::<Message>(64);

    // Register this connection.
    ws_hub
        .connections
        .entry(user_id.clone())
        .or_default()
        .push(WsConnection {
            sender: tx.clone(),
            campus_id,
        });

    tracing::debug!(
        user_id = %user_id,
        total_connections = ws_hub.connections.get(&user_id).map(|c| c.value().len()).unwrap_or(0),
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
                        Some(message) => {
                            if ws_sender.send(message).await.is_err() {
                                break;
                            }
                        }
                        None => break,
                    }
                }
                ping_data = ping_rx.recv() => {
                    match ping_data {
                        Some(data) => {
                            if ws_sender.send(Message::Pong(data.into())).await.is_err() {
                                break;
                            }
                        }
                        None => break,
                    }
                }
                _ = heartbeat.tick() => {
                    if ws_sender.send(Message::Ping(vec![].into())).await.is_err() {
                        break;
                    }
                }
                _ = &mut close_rx => {
                    break;
                }
            }
        }
    });

    // Recv task: read messages from client until close or error.
    while let Some(msg_res) = ws_receiver.next().await {
        match msg_res {
            Ok(Message::Ping(data)) => {
                let _ = ping_tx.send(data.to_vec()).await;
            }
            Ok(Message::Close(_)) | Err(_) => {
                break;
            }
            Ok(_) => {
                // Ignore text/binary/pong from client.
            }
        }
    }

    // Socket closed. Clean up: remove this specific tx from the user's connection list.
    if let Some(mut connections) = ws_hub.connections.get_mut(&user_id) {
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
            ws_hub.connections.remove(&user_id);
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
        let hub = WsHub::new();
        let user_id = format!("ws-scope-{}", uuid::Uuid::new_v4().simple());
        let campus_a = uuid::Uuid::new_v4();
        let campus_b = uuid::Uuid::new_v4();
        let mut campus_a_rx = hub.register_test_connection_for_campus(&user_id, Some(campus_a));
        let mut campus_b_rx = hub.register_test_connection_for_campus(&user_id, Some(campus_b));
        let payload = "{\"event\":\"message_acknowledgement_changed\"}";

        hub.broadcast_to_user_in_campus(&user_id, campus_a, payload);

        let received = campus_a_rx.recv().await.expect("campus A receives event");
        assert!(matches!(received, Message::Text(text) if text.as_str() == payload));
        assert!(campus_b_rx.try_recv().is_err());
    }
}
