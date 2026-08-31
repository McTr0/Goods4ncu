//! Agent Runtime v2 — provider-independent execution engine.
//!
//! This module owns the versioned event protocol, execution budgets,
//! and the loop guard. The runtime engine itself lives in `engine.rs`
//! (Phase 3); this phase establishes the protocol types and serialization
//! contracts that both Rust and Flutter consume.

#![allow(dead_code)]

pub mod api_drivers;
pub mod budget;
pub mod driver;
pub mod engine;
pub mod envelope;
pub mod error;
pub mod event;
pub mod fake_driver;
pub mod hooks;
pub mod loop_guard;
pub mod model;
pub mod route;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

/// A handle for cancelling an in-flight agent turn.
///
/// Uses an atomic bool to avoid adding tokio-util as a dependency.
#[derive(Debug, Clone)]
pub struct TurnCancellation {
    cancelled: Arc<AtomicBool>,
    notify: Arc<tokio::sync::Notify>,
}

impl Default for TurnCancellation {
    fn default() -> Self {
        Self::new()
    }
}

impl TurnCancellation {
    pub fn new() -> Self {
        Self {
            cancelled: Arc::new(AtomicBool::new(false)),
            notify: Arc::new(tokio::sync::Notify::new()),
        }
    }

    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
        self.notify.notify_waiters();
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
    }

    pub async fn cancelled(&self) {
        loop {
            let notified = self.notify.notified();
            if self.is_cancelled() {
                return;
            }
            notified.await;
        }
    }

    fn same_instance(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.cancelled, &other.cancelled)
    }
}

use std::collections::HashMap;
use std::sync::Mutex;

/// Global registry of in-flight turn cancellation tokens.
/// Keyed by conversation_id (one active turn per conversation).
static TURN_REGISTRY: std::sync::LazyLock<Mutex<HashMap<String, TurnCancellation>>> =
    std::sync::LazyLock::new(|| Mutex::new(HashMap::new()));

pub struct TurnRegistry;

impl TurnRegistry {
    pub fn register(conversation_id: &str) -> TurnCancellation {
        let tc = TurnCancellation::new();
        if let Ok(mut map) = TURN_REGISTRY.lock() {
            if let Some(previous) = map.insert(conversation_id.to_string(), tc.clone()) {
                previous.cancel();
            }
        }
        tc
    }

    pub fn cancel(conversation_id: &str) -> bool {
        if let Ok(map) = TURN_REGISTRY.lock() {
            if let Some(tc) = map.get(conversation_id) {
                tc.cancel();
                return true;
            }
        }
        false
    }

    pub fn remove(conversation_id: &str) {
        if let Ok(mut map) = TURN_REGISTRY.lock() {
            map.remove(conversation_id);
        }
    }

    fn remove_if(conversation_id: &str, cancellation: &TurnCancellation) {
        if let Ok(mut map) = TURN_REGISTRY.lock() {
            let should_remove = map
                .get(conversation_id)
                .is_some_and(|registered| registered.same_instance(cancellation));
            if should_remove {
                map.remove(conversation_id);
            }
        }
    }
}

/// The registry key is deliberately based on the public conversation ID.
/// Internal assistant storage IDs are an implementation detail and must not
/// leak into the cancel endpoint contract.
pub fn turn_registry_key(user_id: &str, public_conversation_id: &str) -> String {
    format!("agent:{user_id}:{public_conversation_id}")
}

/// Cancels and unregisters a turn when its SSE response is dropped.
pub struct TurnRegistration {
    key: String,
    cancellation: TurnCancellation,
}

impl TurnRegistration {
    pub fn register(key: String) -> Self {
        let cancellation = TurnRegistry::register(&key);
        Self { key, cancellation }
    }

    pub fn cancellation(&self) -> TurnCancellation {
        self.cancellation.clone()
    }
}

impl Drop for TurnRegistration {
    fn drop(&mut self) {
        self.cancellation.cancel();
        TurnRegistry::remove_if(&self.key, &self.cancellation);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stale_registration_cannot_remove_replacement_turn() {
        let key = format!("test:{}", uuid::Uuid::new_v4());
        let first = TurnRegistration::register(key.clone());
        let second = TurnRegistration::register(key.clone());
        assert!(first.cancellation().is_cancelled());

        drop(first);
        assert!(TurnRegistry::cancel(&key));
        assert!(second.cancellation().is_cancelled());
        drop(second);
    }
}
