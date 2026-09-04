use super::{
    AgentModelChunk, AgentStreamChunk, AgentTokenUsage, CircuitBreaker, EmbeddingGenerator,
    EmbeddingModelMetadata, MarketplaceAgent, ReplyAssistant, LLM_CIRCUIT_BREAKER,
    REPLY_ASSISTANT_PREAMBLE,
};
use crate::agents::models::Document;
use crate::agents::tools::ToolContext;
use async_trait::async_trait;
use futures::Stream;
use futures::StreamExt;
use rig::agent::Agent;
use rig::client::CompletionClient;
use rig::completion::{GetTokenUsage, Message, Prompt};
use rig::embeddings::EmbeddingsBuilder;
use rig::providers::gemini;
use rig::streaming::{StreamedAssistantContent, StreamingCompletion};
use sqlx::PgPool;
use std::pin::Pin;
use std::sync::Arc;

pub struct GeminiProvider {
    client: gemini::Client,
    model: String,
    embedding_dim: usize,
}

impl GeminiProvider {
    #[allow(dead_code)]
    pub fn new(api_key: &str, embedding_dim: usize) -> anyhow::Result<Self> {
        Self::new_with_model(api_key, embedding_dim, "gemini-3-flash-preview")
    }

    pub fn new_with_model(
        api_key: &str,
        embedding_dim: usize,
        model: impl Into<String>,
    ) -> anyhow::Result<Self> {
        let reqwest_client = crate::llm::llm_http_client()?;

        let client = gemini::Client::builder()
            .api_key(api_key)
            .http_client(reqwest_client)
            .build()?;

        Ok(Self {
            client,
            model: model.into(),
            embedding_dim,
        })
    }

    pub fn build_embedding_generator(&self) -> Arc<dyn EmbeddingGenerator> {
        Arc::new(GeminiEmbeddingGenerator {
            client: self.client.clone(),
            embedding_dim: self.embedding_dim,
        })
    }
}

struct GeminiEmbeddingGenerator {
    client: gemini::Client,
    embedding_dim: usize,
}

#[async_trait]
impl EmbeddingGenerator for GeminiEmbeddingGenerator {
    async fn generate(&self, normalized_text: &str) -> anyhow::Result<Vec<f64>> {
        let embedding_model = gemini::embedding::EmbeddingModel::new(
            self.client.clone(),
            gemini::EMBEDDING_001,
            self.embedding_dim,
        );
        let document = Document {
            id: uuid::Uuid::new_v4().to_string(),
            content: normalized_text.to_string(),
        };
        let embeddings = EmbeddingsBuilder::new(embedding_model)
            .document(document)
            .map_err(|e| anyhow::anyhow!("Embedding builder error: {e}"))?
            .build()
            .await
            .map_err(|e| anyhow::anyhow!("Embeddings API error: {e}"))?;
        embeddings
            .first()
            .map(|embedding| embedding.1.first_ref().vec.clone())
            .ok_or_else(|| anyhow::anyhow!("embedding provider returned no vector"))
    }
}

#[async_trait]
impl super::LlmProvider for GeminiProvider {
    fn name(&self) -> &str {
        "gemini"
    }

    fn model(&self) -> &str {
        &self.model
    }

    async fn create_marketplace_agent(
        self: Arc<Self>,
        db_pool: &PgPool,
        current_user_id: Option<String>,
        current_campus_id: Option<uuid::Uuid>,
        proposal_idempotency_key: Option<String>,
        moderation: crate::services::moderation::ModerationService,
    ) -> anyhow::Result<Box<dyn MarketplaceAgent>> {
        let ctx = ToolContext {
            db_pool: db_pool.clone(),
            current_user_id,
            current_campus_id,
            proposal_idempotency_key,
            moderation,
            notification: crate::services::notification::NotificationService::new(db_pool.clone()),
        };

        let agent = self
            .client
            .agent(&self.model)
            .preamble(crate::llm::system_preamble())
            // Global dynamic_context is disabled: rig's vector store cannot
            // apply campus/status/restriction filters before similarity.
            .tool(crate::agents::tools::CreateListingTool { ctx: ctx.clone() })
            .tool(crate::agents::tools::SearchInventoryTool { ctx: ctx.clone() })
            .tool(crate::agents::tools::GetListingDetailsTool { ctx: ctx.clone() })
            .tool(crate::agents::tools::UpdateListingTool { ctx: ctx.clone() })
            .tool(crate::agents::tools::DeleteListingTool { ctx: ctx.clone() })
            .tool(crate::agents::tools::PurchaseItemIntentTool { ctx: ctx.clone() })
            .tool(crate::agents::tools::NegotiateItemTool { ctx: ctx.clone() })
            .tool(crate::agents::tools::GetMyListingsTool { ctx: ctx.clone() })
            .tool(crate::agents::tools::GetUserPostsTool { ctx: ctx.clone() })
            .tool(crate::agents::tools::FindRelatedPostsTool { ctx: ctx.clone() })
            .tool(crate::agents::tools::GetCommentsTool { ctx: ctx.clone() })
            .tool(crate::agents::tools::DraftMessageTool { ctx: ctx.clone() })
            .tool(crate::agents::tools::DraftCommentTool { ctx: ctx.clone() })
            .build();

        Ok(Box::new(GeminiMarketplaceAgent(agent)))
    }

    fn embedding_generator(self: Arc<Self>) -> Arc<dyn EmbeddingGenerator> {
        self.build_embedding_generator()
    }

    fn embedding_metadata(&self) -> EmbeddingModelMetadata {
        EmbeddingModelMetadata {
            provider: "gemini",
            model: gemini::EMBEDDING_001,
            dimensions: self.embedding_dim,
        }
    }

    async fn create_reply_assistant(self: Arc<Self>) -> anyhow::Result<Box<dyn ReplyAssistant>> {
        let agent = self
            .client
            .agent(&self.model)
            .preamble(REPLY_ASSISTANT_PREAMBLE)
            .build();
        Ok(Box::new(GeminiReplyAssistant(agent)))
    }
}

pub struct GeminiMarketplaceAgent(Agent<gemini::completion::CompletionModel<reqwest::Client>>);

#[async_trait]
impl MarketplaceAgent for GeminiMarketplaceAgent {
    async fn prompt(&self, msg: String) -> anyhow::Result<String> {
        if LLM_CIRCUIT_BREAKER.is_open().await {
            tracing::warn!("LLM circuit breaker: prompt rejected (circuit open)");
            return Err(anyhow::anyhow!(CircuitBreaker::degraded_message()));
        }
        match self.0.prompt(msg).await {
            Ok(r) => {
                LLM_CIRCUIT_BREAKER.record_success().await;
                Ok(r)
            }
            Err(e) => {
                LLM_CIRCUIT_BREAKER.record_failure().await;
                Err(anyhow::anyhow!(e))
            }
        }
    }

    async fn prompt_with_history(
        &self,
        msg: String,
        history: Vec<Message>,
    ) -> anyhow::Result<String> {
        if LLM_CIRCUIT_BREAKER.is_open().await {
            tracing::warn!("LLM circuit breaker: prompt_with_history rejected (circuit open)");
            return Err(anyhow::anyhow!(CircuitBreaker::degraded_message()));
        }
        let mut h = history;
        match self.0.prompt(Message::user(msg)).with_history(&mut h).await {
            Ok(reply) => {
                LLM_CIRCUIT_BREAKER.record_success().await;
                Ok(reply)
            }
            Err(e) => {
                LLM_CIRCUIT_BREAKER.record_failure().await;
                Err(anyhow::anyhow!(e))
            }
        }
    }

    async fn prompt_with_history_with_usage(
        &self,
        msg: String,
        history: Vec<Message>,
    ) -> anyhow::Result<(String, Option<AgentTokenUsage>)> {
        if LLM_CIRCUIT_BREAKER.is_open().await {
            tracing::warn!("LLM circuit breaker: prompt_with_history rejected (circuit open)");
            return Err(anyhow::anyhow!(CircuitBreaker::degraded_message()));
        }
        let mut h = history;
        match self
            .0
            .prompt(Message::user(msg))
            .with_history(&mut h)
            .extended_details()
            .await
        {
            Ok(response) => {
                LLM_CIRCUIT_BREAKER.record_success().await;
                Ok((response.output, AgentTokenUsage::from_rig(response.usage)))
            }
            Err(error) => {
                LLM_CIRCUIT_BREAKER.record_failure().await;
                Err(anyhow::anyhow!(error))
            }
        }
    }

    fn stream_chat(
        &self,
        msg: String,
        history: Vec<Message>,
    ) -> Pin<Box<dyn Stream<Item = Result<AgentStreamChunk, anyhow::Error>> + Send>> {
        let h = history;
        let agent = self.0.clone();
        let circuit_breaker = Arc::clone(&LLM_CIRCUIT_BREAKER);
        Box::pin(::async_stream::try_stream! {
            // Check circuit breaker at stream start — fail fast before any LLM call.
            if circuit_breaker.is_open().await {
                tracing::warn!("LLM circuit breaker: stream_chat rejected (circuit open)");
                Err(anyhow::anyhow!(CircuitBreaker::degraded_message()))?;
            }

            let mut current_msg = Message::user(msg);
            let mut chat_history = h;
            let mut call_succeeded = false;

            loop {
                let stream_result = agent
                    .stream_completion(current_msg.clone(), chat_history.clone())
                    .await;
                let stream = match stream_result {
                    Ok(s) => s,
                    Err(e) => {
                        circuit_breaker.record_failure().await;
                        Err(anyhow::anyhow!("stream error: {}", e))?
                    }
                };

                let mut stream = match stream.stream().await {
                    Ok(s) => s,
                    Err(e) => {
                        circuit_breaker.record_failure().await;
                        Err(anyhow::anyhow!("stream error: {}", e))?
                    }
                };

                chat_history.push(current_msg.clone());
                let mut tool_calls = vec![];

                while let Some(content) = stream.next().await {
                    match content.map_err(|e| anyhow::anyhow!("completion error: {}", e))? {
                        StreamedAssistantContent::Text(text) => {
                            yield AgentStreamChunk::Text(text.text);
                            call_succeeded = true;
                        }
                        StreamedAssistantContent::ToolCall { tool_call, internal_call_id: _ } => {
                            let args_str = tool_call.function.arguments.to_string();
                            yield AgentStreamChunk::ToolActivity {
                                tool: tool_call.function.name.clone(),
                            };
                            let result = agent
                                .tool_server_handle
                                .call_tool(&tool_call.function.name, &args_str)
                                .await
                                .map_err(|e| anyhow::anyhow!("tool error: {}", e))?;
                            // Rig serializes the tool Output into a JSON
                            // string; unwrap that envelope so UI-action
                            // parsers and the model see the real text.
                            let result = match serde_json::from_str::<String>(&result) {
                                Ok(unwrapped) => unwrapped,
                                Err(_) => result,
                            };
                            // Emit UI actions for search and details tools so the
                            // frontend can highlight results and scroll to them.
                            let mut envelope = crate::agents::runtime::envelope::ToolResultEnvelope::from_tool_result(
                                &tool_call.function.name,
                                &result,
                            );
                            if tool_call.function.name == "get_listing_details" {
                                if let Some(id) = tool_call
                                    .function
                                    .arguments
                                    .get("listing_id")
                                    .and_then(|v| v.as_str())
                                {
                                    envelope
                                        .ui_actions
                                        .push(crate::llm::UiAction::scroll_to_post(id));
                                }
                            }
                            for action in envelope.ui_actions {
                                yield AgentStreamChunk::UiAction(action);
                            }
                            // Goal §40: user-generated platform content is
                            // untrusted data; fence it before it reaches the
                            // model so embedded instructions stay inert.
                            let result = crate::llm::wrap_untrusted_platform_data(
                                &tool_call.function.name,
                                &envelope.model_data,
                            );
                            tool_calls.push((tool_call.clone(), result));
                            call_succeeded = true;
                        }
                        // Reasoning is provider-internal metadata. Never expose
                        // or persist it as assistant-visible text.
                        StreamedAssistantContent::Reasoning(_) => {}
                        StreamedAssistantContent::ToolCallDelta { .. } => {}
                        StreamedAssistantContent::ReasoningDelta { .. } => {}
                        StreamedAssistantContent::Final(response) => {
                            if let Some(usage) = response.token_usage().and_then(AgentTokenUsage::from_rig) {
                                yield AgentStreamChunk::Usage(usage);
                            }
                        }
                    }
                }

                let has_tool_calls = !tool_calls.is_empty();
                if has_tool_calls {
                    let assistant_calls = tool_calls
                        .iter()
                        .map(|(tool_call, _)| {
                            rig::message::AssistantContent::ToolCall(tool_call.clone())
                        })
                        .collect::<Vec<_>>();
                    if let Ok(content) = rig::OneOrMany::many(assistant_calls) {
                        chat_history.push(Message::Assistant { id: None, content });
                    }
                    for (tool_call, result) in tool_calls {
                        chat_history.push(Message::tool_result_with_call_id(
                            tool_call.id,
                            tool_call.call_id,
                            result,
                        ));
                    }
                }

                if !has_tool_calls {
                    break;
                }

                current_msg = chat_history.pop().unwrap_or(current_msg);
            }

            // Record success only if at least one LLM call succeeded.
            if call_succeeded {
                circuit_breaker.record_success().await;
            }
        })
    }

    fn stream_model_step(
        &self,
        message: Message,
        history: Vec<Message>,
    ) -> Pin<Box<dyn Stream<Item = Result<AgentModelChunk, anyhow::Error>> + Send>> {
        let agent = self.0.clone();
        let circuit_breaker = Arc::clone(&LLM_CIRCUIT_BREAKER);
        Box::pin(async_stream::try_stream! {
            if circuit_breaker.is_open().await {
                Err(anyhow::anyhow!(CircuitBreaker::degraded_message()))?;
            }
            let stream = match agent.stream_completion(message, history).await {
                Ok(stream) => stream,
                Err(error) => {
                    circuit_breaker.record_failure().await;
                    Err(anyhow::anyhow!("stream error: {error}"))?
                }
            };
            let mut stream = match stream.stream().await {
                Ok(stream) => stream,
                Err(error) => {
                    circuit_breaker.record_failure().await;
                    Err(anyhow::anyhow!("stream error: {error}"))?
                }
            };
            let mut succeeded = false;
            while let Some(content) = stream.next().await {
                let content = match content {
                    Ok(content) => content,
                    Err(error) => {
                        circuit_breaker.record_failure().await;
                        Err(anyhow::anyhow!("completion error: {error}"))?
                    }
                };
                match content {
                    StreamedAssistantContent::Text(text) => {
                        succeeded = true;
                        yield AgentModelChunk::Text(text.text);
                    }
                    StreamedAssistantContent::ToolCall { tool_call, .. } => {
                        succeeded = true;
                        yield AgentModelChunk::ToolCall {
                            id: tool_call.id,
                            call_id: tool_call.call_id,
                            name: tool_call.function.name,
                            arguments: tool_call.function.arguments,
                        };
                    }
                    StreamedAssistantContent::Reasoning(_) => {}
                    StreamedAssistantContent::Final(response) => {
                        if let Some(usage) = response.token_usage().and_then(AgentTokenUsage::from_rig) {
                            yield AgentModelChunk::Usage(usage);
                        }
                        yield AgentModelChunk::Stop;
                    }
                    StreamedAssistantContent::ToolCallDelta { .. }
                    | StreamedAssistantContent::ReasoningDelta { .. } => {}
                }
            }
            if succeeded {
                circuit_breaker.record_success().await;
            }
        })
    }

    async fn execute_tool(&self, name: &str, arguments: &str) -> anyhow::Result<String> {
        let result = self
            .0
            .tool_server_handle
            .call_tool(name, arguments)
            .await
            .map_err(|error| anyhow::anyhow!("tool error: {error}"))?;
        Ok(serde_json::from_str::<String>(&result).unwrap_or(result))
    }
}

pub struct GeminiReplyAssistant(Agent<gemini::completion::CompletionModel<reqwest::Client>>);

#[async_trait]
impl ReplyAssistant for GeminiReplyAssistant {
    async fn prompt(&self, msg: String) -> anyhow::Result<String> {
        Ok(self.0.prompt(msg).await?)
    }
}
