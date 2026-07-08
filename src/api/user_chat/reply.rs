use std::sync::LazyLock;
use std::time::{Duration, Instant};

use axum::{
    extract::{Path, State},
    http::HeaderMap,
    Json,
};
use dashmap::DashMap;
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::api::AppState;
use crate::services::chat_conversation::ChatConversationService;

use super::{authenticated_user, ReplySuggestion, ReplySuggestionsResponse};

const REPLY_SUGGESTION_LIMIT_PER_MINUTE: u32 = 6;
static REPLY_LIMITS: LazyLock<DashMap<String, (Instant, u32)>> = LazyLock::new(DashMap::new);

pub async fn reply_suggestions(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(conversation_id): Path<Uuid>,
) -> Result<Json<ReplySuggestionsResponse>, ApiError> {
    let user_id = authenticated_user(&state, &headers)?;
    enforce_reply_limit(&user_id)?;
    let service = ChatConversationService::new(state.infra.db.clone());
    let conversation = service.get_conversation(conversation_id, &user_id).await?;
    if !conversation.capabilities.can_send {
        return Err(ApiError::Conflict(
            "reply_suggestions_unavailable".to_string(),
        ));
    }
    let (mut messages, _) = service
        .get_messages(conversation_id, &user_id, 12, 0)
        .await?;
    messages.reverse();
    let plain_messages: Vec<serde_json::Value> = messages
        .iter()
        .map(|message| {
            serde_json::json!({
                "speaker": if message.sender == user_id { "me" } else { "other" },
                "text": message.content,
            })
        })
        .collect();
    let source_text = messages
        .iter()
        .map(|message| message.content.as_str())
        .collect::<Vec<_>>()
        .join("\n");
    let prompt = serde_json::json!({
        "task": "draft_three_non_binding_replies",
        "conversation_mode": conversation.mode,
        "subject": conversation.subject,
        "listing_title": conversation.listing_title,
        "messages": plain_messages,
    })
    .to_string();

    let assistant = state
        .agents
        .llm_provider
        .clone()
        .create_reply_assistant()
        .await
        .map_err(|error| {
            tracing::warn!(%error, "failed to create reply assistant");
            ApiError::Internal(anyhow::anyhow!("reply assistant unavailable"))
        })?;
    let raw = tokio::time::timeout(Duration::from_secs(8), assistant.prompt(prompt))
        .await
        .map_err(|_| ApiError::Internal(anyhow::anyhow!("reply assistant timeout")))?
        .map_err(|error| {
            tracing::warn!(%error, "reply assistant failed");
            ApiError::Internal(anyhow::anyhow!("reply assistant unavailable"))
        })?;
    let parsed: ReplySuggestionsResponse = serde_json::from_str(raw.trim()).map_err(|error| {
        tracing::warn!(%error, "reply assistant returned invalid json");
        ApiError::Internal(anyhow::anyhow!("reply assistant invalid output"))
    })?;
    validate_suggestions(&parsed.suggestions, &source_text)?;
    Ok(Json(parsed))
}

fn enforce_reply_limit(user_id: &str) -> Result<(), ApiError> {
    let now = Instant::now();
    let mut entry = REPLY_LIMITS.entry(user_id.to_string()).or_insert((now, 0));
    if now.duration_since(entry.0) >= Duration::from_secs(60) {
        *entry = (now, 0);
    }
    if entry.1 >= REPLY_SUGGESTION_LIMIT_PER_MINUTE {
        return Err(ApiError::RateLimitExceeded);
    }
    entry.1 += 1;
    Ok(())
}

fn validate_suggestions(
    suggestions: &[ReplySuggestion],
    source_text: &str,
) -> Result<(), ApiError> {
    let expected_tones = ["direct", "warm", "reserved"];
    if suggestions.len() != expected_tones.len() {
        return Err(invalid_output());
    }
    for (suggestion, tone) in suggestions.iter().zip(expected_tones) {
        let text = suggestion.text.trim();
        if suggestion.tone != tone
            || text.is_empty()
            || text.chars().count() > 120
            || text.contains("http://")
            || text.contains("https://")
            || contains_unbacked_number(text, source_text)
            || contains_binding_commitment(text)
        {
            return Err(invalid_output());
        }
    }
    Ok(())
}

fn contains_unbacked_number(text: &str, source_text: &str) -> bool {
    text.split(|character: char| !character.is_ascii_digit() && character != '.')
        .filter(|value| value.chars().any(|character| character.is_ascii_digit()))
        .any(|value| !source_text.contains(value))
}

fn contains_binding_commitment(text: &str) -> bool {
    [
        "确认成交",
        "我会付款",
        "已经付款",
        "已付款",
        "接受报价",
        "同意这个价格",
    ]
    .iter()
    .any(|phrase| text.contains(phrase))
}

fn invalid_output() -> ApiError {
    ApiError::Internal(anyhow::anyhow!("reply assistant invalid output"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_suggestions() -> Vec<ReplySuggestion> {
        vec![
            ReplySuggestion {
                tone: "direct".to_string(),
                text: "这个价格还能再商量吗？".to_string(),
            },
            ReplySuggestion {
                tone: "warm".to_string(),
                text: "谢谢回复，如果方便的话想再聊聊价格。".to_string(),
            },
            ReplySuggestion {
                tone: "reserved".to_string(),
                text: "我先考虑一下，之后有需要再联系你。".to_string(),
            },
        ]
    }

    #[test]
    fn accepts_three_safe_tones() {
        assert!(validate_suggestions(&valid_suggestions(), "").is_ok());
    }

    #[test]
    fn rejects_unbacked_prices_and_commitments() {
        let mut suggestions = valid_suggestions();
        suggestions[0].text = "300 元我确认成交".to_string();
        assert!(validate_suggestions(&suggestions, "原价 200 元").is_err());
    }
}
