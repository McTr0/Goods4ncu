use super::{
    AgentStreamChunk, AgentTokenUsage, CircuitBreaker, EmbeddingGenerator, EmbeddingModelMetadata,
    MarketplaceAgent, ReplyAssistant, LLM_CIRCUIT_BREAKER, PREAMBLE, REPLY_ASSISTANT_PREAMBLE,
};
use crate::agents::models::Document;
use crate::agents::tools::ToolContext;
use crate::services::BusinessEvent;
use async_trait::async_trait;
use futures::StreamExt;
use rig::agent::Agent;
use rig::client::CompletionClient;
use rig::completion::{GetTokenUsage, Message, Prompt};
use rig::embeddings::EmbeddingsBuilder;
use rig::providers::gemini;
use rig::providers::openai;
use rig::streaming::{StreamedAssistantContent, StreamingCompletion};
use std::pin::Pin;
use std::sync::Arc;
use tokio::sync::mpsc;

pub struct MiniMaxProvider {
    /// MiniMax OpenAI-compatible client for chat completions.
    chat_client: openai::Client<reqwest::Client>,
    /// Gemini client used only for embeddings (vector search + tool insertion).
    embedding_client: gemini::Client,
    model: String,
    embedding_dim: usize,
}

impl MiniMaxProvider {
    #[allow(dead_code)]
    pub fn new(
        api_key: &str,
        base_url: Option<&str>,
        gemini_api_key: &str,
        embedding_dim: usize,
    ) -> anyhow::Result<Self> {
        Self::new_with_model(
            api_key,
            base_url,
            "MiniMax-M2.7",
            gemini_api_key,
            embedding_dim,
        )
    }

    pub fn new_with_model(
        api_key: &str,
        base_url: Option<&str>,
        model: impl Into<String>,
        gemini_api_key: &str,
        embedding_dim: usize,
    ) -> anyhow::Result<Self> {
        let base_url = base_url.unwrap_or("https://api.minimaxi.com/v1");
        let chat_client = openai::Client::builder()
            .api_key(api_key)
            .base_url(base_url)
            .http_client(crate::llm::llm_http_client()?)
            .build()?;

        let embedding_client = gemini::Client::builder()
            .api_key(gemini_api_key)
            .http_client(crate::llm::llm_http_client()?)
            .build()?;

        Ok(Self {
            chat_client,
            embedding_client,
            model: model.into(),
            embedding_dim,
        })
    }

    pub fn build_embedding_generator(&self) -> Arc<dyn EmbeddingGenerator> {
        Arc::new(MiniMaxEmbeddingGenerator {
            embedding_client: self.embedding_client.clone(),
            embedding_dim: self.embedding_dim,
        })
    }
}

struct MiniMaxEmbeddingGenerator {
    embedding_client: gemini::Client,
    embedding_dim: usize,
}

#[async_trait]
impl EmbeddingGenerator for MiniMaxEmbeddingGenerator {
    async fn generate(&self, normalized_text: &str) -> anyhow::Result<Vec<f64>> {
        let embedding_model = gemini::embedding::EmbeddingModel::new(
            self.embedding_client.clone(),
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
impl super::LlmProvider for MiniMaxProvider {
    fn name(&self) -> &str {
        "minimax"
    }

    fn model(&self) -> &str {
        &self.model
    }

    async fn create_marketplace_agent(
        self: Arc<Self>,
        db_pool: &sqlx::PgPool,
        _event_tx: mpsc::Sender<BusinessEvent>,
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
            .chat_client
            .agent(&self.model)
            .preamble(PREAMBLE)
            // Global dynamic_context is disabled until retrieval can enforce
            // campus/status/restriction scope before vector ranking.
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
            .build();

        Ok(Box::new(MiniMaxMarketplaceAgent(agent)))
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
            .chat_client
            .agent(&self.model)
            .preamble(REPLY_ASSISTANT_PREAMBLE)
            .build();
        Ok(Box::new(MiniMaxReplyAssistant(agent)))
    }
}

pub struct MiniMaxMarketplaceAgent(
    Agent<openai::responses_api::ResponsesCompletionModel<reqwest::Client>>,
);

#[async_trait]
impl MarketplaceAgent for MiniMaxMarketplaceAgent {
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
        match self
            .0
            .prompt(rig::completion::Message::user(msg))
            .with_history(&mut h)
            .await
        {
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
            .prompt(rig::completion::Message::user(msg))
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
    ) -> Pin<Box<dyn futures::Stream<Item = Result<AgentStreamChunk, anyhow::Error>> + Send>> {
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
            let mut did_call_tool = false;
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
                            did_call_tool = false;
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
                            match tool_call.function.name.as_str() {
                                "search_inventory" => {
                                    if let Ok(ids) = crate::llm::extract_listing_ids(&result) {
                                        if !ids.is_empty() {
                                            yield AgentStreamChunk::UiAction(
                                                crate::llm::UiAction::show_posts(ids),
                                            );
                                        }
                                    }
                                }
                                "get_listing_details" => {
                                    if let Some(id) = tool_call
                                        .function
                                        .arguments
                                        .get("listing_id")
                                        .and_then(|v| v.as_str())
                                    {
                                        yield AgentStreamChunk::UiAction(
                                            crate::llm::UiAction::scroll_to_post(id),
                                        );
                                    }
                                }
                                "find_related_posts" | "get_user_posts" => {
                                    if let Ok(ids) = crate::llm::extract_listing_ids(&result) {
                                        if !ids.is_empty() {
                                            yield AgentStreamChunk::UiAction(
                                                crate::llm::UiAction::show_posts(ids),
                                            );
                                        }
                                    }
                                }
                                "draft_message" => {
                                    let parts: Vec<&str> = result.splitn(4, '|').collect();
                                    if parts.len() == 4 && parts[0] == "DRAFT_MESSAGE" {
                                        yield AgentStreamChunk::UiAction(
                                            crate::llm::UiAction::open_message_draft(
                                                parts[2],
                                                parts[1],
                                                parts[3],
                                            ),
                                        );
                                    }
                                }
                                _ => {}
                            }
                            // Goal §40: user-generated platform content is
                            // untrusted data; fence it before it reaches the
                            // model so embedded instructions stay inert.
                            let result = crate::llm::wrap_untrusted_platform_data(
                                &tool_call.function.name,
                                &result,
                            );
                            tool_calls.push((tool_call.id.clone(), tool_call.call_id.clone(), result));
                            did_call_tool = true;
                            call_succeeded = true;
                        }
                        StreamedAssistantContent::Reasoning(reasoning) => {
                            let rendered = reasoning.display_text();
                            if !rendered.is_empty() {
                                yield AgentStreamChunk::Text(rendered);
                            }
                            did_call_tool = false;
                            call_succeeded = true;
                        }
                        StreamedAssistantContent::ToolCallDelta { .. } => {}
                        StreamedAssistantContent::ReasoningDelta { .. } => {}
                        StreamedAssistantContent::Final(response) => {
                            if let Some(usage) = response.token_usage().and_then(AgentTokenUsage::from_rig) {
                                yield AgentStreamChunk::Usage(usage);
                            }
                        }
                    }
                }

                if !tool_calls.is_empty() {
                    for (id, call_id, result) in tool_calls {
                        chat_history.push(Message::tool_result_with_call_id(
                            id, call_id, result,
                        ));
                    }
                }

                if !did_call_tool {
                    break;
                }

                current_msg = chat_history.last().cloned().unwrap_or(current_msg);
            }

            // Record success only if at least one LLM call succeeded.
            if call_succeeded {
                circuit_breaker.record_success().await;
            }
        })
    }
}

pub struct MiniMaxReplyAssistant(
    Agent<openai::responses_api::ResponsesCompletionModel<reqwest::Client>>,
);

#[async_trait]
impl ReplyAssistant for MiniMaxReplyAssistant {
    async fn prompt(&self, msg: String) -> anyhow::Result<String> {
        Ok(self.0.prompt(msg).await?)
    }
}
