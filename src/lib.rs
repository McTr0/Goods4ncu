//! Library crate for good4ncu - exposes modules for integration testing.
//!
//! This module re-exports the internal components needed for E2E testing.

pub mod agents;
pub mod api;
pub mod categories;
pub mod cli;
pub mod config;
pub mod db;
pub mod lifecycle;
pub mod llm;
pub mod middleware;
pub mod repositories;
pub mod services;
pub mod test_infra;
pub mod utils;
