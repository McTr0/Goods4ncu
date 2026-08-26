//! Agent Runtime v2 — provider-independent execution engine.
//!
//! This module owns the versioned event protocol, execution budgets,
//! and the loop guard. The runtime engine itself lives in `engine.rs`
//! (Phase 3); this phase establishes the protocol types and serialization
//! contracts that both Rust and Flutter consume.

#![allow(dead_code)]

pub mod budget;
pub mod driver;
pub mod engine;
pub mod envelope;
pub mod error;
pub mod event;
pub mod hooks;
pub mod loop_guard;
pub mod model;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

/// A handle for cancelling an in-flight agent turn.
///
/// Uses an atomic bool to avoid adding tokio-util as a dependency.
#[derive(Debug, Clone)]
pub struct TurnCancellation {
    cancelled: Arc<AtomicBool>,
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
        }
    }

    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
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
            map.insert(conversation_id.to_string(), tc.clone());
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
}
