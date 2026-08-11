//! PostgreSQL implementation of the ChatRepository trait.

use crate::api::error::ApiError;
use crate::repositories::{ChatMessage, ChatRepository, ConversationSummary};
use crate::services::chat::ChatHistoryEntry;
use chrono::Utc;
use sqlx::{PgPool, Row};

#[derive(Clone)]
#[allow(dead_code)]
pub struct PostgresChatRepository {
    pool: PgPool,
}

impl PostgresChatRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    async fn fetch_conversation_summaries(
        &self,
        user_id: &str,
        limit: Option<i64>,
        offset: i64,
    ) -> Result<Vec<ConversationSummary>, ApiError> {
        let base_query = r#"
            WITH visible_messages AS (
                SELECT *
                FROM chat_messages
                WHERE direct_conversation_id IS NULL
                  AND (sender = $1 OR receiver = $1)
            ),
            latest AS (
                SELECT DISTINCT ON (conversation_id)
                       conversation_id, sender, receiver, timestamp
                FROM visible_messages
                ORDER BY conversation_id, timestamp DESC, id DESC
            ),
            rollup AS (
                SELECT conversation_id,
                       MIN(timestamp) AS created_at
                FROM visible_messages
                GROUP BY conversation_id
            )
            SELECT latest.conversation_id AS id,
                   $1::text AS requester_id,
                   COALESCE(
                       CASE WHEN latest.sender = $1 THEN latest.receiver ELSE latest.sender END,
                       ''
                   ) AS other_user_id,
                   users.username AS other_username,
                   'active'::text AS status,
                   NULL::timestamptz AS established_at,
                   rollup.created_at,
                   0::int AS unread_count,
                   latest.receiver = $1 AS is_receiver
            FROM latest
            JOIN rollup USING (conversation_id)
            LEFT JOIN users ON users.id = CASE
                WHEN latest.sender = $1 THEN latest.receiver
                ELSE latest.sender
            END
            ORDER BY latest.timestamp DESC
        "#;
        let rows = match limit {
            Some(limit) => {
                sqlx::query(&format!("{base_query} LIMIT $2 OFFSET $3"))
                    .bind(user_id)
                    .bind(limit)
                    .bind(offset)
                    .fetch_all(&self.pool)
                    .await
            }
            None => {
                sqlx::query(&format!("{base_query} OFFSET $2"))
                    .bind(user_id)
                    .bind(offset)
                    .fetch_all(&self.pool)
                    .await
            }
        }
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(rows
            .into_iter()
            .map(|row| {
                let established_at: Option<chrono::DateTime<Utc>> = row.get("established_at");
                ConversationSummary {
                    id: row.get("id"),
                    requester_id: row.get("requester_id"),
                    other_user_id: row.get("other_user_id"),
                    other_username: row.get("other_username"),
                    status: row.get("status"),
                    established_at: established_at.map(|dt| dt.to_rfc3339()),
                    created_at: row
                        .get::<chrono::DateTime<Utc>, _>("created_at")
                        .to_rfc3339(),
                    unread_count: row.get("unread_count"),
                    is_receiver: row.get("is_receiver"),
                }
            })
            .collect())
    }
}

impl ChatRepository for PostgresChatRepository {
    async fn log_message(
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
    ) -> Result<(), ApiError> {
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
        .execute(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(())
    }

    async fn get_conversation_history(
        &self,
        conversation_id: &str,
    ) -> Result<Vec<ChatHistoryEntry>, ApiError> {
        const LIMIT: i64 = 10;
        let rows = sqlx::query(
            "SELECT sender, content, is_agent, image_data, audio_data, image_url, audio_url FROM chat_messages \
             WHERE conversation_id = $1 ORDER BY id ASC LIMIT $2",
        )
        .bind(conversation_id)
        .bind(LIMIT)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(rows
            .into_iter()
            .map(|row| {
                let image_data: Option<String> = row.try_get("image_data").ok().flatten();
                let audio_data: Option<String> = row.try_get("audio_data").ok().flatten();
                let image_url: Option<String> = row.try_get("image_url").ok().flatten();
                let audio_url: Option<String> = row.try_get("audio_url").ok().flatten();
                ChatHistoryEntry {
                    sender: row.get("sender"),
                    content: row.get("content"),
                    is_agent: row.get("is_agent"),
                    image_data,
                    audio_data,
                    image_url,
                    audio_url,
                }
            })
            .collect())
    }

    async fn list_conversations(
        &self,
        user_id: &str,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<ConversationSummary>, i64), ApiError> {
        let summaries = self
            .fetch_conversation_summaries(user_id, Some(limit), offset)
            .await?;

        let count_row = sqlx::query(
            "SELECT COUNT(DISTINCT conversation_id) FROM chat_messages \
             WHERE direct_conversation_id IS NULL AND (sender = $1 OR receiver = $1)",
        )
        .bind(user_id)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let total: i64 = count_row.get(0);
        Ok((summaries, total))
    }

    async fn get_conversation_messages(
        &self,
        conversation_id: &str,
        before: Option<i64>,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<ChatMessage>, i64), ApiError> {
        let query = if before.is_some() {
            "SELECT id::text AS id, conversation_id, sender, receiver, content, image_data, audio_data, image_url, audio_url, is_agent, edited_at, timestamp AS created_at \
             FROM chat_messages WHERE conversation_id = $1 AND id < $2 ORDER BY id DESC LIMIT $3 OFFSET $4"
        } else {
            "SELECT id::text AS id, conversation_id, sender, receiver, content, image_data, audio_data, image_url, audio_url, is_agent, edited_at, timestamp AS created_at \
             FROM chat_messages WHERE conversation_id = $1 ORDER BY id DESC LIMIT $2 OFFSET $3"
        };

        let rows = if let Some(b) = before {
            sqlx::query_as::<_, ChatMessage>(query)
                .bind(conversation_id)
                .bind(b)
                .bind(limit)
                .bind(offset)
                .fetch_all(&self.pool)
                .await
        } else {
            sqlx::query_as::<_, ChatMessage>(query)
                .bind(conversation_id)
                .bind(limit)
                .bind(offset)
                .fetch_all(&self.pool)
                .await
        }
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let count_row =
            sqlx::query("SELECT COUNT(*) FROM chat_messages WHERE conversation_id = $1")
                .bind(conversation_id)
                .fetch_one(&self.pool)
                .await
                .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let total: i64 = count_row.get(0);
        Ok((rows, total))
    }

    async fn edit_message(
        &self,
        message_id: &str,
        sender_id: &str,
        new_content: &str,
    ) -> Result<(), ApiError> {
        let edited_at = Utc::now();
        let result = sqlx::query(
            "UPDATE chat_messages \
             SET content = $1, edited_at = $2 \
             WHERE id = $3 \
               AND sender = $4 \
               AND direct_conversation_id IS NULL \
               AND timestamp > NOW() - INTERVAL '15 minutes'",
        )
        .bind(new_content)
        .bind(edited_at)
        .bind(message_id)
        .bind(sender_id)
        .execute(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        if result.rows_affected() == 0 {
            return Err(ApiError::BadRequest("消息不存在或无权编辑".to_string()));
        }

        Ok(())
    }
}
