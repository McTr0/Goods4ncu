//! Dual-API drivers: ChatCompletionsDriver and ResponsesDriver.
//!
//! Both implement ModelDriver and translate their respective wire
//! formats into normalized ModelEvents. The runtime engine is
//! protocol-agnostic.

use crate::agents::runtime::event::{ModelEvent, ToolCallData};
use crate::agents::runtime::model::{
    ModelCapabilities, ModelDriver, ModelEventStream, ModelRequest,
};
use crate::llm::{AgentModelChunk, MarketplaceAgent};
use futures::StreamExt;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

/// Which wire format the driver uses.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiStyle {
    Auto,
    ChatCompletions,
    Responses,
}

impl ApiStyle {
    pub fn parse(value: &str) -> Result<Self, String> {
        match value {
            "auto" => Ok(Self::Auto),
            "chat_completions" => Ok(Self::ChatCompletions),
            "responses" => Ok(Self::Responses),
            _ => Err(format!(
                "LLM_API_STYLE must be one of auto, chat_completions, responses; got: {value}"
            )),
        }
    }

    pub fn auto_for_provider(provider: &str) -> Self {
        match provider {
            "minimax" => Self::Responses,
            _ => Self::ChatCompletions,
        }
    }

    pub fn resolve(self, provider: &str) -> Self {
        match self {
            Self::Auto => Self::auto_for_provider(provider),
            explicit => explicit,
        }
    }
}

/// Resolve the effective API style from config + provider defaults.
pub fn resolve_api_style(config_value: &str, provider: &str) -> Result<ApiStyle, String> {
    Ok(ApiStyle::parse(config_value)?.resolve(provider))
}

fn translate_chunk(chunk: AgentModelChunk) -> ModelEvent {
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
        AgentModelChunk::Stop => {
            ModelEvent::Stop(crate::agents::runtime::event::ModelStopReason::EndTurn)
        }
    }
}

/// Driver for providers using the OpenAI `/chat/completions` wire format.
pub struct ChatCompletionsDriver {
    pub agent: Arc<dyn MarketplaceAgent>,
    pub provider_name: String,
    pub model_name: String,
}

impl ModelDriver for ChatCompletionsDriver {
    fn provider(&self) -> &str {
        &self.provider_name
    }

    fn model(&self) -> &str {
        &self.model_name
    }

    fn capabilities(&self) -> ModelCapabilities {
        ModelCapabilities {
            supports_tools: true,
            supports_parallel_tools: false,
            supports_usage: true,
            context_window: 128_000,
        }
    }

    fn stream_step<'life0, 'async_trait>(
        &'life0 self,
        request: ModelRequest,
    ) -> Pin<Box<dyn Future<Output = anyhow::Result<ModelEventStream>> + Send + 'async_trait>>
    where
        'life0: 'async_trait,
        Self: 'async_trait,
    {
        let agent = Arc::clone(&self.agent);
        Box::pin(async move {
            let chunk_stream = agent.stream_model_step(request.message, request.history);
            let translated = chunk_stream.map(|result| result.map(translate_chunk));
            Ok(Box::pin(translated) as ModelEventStream)
        })
    }
}

/// Driver for providers using the OpenAI `/responses` wire format.
/// Normalizes function_call/output into the same ModelEvent::ToolCall.
pub struct ResponsesDriver {
    pub agent: Arc<dyn MarketplaceAgent>,
    pub provider_name: String,
    pub model_name: String,
}

impl ModelDriver for ResponsesDriver {
    fn provider(&self) -> &str {
        &self.provider_name
    }

    fn model(&self) -> &str {
        &self.model_name
    }

    fn capabilities(&self) -> ModelCapabilities {
        ModelCapabilities {
            supports_tools: true,
            supports_parallel_tools: false,
            supports_usage: true,
            context_window: 128_000,
        }
    }

    fn stream_step<'life0, 'async_trait>(
        &'life0 self,
        request: ModelRequest,
    ) -> Pin<Box<dyn Future<Output = anyhow::Result<ModelEventStream>> + Send + 'async_trait>>
    where
        'life0: 'async_trait,
        Self: 'async_trait,
    {
        let agent = Arc::clone(&self.agent);
        Box::pin(async move {
            let chunk_stream = agent.stream_model_step(request.message, request.history);
            let translated = chunk_stream.map(|result| result.map(translate_chunk));
            Ok(Box::pin(translated) as ModelEventStream)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn api_style_rejects_unknown_values() {
        assert!(ApiStyle::parse("response").is_err());
        assert!(ApiStyle::parse("").is_err());
    }

    #[test]
    fn auto_selects_minimax_responses_and_chat_elsewhere() {
        assert_eq!(
            resolve_api_style("auto", "minimax"),
            Ok(ApiStyle::Responses)
        );
        assert_eq!(
            resolve_api_style("auto", "openrouter"),
            Ok(ApiStyle::ChatCompletions)
        );
        assert_eq!(
            resolve_api_style("responses", "openai"),
            Ok(ApiStyle::Responses)
        );
    }
}
