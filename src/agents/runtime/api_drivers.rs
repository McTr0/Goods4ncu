//! Dual-API drivers: ChatCompletionsDriver and ResponsesDriver.
//!
//! Both implement ModelDriver and translate their respective wire
//! formats into normalized ModelEvents. The runtime engine is
//! protocol-agnostic.

use crate::agents::runtime::event::{ModelEvent, ToolCallData};
use crate::agents::runtime::model::{
    ModelCapabilities, ModelDriver, ModelEventStream, ModelRequest,
};
use crate::llm::{AgentStreamChunk, MarketplaceAgent};
use futures::StreamExt;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

/// Which wire format the driver uses.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiStyle {
    ChatCompletions,
    Responses,
}

impl ApiStyle {
    pub fn parse(value: &str) -> Self {
        match value {
            "responses" => Self::Responses,
            _ => Self::ChatCompletions,
        }
    }

    pub fn auto_for_provider(provider: &str) -> Self {
        match provider {
            "minimax" => Self::Responses,
            _ => Self::ChatCompletions,
        }
    }
}

/// Resolve the effective API style from config + provider defaults.
pub fn resolve_api_style(config_value: &str, provider: &str) -> ApiStyle {
    match config_value {
        "chat_completions" => ApiStyle::ChatCompletions,
        "responses" => ApiStyle::Responses,
        _ => ApiStyle::auto_for_provider(provider),
    }
}

fn extract_user_text(msg: &rig::completion::Message) -> String {
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

fn translate_chunk(chunk: &AgentStreamChunk) -> Option<Result<ModelEvent, anyhow::Error>> {
    match chunk {
        AgentStreamChunk::Text(text) => Some(Ok(ModelEvent::TextDelta(text.clone()))),
        AgentStreamChunk::Usage(u) => Some(Ok(ModelEvent::Usage(
            crate::agents::runtime::event::AgentTokenUsage {
                prompt_tokens: u.input_tokens,
                completion_tokens: u.output_tokens,
            },
        ))),
        AgentStreamChunk::ToolActivity { tool } => Some(Ok(ModelEvent::ToolCall(ToolCallData {
            call_id: format!("tc_{}", tool),
            name: tool.clone(),
            arguments: serde_json::json!({}),
        }))),
        AgentStreamChunk::UiAction(_) => None,
    }
}

/// Driver for providers using the OpenAI `/chat/completions` wire format.
pub struct ChatCompletionsDriver {
    pub agent: Arc<dyn MarketplaceAgent>,
    pub model_name: String,
}

impl ModelDriver for ChatCompletionsDriver {
    fn provider(&self) -> &str {
        "openai_compatible"
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
            let msg_text = extract_user_text(&request.message);
            let chunk_stream = agent.stream_chat(msg_text, request.history);
            let translated = chunk_stream.filter_map(|result| async move {
                match result {
                    Ok(ref chunk) => translate_chunk(chunk),
                    Err(e) => Some(Err(anyhow::anyhow!("{}", e))),
                }
            });
            Ok(Box::pin(translated) as ModelEventStream)
        })
    }
}

/// Driver for providers using the OpenAI `/responses` wire format.
/// Normalizes function_call/output into the same ModelEvent::ToolCall.
pub struct ResponsesDriver {
    pub agent: Arc<dyn MarketplaceAgent>,
    pub model_name: String,
}

impl ModelDriver for ResponsesDriver {
    fn provider(&self) -> &str {
        "responses"
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
            let msg_text = extract_user_text(&request.message);
            let chunk_stream = agent.stream_chat(msg_text, request.history);
            let translated = chunk_stream.filter_map(|result| async move {
                match result {
                    Ok(ref chunk) => translate_chunk(chunk),
                    Err(e) => Some(Err(anyhow::anyhow!("{}", e))),
                }
            });
            Ok(Box::pin(translated) as ModelEventStream)
        })
    }
}
