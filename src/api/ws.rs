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
use axum::http::{HeaderMap, StatusCode};
use axum::{
    extract::ws::{Message, WebSocket, WebSocketUpgrade},
    response::IntoResponse,
};
use dashmap::DashMap;
use futures_util::{SinkExt, StreamExt};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};
use tokio::time::interval;

use crate::api::auth::{
    ensure_token_not_revoked, ensure_user_not_banned, extract_user_id_from_token_str_with_fallback,
};
use crate::api::AppState;

/// Connection table: user_id → list of tx channels (one per connected device).
/// DashMap handles concurrent access from multiple tokio tasks.
/// Dead senders are pruned on broadcast or heartbeat timeout.
pub type WsConnections = DashMap<String, Vec<mpsc::Sender<Message>>>;

/// Global WebSocket connections registry.
/// Uses LazyLock so it is initialized on first access (at startup, not lazily per request).
static WS_CONNECTIONS: std::sync::LazyLock<Arc<WsConnections>> =
    std::sync::LazyLock::new(|| Arc::new(DashMap::new()));

pub fn new_ws_state() -> Arc<WsConnections> {
    Arc::clone(&WS_CONNECTIONS)
}

/// Global broadcast — pushes a JSON payload to ALL active connections for a user.
/// Automatically removes dead senders (channel closed).
pub fn broadcast_to_user(user_id: &str, payload: &str) {
    let metrics = crate::api::metrics::GLOBAL_METRICS.get().cloned();

    if let Some(connections) = WS_CONNECTIONS.get(user_id) {
        let mut dead_indices = vec![];
        for (i, tx) in connections.value().iter().enumerate() {
            match tx.try_send(Message::Text(payload.into())) {
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
            if let Some(mut connections) = WS_CONNECTIONS.get_mut(user_id) {
                for i in dead_indices.into_iter().rev() {
                    connections.value_mut().remove(i);
                }
                if let Some(metrics) = metrics.as_ref() {
                    metrics.record_ws_stale_pruned(pruned);
                }
                if connections.value().is_empty() {
                    drop(connections);
                    WS_CONNECTIONS.remove(user_id);
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
/// Authentication is extracted from the Authorization header only.
pub async fn ws_handler(
    axum::extract::State(state): axum::extract::State<AppState>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    let token = match extract_bearer_token(&headers) {
        Ok(token) => token,
        Err(()) => {
            tracing::warn!("WS auth failed: missing or malformed Authorization header");
            return (
                StatusCode::UNAUTHORIZED,
                axum::response::Json(serde_json::json!({
                    "error": "Unauthorized"
                })),
            )
                .into_response();
        }
    };

    if ensure_token_not_revoked(&state, token).await.is_err() {
        tracing::warn!("WS auth failed: revoked token");
        return (
            StatusCode::UNAUTHORIZED,
            axum::response::Json(serde_json::json!({
                "error": "Unauthorized"
            })),
        )
            .into_response();
    }

    let user_id = match extract_user_id_from_token_str_with_fallback(
        token,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    ) {
        Ok(uid) => uid,
        Err(err) => {
            tracing::warn!(err = %err, "WS auth failed");
            return (
                StatusCode::UNAUTHORIZED,
                axum::response::Json(serde_json::json!({
                    "error": "Unauthorized"
                })),
            )
                .into_response();
        }
    };
    if let Err(err) = ensure_user_not_banned(&state, &user_id).await {
        tracing::warn!(user_id = %user_id, "WS auth failed: user is not active");
        return err.into_response();
    }

    ws.on_upgrade(move |socket| async move {
        handle_socket(socket, user_id).await;
    })
}

fn extract_bearer_token(headers: &HeaderMap) -> Result<&str, ()> {
    headers
        .get("Authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .filter(|v| !v.is_empty())
        .ok_or(())
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
async fn handle_socket(socket: WebSocket, user_id: String) {
    let (ws_sender, mut ws_receiver) = socket.split();

    // Channel for relaying ping data from recv task to sender task.
    let (ping_tx, mut ping_rx) = mpsc::channel::<Vec<u8>>(8);

    // Create a channel for this connection — buffer up to 64 pending messages.
    let (tx, rx) = mpsc::channel::<Message>(64);

    // Register this connection.
    WS_CONNECTIONS
        .entry(user_id.clone())
        .or_default()
        .push(tx.clone());

    tracing::debug!(
        user_id = %user_id,
        total_connections = WS_CONNECTIONS.get(&user_id).map(|c| c.value().len()).unwrap_or(0),
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
    if let Some(mut connections) = WS_CONNECTIONS.get_mut(&user_id) {
        let before = connections.value().len();
        connections.value_mut().retain(|t| !t.is_closed());
        let pruned = before.saturating_sub(connections.value().len());
        if pruned > 0 {
            if let Some(metrics) = crate::api::metrics::GLOBAL_METRICS.get() {
                metrics.record_ws_stale_pruned(pruned);
            }
        }
        if connections.value().is_empty() {
            drop(connections);
            WS_CONNECTIONS.remove(&user_id);
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

    #[test]
    fn test_extract_bearer_token_from_header() {
        let mut headers = HeaderMap::new();
        headers.insert(
            "Authorization",
            "Bearer eyJhbGciOiJIUzI1NiJ9.test".parse().expect("header"),
        );

        let token = extract_bearer_token(&headers).expect("token");
        assert_eq!(token, "eyJhbGciOiJIUzI1NiJ9.test");
    }

    #[test]
    fn test_extract_bearer_token_rejects_missing_header() {
        let headers = HeaderMap::new();
        assert!(extract_bearer_token(&headers).is_err());
    }

    #[test]
    fn test_extract_bearer_token_rejects_malformed_header() {
        let mut headers = HeaderMap::new();
        headers.insert("Authorization", "Token abc".parse().expect("header"));
        assert!(extract_bearer_token(&headers).is_err());
    }
}
