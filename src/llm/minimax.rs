use super::{
    CircuitBreaker, MarketplaceAgent, NegotiateAgent, ReplyAssistant, LLM_CIRCUIT_BREAKER,
    NEGOTIATION_PREAMBLE, PREAMBLE, REPLY_ASSISTANT_PREAMBLE,
};
use crate::agents::models::Document;
use crate::agents::tools::{EmbedUpdater, ToolContext, ToolError};
use crate::services::BusinessEvent;
use async_trait::async_trait;
use futures::StreamExt;
use rig::agent::Agent;
use rig::client::CompletionClient;
use rig::completion::{Message, Prompt};
use rig::embeddings::EmbeddingsBuilder;
use rig::providers::gemini;
use rig::providers::openai;
use rig::streaming::{StreamedAssistantContent, StreamingCompletion};
use rig_postgres::{PgVectorDistanceFunction, PostgresVectorStore};
use sqlx::{PgConnection, PgPool};
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

    /// Build the RAG index for dynamic_context and the embed_updater for atomic
    /// listing/vector writes inside tool-owned transactions.
    pub fn build_vector_store(
        &self,
        db_pool: &PgPool,
    ) -> (
        PostgresVectorStore<gemini::embedding::EmbeddingModel>,
        Arc<dyn EmbedUpdater>,
    ) {
        let embedding_model = gemini::embedding::EmbeddingModel::new(
            self.embedding_client.clone(),
            gemini::EMBEDDING_001,
            self.embedding_dim,
        );
        // RAG store: owned by dynamic_context (consumed at agent build time).
        // Retrieval reads through `documents_vector`, a UUID-typed view over
        // `documents`. rig-postgres decodes result ids as `Uuid` while our
        // `documents.id` is TEXT (it mirrors `inventory.id`), so pointing the
        // store at the base table fails to decode as soon as a single row
        // exists. See migration 0046.
        let rag_store = PostgresVectorStore::new(
            embedding_model.clone(),
            db_pool.clone(),
            Some(crate::services::vector::DOCUMENTS_VECTOR_VIEW.to_string()),
            PgVectorDistanceFunction::Cosine,
        );

        // embed_updater: for atomic re-embedding within a transaction (UpdateListingTool).
        let embedding_client_for_updater = self.embedding_client.clone();
        let dim_for_updater = self.embedding_dim;
        let embed_updater: Arc<dyn EmbedUpdater> = Arc::new(MiniMaxEmbedUpdater {
            embedding_client: embedding_client_for_updater,
            embedding_dim: dim_for_updater,
        });

        (rag_store, embed_updater)
    }
}

struct MiniMaxEmbedUpdater {
    embedding_client: gemini::Client,
    embedding_dim: usize,
}

#[async_trait(?Send)]
impl EmbedUpdater for MiniMaxEmbedUpdater {
    async fn embed_and_update(
        &self,
        content: String,
        listing_id: String,
        conn: &mut PgConnection,
    ) -> Result<(), ToolError> {
        let embedding_model = gemini::embedding::EmbeddingModel::new(
            self.embedding_client.clone(),
            gemini::EMBEDDING_001,
            self.embedding_dim,
        );
        let document = Document {
            id: listing_id.clone(),
            content: content.clone(),
        };
        let embeddings = EmbeddingsBuilder::new(embedding_model)
            .document(document)
            .map_err(|e| ToolError(format!("Embedding builder error: {}", e)))?
            .build()
            .await
            .map_err(|e| ToolError(format!("Embeddings API error: {}", e)))?;

        // Extract the embedding vector (Vec<f64>) for SQL binding.
        let embedding_vec: Vec<f64> = embeddings[0].1.first_ref().vec.clone();
        let document_json = serde_json::json!({ "id": listing_id, "content": content });

        sqlx::query(
            "INSERT INTO documents (id, document, embedded_text, embedding) \
             VALUES ($1, $2::jsonb, $3, $4) \
             ON CONFLICT (id) DO UPDATE SET \
               document = EXCLUDED.document, \
               embedded_text = EXCLUDED.embedded_text, \
               embedding = EXCLUDED.embedding",
        )
        .bind(&listing_id)
        .bind(&document_json)
        .bind(&content)
        .bind(&embedding_vec)
        .execute(conn)
        .await
        .map_err(|e| ToolError(format!("Vector DB error: {}", e)))?;

        Ok(())
    }
}

#[async_trait]
impl super::LlmProvider for MiniMaxProvider {
    fn name(&self) -> &str {
        "minimax"
    }

    async fn create_marketplace_agent(
        self: Arc<Self>,
        db_pool: &sqlx::PgPool,
        _event_tx: mpsc::Sender<BusinessEvent>,
        current_user_id: Option<String>,
        current_campus_id: Option<uuid::Uuid>,
    ) -> anyhow::Result<Box<dyn MarketplaceAgent>> {
        let (rag_store, embed_updater) = self.build_vector_store(db_pool);

        let ctx = ToolContext {
            db_pool: db_pool.clone(),
            embed_updater,
            current_user_id,
            current_campus_id,
            notification: crate::services::notification::NotificationService::new(db_pool.clone()),
        };

        let agent = self
            .chat_client
            .agent(&self.model)
            .preamble(PREAMBLE)
            .dynamic_context(3, rag_store)
            .tool(crate::agents::tools::CreateListingTool { ctx: ctx.clone() })
            .tool(crate::agents::tools::SearchInventoryTool { ctx: ctx.clone() })
            .tool(crate::agents::tools::GetListingDetailsTool { ctx: ctx.clone() })
            .tool(crate::agents::tools::UpdateListingTool { ctx: ctx.clone() })
            .tool(crate::agents::tools::DeleteListingTool { ctx: ctx.clone() })
            .tool(crate::agents::tools::PurchaseItemIntentTool { ctx: ctx.clone() })
            .tool(crate::agents::tools::NegotiateItemTool { ctx: ctx.clone() })
            .tool(crate::agents::tools::GetMyListingsTool { ctx: ctx.clone() })
            .build();

        Ok(Box::new(MiniMaxMarketplaceAgent(agent)))
    }

    fn embed_updater(
        self: Arc<Self>,
        db_pool: &PgPool,
    ) -> Arc<dyn crate::agents::tools::EmbedUpdater> {
        self.build_vector_store(db_pool).1
    }

    async fn create_negotiate_agent(self: Arc<Self>) -> anyhow::Result<Box<dyn NegotiateAgent>> {
        let agent = self
            .chat_client
            .agent(&self.model)
            .preamble(NEGOTIATION_PREAMBLE)
            .build();

        Ok(Box::new(MiniMaxNegotiateAgent(agent)))
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

    fn stream_chat(
        &self,
        msg: String,
        history: Vec<Message>,
    ) -> Pin<Box<dyn futures::Stream<Item = Result<String, anyhow::Error>> + Send>> {
        let h = history;
        let agent = self.0.clone();
        let circuit_breaker = LLM_CIRCUIT_BREAKER.clone();
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
                            yield text.text;
                            did_call_tool = false;
                            call_succeeded = true;
                        }
                        StreamedAssistantContent::ToolCall { tool_call, internal_call_id: _ } => {
                            let args_str = tool_call.function.arguments.to_string();
                            let result = agent
                                .tool_server_handle
                                .call_tool(&tool_call.function.name, &args_str)
                                .await
                                .map_err(|e| anyhow::anyhow!("tool error: {}", e))?;
                            tool_calls.push((tool_call.id.clone(), tool_call.call_id.clone(), result));
                            did_call_tool = true;
                            call_succeeded = true;
                        }
                        StreamedAssistantContent::Reasoning(reasoning) => {
                            let rendered = reasoning.display_text();
                            if !rendered.is_empty() {
                                yield rendered;
                            }
                            did_call_tool = false;
                            call_succeeded = true;
                        }
                        StreamedAssistantContent::ToolCallDelta { .. } => {}
                        StreamedAssistantContent::ReasoningDelta { .. } => {}
                        StreamedAssistantContent::Final(_) => {}
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

pub struct MiniMaxNegotiateAgent(
    Agent<openai::responses_api::ResponsesCompletionModel<reqwest::Client>>,
);

#[async_trait]
impl NegotiateAgent for MiniMaxNegotiateAgent {
    async fn prompt(&self, msg: String) -> anyhow::Result<String> {
        Ok(self.0.prompt(msg).await?)
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
