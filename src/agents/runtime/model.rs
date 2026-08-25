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

/// Providers implement this to become a [`ModelDriver`] adapter.
///
/// The driver only translates provider streams into normalized
/// [`ModelEvent`]s; it does NOT execute tools, parse UI actions,
/// manage budgets, or detect loops.
pub trait ModelDriver: Send + Sync {
    /// Provider identifier (e.g., "gemini", "minimax", "openai").
    fn provider(&self) -> &str;

    /// Model identifier (e.g., "gemini-3-flash-preview").
    fn model(&self) -> &str;

    /// Capability flags for routing decisions.
    fn capabilities(&self) -> super::model::ModelCapabilities;

    /// Stream one inference step.
    ///
    /// Returns a stream of normalized events. The runtime consumes these;
    /// it never sees provider-specific formats.
    fn stream_step<'life0, 'async_trait>(
        &'life0 self,
        request: ModelRequest,
    ) -> ::core::pin::Pin<
        Box<
            dyn ::core::future::Future<Output = anyhow::Result<ModelEventStream>>
                + Send
                + 'async_trait,
        >,
    >
    where
        'life0: 'async_trait,
        Self: 'async_trait;
}
