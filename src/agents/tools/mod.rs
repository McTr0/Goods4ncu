//! Agent tools: single registration point via [`ToolRegistry`].
//!
//! Domain modules under `tools/` contain tool implementations;
//! `registry.rs` provides the metadata-driven builder.

pub mod registry;

// Re-export everything from the legacy monolith for backward compatibility.
pub use super::tools_legacy::*;
