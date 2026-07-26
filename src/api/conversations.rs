use axum::{
    extract::{Path, Query, State},
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;

use crate::api::error::ApiError;
use crate::api::session::Session;
use crate::api::AppState;
use crate::repositories::{ChatRepository, ConversationSummary};

#[derive(Deserialize)]
pub struct ConversationListQuery {
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

#[derive(Serialize)]
pub struct ConversationListResponse {
    pub items: Vec<ConversationSummary>,
    pub total: i64,
    pub limit: i64,
    pub offset: i64,
}

#[derive(Deserialize)]
pub struct ConversationMessagesQuery {
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

#[derive(Serialize)]
pub struct ConversationMessagesResponse {
    pub conversation_id: String,
    pub messages: Vec<MessageEntry>,
    pub total: i64,
}

#[derive(Serialize)]
pub struct MessageEntry {
    pub sender: String,
    pub sender_username: Option<String>,
    pub content: String,
    pub is_agent: bool,
    pub timestamp: String,
    pub image_data: Option<String>,
    pub audio_data: Option<String>,
}

/// GET /api/conversations - list user's conversations (paginated)
pub async fn list_conversations(
    State(state): State<AppState>,
    Session(session): Session,
    Query(params): Query<ConversationListQuery>,
) -> Result<Json<ConversationListResponse>, ApiError> {
    let user_id = session.user_id.clone();

    let limit = params.limit.unwrap_or(20).clamp(1, 100);
    let offset = params.offset.unwrap_or(0).max(0);

    let (conversations, total) = state
        .chat_repo
        .list_conversations(&user_id, limit, offset)
        .await?;

    Ok(Json(ConversationListResponse {
        items: conversations,
        total,
        limit,
        offset,
    }))
}

/// GET /api/conversations/:id/messages - get messages in a conversation
pub async fn get_conversation_messages(
    State(state): State<AppState>,
    Session(session): Session,
    Path(conversation_id): Path<String>,
    Query(params): Query<ConversationMessagesQuery>,
) -> Result<Json<ConversationMessagesResponse>, ApiError> {
    let user_id = session.user_id.clone();

    let limit = params.limit.unwrap_or(50).clamp(1, 200);
    let offset = params.offset.unwrap_or(0).max(0);

    // Verify user has access to this conversation (IDOR fix).
    // A user can access a conversation if they are EITHER the sender or receiver
    // of at least one message in it. A null receiver means the message author
    // is the only legitimate accessor for that message.
    let has_access = sqlx::query(
        "SELECT 1 FROM chat_messages \
         WHERE conversation_id = $1 AND (sender = $2 OR receiver = $2) \
         LIMIT 1",
    )
    .bind(&conversation_id)
    .bind(&user_id)
    .fetch_optional(&state.infra.db)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    if has_access.is_none() {
        return Err(ApiError::Forbidden);
    }

    // Use repository for messages and total count
    let (messages, total): (Vec<crate::repositories::ChatMessage>, i64) = state
        .chat_repo
        .get_conversation_messages(&conversation_id, None, limit, offset)
        .await?;

    // Collect unique sender IDs for batch username lookup (skip "assistant" sentinel)
    let sender_ids: Vec<String> = messages
        .iter()
        .filter_map(|msg| {
            if msg.sender == "assistant" {
                None
            } else {
                Some(msg.sender.clone())
            }
        })
        .collect();

    let sender_usernames: std::collections::HashMap<String, String> = if sender_ids.is_empty() {
        std::collections::HashMap::new()
    } else {
        sqlx::query("SELECT id, username FROM users WHERE id = ANY($1)")
            .bind(&sender_ids)
            .fetch_all(&state.infra.db)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
            .into_iter()
            .map(|row| (row.get::<String, _>("id"), row.get::<String, _>("username")))
            .collect()
    };

    let messages: Vec<MessageEntry> = messages
        .into_iter()
        .map(|msg| {
            let sender_username = if msg.sender == "assistant" {
                None
            } else {
                sender_usernames.get(&msg.sender).cloned()
            };
            MessageEntry {
                sender: msg.sender,
                sender_username,
                content: msg.content,
                is_agent: msg.is_agent,
                timestamp: msg.created_at.to_rfc3339(),
                image_data: None,
                audio_data: None,
            }
        })
        .collect();

    Ok(Json(ConversationMessagesResponse {
        conversation_id,
        messages,
        total,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_conversation_list_query_defaults() {
        let query: ConversationListQuery = serde_json::from_str(r#"{}"#).unwrap();
        assert_eq!(query.limit, None);
        assert_eq!(query.offset, None);
    }

    #[test]
    fn test_conversation_list_query_with_pagination() {
        let query: ConversationListQuery =
            serde_json::from_str(r#"{"limit": 10, "offset": 5}"#).unwrap();
        assert_eq!(query.limit, Some(10));
        assert_eq!(query.offset, Some(5));
    }

    #[test]
    fn test_conversation_messages_query_defaults() {
        let query: ConversationMessagesQuery = serde_json::from_str(r#"{}"#).unwrap();
        assert_eq!(query.limit, None);
        assert_eq!(query.offset, None);
    }

    #[test]
    fn test_conversation_messages_query_with_pagination() {
        let query: ConversationMessagesQuery =
            serde_json::from_str(r#"{"limit": 50, "offset": 100}"#).unwrap();
        assert_eq!(query.limit, Some(50));
        assert_eq!(query.offset, Some(100));
    }

    #[test]
    fn test_message_entry_serialization() {
        let entry = MessageEntry {
            sender: "user-123".to_string(),
            sender_username: Some("alice".to_string()),
            content: "Hello!".to_string(),
            is_agent: false,
            timestamp: "2024-01-01T00:00:00Z".to_string(),
            image_data: Some("base64img".to_string()),
            audio_data: None,
        };
        let json = serde_json::to_string(&entry).unwrap();
        assert!(json.contains("user-123"));
        assert!(json.contains("Hello!"));
        assert!(json.contains("\"is_agent\":false"));
        assert!(json.contains("base64img"));
        assert!(json.contains("alice"));
    }

    #[test]
    fn test_conversation_messages_response_serialization() {
        let response = ConversationMessagesResponse {
            conversation_id: "conv-1".to_string(),
            messages: vec![],
            total: 0,
        };
        let json = serde_json::to_string(&response).unwrap();
        assert!(json.contains("conv-1"));
        assert!(json.contains("\"messages\":[]"));
        assert!(json.contains("\"total\":0"));
    }

    #[test]
    fn test_conversation_list_response_serialization() {
        let response = ConversationListResponse {
            items: vec![],
            total: 0,
            limit: 20,
            offset: 0,
        };
        let json = serde_json::to_string(&response).unwrap();
        assert!(json.contains("\"items\":[]"));
        assert!(json.contains("\"total\":0"));
        assert!(json.contains("\"limit\":20"));
        assert!(json.contains("\"offset\":0"));
    }
}
