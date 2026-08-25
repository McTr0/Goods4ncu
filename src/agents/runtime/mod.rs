//! Agent Runtime v2 — provider-independent execution engine.
//!
//! This module owns the versioned event protocol, execution budgets,
//! and the loop guard. The runtime engine itself lives in `engine.rs`
//! (Phase 3); this phase establishes the protocol types and serialization
//! contracts that both Rust and Flutter consume.

#![allow(dead_code)]

pub mod budget;
pub mod error;
pub mod event;
