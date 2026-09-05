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
    pub connection_id: uuid::Uuid,
    pub sender: mpsc::Sender<Message>,
    pub campus_id: Option<uuid::Uuid>,
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

    #[cfg(feature = "redis")]
    #[allow(dead_code)]
    pub fn has_fanout_publisher(&self) -> bool {
        if let Ok(lock) = self.fanout_tx.read() {
            lock.is_some()
        } else {
            false
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

    pub fn register_connection(
        &self,
        user_id: &str,
        connection_id: uuid::Uuid,
        campus_id: Option<uuid::Uuid>,
        sender: mpsc::Sender<Message>,
    ) {
        self.connections
            .entry(user_id.to_string())
            .or_default()
            .push(WsConnection {
                connection_id,
                sender,
                campus_id,
            });
    }

    pub fn remove_connection(&self, user_id: &str, connection_id: uuid::Uuid) -> bool {
        if let Some(mut connections) = self.connections.get_mut(user_id) {
            let before = connections.value().len();
            connections
                .value_mut()
                .retain(|c| c.connection_id != connection_id);
            let pruned = before.saturating_sub(connections.value().len());
            if pruned > 0 {
                if let Some(metrics) = crate::api::metrics::GLOBAL_METRICS.get() {
                    metrics.record_ws_stale_pruned(pruned);
                }
            }
            drop(connections);
            if self
                .connections
                .remove_if(user_id, |_k, conns| conns.is_empty())
                .is_some()
            {
                tracing::debug!(%user_id, %connection_id, "WS: last connection closed, user removed");
            } else {
                tracing::debug!(%user_id, %connection_id, "WS: connection cleaned up");
            }
            pruned > 0
        } else {
            false
        }
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
        self.register_test_connection_with_id(user_id, uuid::Uuid::new_v4(), campus_id)
    }

    #[allow(dead_code)]
    pub fn register_test_connection_with_id(
        &self,
        user_id: &str,
        connection_id: uuid::Uuid,
        campus_id: Option<uuid::Uuid>,
    ) -> mpsc::Receiver<Message> {
        let (tx, rx) = mpsc::channel(16);
        self.register_connection(user_id, connection_id, campus_id, tx);
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
        let mut dead_ids = Vec::new();
        for connection in connections.value().iter() {
            if campus_id.is_some() && connection.campus_id != campus_id {
                continue;
            }
            match connection.sender.try_send(Message::Text(payload.into())) {
                Ok(_) => {}
                Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => {
                    dead_ids.push(connection.connection_id);
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
                        connection_id = %connection.connection_id,
                        "WS outbound buffer full; dropping message"
                    );
                }
            }
        }
        drop(connections);

        // Remove dead connections by stable connection_id.
        // This eliminates the DashMap index-shifting race when concurrent removals occur.
        if !dead_ids.is_empty() {
            if let Some(mut connections) = connections_map.get_mut(user_id) {
                let before = connections.value().len();
                connections
                    .value_mut()
                    .retain(|c| !dead_ids.contains(&c.connection_id));
                let pruned = before.saturating_sub(connections.value().len());
                if pruned > 0 {
                    if let Some(metrics) = metrics.as_ref() {
                        metrics.record_ws_stale_pruned(pruned);
                    }
                }
                drop(connections);
                connections_map.remove_if(user_id, |_k, conns| conns.is_empty());
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

/// RAII guard ensuring the exact connection is removed from `WsHub` on disconnect or drop.
struct WsConnectionGuard {
    ws_hub: Arc<WsHub>,
    user_id: String,
    connection_id: uuid::Uuid,
}

impl Drop for WsConnectionGuard {
    fn drop(&mut self) {
        self.ws_hub
            .remove_connection(&self.user_id, self.connection_id);
    }
}

/// Handle a single WebSocket connection for its lifetime.
async fn handle_socket(
    socket: WebSocket,
    ws_hub: Arc<WsHub>,
    user_id: String,
    campus_id: Option<uuid::Uuid>,
) {
    let connection_id = uuid::Uuid::new_v4();
    let (ws_sender, mut ws_receiver) = socket.split();

    // Channel for relaying ping data from recv task to sender task.
    let (ping_tx, mut ping_rx) = mpsc::channel::<Vec<u8>>(8);

    // Create a channel for this connection — buffer up to 64 pending messages.
    let (tx, rx) = mpsc::channel::<Message>(64);

    // Register this connection with its stable connection_id.
    ws_hub.register_connection(&user_id, connection_id, campus_id, tx);

    tracing::debug!(
        user_id = %user_id,
        %connection_id,
        total_connections = ws_hub.connections.get(&user_id).map(|c| c.value().len()).unwrap_or(0),
        "WS connection registered"
    );

    // RAII cleanup guard ensures exact teardown even on panic, cancellation, or error.
    let _guard = WsConnectionGuard {
        ws_hub: ws_hub.clone(),
        user_id: user_id.clone(),
        connection_id,
    };

    // Signal sender when recv task exits.
    let (close_tx, close_rx) = oneshot::channel::<()>();
    // Signal recv task when sender task exits (bidirectional cancellation).
    let (sender_done_tx, mut sender_done_rx) = oneshot::channel::<()>();

    // Spawn sender task: drives ws_sender, sends pings, handles rx and ping_rx.
    let sender_handle = tokio::spawn(async move {
        let _sender_done = sender_done_tx;
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

    // Recv task: read messages from client until close or error, or until sender task finishes.
    loop {
        tokio::select! {
            _ = &mut sender_done_rx => {
                tracing::debug!(user_id = %user_id, %connection_id, "WS sender task finished; exiting recv loop");
                break;
            }
            msg_res = ws_receiver.next() => {
                match msg_res {
                    Some(Ok(Message::Ping(data))) => {
                        if ping_tx.send(data.to_vec()).await.is_err() {
                            break;
                        }
                    }
                    Some(Ok(Message::Close(_))) | Some(Err(_)) | None => {
                        break;
                    }
                    Some(Ok(_)) => {
                        // Ignore text/binary/pong from client.
                    }
                }
            }
        }
    }

    // Recv loop finished: signal and abort sender task if still active.
    let _ = close_tx.send(());
    sender_handle.abort();
    // _guard will drop here and safely remove this connection_id from ws_hub.
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

    #[test]
    fn exact_disconnect_cleanup_preserves_sibling_connections() {
        let hub = WsHub::new();
        let user_id = format!("ws-exact-{}", uuid::Uuid::new_v4().simple());
        let id_1 = uuid::Uuid::new_v4();
        let id_2 = uuid::Uuid::new_v4();

        let _rx_1 = hub.register_test_connection_with_id(&user_id, id_1, None);
        let mut rx_2 = hub.register_test_connection_with_id(&user_id, id_2, None);

        assert_eq!(
            hub.connections.get(&user_id).map(|c| c.value().len()),
            Some(2)
        );

        // Remove only connection 1
        assert!(hub.remove_connection(&user_id, id_1));

        // User still has connection 2
        assert_eq!(
            hub.connections.get(&user_id).map(|c| c.value().len()),
            Some(1)
        );

        // Connection 2 can still receive broadcasts
        hub.broadcast_to_user(&user_id, "test-msg");
        assert!(rx_2.try_recv().is_ok());

        // Nonexistent connection removal returns false
        assert!(!hub.remove_connection(&user_id, uuid::Uuid::new_v4()));

        // Remove connection 2 -> user entry removed
        assert!(hub.remove_connection(&user_id, id_2));
        assert!(hub.connections.get(&user_id).is_none());
    }

    #[tokio::test]
    async fn dead_senders_pruned_by_id_without_index_corruption() {
        let hub = WsHub::new();
        let user_id = format!("ws-race-{}", uuid::Uuid::new_v4().simple());
        let id_1 = uuid::Uuid::new_v4();
        let id_2 = uuid::Uuid::new_v4();
        let id_3 = uuid::Uuid::new_v4();

        let rx_1 = hub.register_test_connection_with_id(&user_id, id_1, None);
        let mut rx_2 = hub.register_test_connection_with_id(&user_id, id_2, None);
        let rx_3 = hub.register_test_connection_with_id(&user_id, id_3, None);

        // Drop receivers 1 and 3 to make senders dead
        drop(rx_1);
        drop(rx_3);

        // Deliver message: should prune 1 and 3 safely by ID
        hub.broadcast_to_user(&user_id, "hello active");

        // Connection 2 received the message
        let msg = rx_2.recv().await.expect("connection 2 receives message");
        assert!(matches!(msg, Message::Text(t) if t == "hello active"));

        // Only connection 2 remains
        let remaining = hub.connections.get(&user_id).expect("user still exists");
        assert_eq!(remaining.value().len(), 1);
        assert_eq!(remaining.value()[0].connection_id, id_2);
    }

    #[test]
    fn concurrent_reconnection_during_disconnect_cleanup_is_preserved() {
        let hub = WsHub::new();
        let user_id = format!("ws-reconn-{}", uuid::Uuid::new_v4().simple());
        let old_id = uuid::Uuid::new_v4();
        let new_id = uuid::Uuid::new_v4();

        // 1. Initial connection established
        let _rx_old = hub.register_test_connection_with_id(&user_id, old_id, None);

        // 2. Simulate concurrent reconnect: add new connection
        let _rx_new = hub.register_test_connection_with_id(&user_id, new_id, None);

        // 3. Cleanup old connection
        assert!(hub.remove_connection(&user_id, old_id));

        // 4. Verify user entry still exists and new connection is retained
        let conns = hub
            .connections
            .get(&user_id)
            .expect("user entry must not be deleted");
        assert_eq!(conns.value().len(), 1);
        assert_eq!(conns.value()[0].connection_id, new_id);
    }

    #[cfg(feature = "redis")]
    #[test]
    fn has_fanout_publisher_reflects_installation() {
        let hub = WsHub::new();
        assert!(!hub.has_fanout_publisher());

        let (tx, _rx) = tokio::sync::mpsc::channel(1);
        hub.set_fanout_publisher(tx);
        assert!(hub.has_fanout_publisher());

        hub.clear_fanout_publisher();
        assert!(!hub.has_fanout_publisher());
    }
}
