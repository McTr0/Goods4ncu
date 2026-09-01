//! Agent tools: single registration point via [`ToolRegistry`].
//!
//! Domain modules under `tools/` contain tool implementations;
//! `registry.rs` provides the metadata-driven builder.

pub mod common;
pub mod listing;
pub mod registry;
pub mod social;
pub mod trade;

#[cfg(test)]
mod tests;

pub use common::*;
pub use listing::*;
pub use social::*;
pub use trade::*;
