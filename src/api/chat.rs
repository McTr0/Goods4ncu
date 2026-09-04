//! AI-powered marketplace chat endpoints.
//!
//! POST /api/chat/stream    — SSE streaming (JSON body)
//! GET  /api/chat/assistant — history retrieval
//!
//! Intent routing runs before any LLM call so blocked content and greetings never
//! consume tokens.

use crate::api::error::ApiError;
use crate::api::session::Session;
use crate::api::{normalize_platform_media_url, AppState};
use crate::llm::MarketplaceAgent;
use crate::services::agent_chat;
use crate::services::chat::{ChatService, AGENT_CONVERSATION_SENTINEL};
use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::Json;
use serde::{Deserialize, Serialize};

// A dropped SSE body cannot await a database write from its `Drop` path. The
// sender below therefore stays alive for the generator's lifetime; if the
// client disconnects and drops the generator, a bounded grace period later
// the reconciliation task closes a still-started run as cancelled. Normal
// completion explicitly signals the task and avoids an unnecessary wake-up.

/// RAII guard ensuring the spawned agent runtime task is aborted if the SSE stream drops.
struct AbortOnDrop(tokio::task::JoinHandle<()>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

#[derive(Clone, Deserialize)]
pub(crate) struct ChatStreamRequest {
    pub message: String,
    pub listing_id: Option<String>,
    pub page_context: Option<serde_json::Value>,
    pub conversation_id: Option<String>,
    pub image_url: Option<String>,
    pub audio_url: Option<String>,
}

#[derive(Deserialize)]
pub(crate) struct AssistantHistoryQuery {
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

#[derive(Serialize)]
pub(crate) struct AssistantHistoryResponse {
    pub conversation_id: &'static str,
    pub messages: Vec<crate::services::chat::AssistantMessageEntry>,
    pub total: i64,
}

pub(crate) async fn get_assistant_history(
    State(state): State<AppState>,
    Session(session): Session,
    Query(query): Query<AssistantHistoryQuery>,
) -> Result<Json<AssistantHistoryResponse>, ApiError> {
    let user_id = session.user_id.clone();
    let limit = query.limit.unwrap_or(50).clamp(1, 100);
    let offset = query.offset.unwrap_or(0).max(0);
    let service = ChatService::new(state.infra.db.clone());
    let (mut messages, total) = service
        .get_assistant_messages(&user_id, limit, offset)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!(error)))?;
    for message in &mut messages {
        message.image_url = state.public_chat_media_url(message.image_url.take());
        message.audio_url = state.public_chat_media_url(message.audio_url.take());
    }

    Ok(Json(AssistantHistoryResponse {
        conversation_id: AGENT_CONVERSATION_SENTINEL,
        messages,
        total,
    }))
}

/// DELETE /api/chat/assistant — clear the caller's assistant chat history.
pub(crate) async fn clear_assistant_history(
    State(state): State<AppState>,
    Session(session): Session,
) -> Result<Json<serde_json::Value>, ApiError> {
    let service = ChatService::new(state.infra.db.clone());
    let removed = service
        .clear_assistant_messages(&session.user_id)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!(error)))?;
    Ok(Json(serde_json::json!({ "cleared": removed })))
}

/// SSE streaming chat — shared logic for GET and POST paths.
async fn handle_chat_stream_request(
    State(state): State<AppState>,
    Session(session): Session,
    headers: HeaderMap,
    payload: ChatStreamRequest,
) -> Result<impl axum::response::IntoResponse, ApiError> {
    if !state.agents.agent_enabled {
        return Err(ApiError::ServiceUnavailable(
            "AI assistant is disabled on this server.",
        ));
    }
    let ChatStreamRequest {
        message,
        listing_id,
        page_context,
        conversation_id,
        image_url,
        audio_url,
    } = payload;

    fn build_sse_response(
        conversation_id: &str,
        body: axum::body::Body,
    ) -> Result<Response, ApiError> {
        Response::builder()
            .header("Content-Type", "text/event-stream")
            .header("Cache-Control", "no-cache")
            .header("Connection", "keep-alive")
            .header("X-Conversation-Id", conversation_id)
            .body(body)
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("failed to build SSE response: {}", e)))
    }

    fn encode_sse_data(payload: &serde_json::Value) -> Vec<u8> {
        match serde_json::to_string(payload) {
            Ok(json) => format!("data: {}\n\n", json).into_bytes(),
            Err(err) => {
                tracing::error!(%err, "failed to serialize SSE payload");
                b"data: {\"error\":\"internal serialization error\"}\n\n".to_vec()
            }
        }
    }

    if message.len() > 2000 {
        return Err(ApiError::BadRequest(
            "Text message exceeds maximum length of 2000 characters.".to_string(),
        ));
    }
    let moderation = state.infra.moderation.check_text(&message);
    if !moderation.passed {
        return Err(ApiError::ContentViolation(
            moderation.reason.unwrap_or_default(),
        ));
    }

    let normalized_image_url = normalize_platform_media_url(&state, image_url, "image_url")?;
    let normalized_audio_url = normalize_platform_media_url(&state, audio_url, "audio_url")?;
    let proposal_idempotency_key =
        crate::api::request_context::idempotency_key_from_headers(&headers)?;

    let session_campus_id = session.campus_id;
    let current_user_id = session.user_id;
    let (conversation_id, response_conversation_id, is_assistant_conversation) =
        agent_chat::resolve_conversation_id(conversation_id, &current_user_id);
    let chat_svc = ChatService::new(state.infra.db.clone());
    let (resolved_listing_id, receiver) = agent_chat::resolve_listing_context(
        &state.infra.db,
        listing_id.as_deref(),
        &current_user_id,
        session_campus_id,
    )
    .await?;

    let intent_result = state
        .agents
        .tri_tier_router
        .classify(&message, session_campus_id)
        .await;
    tracing::debug!(
        intent = ?intent_result.intent.as_str(),
        confidence = %intent_result.confidence,
        tier = %intent_result.matched_tier,
        "SSE Router classification"
    );

    if let Some(reply) = intent_result.direct_response(&message) {
        let run = agent_chat::begin_agent_run(
            &state.infra.db,
            crate::api::request_context::current_or_new_request_id(),
            session_campus_id,
            &current_user_id,
            &conversation_id,
            intent_result.intent.as_str(),
            intent_result.confidence,
            None,
            None,
        )
        .await;
        if is_assistant_conversation {
            chat_svc
                .log_message(
                    &conversation_id,
                    "global",
                    &current_user_id,
                    None,
                    false,
                    &message,
                    normalized_image_url.as_deref(),
                    normalized_audio_url.as_deref(),
                )
                .await
                .map_err(|error| ApiError::Internal(anyhow::anyhow!(error)))?;
            chat_svc
                .log_message(
                    &conversation_id,
                    "global",
                    &current_user_id,
                    None,
                    true,
                    &reply,
                    None,
                    None,
                )
                .await
                .map_err(|error| ApiError::Internal(anyhow::anyhow!(error)))?;
        }
        if let Some(run) = &run {
            agent_chat::finish_agent_run(run, "completed", "direct_response", None).await;
        }
        let turn_id = crate::agents::runtime::event::TurnId::generate();
        let ev_start = crate::agents::runtime::event::AgentEvent::new(
            turn_id,
            &response_conversation_id,
            1,
            crate::agents::runtime::event::EventData::TurnStarted {
                category: "direct".to_string(),
                route: "direct_reply".to_string(),
            },
        );
        let ev_text = crate::agents::runtime::event::AgentEvent::new(
            turn_id,
            &response_conversation_id,
            2,
            crate::agents::runtime::event::EventData::TextDelta { text: reply },
        );
        let ev_end = crate::agents::runtime::event::AgentEvent::new(
            turn_id,
            &response_conversation_id,
            3,
            crate::agents::runtime::event::EventData::TurnCompleted {
                usage: crate::agents::runtime::event::UsageSummary {
                    model_steps: 0,
                    tool_calls: 0,
                    prompt_tokens: None,
                    completion_tokens: None,
                },
            },
        );
        let mut sse_frames = Vec::new();
        sse_frames.extend_from_slice(&encode_sse_data(
            &serde_json::to_value(&ev_start).unwrap_or_default(),
        ));
        sse_frames.extend_from_slice(&encode_sse_data(
            &serde_json::to_value(&ev_text).unwrap_or_default(),
        ));
        sse_frames.extend_from_slice(&encode_sse_data(
            &serde_json::to_value(&ev_end).unwrap_or_default(),
        ));
        let body = axum::body::Body::from(sse_frames);
        return build_sse_response(&response_conversation_id, body);
    }

    let history = chat_svc
        .get_conversation_history(&conversation_id)
        .await
        .unwrap_or_default();
    let chat_history = agent_chat::history_to_rig_messages(&history);

    // Persist user turn before streaming — aborted streams must not lose the message.
    let persisted = agent_chat::persist_context_message(
        &chat_svc,
        &conversation_id,
        &resolved_listing_id,
        &current_user_id,
        receiver.as_deref(),
        false,
        &message,
        normalized_image_url.as_deref(),
        normalized_audio_url.as_deref(),
        session_campus_id,
    )
    .await
    .map_err(|e| {
        tracing::error!(%e, "Failed to persist user message for SSE stream");
        ApiError::Internal(anyhow::anyhow!("Failed to persist user message"))
    })?;
    if !persisted {
        return Err(ApiError::NotFound);
    }

    let memory_context = if let Some(campus_id) = session_campus_id {
        let memory_svc =
            crate::services::agent_memory::AgentMemoryService::new(state.infra.db.clone());
        let embedder = state.agents.llm_provider.clone().embedding_generator();
        memory_svc
            .format_memory_context(
                &current_user_id,
                campus_id,
                &message,
                page_context.as_ref(),
                Some(&embedder),
            )
            .await
            .unwrap_or_default()
    } else {
        String::new()
    };

    let prompt_msg = if memory_context.is_empty() {
        message.clone()
    } else {
        format!("{}\n\n{}", message, memory_context)
    };

    let provider_name = state.agents.llm_provider.name().to_string();
    let provider_model = state.agents.llm_provider.model().to_string();
    let run = agent_chat::begin_agent_run(
        &state.infra.db,
        crate::api::request_context::current_or_new_request_id(),
        session_campus_id,
        &current_user_id,
        &conversation_id,
        intent_result.intent.as_str(),
        intent_result.confidence,
        Some(&provider_name),
        Some(&provider_model),
    )
    .await;

    let agent: Box<dyn MarketplaceAgent> = match std::sync::Arc::clone(&state.agents.llm_provider)
        .create_marketplace_agent(
            &state.infra.db,
            Some(current_user_id.clone()),
            session.campus_id,
            proposal_idempotency_key,
            state.infra.moderation.clone(),
        )
        .await
    {
        Ok(agent) => agent,
        Err(error) => {
            if let Some(run) = &run {
                agent_chat::finish_agent_run(
                    run,
                    "failed",
                    "provider_unavailable",
                    Some("provider_unavailable"),
                )
                .await;
            }
            return Err(ApiError::Internal(anyhow::anyhow!(error)));
        }
    };

    use crate::agents::runtime::api_drivers::{ApiStyle, ChatCompletionsDriver, ResponsesDriver};
    use crate::agents::runtime::driver::MarketplaceDriver;
    use crate::agents::runtime::engine::{AgentRuntime, RuntimeContext, ToolExecutor, TurnEvent};
    use crate::agents::runtime::event::{EventData, TurnId};
    use crate::agents::runtime::hooks::{CategoryTagPolicy, HookChain, MetricsHook};
    use crate::agents::runtime::model::{ModelDriver, ModelRequest};

    let agent: std::sync::Arc<dyn MarketplaceAgent> = agent.into();
    let driver: std::sync::Arc<dyn ModelDriver> = match state.agents.llm_provider.api_style() {
        Some(ApiStyle::Responses) => std::sync::Arc::new(ResponsesDriver {
            agent: std::sync::Arc::clone(&agent),
            provider_name: provider_name.clone(),
            model_name: provider_model.clone(),
        }),
        Some(ApiStyle::ChatCompletions) => std::sync::Arc::new(ChatCompletionsDriver {
            agent: std::sync::Arc::clone(&agent),
            provider_name: provider_name.clone(),
            model_name: provider_model.clone(),
        }),
        Some(ApiStyle::Auto) | None => std::sync::Arc::new(MarketplaceDriver::new(
            std::sync::Arc::clone(&agent),
            provider_name.clone(),
            provider_model.clone(),
        )),
    };
    let executor_agent = std::sync::Arc::clone(&agent);
    let execute_tool: ToolExecutor = std::sync::Arc::new(move |name, arguments| {
        let agent = std::sync::Arc::clone(&executor_agent);
        let name = name.to_string();
        let arguments = arguments.to_string();
        Box::pin(async move { agent.execute_tool(&name, &arguments).await })
    });
    let registry_key =
        crate::agents::runtime::turn_registry_key(&current_user_id, &response_conversation_id);
    let registration = crate::agents::runtime::TurnRegistration::register(registry_key);
    let cancellation = registration.cancellation();
    let policy_category = page_context
        .as_ref()
        .and_then(|context| context.get("category"))
        .and_then(|value| value.as_str())
        .unwrap_or_else(|| intent_result.intent.as_str())
        .to_string();
    let runtime_context = RuntimeContext {
        cancellation: cancellation.clone(),
        registry: std::sync::Arc::new(crate::agents::tools::registry::ToolRegistry::marketplace()),
        hooks: std::sync::Arc::new(
            HookChain::builder()
                .push_hook(Box::new(CategoryTagPolicy))
                .push_hook(Box::new(MetricsHook))
                .build(),
        ),
        category: policy_category,
        route: intent_result.intent.as_str().to_string(),
        user_id: current_user_id.clone(),
    };
    state.infra.metrics.record_chat_message();
    state.infra.metrics.record_llm_call();
    let request = ModelRequest::user(prompt_msg, chat_history);
    let turn_id = TurnId::generate();
    let runtime_conversation_id = response_conversation_id.clone();
    let (event_tx, mut event_rx) = tokio::sync::mpsc::channel(128);
    let run_cancellation = cancellation.clone();
    let runtime_handle = tokio::spawn(async move {
        AgentRuntime::new(crate::agents::runtime::budget::ExecutionBudget::default())
            .run_turn(
                driver.as_ref(),
                request,
                execute_tool,
                turn_id,
                &runtime_conversation_id,
                runtime_context,
                &mut |event| match event_tx.try_send(event) {
                    Ok(_) => {}
                    Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {
                        tracing::warn!(
                            %turn_id,
                            "SSE event buffer full (128); dropping event to preserve bounded memory"
                        );
                    }
                    Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => {
                        run_cancellation.cancel();
                    }
                },
            )
            .await;
    });

    let log_page = page_context
        .as_ref()
        .and_then(|ctx| ctx.get("page"))
        .and_then(|value| value.as_str())
        .unwrap_or("chat")
        .to_string();
    let log_route = intent_result.intent.as_str().to_string();
    let log_request_id = crate::api::request_context::current_or_new_request_id();
    let run_for_stream = run.clone();
    let reconciliation_tx = run.clone().map(agent_chat::schedule_reconciliation);
    let persisted_conversation_id = conversation_id.clone();
    let public_conversation_id = response_conversation_id.clone();
    let persisted_listing_id = resolved_listing_id.clone();
    let persisted_user_id = current_user_id.clone();
    let persisted_campus_id = session_campus_id;
    let persist_service = chat_svc.clone();
    let metrics_for_stream = std::sync::Arc::clone(&state.infra.metrics);

    const HEARTBEAT_INTERVAL: std::time::Duration = std::time::Duration::from_secs(10);
    let sse_stream = async_stream::stream! {
        let _registration = registration;
        let _runtime_guard = AbortOnDrop(runtime_handle);
        let mut full_reply = String::new();
        let mut completed = false;
        let mut cancelled = false;
        let mut prompt_tokens = None;
        let mut completion_tokens = None;
        let mut tool_calls = 0_u32;
        let mut ttft_recorded = false;
        let mut first_token_ms = None;
        let stream_started_at = std::time::Instant::now();
        let mut transport_seq = 0_u64;
        let mut heartbeat_ticker = tokio::time::interval(HEARTBEAT_INTERVAL);
        heartbeat_ticker.tick().await;

        loop {
            let turn_event = tokio::select! {
                event = event_rx.recv() => match event {
                    Some(event) => event,
                    None => break,
                },
                _ = heartbeat_ticker.tick() => {
                    transport_seq += 1;
                    let heartbeat = crate::agents::runtime::event::AgentEvent::new(
                        turn_id,
                        &public_conversation_id,
                        transport_seq,
                        EventData::Heartbeat,
                    );
                    yield Ok::<_, std::convert::Infallible>(encode_sse_data(
                        &serde_json::to_value(heartbeat).unwrap_or_default(),
                    ));
                    continue;
                }
            };

            let TurnEvent::Emit(mut event) = turn_event else {
                if let TurnEvent::ToolResult {
                    tool_name,
                    resource_ids,
                    ..
                } = turn_event
                {
                    if let Some(run) = &run_for_stream {
                        if !resource_ids.is_empty() {
                            let count = resource_ids.len() as i32;
                            if let Err(error) = run
                                .service
                                .record_retrieval(
                                    &run.trace_id,
                                    run.campus_id,
                                    &run.user_id,
                                    &tool_name,
                                    count,
                                    None,
                                    resource_ids,
                                )
                                .await
                            {
                                tracing::warn!(
                                    %error,
                                    trace_id = %run.trace_id,
                                    tool = %tool_name,
                                    "failed to record retrieval resource ids"
                                );
                            }
                        }
                        if let Err(error) = run
                            .service
                            .record_tool(
                                &run.trace_id,
                                run.campus_id,
                                &run.user_id,
                                &tool_name,
                                None,
                                "completed",
                            )
                            .await
                        {
                            tracing::warn!(
                                %error,
                                trace_id = %run.trace_id,
                                tool = %tool_name,
                                "failed to record Runtime v2 tool event"
                            );
                        }
                    }
                }
                continue;
            };
            transport_seq += 1;
            event.seq = transport_seq;
            match &event.data {
                EventData::TextDelta { text } => {
                    if !ttft_recorded {
                        if let Some(run) = &run_for_stream {
                            let ttft_ms = run.started_at.elapsed().as_millis().min(i32::MAX as u128) as i32;
                            first_token_ms = Some(ttft_ms);
                            if let Err(error) = run
                                .service
                                .record_ttft(
                                    &run.trace_id,
                                    run.campus_id,
                                    &run.user_id,
                                    ttft_ms,
                                )
                                .await
                            {
                                tracing::debug!(%error, trace_id = %run.trace_id, "failed to record AgentRun TTFT");
                            }
                        }
                        ttft_recorded = true;
                    }
                    full_reply.push_str(text);
                }
                EventData::ToolStarted { .. } => tool_calls += 1,
                EventData::TurnCompleted { usage } => {
                    completed = true;
                    prompt_tokens = usage.prompt_tokens;
                    completion_tokens = usage.completion_tokens;
                }
                EventData::TurnCancelled { .. } => cancelled = true,
                _ => {}
            }
            let is_terminal = event.is_terminal();
            let json = serde_json::to_value(&event).unwrap_or_default();
            yield Ok::<_, std::convert::Infallible>(encode_sse_data(&json));
            if is_terminal {
                break;
            }
        }

        if completed && !full_reply.trim().is_empty() {
            if let Err(error) = agent_chat::persist_context_message(
                &persist_service,
                &persisted_conversation_id,
                &persisted_listing_id,
                &persisted_user_id,
                None,
                true,
                &full_reply,
                None,
                None,
                persisted_campus_id,
            )
            .await
            {
                tracing::warn!(%error, "failed to persist streamed assistant reply");
            }
        }

        let finished = if let Some(run) = &run_for_stream {
            if completed {
                agent_chat::finish_agent_run_with_usage(
                    run,
                    "completed",
                    "runtime_completed",
                    None,
                    prompt_tokens,
                    completion_tokens,
                )
                .await
            } else if cancelled {
                agent_chat::finish_agent_run(run, "cancelled", "user_cancelled", Some("cancelled")).await
            } else {
                metrics_for_stream.record_llm_error();
                agent_chat::finish_agent_run(run, "failed", "runtime_failed", Some("runtime_error")).await
            }
        } else {
            true
        };
        tracing::info!(
            request_id = %log_request_id,
            user_id = %persisted_user_id,
            conversation_id = %public_conversation_id,
            page = %log_page,
            route = %log_route,
            provider = %provider_name,
            model = %provider_model,
            tool_calls,
            ttft_ms = first_token_ms.unwrap_or(0),
            total_ms = stream_started_at.elapsed().as_millis() as u64,
            completed,
            cancelled,
            "agent runtime stream finished"
        );
        if finished {
            if let Some(done_tx) = reconciliation_tx {
                let _ = done_tx.send(());
            }
        }
    };

    let body = axum::body::Body::from_stream(sse_stream);
    build_sse_response(&response_conversation_id, body)
}

/// POST /api/agent/turns/:conversation_id/cancel — cancel an in-flight turn.
pub(crate) async fn cancel_turn(
    Session(session): Session,
    Path(conversation_id): Path<String>,
) -> Json<serde_json::Value> {
    let registry_key =
        crate::agents::runtime::turn_registry_key(&session.user_id, &conversation_id);
    let cancelled = crate::agents::runtime::TurnRegistry::cancel(&registry_key);
    Json(serde_json::json!({ "cancelled": cancelled }))
}

/// POST /api/chat/stream — preferred SSE path for authenticated JSON payloads.
pub(crate) async fn handle_chat_stream_post(
    state: State<AppState>,
    session: Session,
    headers: HeaderMap,
    Json(payload): Json<ChatStreamRequest>,
) -> Result<impl axum::response::IntoResponse, ApiError> {
    handle_chat_stream_request(state, session, headers, payload).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_chat_stream_request_deserialization() {
        let json = r#"{"message": "Hello!", "conversation_id": "conv-1", "listing_id": "listing-123", "image_url": "https://oss.example.com/img.jpg"}"#;
        let req: ChatStreamRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.message, "Hello!");
        assert_eq!(req.conversation_id, Some("conv-1".to_string()));
        assert_eq!(req.listing_id, Some("listing-123".to_string()));
        assert_eq!(
            req.image_url,
            Some("https://oss.example.com/img.jpg".to_string())
        );
        assert_eq!(req.audio_url, None);
    }

    #[test]
    fn test_chat_stream_request_minimal() {
        let json = r#"{"message": "Hello!"}"#;
        let req: ChatStreamRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.message, "Hello!");
        assert_eq!(req.conversation_id, None);
        assert_eq!(req.listing_id, None);
        assert_eq!(req.image_url, None);
        assert_eq!(req.audio_url, None);
    }

    #[test]
    fn assistant_sentinel_maps_to_user_scoped_conversation() {
        let (internal, public, is_assistant) = agent_chat::resolve_conversation_id(
            Some(AGENT_CONVERSATION_SENTINEL.to_string()),
            "user-1",
        );
        assert_eq!(internal, "agent:user-1");
        assert_eq!(public, AGENT_CONVERSATION_SENTINEL);
        assert!(is_assistant);
    }

    #[test]
    fn assistant_conversations_are_isolated_between_users() {
        let (first, _, _) = agent_chat::resolve_conversation_id(
            Some(AGENT_CONVERSATION_SENTINEL.to_string()),
            "user-1",
        );
        let (second, _, _) = agent_chat::resolve_conversation_id(
            Some(AGENT_CONVERSATION_SENTINEL.to_string()),
            "user-2",
        );
        assert_ne!(first, second);
    }

    #[test]
    fn regular_conversation_id_is_preserved() {
        let (internal, public, is_assistant) =
            agent_chat::resolve_conversation_id(Some("conv-123".to_string()), "user-1");
        assert_eq!(internal, "conv-123");
        assert_eq!(public, "conv-123");
        assert!(!is_assistant);
    }
}
