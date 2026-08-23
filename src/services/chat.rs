use anyhow::Result;
use serde::Serialize;
use sqlx::{PgPool, Row};
use uuid::Uuid;

/// Maximum number of historical message pairs to include in conversation context
const CONVERSATION_HISTORY_LIMIT: usize = 10;
pub const AGENT_CONVERSATION_SENTINEL: &str = "__agent__";

/// A single turn in the conversation history
#[derive(Debug, Clone)]
pub struct ChatHistoryEntry {
    #[allow(dead_code)]
    pub sender: String,
    pub content: String,
    pub is_agent: bool,
    #[allow(dead_code)]
    pub image_data: Option<String>,
    #[allow(dead_code)]
    pub audio_data: Option<String>,
    #[allow(dead_code)]
    pub image_url: Option<String>,
    #[allow(dead_code)]
    pub audio_url: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct AssistantMessageEntry {
    pub id: String,
    pub role: &'static str,
    pub content: String,
    pub image_url: Option<String>,
    pub audio_url: Option<String>,
    pub timestamp: String,
}

#[derive(Clone)]
pub struct ChatService {
    db: PgPool,
}

impl ChatService {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    pub fn assistant_conversation_id(user_id: &str) -> String {
        format!("agent:{user_id}")
    }

    /// Log a chat message to the database.
    /// receiver is the intended recipient (listing owner for item inquiries, null for global/agent messages).
    #[allow(clippy::too_many_arguments)]
    pub async fn log_message(
        &self,
        conversation_id: &str,
        listing_id: &str,
        sender: &str,
        receiver: Option<&str>,
        is_agent: bool,
        content: &str,
        image_data: Option<&str>,
        audio_data: Option<&str>,
        image_url: Option<&str>,
        audio_url: Option<&str>,
    ) -> Result<()> {
        sqlx::query(
            "INSERT INTO chat_messages (conversation_id, listing_id, sender, receiver, is_agent, content, image_data, audio_data, image_url, audio_url) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
        )
        .bind(conversation_id)
        .bind(listing_id)
        .bind(sender)
        .bind(receiver)
        .bind(is_agent)
        .bind(content)
        .bind(image_data)
        .bind(audio_data)
        .bind(image_url)
        .bind(audio_url)
        .execute(&self.db)
        .await?;
        Ok(())
    }

    /// Persist a listing-associated message only while the listing is still
    /// eligible. The inventory lock is held through the insert so moderation
    /// cannot activate a restriction between validation and persistence.
    #[allow(clippy::too_many_arguments)]
    pub async fn log_listing_message_if_eligible(
        &self,
        conversation_id: &str,
        listing_id: &str,
        sender: &str,
        receiver: Option<&str>,
        is_agent: bool,
        content: &str,
        image_data: Option<&str>,
        audio_data: Option<&str>,
        image_url: Option<&str>,
        audio_url: Option<&str>,
        session_campus_id: Option<Uuid>,
    ) -> Result<bool> {
        let mut tx = self.db.begin().await?;
        let listing = sqlx::query(
            "SELECT owner_id, status, campus_id
             FROM inventory WHERE id = $1 FOR SHARE",
        )
        .bind(listing_id)
        .fetch_optional(&mut *tx)
        .await?;
        let Some(listing) = listing else {
            return Ok(false);
        };
        let owner_id: String = listing.get("owner_id");
        let status: String = listing.get("status");
        let campus_id: Uuid = listing.get("campus_id");

        let restricted: bool = sqlx::query_scalar("SELECT listing_has_active_restriction($1)")
            .bind(listing_id)
            .fetch_one(&mut *tx)
            .await?;
        let campus_access: bool = sqlx::query_scalar(
            "SELECT EXISTS(
                 SELECT 1
                 FROM campuses campus
                 JOIN campus_memberships membership
                   ON membership.campus_id = campus.id
                 WHERE campus.id = $1
                   AND campus.status = 'active'
                   AND membership.user_id = $2
                   AND membership.status = 'verified'
             )",
        )
        .bind(campus_id)
        .bind(sender)
        .fetch_one(&mut *tx)
        .await?;
        if status != "active"
            || restricted
            || !campus_access
            || session_campus_id.is_some_and(|session_campus| session_campus != campus_id)
            || owner_id == sender
            || (!is_agent && receiver != Some(owner_id.as_str()))
        {
            return Ok(false);
        }

        sqlx::query(
            "INSERT INTO chat_messages (conversation_id, listing_id, sender, receiver, is_agent, content, image_data, audio_data, image_url, audio_url)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
        )
        .bind(conversation_id)
        .bind(listing_id)
        .bind(sender)
        .bind(receiver)
        .bind(is_agent)
        .bind(content)
        .bind(image_data)
        .bind(audio_data)
        .bind(image_url)
        .bind(audio_url)
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(true)
    }

    /// Fetch the most recent conversation history for a given conversation_id.
    /// Returns up to CONVERSATION_HISTORY_LIMIT entries, oldest first.
    pub async fn get_conversation_history(
        &self,
        conversation_id: &str,
    ) -> Result<Vec<ChatHistoryEntry>> {
        let rows = sqlx::query(
            "SELECT sender, content, is_agent, image_data, audio_data, image_url, audio_url \
             FROM ( \
                 SELECT id, sender, content, is_agent, image_data, audio_data, image_url, audio_url \
                 FROM chat_messages WHERE conversation_id = $1 ORDER BY id DESC LIMIT $2 \
             ) recent ORDER BY id ASC",
        )
        .bind(conversation_id)
        .bind(CONVERSATION_HISTORY_LIMIT as i64)
        .fetch_all(&self.db)
        .await?;

        Ok(rows
            .into_iter()
            .map(|row| {
                let image_data: Option<String> = row.try_get("image_data").ok().flatten();
                let audio_data: Option<String> = row.try_get("audio_data").ok().flatten();
                let image_url: Option<String> = row.try_get("image_url").ok().flatten();
                let audio_url: Option<String> = row.try_get("audio_url").ok().flatten();
                ChatHistoryEntry {
                    sender: Row::get(&row, "sender"),
                    content: Row::get(&row, "content"),
                    is_agent: Row::get(&row, "is_agent"),
                    image_data,
                    audio_data,
                    image_url,
                    audio_url,
                }
            })
            .collect())
    }

    /// Hard-delete every message in the user's synthetic assistant thread.
    pub async fn clear_assistant_messages(&self, user_id: &str) -> Result<u64> {
        let conversation_id = Self::assistant_conversation_id(user_id);
        let result =
            sqlx::query("DELETE FROM chat_messages WHERE conversation_id = $1 AND sender = $2")
                .bind(&conversation_id)
                .bind(user_id)
                .execute(&self.db)
                .await?;
        Ok(result.rows_affected())
    }

    pub async fn get_assistant_messages(
        &self,
        user_id: &str,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<AssistantMessageEntry>, i64)> {
        let conversation_id = Self::assistant_conversation_id(user_id);
        let rows = sqlx::query(
            r#"
            SELECT id, content, is_agent, image_url, audio_url, timestamp
            FROM (
                SELECT id, content, is_agent, image_url, audio_url, timestamp
                FROM chat_messages
                WHERE conversation_id = $1 AND sender = $2
                ORDER BY timestamp DESC, id DESC
                LIMIT $3 OFFSET $4
            ) recent
            ORDER BY timestamp ASC, id ASC
            "#,
        )
        .bind(&conversation_id)
        .bind(user_id)
        .bind(limit)
        .bind(offset)
        .fetch_all(&self.db)
        .await?;

        let total = sqlx::query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM chat_messages WHERE conversation_id = $1 AND sender = $2",
        )
        .bind(&conversation_id)
        .bind(user_id)
        .fetch_one(&self.db)
        .await?;

        let messages = rows
            .into_iter()
            .map(|row| {
                let is_agent: bool = row.get("is_agent");
                AssistantMessageEntry {
                    id: row.get::<i64, _>("id").to_string(),
                    role: if is_agent { "assistant" } else { "user" },
                    content: row.get("content"),
                    image_url: row.try_get("image_url").ok().flatten(),
                    audio_url: row.try_get("audio_url").ok().flatten(),
                    timestamp: row
                        .get::<chrono::DateTime<chrono::Utc>, _>("timestamp")
                        .to_rfc3339(),
                }
            })
            .collect();

        Ok((messages, total))
    }

    /// List all conversation IDs for a user with metadata.
    /// Returns paginated results ordered by most recent message.
    #[allow(dead_code)]
    pub async fn list_conversations(
        &self,
        user_id: &str,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<ConversationSummary>, i64)> {
        // Count conversations where user is either sender or receiver.
        // The receiver column was added later, so NULL receiver means sender-only visibility.
        let count_row = sqlx::query(
            "SELECT COUNT(DISTINCT conversation_id) as cnt \
             FROM chat_messages \
             WHERE sender = $1 OR receiver = $1",
        )
        .bind(user_id)
        .fetch_one(&self.db)
        .await?;
        let total: i64 = count_row.try_get("cnt").unwrap_or(0);

        let rows = sqlx::query(
            r#"
            SELECT DISTINCT ON (cm.conversation_id)
                   cm.conversation_id,
                   cm.listing_id,
                   i.title as listing_title,
                   cm.content as last_message,
                   cm.is_agent as last_message_is_agent,
                   cm.timestamp as last_timestamp,
                   CASE WHEN cm.sender = $1 THEN cm.receiver ELSE cm.sender END as other_user_id
            FROM chat_messages cm
            LEFT JOIN inventory i ON cm.listing_id = i.id
            WHERE cm.sender = $1 OR cm.receiver = $1
            ORDER BY cm.conversation_id, cm.timestamp DESC
            LIMIT $2 OFFSET $3
            "#,
        )
        .bind(user_id)
        .bind(limit)
        .bind(offset)
        .fetch_all(&self.db)
        .await?;

        // Batch-fetch usernames for other participants
        let other_ids: Vec<String> = rows
            .iter()
            .filter_map(|row| {
                row.try_get::<Option<String>, _>("other_user_id")
                    .ok()
                    .flatten()
            })
            .collect();
        let other_usernames: std::collections::HashMap<String, String> = if other_ids.is_empty() {
            std::collections::HashMap::new()
        } else {
            sqlx::query("SELECT id, username FROM users WHERE id = ANY($1)")
                .bind(&other_ids)
                .fetch_all(&self.db)
                .await
                .map(|rows| {
                    rows.into_iter()
                        .map(|row| (row.get::<String, _>("id"), row.get::<String, _>("username")))
                        .collect()
                })
                .unwrap_or_default()
        };

        let items = rows
            .into_iter()
            .map(|row| {
                let other_user_id: Option<String> = row.try_get("other_user_id").ok().flatten();
                let other_username = other_user_id
                    .as_ref()
                    .and_then(|id| other_usernames.get(id).cloned());
                ConversationSummary {
                    conversation_id: row.get("conversation_id"),
                    listing_id: row.get("listing_id"),
                    listing_title: row.try_get("listing_title").ok(),
                    last_message: row.get("last_message"),
                    last_message_is_agent: row.get("last_message_is_agent"),
                    last_timestamp: row
                        .try_get::<sqlx::types::chrono::DateTime<sqlx::types::chrono::Utc>, _>(
                            "last_timestamp",
                        )
                        .map(|dt| dt.to_rfc3339())
                        .unwrap_or_default(),
                    other_user_id,
                    other_username,
                }
            })
            .collect();

        Ok((items, total))
    }
}

/// Summary of a conversation for listing
#[allow(dead_code)]
#[derive(Debug, Clone, Serialize)]
pub struct ConversationSummary {
    pub conversation_id: String,
    pub listing_id: String,
    pub listing_title: Option<String>,
    pub last_message: String,
    pub last_message_is_agent: bool,
    pub last_timestamp: String,
    /// User ID of the other participant in this conversation.
    pub other_user_id: Option<String>,
    /// Username of the other participant.
    pub other_username: Option<String>,
}

// ---------------------------------------------------------------------------
// Unit tests (no DB required)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod unit_tests {
    use super::*;

    #[test]
    fn test_chat_history_entry_clone() {
        let entry = ChatHistoryEntry {
            sender: "user-1".to_string(),
            content: "Hello".to_string(),
            is_agent: false,
            image_data: None,
            audio_data: None,
            image_url: None,
            audio_url: None,
        };
        let cloned = entry.clone();
        assert_eq!(cloned.content, "Hello");
        assert!(!cloned.is_agent);
    }

    #[test]
    fn test_chat_history_entry_with_media() {
        let entry = ChatHistoryEntry {
            sender: "user-1".to_string(),
            content: "Check this image".to_string(),
            is_agent: true,
            image_data: Some("base64image".to_string()),
            audio_data: Some("base64audio".to_string()),
            image_url: Some("https://example.com/image.jpg".to_string()),
            audio_url: Some("https://example.com/audio.m4a".to_string()),
        };
        assert!(entry.image_data.is_some());
        assert!(entry.audio_data.is_some());
        assert!(entry.image_url.is_some());
        assert!(entry.audio_url.is_some());
        assert_eq!(entry.sender, "user-1");
    }

    #[test]
    fn test_conversation_summary_serialization() {
        let summary = ConversationSummary {
            conversation_id: "conv-123".to_string(),
            listing_id: "listing-456".to_string(),
            listing_title: Some("iPhone 13".to_string()),
            last_message: "Is this still available?".to_string(),
            last_message_is_agent: false,
            last_timestamp: "2024-01-01T12:00:00Z".to_string(),
            other_user_id: None,
            other_username: None,
        };
        let json = serde_json::to_string(&summary).unwrap();
        assert!(json.contains("conv-123"));
        assert!(json.contains("listing-456"));
        assert!(json.contains("iPhone 13"));
        assert!(json.contains("Is this still available"));
    }

    #[test]
    fn test_conversation_summary_without_title() {
        let summary = ConversationSummary {
            conversation_id: "conv-789".to_string(),
            listing_id: "listing-000".to_string(),
            listing_title: None,
            last_message: "Hello!".to_string(),
            last_message_is_agent: true,
            last_timestamp: "2024-01-01T12:00:00Z".to_string(),
            other_user_id: Some("user-other".to_string()),
            other_username: Some("other_user".to_string()),
        };
        let json = serde_json::to_string(&summary).unwrap();
        assert!(json.contains("conv-789"));
        assert!(json.contains("listing-000"));
        assert!(json.contains("\"last_message_is_agent\":true"));
    }

    #[test]
    fn test_conversation_summary_empty_title() {
        let summary = ConversationSummary {
            conversation_id: "conv-empty".to_string(),
            listing_id: "listing-empty".to_string(),
            listing_title: None,
            last_message: "".to_string(),
            last_message_is_agent: false,
            last_timestamp: "".to_string(),
            other_user_id: None,
            other_username: None,
        };
        let json = serde_json::to_string(&summary).unwrap();
        assert!(json.contains("conv-empty"));
        assert!(json.contains("\"listing_title\":null"));
    }

    #[test]
    fn test_chat_service_clone() {
        // ChatService is Clone, verify it compiles
        fn assert_clone<T: Clone>() {}
        assert_clone::<ChatService>();
    }

    #[test]
    fn test_conversation_history_limit_constant() {
        let limit = CONVERSATION_HISTORY_LIMIT;
        assert!((1..=100).contains(&limit));
    }
}
