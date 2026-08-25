//! ModelDriver trait: providers implement only model calls.
//!
//! The runtime engine (Phase 3) drives the loop; drivers never execute
//! tools, parse UI actions, or manage budgets.

use crate::agents::runtime::event::ModelEvent;
use rig::completion::Message;
use std::pin::Pin;

/// Normalized stream of model output events.
pub type ModelEventStream =
    Pin<Box<dyn futures::Stream<Item = Result<ModelEvent, anyhow::Error>> + Send>>;

/// What a provider can do — used for capability-aware routing.
#[derive(Debug, Clone, Default)]
pub struct ModelCapabilities {
    pub supports_tools: bool,
    pub supports_parallel_tools: bool,
    pub supports_usage: bool,
    pub context_window: u32,
}

/// A single step's request to the model.
#[derive(Debug, Clone)]
pub struct ModelRequest {
    /// The latest user message (or tool result fed back).
    pub message: Message,
    /// Prior conversation turns.
    pub history: Vec<Message>,
    /// Tool schemas the model may call this turn.
    pub tool_schemas: Vec<serde_json::Value>,
}

impl ModelRequest {
    pub fn user(msg: impl Into<String>, history: Vec<Message>) -> Self {
        Self {
            message: Message::user(msg.into()),
            history,
            tool_schemas: vec![],
        }
    }

    pub fn with_tools(mut self, tools: Vec<serde_json::Value>) -> Self {
        self.tool_schemas = tools;
        self
    }
}
