//! Agent chat orchestration: conversation resolution, context persistence,
//! and agent-run lifecycle management.
//!
//! Transport concerns (SSE encoding, HTTP extraction) remain in
//! `api/chat.rs`; this module owns the business decisions.

use crate::services::agent_run::AgentRunService;
use crate::services::chat::ChatService;
use rig::message::{AssistantContent, Message, Text, UserContent};
use rig::OneOrMany;
use sqlx::Row;
use std::time::Instant;
use uuid::Uuid;

pub const AGENT_CONVERSATION_SENTINEL: &str = "__agent__";
const AGENT_RUN_RECONCILIATION_DELAY: std::time::Duration = std::time::Duration::from_secs(3);

// ---------------------------------------------------------------------------
// Conversation resolution
// ---------------------------------------------------------------------------

pub fn resolve_conversation_id(
    requested_id: Option<String>,
    user_id: &str,
) -> (String, String, bool) {
    match requested_id.filter(|id| !id.is_empty()) {
        Some(id) if id == AGENT_CONVERSATION_SENTINEL => (
            ChatService::assistant_conversation_id(user_id),
            AGENT_CONVERSATION_SENTINEL.to_string(),
            true,
        ),
        Some(id) => (id.clone(), id, false),
        None => {
            let id = Uuid::new_v4().to_string();
            (id.clone(), id, false)
        }
    }
}

// ---------------------------------------------------------------------------
// Listing context
// ---------------------------------------------------------------------------

pub async fn resolve_listing_context(
    db: &sqlx::PgPool,
    listing_id: Option<&str>,
    current_user_id: &str,
    session_campus_id: Option<Uuid>,
) -> Result<(String, Option<String>), crate::api::error::ApiError> {
    let Some(lid) = listing_id.filter(|l| !l.is_empty()) else {
        return Ok(("global".to_string(), None));
    };

    let row = sqlx::query(
        "SELECT listing.owner_id
         FROM inventory listing
         JOIN campuses campus
           ON campus.id = listing.campus_id AND campus.status = 'active'
         WHERE listing.id = $1
           AND listing.status = 'active'
           AND NOT listing_has_active_restriction(listing.id)
           AND ($2::uuid IS NULL OR listing.campus_id = $2)
           AND EXISTS (
               SELECT 1 FROM campus_memberships membership
               WHERE membership.campus_id = listing.campus_id
                 AND membership.user_id = $3
                 AND membership.status = 'verified'
           )",
    )
    .bind(lid)
    .bind(session_campus_id)
    .bind(current_user_id)
    .fetch_optional(db)
    .await
    .map_err(|e| crate::api::error::ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    match row {
        Some(r) => {
            let owner_id: String = r.get("owner_id");
            if owner_id != current_user_id {
                Ok((lid.to_string(), Some(owner_id)))
            } else {
                Ok(("global".to_string(), None))
            }
        }
        None => Err(crate::api::error::ApiError::NotFound),
    }
}

// ---------------------------------------------------------------------------
// Message persistence
// ---------------------------------------------------------------------------

#[allow(clippy::too_many_arguments)]
pub async fn persist_context_message(
    chat_svc: &ChatService,
    conversation_id: &str,
    listing_id: &str,
    sender: &str,
    receiver: Option<&str>,
    is_agent: bool,
    content: &str,
    image_url: Option<&str>,
    audio_url: Option<&str>,
    session_campus_id: Option<Uuid>,
) -> anyhow::Result<bool> {
    if listing_id == "global" {
        chat_svc
            .log_message(
                conversation_id,
                listing_id,
                sender,
                receiver,
                is_agent,
                content,
                image_url,
                audio_url,
            )
            .await?;
        return Ok(true);
    }

    chat_svc
        .log_listing_message_if_eligible(
            conversation_id,
            listing_id,
            sender,
            receiver,
            is_agent,
            content,
            image_url,
            audio_url,
            session_campus_id,
        )
        .await
}

// ---------------------------------------------------------------------------
// History conversion
// ---------------------------------------------------------------------------

pub fn history_to_rig_messages(
    entries: &[crate::services::chat::ChatHistoryEntry],
) -> Vec<Message> {
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

// ---------------------------------------------------------------------------
// Bearer token extraction
// ---------------------------------------------------------------------------

#[allow(dead_code)] // Prefer crate::api::session::Session extractor on handlers
pub fn extract_bearer_token(
    headers: &axum::http::HeaderMap,
) -> Result<&str, crate::api::error::ApiError> {
    headers
        .get("Authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .filter(|v| !v.is_empty())
        .ok_or(crate::api::error::ApiError::Unauthorized)
}

// ---------------------------------------------------------------------------
// AgentRun lifecycle
// ---------------------------------------------------------------------------

#[derive(Clone)]
pub struct AgentRunHandle {
    pub service: AgentRunService,
    pub trace_id: String,
    pub campus_id: Uuid,
    pub user_id: String,
    pub started_at: Instant,
}

#[allow(clippy::too_many_arguments)]
pub async fn begin_agent_run(
    db: &sqlx::PgPool,
    trace_id: String,
    campus_id: Option<Uuid>,
    user_id: &str,
    conversation_id: &str,
    route: &str,
    route_confidence: f32,
    provider: Option<&str>,
    model: Option<&str>,
) -> Option<AgentRunHandle> {
    let campus_id = campus_id?;
    let service = AgentRunService::new(db.clone());
    match service
        .start(
            &trace_id,
            campus_id,
            user_id,
            conversation_id,
            route,
            route_confidence,
            provider,
            model,
        )
        .await
    {
        Ok(_) => Some(AgentRunHandle {
            service,
            trace_id,
            campus_id,
            user_id: user_id.to_string(),
            started_at: Instant::now(),
        }),
        Err(error) => {
            tracing::warn!(%error, "failed to start AgentRun envelope");
            None
        }
    }
}

pub async fn finish_agent_run(
    run: &AgentRunHandle,
    status: &str,
    outcome_code: &str,
    error_code: Option<&str>,
) -> bool {
    finish_agent_run_with_usage(run, status, outcome_code, error_code, None, None).await
}

pub async fn finish_agent_run_with_usage(
    run: &AgentRunHandle,
    status: &str,
    outcome_code: &str,
    error_code: Option<&str>,
    input_tokens: Option<u64>,
    output_tokens: Option<u64>,
) -> bool {
    let duration_ms = Some(run.started_at.elapsed().as_millis().min(i32::MAX as u128) as i32);
    let token_input = input_tokens.map(|v| v.min(i32::MAX as u64) as i32);
    let token_output = output_tokens.map(|v| v.min(i32::MAX as u64) as i32);
    match run
        .service
        .finish_with_usage(
            &run.trace_id,
            run.campus_id,
            &run.user_id,
            status,
            outcome_code,
            error_code,
            token_input,
            token_output,
            duration_ms,
        )
        .await
    {
        Ok(finished) => finished,
        Err(error) => {
            tracing::warn!(%error, trace_id = %run.trace_id, "failed to finish AgentRun envelope");
            false
        }
    }
}

/// Schedule reconciliation when a stream is dropped without completing.
pub fn schedule_reconciliation(run: AgentRunHandle) -> tokio::sync::oneshot::Sender<()> {
    let (done_tx, done_rx) = tokio::sync::oneshot::channel::<()>();
    tokio::spawn(async move {
        if done_rx.await.is_ok() {
            return;
        }
        tokio::time::sleep(AGENT_RUN_RECONCILIATION_DELAY).await;
        let duration_ms = Some(run.started_at.elapsed().as_millis().min(i32::MAX as u128) as i32);
        match run
            .service
            .cancel_started(
                &run.trace_id,
                run.campus_id,
                &run.user_id,
                Some("client_disconnect_or_timeout"),
                duration_ms,
            )
            .await
        {
            Ok(true) => tracing::debug!(
                trace_id = %run.trace_id, "reconciled abandoned AgentRun as cancelled"
            ),
            Ok(false) => {}
            Err(error) => tracing::warn!(
                %error, trace_id = %run.trace_id,
                "failed to reconcile abandoned AgentRun"
            ),
        }
    });
    done_tx
}
