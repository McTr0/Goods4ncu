//! Chat space and group call service — manages spaces, members, messages, and calls.

use chrono::{DateTime, Utc};
use serde::Serialize;
use sqlx::{PgPool, Row};
use uuid::Uuid;

use crate::api::error::ApiError;

#[derive(Debug, Clone, Serialize)]
pub struct SpaceView {
    pub id: String,
    pub kind: String,
    pub name: String,
    pub description: Option<String>,
    pub owner_id: Option<String>,
    pub my_role: String,
    pub member_count: i64,
    pub online_count: i64,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct SpaceMessageView {
    pub id: i64,
    pub space_id: String,
    pub sender_id: String,
    pub sender_username: Option<String>,
    pub content: String,
    pub reply_to_message_id: Option<i64>,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct CallView {
    pub id: String,
    pub conversation_id: String,
    pub caller_id: String,
    pub callee_id: String,
    pub media: String,
    pub state: String,
    pub offer_sdp: String,
    pub answer_sdp: Option<String>,
    pub created_at: String,
}

fn db_error(error: sqlx::Error) -> ApiError {
    ApiError::Internal(anyhow::anyhow!(error))
}

fn row_to_space_message(row: sqlx::postgres::PgRow) -> SpaceMessageView {
    SpaceMessageView {
        id: row.get("id"),
        space_id: row.get::<Uuid, _>("space_id").to_string(),
        sender_id: row.get("sender_id"),
        sender_username: row.try_get("sender_username").ok(),
        content: row.get("content"),
        reply_to_message_id: row.get("reply_to_message_id"),
        created_at: row.get::<DateTime<Utc>, _>("created_at").to_rfc3339(),
    }
}

fn row_to_call(row: sqlx::postgres::PgRow) -> CallView {
    CallView {
        id: row.get::<Uuid, _>("id").to_string(),
        conversation_id: row.get::<Uuid, _>("conversation_id").to_string(),
        caller_id: row.get("caller_id"),
        callee_id: row.get("callee_id"),
        media: row.get("media"),
        state: row.get("state"),
        offer_sdp: row.get("offer_sdp"),
        answer_sdp: row.get("answer_sdp"),
        created_at: row.get::<DateTime<Utc>, _>("created_at").to_rfc3339(),
    }
}

#[derive(Clone)]
pub struct ChatSpaceService {
    pool: PgPool,
}

impl ChatSpaceService {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn create_space(
        &self,
        campus_id: Uuid,
        kind: &str,
        name: &str,
        description: Option<&str>,
        owner_id: &str,
    ) -> Result<Uuid, ApiError> {
        let mut tx = self.pool.begin().await.map_err(db_error)?;
        let row = sqlx::query(
            "INSERT INTO chat_spaces (campus_id, kind, name, description, owner_id)
             VALUES ($1, $2, $3, $4, $5)
             RETURNING id",
        )
        .bind(campus_id)
        .bind(kind)
        .bind(name)
        .bind(description)
        .bind(owner_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(db_error)?;
        let space_id: Uuid = row.get("id");
        sqlx::query(
            "INSERT INTO chat_space_members (space_id, user_id, role)
             VALUES ($1, $2, 'owner')",
        )
        .bind(space_id)
        .bind(owner_id)
        .execute(&mut *tx)
        .await
        .map_err(db_error)?;
        tx.commit().await.map_err(db_error)?;
        Ok(space_id)
    }

    pub async fn list_space_ids(
        &self,
        user_id: &str,
        campus_id: Uuid,
        kind: Option<&str>,
        limit: i64,
        offset: i64,
    ) -> Result<Vec<Uuid>, ApiError> {
        let rows = sqlx::query(
            "SELECT s.id
             FROM chat_spaces s
             JOIN chat_space_members m ON m.space_id = s.id AND m.user_id = $1
             WHERE s.status = 'active'
               AND s.campus_id = $2
               AND s.kind = 'group'
               AND m.role <> 'banned'
               AND ($3::TEXT IS NULL OR s.kind = $3)
             ORDER BY s.updated_at DESC
             LIMIT $4 OFFSET $5",
        )
        .bind(user_id)
        .bind(campus_id)
        .bind(kind)
        .bind(limit)
        .bind(offset)
        .fetch_all(&self.pool)
        .await
        .map_err(db_error)?;

        Ok(rows.into_iter().map(|r| r.get("id")).collect())
    }

    pub async fn load_space_view(
        &self,
        space_id: Uuid,
        user_id: &str,
    ) -> Result<SpaceView, ApiError> {
        let row = sqlx::query(
            "SELECT s.id, s.kind, s.name, s.description, s.owner_id,
                    m.role AS my_role,
                    (SELECT COUNT(*)::BIGINT FROM chat_space_members sm WHERE sm.space_id = s.id AND sm.role <> 'banned') AS member_count,
                    (SELECT COUNT(*)::BIGINT FROM chat_space_presence presence
                      WHERE presence.space_id = s.id
                        AND presence.expires_at > NOW()
                        AND NOT EXISTS (
                            SELECT 1 FROM chat_space_members banned
                             WHERE banned.space_id = presence.space_id
                               AND banned.user_id = presence.user_id
                               AND banned.role = 'banned'
                        )) AS online_count,
                    s.created_at, s.updated_at
             FROM chat_spaces s
             LEFT JOIN chat_space_members m ON m.space_id = s.id AND m.user_id = $2
             WHERE s.id = $1",
        )
        .bind(space_id)
        .bind(user_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::NotFound)?;

        Ok(SpaceView {
            id: row.get::<Uuid, _>("id").to_string(),
            kind: row.get("kind"),
            name: row.get("name"),
            description: row.get("description"),
            owner_id: row.get("owner_id"),
            my_role: row
                .get::<Option<String>, _>("my_role")
                .unwrap_or_else(|| "visitor".to_string()),
            member_count: row.get("member_count"),
            online_count: row.get("online_count"),
            created_at: row.get::<DateTime<Utc>, _>("created_at").to_rfc3339(),
            updated_at: row.get::<DateTime<Utc>, _>("updated_at").to_rfc3339(),
        })
    }

    pub async fn add_space_member(
        &self,
        space_id: Uuid,
        user_id: &str,
        role: &str,
    ) -> Result<(), ApiError> {
        sqlx::query(
            "INSERT INTO chat_space_members (space_id, user_id, role)
             VALUES ($1, $2, $3)
             ON CONFLICT (space_id, user_id)
             DO UPDATE SET role = EXCLUDED.role, joined_at = NOW()",
        )
        .bind(space_id)
        .bind(user_id)
        .bind(role)
        .execute(&self.pool)
        .await
        .map_err(db_error)?;

        Ok(())
    }

    pub async fn remove_space_member(
        &self,
        space_id: Uuid,
        target_user_id: &str,
    ) -> Result<(), ApiError> {
        sqlx::query("DELETE FROM chat_space_members WHERE space_id = $1 AND user_id = $2")
            .bind(space_id)
            .bind(target_user_id)
            .execute(&self.pool)
            .await
            .map_err(db_error)?;

        Ok(())
    }

    pub async fn is_root_topic(&self, reply_to: i64, space_id: Uuid) -> Result<bool, ApiError> {
        let is_root: bool = sqlx::query_scalar(
            "SELECT EXISTS(
                 SELECT 1
                 FROM chat_space_messages
                 WHERE id = $1
                   AND space_id = $2
                   AND reply_to_message_id IS NULL
             )",
        )
        .bind(reply_to)
        .bind(space_id)
        .fetch_one(&self.pool)
        .await
        .map_err(db_error)?;

        Ok(is_root)
    }

    pub async fn send_space_message(
        &self,
        space_id: Uuid,
        client_message_id: Uuid,
        user_id: &str,
        content: &str,
        reply_to_message_id: Option<i64>,
    ) -> Result<SpaceMessageView, ApiError> {
        let row = sqlx::query(
            "WITH saved AS (
                 INSERT INTO chat_space_messages (
                     space_id, client_message_id, sender_id, content, reply_to_message_id
                 )
                 VALUES ($1, $2, $3, $4, $5)
                 ON CONFLICT (space_id, sender_id, client_message_id)
                 DO UPDATE SET content = chat_space_messages.content
                 RETURNING id, space_id, sender_id, content, reply_to_message_id, created_at
             )
             SELECT saved.id, saved.space_id, saved.sender_id, u.username AS sender_username,
                    saved.content, saved.reply_to_message_id, saved.created_at
             FROM saved
             LEFT JOIN users u ON u.id = saved.sender_id",
        )
        .bind(space_id)
        .bind(client_message_id)
        .bind(user_id)
        .bind(content)
        .bind(reply_to_message_id)
        .fetch_one(&self.pool)
        .await
        .map_err(db_error)?;

        sqlx::query("UPDATE chat_spaces SET updated_at = NOW() WHERE id = $1")
            .bind(space_id)
            .execute(&self.pool)
            .await
            .map_err(db_error)?;

        Ok(row_to_space_message(row))
    }

    pub async fn list_space_messages(
        &self,
        space_id: Uuid,
        limit: i64,
        offset: i64,
    ) -> Result<Vec<SpaceMessageView>, ApiError> {
        let rows = sqlx::query(
            "SELECT m.id, m.space_id, m.sender_id, u.username AS sender_username,
                    m.content, m.reply_to_message_id, m.created_at
             FROM chat_space_messages m
             LEFT JOIN users u ON u.id = m.sender_id
             WHERE m.space_id = $1
             ORDER BY m.created_at DESC, m.id DESC
             LIMIT $2 OFFSET $3",
        )
        .bind(space_id)
        .bind(limit)
        .bind(offset)
        .fetch_all(&self.pool)
        .await
        .map_err(db_error)?;

        Ok(rows.into_iter().map(row_to_space_message).collect())
    }

    pub async fn create_call(
        &self,
        conversation_id: Uuid,
        caller_id: &str,
        callee_id: &str,
        media: &str,
        offer_sdp: &str,
    ) -> Result<CallView, ApiError> {
        let row = sqlx::query(
            "INSERT INTO chat_calls (conversation_id, caller_id, callee_id, media, offer_sdp)
             VALUES ($1, $2, $3, $4, $5)
             RETURNING id, conversation_id, caller_id, callee_id, media, state, offer_sdp, answer_sdp, created_at",
        )
        .bind(conversation_id)
        .bind(caller_id)
        .bind(callee_id)
        .bind(media)
        .bind(offer_sdp)
        .fetch_one(&self.pool)
        .await
        .map_err(db_error)?;

        Ok(row_to_call(row))
    }

    pub async fn answer_call(
        &self,
        call_id: Uuid,
        user_id: &str,
        answer_sdp: &str,
    ) -> Result<CallView, ApiError> {
        let row = sqlx::query(
            "UPDATE chat_calls
             SET state = 'accepted', answer_sdp = $1, answered_at = NOW()
             WHERE id = $2 AND callee_id = $3 AND state = 'ringing'
             RETURNING id, conversation_id, caller_id, callee_id, media, state, offer_sdp, answer_sdp, created_at",
        )
        .bind(answer_sdp)
        .bind(call_id)
        .bind(user_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::NotFound)?;

        Ok(row_to_call(row))
    }

    pub async fn end_call(
        &self,
        call_id: Uuid,
        user_id: &str,
        reason: &str,
    ) -> Result<CallView, ApiError> {
        let row = sqlx::query(
            "UPDATE chat_calls
             SET state = 'ended', ended_reason = $1, ended_at = NOW()
             WHERE id = $2 AND (caller_id = $3 OR callee_id = $3) AND state <> 'ended'
             RETURNING id, conversation_id, caller_id, callee_id, media, state, offer_sdp, answer_sdp, created_at",
        )
        .bind(reason)
        .bind(call_id)
        .bind(user_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::NotFound)?;

        Ok(row_to_call(row))
    }

    pub async fn get_member_role(
        &self,
        space_id: Uuid,
        user_id: &str,
    ) -> Result<Option<String>, ApiError> {
        sqlx::query_scalar(
            "SELECT role FROM chat_space_members WHERE space_id = $1 AND user_id = $2",
        )
        .bind(space_id)
        .bind(user_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(db_error)
    }

    pub async fn load_space_campus(&self, space_id: Uuid) -> Result<Uuid, ApiError> {
        sqlx::query_scalar("SELECT campus_id FROM chat_spaces WHERE id = $1")
            .bind(space_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(db_error)?
            .ok_or(ApiError::NotFound)
    }

    pub async fn list_broadcast_user_ids(&self, space_id: Uuid) -> Result<Vec<String>, ApiError> {
        let rows = sqlx::query(
            "SELECT user_id
               FROM chat_space_members
              WHERE space_id = $1 AND role <> 'banned'
             UNION
             SELECT user_id
               FROM chat_space_presence presence
              WHERE presence.space_id = $1
                AND presence.expires_at > NOW()
                AND NOT EXISTS (
                    SELECT 1 FROM chat_space_members banned
                     WHERE banned.space_id = presence.space_id
                       AND banned.user_id = presence.user_id
                       AND banned.role = 'banned'
                )
                AND EXISTS (
                    SELECT 1
                      FROM chat_spaces location
                     WHERE location.id = presence.space_id
                       AND location.origin IN ('campus_location', 'location_child')
                )",
        )
        .bind(space_id)
        .fetch_all(&self.pool)
        .await
        .map_err(db_error)?;

        Ok(rows.into_iter().map(|r| r.get("user_id")).collect())
    }

    pub async fn load_active_realtime_conversation(
        &self,
        conversation_id: Uuid,
    ) -> Result<(String, String), ApiError> {
        let row = sqlx::query(
            "SELECT initiator_id, recipient_id
             FROM chat_conversations
             WHERE id = $1 AND mode = 'realtime' AND state = 'active'",
        )
        .bind(conversation_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::Conflict(
            "call_requires_active_realtime".to_string(),
        ))?;

        Ok((row.get("initiator_id"), row.get("recipient_id")))
    }
}
