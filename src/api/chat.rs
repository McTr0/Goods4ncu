//! AI-powered marketplace chat endpoints.
//!
//! POST /api/chat        — single-turn JSON request/response
//! GET  /api/chat/stream — SSE streaming (query-string, text-only compat)
//! POST /api/chat/stream — SSE streaming (JSON body, preferred)
//!
//! Both paths persist the user turn first, then invoke the LLM, then persist
//! the assistant reply. Intent routing runs before any LLM call so blocked
//! content and greetings never consume tokens.

use crate::api::auth;
use crate::api::error::ApiError;
use crate::api::session::Session;
use crate::api::{normalize_platform_media_url, AppState, PeerAddr};
use crate::llm::{AgentStreamChunk, MarketplaceAgent};
use crate::services::agent_chat;
use crate::services::chat::{ChatService, AGENT_CONVERSATION_SENTINEL};
use axum::extract::{Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::Json;
use futures::StreamExt;
use serde::{Deserialize, Serialize};

/// A dropped SSE body cannot await a database write from its `Drop` path.  The
/// sender below therefore stays alive for the generator's lifetime; if the
/// client disconnects and drops the generator, a bounded grace period later
/// the reconciliation task closes a still-started run as cancelled.  Normal
/// completion explicitly signals the task and avoids an unnecessary wake-up.

#[derive(Deserialize)]
pub(crate) struct ChatRequest {
    pub message: String,
    pub image: Option<String>,
    pub audio: Option<String>,
    pub image_url: Option<String>,
    pub audio_url: Option<String>,
    pub conversation_id: Option<String>,
    /// When provided, anchors the conversation to a specific listing. The
    /// listing owner is stored as receiver so they see the inquiry immediately.
    pub listing_id: Option<String>,
    /// Current page context (e.g. {"page": "post_detail", "postId": "..."}).
    pub page_context: Option<serde_json::Value>,
}

#[derive(Serialize)]
pub(crate) struct ChatResponse {
    pub reply: String,
    pub conversation_id: String,
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

/// Resolve listing context for a chat request.
///
/// Returns `(resolved_listing_id, receiver)`. When `listing_id` points to an
/// active listing owned by someone other than the caller, both values are
/// returned verbatim. Otherwise both fall back to `"global"` / `None`.
pub(crate) async fn handle_chat(
    State(state): State<AppState>,
    PeerAddr(addr): PeerAddr,
    headers: HeaderMap,
    Session(session): Session,
    Json(payload): Json<ChatRequest>,
) -> Result<Json<ChatResponse>, ApiError> {
    if !state.agents.agent_enabled {
        return Err(ApiError::ServiceUnavailable(
            "AI assistant is disabled on this server.",
        ));
    }
    let ChatRequest {
        message,
        image,
        audio,
        image_url,
        audio_url,
        conversation_id,
        listing_id,
        page_context,
    } = payload;

    // 10 MB network limit enforced by RequestBodyLimitLayer; text beyond 2000
    // chars is almost certainly abuse.
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

    // Direct TCP peer address as rate-limit key — cannot be spoofed.
    // X-Forwarded-For is read for logging only, never as a rate-limit token.
    if let Some(proxy_ip) = headers
        .get("x-forwarded-for")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.split(',').next())
        .map(|s| s.trim())
    {
        tracing::debug!(client_ip = %proxy_ip, peer = %addr, "Chat request");
    }

    let session_campus_id = session.campus_id;
    let current_user_id = session.user_id;
    let (conversation_id, response_conversation_id, is_assistant_conversation) =
        agent_chat::resolve_conversation_id(conversation_id, &current_user_id);
    let chat_svc = ChatService::new(state.infra.db.clone());
    // Validate an explicit listing before greeting/blocked-intent shortcuts so
    // those fast paths cannot turn an ineligible id into a successful request.
    let (resolved_listing_id, receiver) = agent_chat::resolve_listing_context(
        &state.infra.db,
        listing_id.as_deref(),
        &current_user_id,
        session_campus_id,
    )
    .await?;

    // Tri-tier intent classification — blocked content and greetings short-circuit here.
    let intent_result = state
        .agents
        .tri_tier_router
        .classify(&message, session_campus_id)
        .await;
    tracing::debug!(
        intent = ?intent_result.intent.as_str(),
        confidence = %intent_result.confidence,
        tier = %intent_result.matched_tier,
        "Router classification"
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
                    image.as_deref(),
                    audio.as_deref(),
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
                    None,
                    None,
                )
                .await
                .map_err(|error| ApiError::Internal(anyhow::anyhow!(error)))?;
        }
        if let Some(run) = run {
            agent_chat::finish_agent_run(&run, "completed", "direct_response", None).await;
        }
        return Ok(Json(ChatResponse {
            reply,
            conversation_id: response_conversation_id,
        }));
    }

    let history = chat_svc
        .get_conversation_history(&conversation_id)
        .await
        .unwrap_or_default();
    let chat_history = agent_chat::history_to_rig_messages(&history);

    // Persist before LLM execution to avoid message loss on timeout or abort.
    let persisted = agent_chat::persist_context_message(
        &chat_svc,
        &conversation_id,
        &resolved_listing_id,
        &current_user_id,
        receiver.as_deref(),
        false,
        &message,
        image.as_deref(),
        audio.as_deref(),
        normalized_image_url.as_deref(),
        normalized_audio_url.as_deref(),
        session_campus_id,
    )
    .await
    .map_err(|e| {
        tracing::error!(%e, "Failed to persist user message");
        ApiError::Internal(anyhow::anyhow!("Failed to persist user message"))
    })?;
    if !persisted {
        return Err(ApiError::NotFound);
    }

    state.infra.metrics.record_chat_message();

    let run = agent_chat::begin_agent_run(
        &state.infra.db,
        crate::api::request_context::current_or_new_request_id(),
        session_campus_id,
        &current_user_id,
        &conversation_id,
        intent_result.intent.as_str(),
        intent_result.confidence,
        Some(state.agents.llm_provider.name()),
        Some(state.agents.llm_provider.model()),
    )
    .await;

    let agent: Box<dyn MarketplaceAgent> = match state
        .agents
        .llm_provider
        .clone()
        .create_marketplace_agent(
            &state.infra.db,
            state.infra.event_tx.clone(),
            Some(current_user_id.clone()),
            session.campus_id,
            proposal_idempotency_key.clone(),
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

    let (reply, usage) = match agent
        .prompt_with_history_with_usage(prompt_msg, chat_history)
        .await
    {
        Ok(reply) => reply,
        Err(error) => {
            tracing::error!(err = %error, "LLM prompt failed");
            state.infra.metrics.record_llm_error();
            if let Some(run) = &run {
                agent_chat::finish_agent_run(run, "failed", "llm_failed", Some("provider_error"))
                    .await;
            }
            return Err(ApiError::Internal(anyhow::anyhow!(error)));
        }
    };

    // Auto-record preference memory in background for future turns
    if let Some(campus_id) = session_campus_id {
        if matches!(
            intent_result.intent,
            crate::agents::router::Intent::Search
                | crate::agents::router::Intent::Wanted
                | crate::agents::router::Intent::Offer
        ) {
            let bg_db = state.infra.db.clone();
            let bg_user_id = current_user_id.clone();
            let bg_msg = message.clone();
            let bg_embedder = state.agents.llm_provider.clone().embedding_generator();
            tokio::spawn(async move {
                let memory_svc = crate::services::agent_memory::AgentMemoryService::new(bg_db);
                let note = format!("用户曾表达需求：{}", bg_msg);
                let _ = memory_svc
                    .add_memory(
                        crate::services::agent_memory::CreateMemoryInput {
                            user_id: &bg_user_id,
                            campus_id,
                            memory_type: "preference",
                            content: &note,
                            source_ref: Some("chat_turn"),
                            confidence: 0.9,
                        },
                        Some(&bg_embedder),
                    )
                    .await;
            });
        }
    }

    state.infra.metrics.record_llm_call();
    if let Some(run) = &run {
        agent_chat::finish_agent_run_with_usage(
            run,
            "completed",
            "llm_completed",
            None,
            usage.as_ref().map(|u| u.input_tokens),
            usage.as_ref().map(|u| u.output_tokens),
        )
        .await;
    }

    // Fire-and-forget: agent reply persistence — errors are non-fatal.
    if let Err(e) = agent_chat::persist_context_message(
        &chat_svc,
        &conversation_id,
        &resolved_listing_id,
        &current_user_id,
        None,
        true,
        &reply,
        None,
        None,
        None,
        None,
        session_campus_id,
    )
    .await
    {
        tracing::warn!(%e, "Failed to log agent reply");
    }

    Ok(Json(ChatResponse {
        reply,
        conversation_id: response_conversation_id,
    }))
}

/// SSE streaming chat — shared logic for GET and POST paths.
async fn handle_chat_stream_request(
    State(state): State<AppState>,
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

    let token = agent_chat::extract_bearer_token(&headers)?;

    auth::ensure_token_not_revoked(&state, token)
        .await
        .map_err(|_| ApiError::Unauthorized)?;

    let session = auth::extract_auth_session_from_token_str_with_fallback(
        token,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)?;
    let session_campus_id = session.campus_id;
    let current_user_id = session.user_id;
    auth::ensure_user_not_banned(&state, &current_user_id).await?;
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
                    None,
                    None,
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
                    None,
                    None,
                )
                .await
                .map_err(|error| ApiError::Internal(anyhow::anyhow!(error)))?;
        }
        if let Some(run) = &run {
            agent_chat::finish_agent_run(run, "completed", "direct_response", None).await;
        }
        let sse_payload = serde_json::json!({
            "token": reply,
            "conversation_id": response_conversation_id,
            "is_complete": true
        });
        let body = axum::body::Body::from(encode_sse_data(&sse_payload));
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
        None,
        None,
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

    let agent: Box<dyn MarketplaceAgent> = match state
        .agents
        .llm_provider
        .create_marketplace_agent(
            &state.infra.db,
            state.infra.event_tx.clone(),
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

    let mut stream = agent.stream_chat(prompt_msg, chat_history);
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
    let sse_stream = async_stream::stream! {
        let mut full_reply = String::new();
        let mut usage = None;
        let mut completed = true;
        let mut ttft_recorded = false;
        let mut tool_calls: u32 = 0;
        let mut first_token_ms: Option<i32> = None;
        let stream_started_at = std::time::Instant::now();
        while let Some(result) = stream.next().await {
            let bytes = match result {
                Ok(AgentStreamChunk::Text(token)) => {
                    if !ttft_recorded {
                        if let Some(run) = &run_for_stream {
                            let ttft_ms = run
                                .started_at
                                .elapsed()
                                .as_millis()
                                .min(i32::MAX as u128) as i32;
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
                                tracing::debug!(
                                    %error,
                                    trace_id = %run.trace_id,
                                    "failed to record AgentRun TTFT"
                                );
                            }
                        }
                        ttft_recorded = true;
                    }
                    full_reply.push_str(&token);
                    let payload = serde_json::json!({
                        "token": token,
                        "conversation_id": public_conversation_id
                    });
                    encode_sse_data(&payload)
                }
                Ok(AgentStreamChunk::Usage(reported_usage)) => {
                    usage = Some(reported_usage);
                    continue;
                }
                Ok(AgentStreamChunk::ToolActivity { tool }) => {
                    tool_calls += 1;
                    let payload = serde_json::json!({
                        "tool_activity": {
                            "tool": tool,
                        },
                        "conversation_id": public_conversation_id,
                    });
                    encode_sse_data(&payload)
                }
                Ok(AgentStreamChunk::UiAction(action)) => {
                    let payload = serde_json::json!({
                        "ui_action": {
                            "type": action.kind,
                            "payload": action.payload,
                        },
                        "conversation_id": public_conversation_id
                    });
                    encode_sse_data(&payload)
                }
                Err(error) => {
                    completed = false;
                    // Goal §49: raw provider/SQL internals must not reach the
                    // client; the full error is already in the server log.
                    tracing::error!(err = %error, "chat stream failed");
                    let payload = serde_json::json!({ "error": "assistant_stream_failed" });
                    encode_sse_data(&payload)
                }
            };
            yield Ok::<_, std::convert::Infallible>(bytes);
            if !completed {
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
        run, "completed", "llm_completed", None,
        usage.as_ref().map(|u| u.input_tokens),
        usage.as_ref().map(|u| u.output_tokens),
    ).await
            } else {
                agent_chat::finish_agent_run(run, "failed", "llm_failed", Some("provider_error")).await
            }
        } else {
            true
        };
        // Goal §75: one structured line per agent turn. Message bodies,
        // tokens, and keys never enter logs; per-tool detail lives in
        // agent_runs DB events instead of stdout.
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
            "agent stream finished"
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

/// GET /api/chat/stream — text-only SSE compat path (query string params).
pub(crate) async fn handle_chat_stream_get(
    state: State<AppState>,
    headers: HeaderMap,
    axum::extract::Query(payload): axum::extract::Query<ChatStreamRequest>,
) -> Result<impl axum::response::IntoResponse, ApiError> {
    handle_chat_stream_request(state, headers, payload).await
}

/// POST /api/chat/stream — preferred SSE path for authenticated JSON payloads.
pub(crate) async fn handle_chat_stream_post(
    state: State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<ChatStreamRequest>,
) -> Result<impl axum::response::IntoResponse, ApiError> {
    handle_chat_stream_request(state, headers, payload).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_chat_request_with_message() {
        let json = r#"{"message": "Hello!", "conversation_id": "conv-1"}"#;
        let req: ChatRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.message, "Hello!");
        assert_eq!(req.conversation_id, Some("conv-1".to_string()));
        assert_eq!(req.image, None);
        assert_eq!(req.audio, None);
        assert_eq!(req.listing_id, None);
    }

    #[test]
    fn test_chat_request_with_media() {
        let json = r#"{"message": "Check this", "image": "base64data", "audio": "base64audio", "image_url": "https://cdn.example.com/a.jpg", "audio_url": "https://cdn.example.com/a.ogg"}"#;
        let req: ChatRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.message, "Check this");
        assert_eq!(req.image, Some("base64data".to_string()));
        assert_eq!(req.audio, Some("base64audio".to_string()));
        assert_eq!(
            req.image_url,
            Some("https://cdn.example.com/a.jpg".to_string())
        );
        assert_eq!(
            req.audio_url,
            Some("https://cdn.example.com/a.ogg".to_string())
        );
        assert_eq!(req.listing_id, None);
    }

    #[test]
    fn test_chat_request_with_listing_context() {
        let json = r#"{"message": "Is this available?", "listing_id": "listing-123"}"#;
        let req: ChatRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.message, "Is this available?");
        assert_eq!(req.listing_id, Some("listing-123".to_string()));
    }

    #[test]
    fn test_chat_request_without_conversation_id() {
        let json = r#"{"message": "Hello!"}"#;
        let req: ChatRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.message, "Hello!");
        assert_eq!(req.conversation_id, None);
    }

    #[test]
    fn test_chat_request_empty_conversation_id() {
        let json = r#"{"message": "Hi", "conversation_id": ""}"#;
        let req: ChatRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.message, "Hi");
        assert_eq!(req.conversation_id, Some("".to_string()));
    }

    #[test]
    fn test_chat_response_serialization() {
        let resp = ChatResponse {
            reply: "Hello back!".to_string(),
            conversation_id: "conv-123".to_string(),
        };
        let json = serde_json::to_string(&resp).unwrap();
        assert!(json.contains("Hello back!"));
        assert!(json.contains("conv-123"));
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
