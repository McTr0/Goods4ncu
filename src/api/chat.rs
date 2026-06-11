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
use crate::api::{AppState, PeerAddr};
use crate::llm::MarketplaceAgent;
use crate::services::chat::ChatService;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use axum::Json;
use futures::StreamExt;
use rig::completion::Message;
use rig::message::{AssistantContent, Text, UserContent};
use rig::OneOrMany;
use serde::{Deserialize, Serialize};
use sqlx::Row;
use uuid::Uuid;

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
    pub conversation_id: Option<String>,
    pub image_url: Option<String>,
    pub audio_url: Option<String>,
}

pub(crate) fn normalize_optional_media_url(
    value: Option<String>,
    field_name: &str,
) -> Result<Option<String>, ApiError> {
    let normalized = value
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty());
    if let Some(url) = normalized.as_deref() {
        if !url.starts_with("http://") && !url.starts_with("https://") {
            return Err(ApiError::BadRequest(format!("{field_name}格式无效")));
        }
    }
    Ok(normalized)
}

fn extract_bearer_token(headers: &HeaderMap) -> Result<&str, ApiError> {
    headers
        .get("Authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .filter(|v| !v.is_empty())
        .ok_or(ApiError::Unauthorized)
}

/// Resolve listing context for a chat request.
///
/// Returns `(resolved_listing_id, receiver)`. When `listing_id` points to an
/// active listing owned by someone other than the caller, both values are
/// returned verbatim. Otherwise both fall back to `"global"` / `None`.
async fn resolve_listing_context(
    db: &sqlx::PgPool,
    listing_id: Option<&str>,
    current_user_id: &str,
) -> Result<(String, Option<String>), ApiError> {
    match listing_id {
        Some(lid) if !lid.is_empty() => {
            let row = sqlx::query("SELECT owner_id, status FROM inventory WHERE id = $1")
                .bind(lid)
                .fetch_optional(db)
                .await
                .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

            match row {
                Some(r) => {
                    let owner_id: String = r.get("owner_id");
                    let status: String = r.get("status");
                    if status == "active" && owner_id != current_user_id {
                        Ok((lid.to_string(), Some(owner_id)))
                    } else {
                        Ok(("global".to_string(), None))
                    }
                }
                None => Ok(("global".to_string(), None)),
            }
        }
        _ => Ok(("global".to_string(), None)),
    }
}

fn history_to_rig_messages(entries: &[crate::services::chat::ChatHistoryEntry]) -> Vec<Message> {
    entries
        .iter()
        .map(|entry| {
            if entry.is_agent {
                Message::Assistant {
                    id: None,
                    content: OneOrMany::one(AssistantContent::Text(Text {
                        text: entry.content.clone(),
                    })),
                }
            } else {
                Message::User {
                    content: OneOrMany::one(UserContent::Text(Text {
                        text: entry.content.clone(),
                    })),
                }
            }
        })
        .collect()
}

pub(crate) async fn handle_chat(
    State(state): State<AppState>,
    PeerAddr(addr): PeerAddr,
    headers: HeaderMap,
    Json(payload): Json<ChatRequest>,
) -> Result<Json<ChatResponse>, ApiError> {
    let ChatRequest {
        message,
        image,
        audio,
        image_url,
        audio_url,
        conversation_id,
        listing_id,
    } = payload;

    // 10 MB network limit enforced by RequestBodyLimitLayer; text beyond 2000
    // chars is almost certainly abuse.
    if message.len() > 2000 {
        return Err(ApiError::BadRequest(
            "Text message exceeds maximum length of 2000 characters.".to_string(),
        ));
    }

    let normalized_image_url = normalize_optional_media_url(image_url, "image_url")?;
    let normalized_audio_url = normalize_optional_media_url(audio_url, "audio_url")?;

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

    let current_user_id = auth::extract_user_id_from_token_with_fallback(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)?;

    // Lightweight intent classification — blocked content and greetings short-circuit here.
    let intent_result = state.agents.router.classify(&message);
    tracing::debug!(intent = ?intent_result.intent.as_str(), confidence = %intent_result.confidence, "Router classification");

    if let Some(reply) = intent_result.direct_response(&message) {
        let conversation_id = conversation_id
            .filter(|id| !id.is_empty())
            .unwrap_or_else(|| Uuid::new_v4().to_string());
        return Ok(Json(ChatResponse {
            reply,
            conversation_id,
        }));
    }

    let (resolved_listing_id, receiver) =
        resolve_listing_context(&state.infra.db, listing_id.as_deref(), &current_user_id).await?;

    let conversation_id = conversation_id
        .filter(|id| !id.is_empty())
        .unwrap_or_else(|| Uuid::new_v4().to_string());

    let chat_svc = ChatService::new(state.infra.db.clone());

    // Persist before LLM execution to avoid message loss on timeout or abort.
    chat_svc
        .log_message(
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
        )
        .await
        .map_err(|e| {
            tracing::error!(%e, "Failed to persist user message");
            ApiError::Internal(anyhow::anyhow!("Failed to persist user message"))
        })?;

    state.infra.metrics.record_chat_message();

    let history = chat_svc
        .get_conversation_history(&conversation_id)
        .await
        .unwrap_or_default();
    let chat_history = history_to_rig_messages(&history);

    let agent: Box<dyn MarketplaceAgent> = state
        .agents
        .llm_provider
        .create_marketplace_agent(
            &state.infra.db,
            state.infra.event_tx.clone(),
            Some(current_user_id.clone()),
        )
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!(e)))?;

    let reply = agent
        .prompt_with_history(message.clone(), chat_history)
        .await
        .map_err(|e| {
            tracing::error!(err = %e, "LLM prompt failed");
            state.infra.metrics.record_llm_error();
            ApiError::Internal(anyhow::anyhow!(e))
        })?;

    state.infra.metrics.record_llm_call();

    // Fire-and-forget: agent reply persistence — errors are non-fatal.
    if let Err(e) = chat_svc
        .log_message(
            &conversation_id,
            &resolved_listing_id,
            "assistant",
            None,
            true,
            &reply,
            None,
            None,
            None,
            None,
        )
        .await
    {
        tracing::warn!(%e, "Failed to log agent reply");
    }

    Ok(Json(ChatResponse {
        reply,
        conversation_id,
    }))
}

/// SSE streaming chat — shared logic for GET and POST paths.
async fn handle_chat_stream_request(
    State(state): State<AppState>,
    headers: HeaderMap,
    payload: ChatStreamRequest,
) -> Result<impl axum::response::IntoResponse, ApiError> {
    let ChatStreamRequest {
        message,
        listing_id,
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

    let normalized_image_url = normalize_optional_media_url(image_url, "image_url")?;
    let normalized_audio_url = normalize_optional_media_url(audio_url, "audio_url")?;

    let token = extract_bearer_token(&headers)?;

    auth::ensure_token_not_revoked(&state, token)
        .await
        .map_err(|_| ApiError::Unauthorized)?;

    let current_user_id = auth::extract_user_id_from_token_str_with_fallback(
        token,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)?;
    auth::ensure_user_not_banned(&state, &current_user_id).await?;

    let intent_result = state.agents.router.classify(&message);
    tracing::debug!(intent = ?intent_result.intent.as_str(), confidence = %intent_result.confidence, "SSE Router classification");

    if let Some(reply) = intent_result.direct_response(&message) {
        let conversation_id = conversation_id
            .filter(|id| !id.is_empty())
            .unwrap_or_else(|| Uuid::new_v4().to_string());
        let sse_payload = serde_json::json!({ "token": reply, "conversation_id": conversation_id });
        let body = axum::body::Body::from(encode_sse_data(&sse_payload));
        return build_sse_response(&conversation_id, body);
    }

    let (resolved_listing_id, receiver) =
        resolve_listing_context(&state.infra.db, listing_id.as_deref(), &current_user_id).await?;

    let conversation_id = conversation_id
        .filter(|id| !id.is_empty())
        .unwrap_or_else(|| Uuid::new_v4().to_string());

    let chat_svc = ChatService::new(state.infra.db.clone());

    // Persist user turn before streaming — aborted streams must not lose the message.
    chat_svc
        .log_message(
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
        )
        .await
        .map_err(|e| {
            tracing::error!(%e, "Failed to persist user message for SSE stream");
            ApiError::Internal(anyhow::anyhow!("Failed to persist user message"))
        })?;

    let history = chat_svc
        .get_conversation_history(&conversation_id)
        .await
        .unwrap_or_default();
    let chat_history = history_to_rig_messages(&history);

    let agent: Box<dyn MarketplaceAgent> = state
        .agents
        .llm_provider
        .create_marketplace_agent(
            &state.infra.db,
            state.infra.event_tx.clone(),
            Some(current_user_id.clone()),
        )
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!(e)))?;

    let stream = agent.stream_chat(message.clone(), chat_history);

    let conv_id = conversation_id.clone();
    let sse_stream = stream.map(move |result| {
        let bytes = match result {
            Ok(token) => {
                let payload = serde_json::json!({ "token": token, "conversation_id": conv_id });
                encode_sse_data(&payload)
            }
            Err(e) => {
                let payload = serde_json::json!({ "error": e.to_string() });
                encode_sse_data(&payload)
            }
        };
        Ok::<_, std::convert::Infallible>(bytes)
    });

    let body = axum::body::Body::from_stream(sse_stream);
    build_sse_response(&conversation_id, body)
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
    fn normalize_optional_media_url_allows_https_urls() {
        let normalized = normalize_optional_media_url(
            Some(" https://cdn.example.com/file.jpg ".to_string()),
            "image_url",
        )
        .expect("normalized");
        assert_eq!(
            normalized,
            Some("https://cdn.example.com/file.jpg".to_string())
        );
    }

    #[test]
    fn normalize_optional_media_url_rejects_non_http_urls() {
        let err =
            normalize_optional_media_url(Some("file:///tmp/image.jpg".to_string()), "image_url")
                .expect_err("invalid");
        assert!(matches!(err, ApiError::BadRequest(_)));
    }
}
