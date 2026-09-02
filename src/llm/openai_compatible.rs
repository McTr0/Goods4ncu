use super::{
    AgentModelChunk, AgentStreamChunk, AgentTokenUsage, CircuitBreaker, EmbeddingGenerator,
    EmbeddingModelMetadata, MarketplaceAgent, ReplyAssistant, LLM_CIRCUIT_BREAKER,
    REPLY_ASSISTANT_PREAMBLE,
};
use crate::agents::models::Document;
use crate::agents::runtime::api_drivers::ApiStyle;
use crate::agents::tools::ToolContext;
use crate::services::BusinessEvent;
use async_trait::async_trait;
use futures::StreamExt;
use rig::agent::Agent;
use rig::client::CompletionClient;
use rig::completion::{CompletionModel, GetTokenUsage, Message, Prompt};
use rig::embeddings::EmbeddingsBuilder;
use rig::providers::gemini;
use rig::providers::openai;
use rig::streaming::{StreamedAssistantContent, StreamingCompletion};
use sqlx::PgPool;
use std::pin::Pin;
use std::sync::Arc;
use tokio::sync::mpsc;

fn stream_single_model_step<M>(
    agent: Agent<M>,
    message: Message,
    history: Vec<Message>,
) -> Pin<Box<dyn futures::Stream<Item = Result<AgentModelChunk, anyhow::Error>> + Send>>
where
    M: CompletionModel + Clone + Send + Sync + 'static,
    M::StreamingResponse: Clone + Unpin + Send + GetTokenUsage + 'static,
{
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
                // Reasoning is provider-internal metadata. Never expose or
                // persist it as assistant-visible text.
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

async fn execute_registered_tool<M: CompletionModel>(
    agent: &Agent<M>,
    name: &str,
    arguments: &str,
) -> anyhow::Result<String> {
    let result = agent
        .tool_server_handle
        .call_tool(name, arguments)
        .await
        .map_err(|error| anyhow::anyhow!("tool error: {error}"))?;
    Ok(serde_json::from_str::<String>(&result).unwrap_or(result))
}

/// Generic OpenAI Chat Completions compatible provider.
///
/// This covers providers such as OpenAI, DeepSeek, Groq, OpenRouter, xAI,
/// Together, and local gateways that expose `/v1/chat/completions`.
/// Embeddings still use Gemini so the existing pgvector dimension and RAG
/// pipeline remain stable while chat providers can vary independently.
pub struct OpenAiCompatibleProvider {
    provider_name: String,
    api_client: OpenAiApiClient,
    api_style: ApiStyle,
    embedding_client: gemini::Client,
    model: String,
    embedding_dim: usize,
}

enum OpenAiApiClient {
    ChatCompletions(openai::CompletionsClient<reqwest::Client>),
    Responses(openai::Client<reqwest::Client>),
}

impl OpenAiCompatibleProvider {
    pub fn new(
        provider_name: impl Into<String>,
        api_key: &str,
        base_url: Option<&str>,
        model: impl Into<String>,
        gemini_api_key: &str,
        embedding_dim: usize,
        api_style: ApiStyle,
    ) -> anyhow::Result<Self> {
        let api_client = match api_style {
            ApiStyle::Auto => {
                return Err(anyhow::anyhow!(
                    "OpenAiCompatibleProvider requires a resolved API style"
                ));
            }
            ApiStyle::ChatCompletions => {
                let mut builder = openai::CompletionsClient::builder()
                    .api_key(api_key)
                    .http_client(crate::llm::llm_http_client()?);
                if let Some(base_url) = base_url {
                    builder = builder.base_url(base_url);
                }
                OpenAiApiClient::ChatCompletions(builder.build()?)
            }
            ApiStyle::Responses => {
                let mut builder = openai::Client::builder()
                    .api_key(api_key)
                    .http_client(crate::llm::llm_http_client()?);
                if let Some(base_url) = base_url {
                    builder = builder.base_url(base_url);
                }
                OpenAiApiClient::Responses(builder.build()?)
            }
        };

        let embedding_client = gemini::Client::builder()
            .api_key(gemini_api_key)
            .http_client(crate::llm::llm_http_client()?)
            .build()?;

        Ok(Self {
            provider_name: provider_name.into(),
            api_client,
            api_style,
            embedding_client,
            model: model.into(),
            embedding_dim,
        })
    }

    pub fn build_embedding_generator(&self) -> Arc<dyn EmbeddingGenerator> {
        Arc::new(OpenAiCompatibleEmbeddingGenerator {
            embedding_client: self.embedding_client.clone(),
            embedding_dim: self.embedding_dim,
        })
    }
}

struct OpenAiCompatibleEmbeddingGenerator {
    embedding_client: gemini::Client,
    embedding_dim: usize,
}

#[async_trait]
impl EmbeddingGenerator for OpenAiCompatibleEmbeddingGenerator {
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
impl super::LlmProvider for OpenAiCompatibleProvider {
    fn name(&self) -> &str {
        &self.provider_name
    }

    fn model(&self) -> &str {
        &self.model
    }

    fn api_style(&self) -> Option<ApiStyle> {
        Some(self.api_style)
    }

    async fn create_marketplace_agent(
        self: Arc<Self>,
        db_pool: &PgPool,
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

        macro_rules! build_agent {
            ($client:expr, $wrapper:ident) => {{
                let agent = $client
                    .agent(&self.model)
                    .preamble(crate::llm::system_preamble())
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
                Box::new($wrapper(agent)) as Box<dyn MarketplaceAgent>
            }};
        }

        Ok(match &self.api_client {
            OpenAiApiClient::ChatCompletions(client) => {
                build_agent!(client, OpenAiCompatibleMarketplaceAgent)
            }
            OpenAiApiClient::Responses(client) => {
                build_agent!(client, OpenAiResponsesMarketplaceAgent)
            }
        })
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
        Ok(match &self.api_client {
            OpenAiApiClient::ChatCompletions(client) => Box::new(OpenAiCompatibleReplyAssistant(
                client
                    .agent(&self.model)
                    .preamble(REPLY_ASSISTANT_PREAMBLE)
                    .build(),
            )) as Box<dyn ReplyAssistant>,
            OpenAiApiClient::Responses(client) => Box::new(OpenAiResponsesReplyAssistant(
                client
                    .agent(&self.model)
                    .preamble(REPLY_ASSISTANT_PREAMBLE)
                    .build(),
            )),
        })
    }
}

pub struct OpenAiCompatibleMarketplaceAgent(
    Agent<openai::completion::CompletionModel<reqwest::Client>>,
);

#[async_trait]
impl MarketplaceAgent for OpenAiCompatibleMarketplaceAgent {
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
                                "draft_comment" => {
                                    // Parse DRAFT_COMMENT|post_id|text
                                    let parts: Vec<&str> = result.splitn(3, '|').collect();
                                    if parts.len() == 3 && parts[0] == "DRAFT_COMMENT" {
                                        yield AgentStreamChunk::UiAction(
                                            crate::llm::UiAction::open_comment_draft(
                                                parts[1], parts[2],
                                            ),
                                        );
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
                            tool_calls.push((tool_call.clone(), result));
                            call_succeeded = true;
                        }
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

            if call_succeeded {
                circuit_breaker.record_success().await;
            }
        })
    }

    fn stream_model_step(
        &self,
        message: Message,
        history: Vec<Message>,
    ) -> Pin<Box<dyn futures::Stream<Item = Result<AgentModelChunk, anyhow::Error>> + Send>> {
        stream_single_model_step(self.0.clone(), message, history)
    }

    async fn execute_tool(&self, name: &str, arguments: &str) -> anyhow::Result<String> {
        execute_registered_tool(&self.0, name, arguments).await
    }
}

pub struct OpenAiResponsesMarketplaceAgent(
    Agent<openai::responses_api::ResponsesCompletionModel<reqwest::Client>>,
);

#[async_trait]
impl MarketplaceAgent for OpenAiResponsesMarketplaceAgent {
    async fn prompt(&self, msg: String) -> anyhow::Result<String> {
        if LLM_CIRCUIT_BREAKER.is_open().await {
            tracing::warn!("LLM circuit breaker: prompt rejected (circuit open)");
            return Err(anyhow::anyhow!(CircuitBreaker::degraded_message()));
        }
        match self.0.prompt(msg).await {
            Ok(reply) => {
                LLM_CIRCUIT_BREAKER.record_success().await;
                Ok(reply)
            }
            Err(error) => {
                LLM_CIRCUIT_BREAKER.record_failure().await;
                Err(anyhow::anyhow!(error))
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
        let mut history = history;
        match self
            .0
            .prompt(Message::user(msg))
            .with_history(&mut history)
            .await
        {
            Ok(reply) => {
                LLM_CIRCUIT_BREAKER.record_success().await;
                Ok(reply)
            }
            Err(error) => {
                LLM_CIRCUIT_BREAKER.record_failure().await;
                Err(anyhow::anyhow!(error))
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
        let mut history = history;
        match self
            .0
            .prompt(Message::user(msg))
            .with_history(&mut history)
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
        let agent = self.0.clone();
        Box::pin(async_stream::try_stream! {
            let mut current = Message::user(msg);
            let mut history = history;
            loop {
                let mut step = stream_single_model_step(agent.clone(), current.clone(), history.clone());
                history.push(current.clone());
                let mut calls = Vec::new();
                let mut emitted_text = false;
                while let Some(item) = step.next().await {
                    match item? {
                        AgentModelChunk::Text(text) => {
                            emitted_text = true;
                            yield AgentStreamChunk::Text(text);
                        }
                        AgentModelChunk::ToolCall { id, call_id, name, arguments } => {
                            yield AgentStreamChunk::ToolActivity { tool: name.clone() };
                            let result = execute_registered_tool(&agent, &name, &arguments.to_string()).await?;
                            calls.push((id, call_id, name, arguments, result));
                        }
                        AgentModelChunk::Usage(usage) => yield AgentStreamChunk::Usage(usage),
                        AgentModelChunk::Stop => {}
                    }
                }

                if calls.is_empty() {
                    if emitted_text {
                        break;
                    }
                    break;
                }
                let assistant_calls = calls
                    .iter()
                    .map(|(id, call_id, name, arguments, _)| {
                        rig::message::AssistantContent::ToolCall(rig::message::ToolCall {
                            id: id.clone(),
                            call_id: call_id.clone(),
                            function: rig::message::ToolFunction::new(
                                name.clone(),
                                arguments.clone(),
                            ),
                            signature: None,
                            additional_params: None,
                        })
                    })
                    .collect::<Vec<_>>();
                if let Ok(content) = rig::OneOrMany::many(assistant_calls) {
                    history.push(Message::Assistant { id: None, content });
                }
                for (id, call_id, name, _arguments, result) in calls {
                    for action in crate::agents::runtime::envelope::legacy::from_tool_result(&name, &result).ui_actions {
                        yield AgentStreamChunk::UiAction(action);
                    }
                    let fenced = crate::llm::wrap_untrusted_platform_data(&name, &result);
                    history.push(Message::tool_result_with_call_id(id, call_id, fenced));
                }
                current = history.pop().expect("tool result was just appended");
            }
        })
    }

    fn stream_model_step(
        &self,
        message: Message,
        history: Vec<Message>,
    ) -> Pin<Box<dyn futures::Stream<Item = Result<AgentModelChunk, anyhow::Error>> + Send>> {
        stream_single_model_step(self.0.clone(), message, history)
    }

    async fn execute_tool(&self, name: &str, arguments: &str) -> anyhow::Result<String> {
        execute_registered_tool(&self.0, name, arguments).await
    }
}

pub struct OpenAiCompatibleReplyAssistant(
    Agent<openai::completion::CompletionModel<reqwest::Client>>,
);

#[async_trait]
impl ReplyAssistant for OpenAiCompatibleReplyAssistant {
    async fn prompt(&self, msg: String) -> anyhow::Result<String> {
        Ok(self.0.prompt(msg).await?)
    }
}

pub struct OpenAiResponsesReplyAssistant(
    Agent<openai::responses_api::ResponsesCompletionModel<reqwest::Client>>,
);

#[async_trait]
impl ReplyAssistant for OpenAiResponsesReplyAssistant {
    async fn prompt(&self, msg: String) -> anyhow::Result<String> {
        Ok(self.0.prompt(msg).await?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn api_style_selects_distinct_rig_clients() {
        let chat = OpenAiCompatibleProvider::new(
            "openai",
            "test-key",
            Some("http://127.0.0.1:9/v1"),
            "test-model",
            "test-gemini-key",
            768,
            ApiStyle::ChatCompletions,
        )
        .unwrap();
        assert!(matches!(
            chat.api_client,
            OpenAiApiClient::ChatCompletions(_)
        ));

        let responses = OpenAiCompatibleProvider::new(
            "openai",
            "test-key",
            Some("http://127.0.0.1:9/v1"),
            "test-model",
            "test-gemini-key",
            768,
            ApiStyle::Responses,
        )
        .unwrap();
        assert!(matches!(
            responses.api_client,
            OpenAiApiClient::Responses(_)
        ));
    }

    #[test]
    fn unresolved_auto_style_is_rejected() {
        let error = OpenAiCompatibleProvider::new(
            "openai",
            "test-key",
            None,
            "test-model",
            "test-gemini-key",
            768,
            ApiStyle::Auto,
        )
        .err()
        .expect("auto must be resolved by config");
        assert!(error.to_string().contains("resolved API style"));
    }
}
