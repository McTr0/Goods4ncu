//! MarketplaceAgent → ModelDriver adapters.
//!
//! Wraps existing provider agents as [`ModelDriver`] implementations.
//! The underlying agents execute tools inline inside their streaming
//! loops; this adapter translates the mixed output into normalized
//! [`ModelEvent`]s for the runtime engine. Full tool/model separation
//! arrives with ToolResultEnvelope (Phase 4).

use crate::agents::runtime::event::ModelEvent;
use crate::agents::runtime::model::{
    ModelCapabilities, ModelDriver, ModelEventStream, ModelRequest,
};
use crate::llm::{AgentStreamChunk, MarketplaceAgent};
use futures::StreamExt;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

/// Generic adapter wrapping any [`MarketplaceAgent`].
pub struct MarketplaceDriver {
    inner: Arc<dyn MarketplaceAgent>,
    provider_name: String,
    model_name: String,
    caps: ModelCapabilities,
}

impl MarketplaceDriver {
    pub fn new(
        inner: Arc<dyn MarketplaceAgent>,
        provider_name: impl Into<String>,
        model_name: impl Into<String>,
    ) -> Self {
        Self {
            inner,
            provider_name: provider_name.into(),
            model_name: model_name.into(),
            caps: ModelCapabilities {
                supports_tools: true,
                supports_parallel_tools: false,
                supports_usage: true,
                context_window: 128_000,
            },
        }
    }

    /// Translate an AgentStreamChunk into zero or more ModelEvents.
    fn translate(chunk: &AgentStreamChunk) -> Vec<ModelEvent> {
        match chunk {
            AgentStreamChunk::Text(text) => vec![ModelEvent::TextDelta(text.clone())],
            AgentStreamChunk::Usage(u) => vec![ModelEvent::Usage(
                crate::agents::runtime::event::AgentTokenUsage {
                    prompt_tokens: u.input_tokens,
                    completion_tokens: u.output_tokens,
                },
            )],
            // Tool activity and UI actions are inline side effects from the
            // legacy loop; the runtime observes them but doesn't act on them.
            _ => vec![],
        }
    }
}

impl ModelDriver for MarketplaceDriver {
    fn provider(&self) -> &str {
        &self.provider_name
    }

    fn model(&self) -> &str {
        &self.model_name
    }

    fn capabilities(&self) -> ModelCapabilities {
        self.caps.clone()
    }

    fn stream_step<'life0, 'async_trait>(
        &'life0 self,
        request: ModelRequest,
    ) -> Pin<Box<dyn Future<Output = anyhow::Result<ModelEventStream>> + Send + 'async_trait>>
    where
        'life0: 'async_trait,
        Self: 'async_trait,
    {
        let agent = Arc::clone(&self.inner);
        Box::pin(async move {
            // Extract the user message text from the rig Message.
            let msg_text = extract_message_text(&request.message);

            // Call the existing stream_chat which handles model calls +
            // inline tool execution transparently.
            let chunk_stream = agent.stream_chat(msg_text, request.history);

            // Translate each chunk into ModelEvents.
            let translated = chunk_stream.filter_map(|result| async move {
                match result {
                    Ok(chunk) => {
                        let events = Self::translate(&chunk);
                        events.into_iter().next().map(Ok)
                    }
                    Err(e) => Some(Err(anyhow::anyhow!("{}", e))),
                }
            });

            Ok(Box::pin(translated) as ModelEventStream)
        })
    }
}

/// Extract text content from a rig Message (user variant only).
fn extract_message_text(msg: &rig::completion::Message) -> String {
    match msg {
        rig::completion::Message::User { content } => content
            .iter()
            .filter_map(|c| match c {
                rig::message::UserContent::Text(t) => Some(t.text.clone()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join(" "),
        _ => String::new(),
    }
}
