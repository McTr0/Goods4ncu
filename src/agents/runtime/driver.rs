//! MarketplaceAgent → ModelDriver adapters.
//!
//! Wraps existing provider agents as [`ModelDriver`] implementations.
//! The underlying agent exposes a single raw model step. Tool execution stays
//! in AgentRuntime, so this adapter only translates normalized provider output.

use crate::agents::runtime::event::{ModelEvent, ModelStopReason, ToolCallData};
use crate::agents::runtime::model::{
    ModelCapabilities, ModelDriver, ModelEventStream, ModelRequest,
};
use crate::llm::{AgentModelChunk, MarketplaceAgent};
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

    fn translate(chunk: AgentModelChunk) -> ModelEvent {
        match chunk {
            AgentModelChunk::Text(text) => ModelEvent::TextDelta(text),
            AgentModelChunk::Usage(u) => {
                ModelEvent::Usage(crate::agents::runtime::event::AgentTokenUsage {
                    prompt_tokens: u.input_tokens,
                    completion_tokens: u.output_tokens,
                })
            }
            AgentModelChunk::ToolCall {
                id,
                call_id,
                name,
                arguments,
            } => ModelEvent::ToolCall(ToolCallData {
                id,
                call_id,
                name,
                arguments,
            }),
            AgentModelChunk::Stop => ModelEvent::Stop(ModelStopReason::EndTurn),
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
            let chunk_stream = agent.stream_model_step(request.message, request.history);
            let translated = chunk_stream.map(|result| result.map(Self::translate));

            Ok(Box::pin(translated) as ModelEventStream)
        })
    }
}
