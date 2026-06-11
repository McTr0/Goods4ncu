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

#[derive(Debug, Clone)]
pub struct ConnectionRequestResult {
    pub connection_id: String,
}

#[derive(Debug, Clone)]
pub struct ConnectionDecisionResult {
    pub requester_id: String,
    pub receiver_id: String,
    pub established_at: Option<chrono::DateTime<Utc>>,
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct UserChatMessageRecord {
    pub id: i64,
    pub sender: String,
    pub content: String,
    pub is_agent: bool,
    pub timestamp: chrono::DateTime<Utc>,
    pub read_at: Option<chrono::DateTime<Utc>>,
    pub read_by: Option<String>,
    pub image_data: Option<String>,
    pub audio_data: Option<String>,
    pub image_url: Option<String>,
    pub audio_url: Option<String>,
    pub edited_at: Option<chrono::DateTime<Utc>>,
    pub status: String,
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
        let rows = match limit {
            Some(limit) => {
                sqlx::query(
                    r#"
                    SELECT cc.id, cc.requester_id, cc.receiver_id, cc.status, cc.established_at, cc.created_at, cc.unread_count,
                           CASE WHEN cc.requester_id = $1 THEN cc.receiver_id ELSE cc.requester_id END as other_user_id,
                           u2.username as other_username,
                           CASE WHEN cc.receiver_id = $1 THEN true ELSE false END as is_receiver
                    FROM chat_connections cc
                    LEFT JOIN users u2 ON u2.id = CASE WHEN cc.requester_id = $1 THEN cc.receiver_id ELSE cc.requester_id END
                    WHERE cc.requester_id = $1 OR cc.receiver_id = $1
                    ORDER BY cc.created_at DESC
                    LIMIT $2 OFFSET $3
                    "#,
                )
                .bind(user_id)
                .bind(limit)
                .bind(offset)
                .fetch_all(&self.pool)
                .await
            }
            None => {
                sqlx::query(
                    r#"
                    SELECT cc.id, cc.requester_id, cc.receiver_id, cc.status, cc.established_at, cc.created_at, cc.unread_count,
                           CASE WHEN cc.requester_id = $1 THEN cc.receiver_id ELSE cc.requester_id END as other_user_id,
                           u2.username as other_username,
                           CASE WHEN cc.receiver_id = $1 THEN true ELSE false END as is_receiver
                    FROM chat_connections cc
                    LEFT JOIN users u2 ON u2.id = CASE WHEN cc.requester_id = $1 THEN cc.receiver_id ELSE cc.requester_id END
                    WHERE cc.requester_id = $1 OR cc.receiver_id = $1
                    ORDER BY cc.created_at DESC
                    OFFSET $2
                    "#,
                )
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

    pub async fn list_all_connections_for_user(
        &self,
        user_id: &str,
    ) -> Result<Vec<ConversationSummary>, ApiError> {
        self.fetch_conversation_summaries(user_id, None, 0).await
    }

    pub async fn upsert_connection_request(
        &self,
        requester_id: &str,
        receiver_id: &str,
    ) -> Result<ConnectionRequestResult, ApiError> {
        let mut tx: sqlx::Transaction<'_, sqlx::Postgres> = sqlx::Acquire::begin(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let receiver_exists: bool =
            sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM users WHERE id = $1)")
                .bind(receiver_id)
                .fetch_one(&mut *tx)
                .await
                .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        if !receiver_exists {
            return Err(ApiError::NotFound);
        }

        let existing = sqlx::query(
            "SELECT id, status FROM chat_connections
             WHERE LEAST(requester_id, receiver_id) = LEAST($1, $2)
               AND GREATEST(requester_id, receiver_id) = GREATEST($1, $2)
             FOR UPDATE",
        )
        .bind(requester_id)
        .bind(receiver_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let connection_id = match existing {
            Some(row) => {
                let id: uuid::Uuid = row
                    .try_get("id")
                    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
                let status: String = row.get("status");

                if status != "connected" {
                    sqlx::query(
                        "UPDATE chat_connections
                         SET status = 'pending', requester_id = $1, receiver_id = $2, established_at = NULL
                         WHERE id = $3",
                    )
                    .bind(requester_id)
                    .bind(receiver_id)
                    .bind(id)
                    .execute(&mut *tx)
                    .await
                    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
                }

                id.to_string()
            }
            None => {
                let row = sqlx::query(
                    "INSERT INTO chat_connections (requester_id, receiver_id, status)
                     VALUES ($1, $2, 'pending')
                     RETURNING id",
                )
                .bind(requester_id)
                .bind(receiver_id)
                .fetch_one(&mut *tx)
                .await
                .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

                let connection_id: uuid::Uuid = row
                    .try_get("id")
                    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
                connection_id.to_string()
            }
        };

        tx.commit()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("Commit error: {}", e)))?;

        Ok(ConnectionRequestResult { connection_id })
    }

    pub async fn accept_pending_connection(
        &self,
        connection_id: &str,
        acceptor_id: &str,
    ) -> Result<ConnectionDecisionResult, ApiError> {
        let mut tx: sqlx::Transaction<'_, sqlx::Postgres> = sqlx::Acquire::begin(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let row = sqlx::query(
            "SELECT requester_id, receiver_id, status
             FROM chat_connections
             WHERE id = $1::uuid
             FOR UPDATE",
        )
        .bind(connection_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        .ok_or(ApiError::NotFound)?;

        let requester_id: String = row.get("requester_id");
        let receiver_id: String = row.get("receiver_id");
        let status: String = row.get("status");

        if receiver_id != acceptor_id {
            return Err(ApiError::Forbidden);
        }
        if status != "pending" {
            return Err(ApiError::BadRequest(format!(
                "连接状态不是 pending，当前状态: {}",
                status
            )));
        }

        let established_at = chrono::Utc::now();
        sqlx::query(
            "UPDATE chat_connections
             SET status = 'connected', established_at = $1
             WHERE id = $2::uuid",
        )
        .bind(established_at)
        .bind(connection_id)
        .execute(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        tx.commit()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("Commit error: {}", e)))?;

        Ok(ConnectionDecisionResult {
            requester_id,
            receiver_id,
            established_at: Some(established_at),
        })
    }

    pub async fn reject_pending_connection(
        &self,
        connection_id: &str,
        rejector_id: &str,
    ) -> Result<ConnectionDecisionResult, ApiError> {
        let mut tx: sqlx::Transaction<'_, sqlx::Postgres> = sqlx::Acquire::begin(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let row = sqlx::query(
            "SELECT requester_id, receiver_id, status
             FROM chat_connections
             WHERE id = $1::uuid
             FOR UPDATE",
        )
        .bind(connection_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        .ok_or(ApiError::NotFound)?;

        let requester_id: String = row.get("requester_id");
        let receiver_id: String = row.get("receiver_id");
        let status: String = row.get("status");

        if receiver_id != rejector_id {
            return Err(ApiError::Forbidden);
        }
        if status != "pending" {
            return Err(ApiError::BadRequest(format!(
                "连接状态不是 pending，当前状态: {}",
                status
            )));
        }

        sqlx::query(
            "UPDATE chat_connections
             SET status = 'rejected'
             WHERE id = $1::uuid",
        )
        .bind(connection_id)
        .execute(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        tx.commit()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("Commit error: {}", e)))?;

        Ok(ConnectionDecisionResult {
            requester_id,
            receiver_id,
            established_at: None,
        })
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn create_direct_message(
        &self,
        connection_id: &str,
        connection_uuid: Option<uuid::Uuid>,
        sender_id: &str,
        receiver: Option<&str>,
        content: &str,
        image_base64: Option<&str>,
        audio_base64: Option<&str>,
        image_url: Option<&str>,
        audio_url: Option<&str>,
        read_at: Option<chrono::DateTime<Utc>>,
    ) -> Result<(i64, chrono::DateTime<Utc>, Option<chrono::DateTime<Utc>>), ApiError> {
        let mut tx: sqlx::Transaction<'_, sqlx::Postgres> = sqlx::Acquire::begin(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        let read_by = read_at.map(|_| sender_id);

        let row = sqlx::query(
            r#"INSERT INTO chat_messages (conversation_id, listing_id, sender, receiver, is_agent, content, image_data, audio_data, image_url, audio_url, read_at, read_by, status)
               VALUES ($1::text, 'direct', $2, $3, false, $4, $5, $6, $7, $8, $9, $10, 'sent')
               RETURNING id, timestamp"#,
        )
        .bind(connection_id)
        .bind(sender_id)
        .bind(receiver)
        .bind(content)
        .bind(image_base64)
        .bind(audio_base64)
        .bind(image_url)
        .bind(audio_url)
        .bind(read_at)
        .bind(read_by)
        .fetch_one(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        if let Some(uuid) = connection_uuid {
            sqlx::query(
                "UPDATE chat_connections SET unread_count = unread_count + 1 WHERE id = $1",
            )
            .bind(uuid)
            .execute(&mut *tx)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        }

        tx.commit()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("Commit error: {}", e)))?;

        Ok((row.get("id"), row.get("timestamp"), read_at))
    }

    pub async fn mark_connection_read_with_count(
        &self,
        conversation_id: &str,
        connection_uuid: Option<uuid::Uuid>,
        reader_id: &str,
        read_at: chrono::DateTime<Utc>,
    ) -> Result<u64, ApiError> {
        let mut tx: sqlx::Transaction<'_, sqlx::Postgres> = sqlx::Acquire::begin(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let result = sqlx::query(
            r#"UPDATE chat_messages
               SET read_at = $1, read_by = $2, status = 'read'
               WHERE conversation_id = $3::text
                 AND receiver = $2
                 AND read_at IS NULL"#,
        )
        .bind(read_at)
        .bind(reader_id)
        .bind(conversation_id)
        .execute(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        if let Some(uuid) = connection_uuid {
            sqlx::query("UPDATE chat_connections SET unread_count = 0 WHERE id = $1")
                .bind(uuid)
                .execute(&mut *tx)
                .await
                .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        }

        tx.commit()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("Commit error: {}", e)))?;

        Ok(result.rows_affected())
    }

    pub async fn mark_direct_message_read(
        &self,
        message_id: i64,
        conversation_id: &str,
        connection_uuid: Option<uuid::Uuid>,
        reader_id: &str,
        read_at: chrono::DateTime<Utc>,
    ) -> Result<(), ApiError> {
        let mut tx: sqlx::Transaction<'_, sqlx::Postgres> = sqlx::Acquire::begin(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        sqlx::query("UPDATE chat_messages SET read_at = $1, read_by = $2 WHERE id = $3")
            .bind(read_at)
            .bind(reader_id)
            .bind(message_id)
            .execute(&mut *tx)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        if let Some(uuid) = connection_uuid {
            let remaining_unread: i64 = sqlx::query_scalar(
                r#"SELECT COUNT(*)
                   FROM chat_messages
                   WHERE conversation_id = $1::text
                     AND receiver = $2
                     AND read_at IS NULL"#,
            )
            .bind(conversation_id)
            .bind(reader_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

            sqlx::query("UPDATE chat_connections SET unread_count = $1 WHERE id = $2")
                .bind(remaining_unread as i32)
                .bind(uuid)
                .execute(&mut *tx)
                .await
                .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        }

        tx.commit()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("Commit error: {}", e)))?;

        Ok(())
    }

    pub async fn update_direct_message_content(
        &self,
        message_id: i64,
        content: &str,
        edited_at: chrono::DateTime<Utc>,
    ) -> Result<(), ApiError> {
        sqlx::query("UPDATE chat_messages SET content = $1, edited_at = $2 WHERE id = $3")
            .bind(content)
            .bind(edited_at)
            .bind(message_id)
            .execute(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(())
    }

    pub async fn list_user_chat_messages(
        &self,
        conversation_id: &str,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<UserChatMessageRecord>, i64), ApiError> {
        let rows = sqlx::query_as::<_, UserChatMessageRecord>(
            r#"SELECT id, sender, content, is_agent, timestamp, read_at, read_by, image_data, audio_data, image_url, audio_url, edited_at, status
               FROM chat_messages
               WHERE conversation_id = $1::text
               ORDER BY id DESC
               LIMIT $2 OFFSET $3"#,
        )
        .bind(conversation_id)
        .bind(limit)
        .bind(offset)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let total: i64 = sqlx::query_scalar(
            r#"SELECT COUNT(*)
               FROM chat_messages
               WHERE conversation_id = $1::text"#,
        )
        .bind(conversation_id)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok((rows, total))
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
            "SELECT COUNT(*) FROM chat_connections WHERE requester_id = $1 OR receiver_id = $1",
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

    async fn mark_conversation_read(
        &self,
        conversation_id: &str,
        reader_id: &str,
    ) -> Result<(), ApiError> {
        let mut tx: sqlx::Transaction<'_, sqlx::Postgres> = sqlx::Acquire::begin(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        sqlx::query(
            "UPDATE chat_messages SET read_at = NOW() \
             WHERE conversation_id = $1 AND receiver = $2 AND read_at IS NULL",
        )
        .bind(conversation_id)
        .bind(reader_id)
        .execute(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        sqlx::query(
            "UPDATE chat_connections SET unread_count = 0 WHERE id = $1 AND receiver_id = $2",
        )
        .bind(conversation_id)
        .bind(reader_id)
        .execute(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        tx.commit()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("Commit error: {}", e)))?;

        Ok(())
    }

    async fn edit_message(
        &self,
        message_id: &str,
        sender_id: &str,
        new_content: &str,
    ) -> Result<(), ApiError> {
        let _row = sqlx::query(
            "SELECT cm.id FROM chat_messages cm \
                         JOIN chat_connections cc \
                             ON cc.id = CASE \
                                                         WHEN cm.conversation_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
                                                         THEN cm.conversation_id::uuid \
                                                         ELSE NULL \
                                                    END \
             WHERE cm.id = $1 AND cm.sender = $2 AND cc.status = 'connected'",
        )
        .bind(message_id)
        .bind(sender_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        .ok_or_else(|| ApiError::BadRequest("消息不存在或无权编辑".to_string()))?;

        let edited_at = Utc::now();
        sqlx::query("UPDATE chat_messages SET content = $1, edited_at = $2 WHERE id = $3")
            .bind(new_content)
            .bind(edited_at)
            .bind(message_id)
            .execute(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(())
    }

    async fn mark_message_read(&self, message_id: &str, reader_id: &str) -> Result<(), ApiError> {
        sqlx::query("UPDATE chat_messages SET read_at = NOW() WHERE id = $1 AND receiver = $2")
            .bind(message_id)
            .bind(reader_id)
            .execute(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(())
    }

    async fn request_connection(
        &self,
        requester_id: &str,
        receiver_id: &str,
        _listing_id: &str,
    ) -> Result<String, ApiError> {
        let connection_id = uuid::Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO chat_connections (id, requester_id, receiver_id, status) \
             VALUES ($1, $2, $3, 'pending')",
        )
        .bind(&connection_id)
        .bind(requester_id)
        .bind(receiver_id)
        .execute(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(connection_id)
    }

    async fn accept_connection(
        &self,
        connection_id: &str,
        acceptor_id: &str,
    ) -> Result<(), ApiError> {
        sqlx::query(
            "UPDATE chat_connections SET status = 'connected', established_at = NOW() \
             WHERE id = $1 AND receiver_id = $2 AND status = 'pending'",
        )
        .bind(connection_id)
        .bind(acceptor_id)
        .execute(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(())
    }

    async fn reject_connection(
        &self,
        connection_id: &str,
        rejector_id: &str,
    ) -> Result<(), ApiError> {
        sqlx::query(
            "UPDATE chat_connections SET status = 'rejected' \
             WHERE id = $1 AND receiver_id = $2 AND status = 'pending'",
        )
        .bind(connection_id)
        .bind(rejector_id)
        .execute(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(())
    }
}
