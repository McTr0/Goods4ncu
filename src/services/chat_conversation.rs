use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::{FromRow, PgPool, Postgres, Row, Transaction};
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::services::moderation_case::create_case_for_report;
use crate::utils::cents_to_yuan;

pub const INVITE_TTL_MINUTES: i64 = 10;
pub const ACK_TTL_MINUTES: i64 = 5;
pub const ACTIVE_IDLE_HOURS: i64 = 24;
pub const DAILY_CONVERSATION_LIMIT: i64 = 20;
pub const SAME_RECIPIENT_DAILY_LIMIT: i64 = 3;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConversationMode {
    Realtime,
    Mail,
}

impl ConversationMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Realtime => "realtime",
            Self::Mail => "mail",
        }
    }

    fn parse(value: &str) -> Result<Self, ApiError> {
        match value {
            "realtime" => Ok(Self::Realtime),
            "mail" => Ok(Self::Mail),
            _ => Err(ApiError::Internal(anyhow::anyhow!(
                "unknown conversation mode"
            ))),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConversationState {
    SynSent,
    SynAck,
    Active,
    Declined,
    Cancelled,
    Expired,
    Closed,
    Open,
}

impl ConversationState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::SynSent => "syn_sent",
            Self::SynAck => "syn_ack",
            Self::Active => "active",
            Self::Declined => "declined",
            Self::Cancelled => "cancelled",
            Self::Expired => "expired",
            Self::Closed => "closed",
            Self::Open => "open",
        }
    }

    fn parse(value: &str) -> Result<Self, ApiError> {
        match value {
            "syn_sent" => Ok(Self::SynSent),
            "syn_ack" => Ok(Self::SynAck),
            "active" => Ok(Self::Active),
            "declined" => Ok(Self::Declined),
            "cancelled" => Ok(Self::Cancelled),
            "expired" => Ok(Self::Expired),
            "closed" => Ok(Self::Closed),
            "open" => Ok(Self::Open),
            _ => Err(ApiError::Internal(anyhow::anyhow!(
                "unknown conversation state"
            ))),
        }
    }

    pub fn is_live_realtime(self) -> bool {
        matches!(self, Self::SynSent | Self::SynAck | Self::Active)
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct ConversationCapabilities {
    pub can_respond: bool,
    pub can_ack: bool,
    pub can_send: bool,
    pub can_close: bool,
    pub can_archive: bool,
    pub can_restart: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct ConversationView {
    pub id: String,
    pub mode: ConversationMode,
    pub state: ConversationState,
    pub initiator_id: String,
    pub recipient_id: String,
    pub other_user_id: String,
    pub other_username: String,
    pub listing_id: Option<String>,
    pub listing_title: Option<String>,
    pub subject: Option<String>,
    pub last_message: Option<String>,
    pub last_message_at: Option<String>,
    pub archived: bool,
    pub expires_at: Option<String>,
    pub established_at: Option<String>,
    pub closed_at: Option<String>,
    pub close_reason: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub version: i32,
    pub is_initiator: bool,
    pub is_blocked: bool,
    pub capabilities: ConversationCapabilities,
}

#[derive(Debug, Clone, Serialize)]
pub struct ChatThreadView {
    pub peer_user_id: String,
    pub peer_username: String,
    pub latest_activity_at: String,
    pub latest_preview: Option<String>,
    pub conversation_count: i64,
    pub mail_count: i64,
    pub realtime_count: i64,
    pub pending_count: i64,
    pub has_active_realtime: bool,
    pub latest_listing_title: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ChatThreadDetail {
    pub thread: ChatThreadView,
    pub conversations: Vec<ConversationView>,
}

#[derive(Debug, Clone)]
pub struct CreateConversationInput {
    pub client_request_id: Uuid,
    pub campus_id: Uuid,
    pub initiator_id: String,
    pub recipient_id: String,
    pub listing_id: Option<String>,
    pub mode: ConversationMode,
    pub subject: Option<String>,
    pub content: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct CreateConversationResult {
    pub conversation: ConversationView,
    pub created: bool,
    pub mutual_open: bool,
    /// Whether the recipient's current contact mute allows an interrupting
    /// notification.  The conversation itself is still persisted when false.
    pub notify_recipient: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct ConnectionPreferencesView {
    pub allow_strangers: bool,
    pub busy_until: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ContactPermissionView {
    pub peer_user_id: String,
    pub allow_connection: bool,
    pub muted_until: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConversationDecision {
    Accept,
    Decline,
}

#[derive(Debug, Clone)]
pub struct SendConversationMessageInput {
    pub client_message_id: Uuid,
    pub conversation_id: Uuid,
    pub sender_id: String,
    pub content: String,
    pub reply_to_message_id: Option<i64>,
    pub quote: Option<StructuredQuoteInput>,
    pub image_data: Option<String>,
    pub audio_data: Option<String>,
    pub image_url: Option<String>,
    pub audio_url: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StructuredQuoteKind {
    Listing,
    Order,
    HitlOffer,
}

impl StructuredQuoteKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Listing => "listing",
            Self::Order => "order",
            Self::HitlOffer => "hitl_offer",
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct StructuredQuoteInput {
    pub kind: StructuredQuoteKind,
    pub ref_id: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct StructuredQuote {
    pub kind: String,
    pub ref_id: String,
    pub snapshot: Value,
}

#[derive(Debug, Clone, Serialize)]
pub struct MessageReplyPreview {
    pub id: i64,
    pub sender: String,
    pub content: String,
    pub kind: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct MessageReactionSummary {
    pub emoji: String,
    pub count: i64,
    pub reacted_by_me: bool,
}

/// An acknowledgement is an explicit action by the recipient, not a read
/// receipt inferred from transport or UI activity.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AcknowledgementKind {
    Received,
    WillReview,
    Completed,
}

impl AcknowledgementKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Received => "received",
            Self::WillReview => "will_review",
            Self::Completed => "completed",
        }
    }

    fn parse(value: &str) -> Result<Self, ApiError> {
        match value {
            "received" => Ok(Self::Received),
            "will_review" => Ok(Self::WillReview),
            "completed" => Ok(Self::Completed),
            _ => Err(ApiError::Internal(anyhow::anyhow!(
                "unknown message acknowledgement kind"
            ))),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct MessageAcknowledgement {
    pub user_id: String,
    pub kind: AcknowledgementKind,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ConversationMessageRecord {
    pub id: i64,
    pub client_message_id: Option<String>,
    pub conversation_id: String,
    pub sender: String,
    pub content: String,
    pub reply_to_message_id: Option<i64>,
    pub reply_preview: Option<MessageReplyPreview>,
    pub quote: Option<StructuredQuote>,
    pub reactions: Vec<MessageReactionSummary>,
    pub acknowledgements: Vec<MessageAcknowledgement>,
    pub hidden_for_me: bool,
    pub can_hide: bool,
    pub can_react: bool,
    pub can_report: bool,
    pub timestamp: String,
    pub image_data: Option<String>,
    pub audio_data: Option<String>,
    pub image_url: Option<String>,
    pub audio_url: Option<String>,
    pub status: String,
    pub kind: String,
    pub edited_at: Option<String>,
}

#[derive(Debug, Clone, FromRow)]
struct ConversationRow {
    id: Uuid,
    mode: String,
    state: String,
    initiator_id: String,
    recipient_id: String,
    listing_id: Option<String>,
    subject: Option<String>,
    invite_expires_at: Option<DateTime<Utc>>,
    ack_expires_at: Option<DateTime<Utc>>,
    idle_expires_at: Option<DateTime<Utc>>,
    established_at: Option<DateTime<Utc>>,
    closed_at: Option<DateTime<Utc>>,
    close_reason: Option<String>,
    version: i32,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

struct DirectMessageContext {
    other_user_id: String,
}

impl ConversationRow {
    fn mode(&self) -> Result<ConversationMode, ApiError> {
        ConversationMode::parse(&self.mode)
    }

    fn state(&self) -> Result<ConversationState, ApiError> {
        ConversationState::parse(&self.state)
    }

    fn ensure_participant(&self, user_id: &str) -> Result<(), ApiError> {
        if user_id == self.initiator_id || user_id == self.recipient_id {
            Ok(())
        } else {
            Err(ApiError::Forbidden)
        }
    }

    fn other_user_id<'a>(&'a self, user_id: &str) -> Result<&'a str, ApiError> {
        self.ensure_participant(user_id)?;
        if user_id == self.initiator_id {
            Ok(&self.recipient_id)
        } else {
            Ok(&self.initiator_id)
        }
    }

    fn expiry_at(&self) -> Option<DateTime<Utc>> {
        match self.state.as_str() {
            "syn_sent" => self.invite_expires_at,
            "syn_ack" => self.ack_expires_at,
            "active" => self.idle_expires_at,
            _ => None,
        }
    }
}

#[derive(Clone)]
pub struct ChatConversationService {
    pool: PgPool,
}

impl ChatConversationService {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn get_connection_preferences(
        &self,
        user_id: &str,
    ) -> Result<ConnectionPreferencesView, ApiError> {
        let row = sqlx::query(
            "SELECT allow_strangers, busy_until
             FROM chat_connection_preferences
             WHERE user_id = $1",
        )
        .bind(user_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(db_error)?;
        Ok(ConnectionPreferencesView {
            allow_strangers: row
                .as_ref()
                .map(|value| value.get("allow_strangers"))
                .unwrap_or(false),
            busy_until: row
                .and_then(|value| value.get::<Option<DateTime<Utc>>, _>("busy_until"))
                .map(|value| value.to_rfc3339()),
        })
    }

    pub async fn set_connection_preferences(
        &self,
        user_id: &str,
        allow_strangers: bool,
        busy_until: Option<DateTime<Utc>>,
    ) -> Result<ConnectionPreferencesView, ApiError> {
        let busy_until = busy_until.filter(|value| *value > Utc::now());
        sqlx::query(
            "INSERT INTO chat_connection_preferences (user_id, allow_strangers, busy_until)
             VALUES ($1, $2, $3)
             ON CONFLICT (user_id) DO UPDATE
             SET allow_strangers = EXCLUDED.allow_strangers,
                 busy_until = EXCLUDED.busy_until,
                 updated_at = NOW()",
        )
        .bind(user_id)
        .bind(allow_strangers)
        .bind(busy_until)
        .execute(&self.pool)
        .await
        .map_err(db_error)?;
        self.get_connection_preferences(user_id).await
    }

    pub async fn list_contact_permissions(
        &self,
        owner_id: &str,
    ) -> Result<Vec<ContactPermissionView>, ApiError> {
        let rows = sqlx::query(
            "SELECT peer_id, allow_connection, muted_until
             FROM chat_contact_permissions
             WHERE owner_id = $1
             ORDER BY updated_at DESC, peer_id ASC",
        )
        .bind(owner_id)
        .fetch_all(&self.pool)
        .await
        .map_err(db_error)?;
        Ok(rows
            .into_iter()
            .map(|row| ContactPermissionView {
                peer_user_id: row.get("peer_id"),
                allow_connection: row.get("allow_connection"),
                muted_until: row
                    .get::<Option<DateTime<Utc>>, _>("muted_until")
                    .map(|value| value.to_rfc3339()),
            })
            .collect())
    }

    pub async fn set_contact_permission(
        &self,
        owner_id: &str,
        peer_id: &str,
        allow_connection: bool,
        muted_until: Option<DateTime<Utc>>,
    ) -> Result<ContactPermissionView, ApiError> {
        if owner_id == peer_id {
            return Err(ApiError::BadRequest("不能设置自己的联系人权限".to_string()));
        }
        let peer_exists: bool =
            sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM users WHERE id = $1)")
                .bind(peer_id)
                .fetch_one(&self.pool)
                .await
                .map_err(db_error)?;
        if !peer_exists {
            return Err(ApiError::NotFound);
        }
        let muted_until = muted_until.filter(|value| *value > Utc::now());
        let row = sqlx::query(
            "INSERT INTO chat_contact_permissions (
                owner_id, peer_id, allow_connection, muted_until
             ) VALUES ($1, $2, $3, $4)
             ON CONFLICT (owner_id, peer_id) DO UPDATE
             SET allow_connection = EXCLUDED.allow_connection,
                 muted_until = EXCLUDED.muted_until,
                 updated_at = NOW()
             RETURNING peer_id, allow_connection, muted_until",
        )
        .bind(owner_id)
        .bind(peer_id)
        .bind(allow_connection)
        .bind(muted_until)
        .fetch_one(&self.pool)
        .await
        .map_err(db_error)?;
        Ok(ContactPermissionView {
            peer_user_id: row.get("peer_id"),
            allow_connection: row.get("allow_connection"),
            muted_until: row
                .get::<Option<DateTime<Utc>>, _>("muted_until")
                .map(|value| value.to_rfc3339()),
        })
    }

    pub async fn delete_contact_permission(
        &self,
        owner_id: &str,
        peer_id: &str,
    ) -> Result<(), ApiError> {
        sqlx::query(
            "DELETE FROM chat_contact_permissions
             WHERE owner_id = $1 AND peer_id = $2",
        )
        .bind(owner_id)
        .bind(peer_id)
        .execute(&self.pool)
        .await
        .map_err(db_error)?;
        Ok(())
    }

    pub async fn create_conversation(
        &self,
        input: CreateConversationInput,
    ) -> Result<CreateConversationResult, ApiError> {
        validate_create_input(&input)?;
        if input.initiator_id == input.recipient_id {
            return Err(ApiError::BadRequest("不能联系自己".to_string()));
        }

        let mut tx = self.begin().await?;

        let same_campus: bool = sqlx::query_scalar(
            "SELECT EXISTS(
                SELECT 1
                FROM campus_memberships initiator
                JOIN campus_memberships recipient
                  ON recipient.campus_id = initiator.campus_id
                 AND recipient.user_id = $2
                 AND recipient.status = 'verified'
                JOIN campuses c ON c.id = initiator.campus_id AND c.status = 'active'
                WHERE initiator.user_id = $1
                  AND initiator.campus_id = $3
                  AND initiator.status = 'verified'
             )",
        )
        .bind(&input.initiator_id)
        .bind(&input.recipient_id)
        .bind(input.campus_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(db_error)?;
        if !same_campus {
            return Err(ApiError::CampusScopeMismatch);
        }
        if let Some(listing_id) = input.listing_id.as_deref() {
            let listing_status = sqlx::query_scalar::<_, String>(
                "SELECT status FROM inventory
                 WHERE id = $1 AND campus_id = $2 FOR UPDATE",
            )
            .bind(listing_id)
            .bind(input.campus_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(db_error)?;
            let restricted: bool = sqlx::query_scalar("SELECT listing_has_active_restriction($1)")
                .bind(listing_id)
                .fetch_one(&mut *tx)
                .await
                .map_err(db_error)?;
            if listing_status.as_deref() != Some("active") || restricted {
                return Err(ApiError::CampusScopeMismatch);
            }
        }

        if let Some(existing_id) = sqlx::query_scalar::<_, Uuid>(
            "SELECT id FROM chat_conversations
             WHERE initiator_id = $1 AND client_request_id = $2 AND campus_id = $3",
        )
        .bind(&input.initiator_id)
        .bind(input.client_request_id)
        .bind(input.campus_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(db_error)?
        {
            let notify_recipient =
                !recipient_has_muted_contact(&mut tx, &input.recipient_id, &input.initiator_id)
                    .await?;
            tx.commit().await.map_err(commit_error)?;
            let conversation = self
                .get_conversation(existing_id, &input.initiator_id)
                .await?;
            return Ok(CreateConversationResult {
                conversation,
                created: false,
                mutual_open: false,
                notify_recipient,
            });
        }

        let recipient_exists: bool =
            sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM users WHERE id = $1)")
                .bind(&input.recipient_id)
                .fetch_one(&mut *tx)
                .await
                .map_err(db_error)?;
        if !recipient_exists {
            return Err(ApiError::NotFound);
        }
        if pair_is_blocked(&mut tx, &input.initiator_id, &input.recipient_id).await? {
            return Err(ApiError::Conflict("conversation_unavailable".to_string()));
        }

        if input.mode == ConversationMode::Realtime {
            lock_realtime_pair(
                &mut tx,
                input.campus_id,
                &input.initiator_id,
                &input.recipient_id,
            )
            .await?;
            if let Some(existing) = find_live_realtime(
                &mut tx,
                &input.initiator_id,
                &input.recipient_id,
                input.listing_id.as_deref(),
                input.campus_id,
            )
            .await?
            {
                if existing.state == "syn_sent"
                    && existing.initiator_id == input.recipient_id
                    && existing.recipient_id == input.initiator_id
                {
                    insert_message(
                        &mut tx,
                        existing.id,
                        input.client_request_id,
                        input.listing_id.as_deref(),
                        &input.initiator_id,
                        &input.recipient_id,
                        &input.content,
                        "opening",
                        None,
                        None,
                        None,
                        None,
                        None,
                        None,
                    )
                    .await?;
                    let now = Utc::now();
                    sqlx::query(
                        "UPDATE chat_conversations
                         SET state = 'active', established_at = $1,
                             idle_expires_at = $2, invite_expires_at = NULL,
                             last_activity_at = $1, updated_at = $1, version = version + 1
                         WHERE id = $3",
                    )
                    .bind(now)
                    .bind(now + Duration::hours(ACTIVE_IDLE_HOURS))
                    .bind(existing.id)
                    .execute(&mut *tx)
                    .await
                    .map_err(db_error)?;
                    insert_event(
                        &mut tx,
                        existing.id,
                        Some(&input.initiator_id),
                        "mutual_open",
                        Some("syn_sent"),
                        "active",
                    )
                    .await?;
                    let notify_recipient = !recipient_has_muted_contact(
                        &mut tx,
                        &input.recipient_id,
                        &input.initiator_id,
                    )
                    .await?;
                    tx.commit().await.map_err(commit_error)?;
                    let conversation = self
                        .get_conversation(existing.id, &input.initiator_id)
                        .await?;
                    return Ok(CreateConversationResult {
                        conversation,
                        created: false,
                        mutual_open: true,
                        notify_recipient,
                    });
                }

                let notify_recipient =
                    !recipient_has_muted_contact(&mut tx, &input.recipient_id, &input.initiator_id)
                        .await?;
                tx.commit().await.map_err(commit_error)?;
                let conversation = self
                    .get_conversation(existing.id, &input.initiator_id)
                    .await?;
                return Ok(CreateConversationResult {
                    conversation,
                    created: false,
                    mutual_open: false,
                    notify_recipient,
                });
            }
        }

        let notify_recipient = if input.mode == ConversationMode::Realtime {
            evaluate_connection_request(&mut tx, &input.initiator_id, &input.recipient_id).await?
        } else {
            !recipient_has_muted_contact(&mut tx, &input.recipient_id, &input.initiator_id).await?
        };

        enforce_creation_limits(&mut tx, &input.initiator_id, &input.recipient_id).await?;

        let now = Utc::now();
        let conversation_id = Uuid::new_v4();
        let (state, invite_expires_at) = match input.mode {
            ConversationMode::Realtime => (
                ConversationState::SynSent,
                Some(now + Duration::minutes(INVITE_TTL_MINUTES)),
            ),
            ConversationMode::Mail => (ConversationState::Open, None),
        };

        sqlx::query(
            "INSERT INTO chat_conversations (
                id, client_request_id, campus_id, mode, state, initiator_id, recipient_id,
                listing_id, subject, invite_expires_at, last_activity_at, created_at, updated_at
             ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $11, $11)",
        )
        .bind(conversation_id)
        .bind(input.client_request_id)
        .bind(input.campus_id)
        .bind(input.mode.as_str())
        .bind(state.as_str())
        .bind(&input.initiator_id)
        .bind(&input.recipient_id)
        .bind(input.listing_id.as_deref())
        .bind(input.subject.as_deref())
        .bind(invite_expires_at)
        .bind(now)
        .execute(&mut *tx)
        .await
        .map_err(db_error)?;

        sqlx::query(
            "INSERT INTO chat_conversation_members (conversation_id, user_id)
             VALUES ($1, $2), ($1, $3)",
        )
        .bind(conversation_id)
        .bind(&input.initiator_id)
        .bind(&input.recipient_id)
        .execute(&mut *tx)
        .await
        .map_err(db_error)?;

        insert_message(
            &mut tx,
            conversation_id,
            input.client_request_id,
            input.listing_id.as_deref(),
            &input.initiator_id,
            &input.recipient_id,
            &input.content,
            "opening",
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await?;
        insert_event(
            &mut tx,
            conversation_id,
            Some(&input.initiator_id),
            "conversation_created",
            None,
            state.as_str(),
        )
        .await?;

        tx.commit().await.map_err(commit_error)?;
        let conversation = self
            .get_conversation(conversation_id, &input.initiator_id)
            .await?;
        Ok(CreateConversationResult {
            conversation,
            created: true,
            mutual_open: false,
            notify_recipient,
        })
    }

    pub async fn list_conversations(
        &self,
        user_id: &str,
        mode: Option<ConversationMode>,
        cursor: Option<Uuid>,
        limit: i64,
    ) -> Result<(Vec<ConversationView>, Option<String>), ApiError> {
        let limit = limit.clamp(1, 50);
        let rows = sqlx::query(
            r#"
            SELECT c.id
            FROM chat_conversations c
            JOIN chat_conversation_members member
              ON member.conversation_id = c.id AND member.user_id = $1
            WHERE member.archived_at IS NULL
              AND ($2::text IS NULL OR c.mode = $2)
              AND (
                $3::uuid IS NULL OR
                (c.last_activity_at, c.id) < (
                    SELECT anchor.last_activity_at, anchor.id
                    FROM chat_conversations anchor WHERE anchor.id = $3::uuid
                )
              )
            ORDER BY c.last_activity_at DESC, c.id DESC
            LIMIT $4
            "#,
        )
        .bind(user_id)
        .bind(mode.map(ConversationMode::as_str))
        .bind(cursor)
        .bind(limit + 1)
        .fetch_all(&self.pool)
        .await
        .map_err(db_error)?;

        let has_more = rows.len() as i64 > limit;
        let ids: Vec<Uuid> = rows
            .into_iter()
            .take(limit as usize)
            .map(|row| row.get("id"))
            .collect();
        let mut conversations = Vec::with_capacity(ids.len());
        for id in ids {
            conversations.push(self.get_conversation(id, user_id).await?);
        }
        let next_cursor = if has_more {
            conversations.last().map(|item| item.id.clone())
        } else {
            None
        };
        Ok((conversations, next_cursor))
    }

    pub async fn list_threads(
        &self,
        user_id: &str,
        mode: Option<ConversationMode>,
        limit: i64,
    ) -> Result<Vec<ChatThreadView>, ApiError> {
        let limit = limit.clamp(1, 50);
        let rows = sqlx::query(
            r#"
            WITH visible AS (
                SELECT c.id,
                       c.mode,
                       c.state,
                       c.initiator_id,
                       c.recipient_id,
                       c.last_activity_at,
                       CASE
                           WHEN c.initiator_id = $1 THEN c.recipient_id
                           ELSE c.initiator_id
                       END AS peer_user_id,
                       inventory.title AS listing_title,
                       latest.content AS latest_preview,
                       ROW_NUMBER() OVER (
                           PARTITION BY CASE
                               WHEN c.initiator_id = $1 THEN c.recipient_id
                               ELSE c.initiator_id
                           END
                           ORDER BY c.last_activity_at DESC, c.id DESC
                       ) AS recency_rank
                FROM chat_conversations c
                JOIN chat_conversation_members member
                  ON member.conversation_id = c.id AND member.user_id = $1
                LEFT JOIN inventory ON inventory.id = c.listing_id
                LEFT JOIN LATERAL (
                    SELECT content
                    FROM chat_messages
                    WHERE direct_conversation_id = c.id
                    ORDER BY timestamp DESC, id DESC
                    LIMIT 1
                ) latest ON TRUE
                WHERE member.archived_at IS NULL
                  AND ($2::text IS NULL OR c.mode = $2)
            )
            SELECT visible.peer_user_id,
                   COALESCE(peer.username, '') AS peer_username,
                   MAX(visible.last_activity_at) AS latest_activity_at,
                   MAX(visible.latest_preview) FILTER (WHERE visible.recency_rank = 1)
                       AS latest_preview,
                   COUNT(*)::bigint AS conversation_count,
                   COUNT(*) FILTER (WHERE visible.mode = 'mail')::bigint AS mail_count,
                   COUNT(*) FILTER (WHERE visible.mode = 'realtime')::bigint AS realtime_count,
                   COUNT(*) FILTER (
                       WHERE visible.mode = 'realtime'
                         AND visible.state = 'syn_sent'
                         AND visible.recipient_id = $1
                   )::bigint AS pending_count,
                   BOOL_OR(
                       visible.mode = 'realtime'
                       AND visible.state IN ('syn_sent', 'syn_ack', 'active')
                   ) AS has_active_realtime,
                   MAX(visible.listing_title) FILTER (WHERE visible.recency_rank = 1)
                       AS latest_listing_title
            FROM visible
            LEFT JOIN users peer ON peer.id = visible.peer_user_id
            GROUP BY visible.peer_user_id, peer.username
            ORDER BY
                (COUNT(*) FILTER (
                    WHERE visible.mode = 'realtime'
                      AND visible.state = 'syn_sent'
                      AND visible.recipient_id = $1
                )) DESC,
                MAX(visible.last_activity_at) DESC,
                visible.peer_user_id ASC
            LIMIT $3
            "#,
        )
        .bind(user_id)
        .bind(mode.map(ConversationMode::as_str))
        .bind(limit)
        .fetch_all(&self.pool)
        .await
        .map_err(db_error)?;

        Ok(rows
            .into_iter()
            .map(|row| {
                let latest_activity_at: DateTime<Utc> = row.get("latest_activity_at");
                ChatThreadView {
                    peer_user_id: row.get("peer_user_id"),
                    peer_username: row.get("peer_username"),
                    latest_activity_at: latest_activity_at.to_rfc3339(),
                    latest_preview: row.get("latest_preview"),
                    conversation_count: row.get("conversation_count"),
                    mail_count: row.get("mail_count"),
                    realtime_count: row.get("realtime_count"),
                    pending_count: row.get("pending_count"),
                    has_active_realtime: row.get("has_active_realtime"),
                    latest_listing_title: row.get("latest_listing_title"),
                }
            })
            .collect())
    }

    pub async fn get_thread(
        &self,
        user_id: &str,
        peer_user_id: &str,
        mode: Option<ConversationMode>,
    ) -> Result<ChatThreadDetail, ApiError> {
        let mut threads = self.list_threads(user_id, mode, 50).await?;
        let thread = threads
            .drain(..)
            .find(|item| item.peer_user_id == peer_user_id)
            .ok_or(ApiError::NotFound)?;

        let rows = sqlx::query(
            r#"
            SELECT c.id
            FROM chat_conversations c
            JOIN chat_conversation_members member
              ON member.conversation_id = c.id AND member.user_id = $1
            WHERE member.archived_at IS NULL
              AND ($3::text IS NULL OR c.mode = $3)
              AND (
                  CASE
                      WHEN c.initiator_id = $1 THEN c.recipient_id
                      ELSE c.initiator_id
                  END
              ) = $2
            ORDER BY c.last_activity_at DESC, c.id DESC
            LIMIT 50
            "#,
        )
        .bind(user_id)
        .bind(peer_user_id)
        .bind(mode.map(ConversationMode::as_str))
        .fetch_all(&self.pool)
        .await
        .map_err(db_error)?;

        let mut conversations = Vec::with_capacity(rows.len());
        for row in rows {
            let id: Uuid = row.get("id");
            conversations.push(self.get_conversation(id, user_id).await?);
        }

        Ok(ChatThreadDetail {
            thread,
            conversations,
        })
    }

    pub async fn get_conversation(
        &self,
        conversation_id: Uuid,
        user_id: &str,
    ) -> Result<ConversationView, ApiError> {
        let row = load_conversation(&self.pool, conversation_id).await?;
        row.ensure_participant(user_id)?;
        let state = row.state()?;
        let mode = row.mode()?;
        let other_user_id = row.other_user_id(user_id)?.to_string();

        let metadata = sqlx::query(
            r#"
            SELECT COALESCE(other_user.username, '') AS other_username,
                   inventory.title AS listing_title,
                   member.archived_at,
                   latest.content AS last_message,
                   latest.timestamp AS last_message_at,
                   EXISTS(
                       SELECT 1 FROM chat_blocks block
                       WHERE (block.blocker_id = $2 AND block.blocked_id = $3)
                          OR (block.blocker_id = $3 AND block.blocked_id = $2)
                   ) AS is_blocked
            FROM chat_conversations c
            JOIN chat_conversation_members member
              ON member.conversation_id = c.id AND member.user_id = $2
            LEFT JOIN users other_user ON other_user.id = $3
            LEFT JOIN inventory ON inventory.id = c.listing_id
            LEFT JOIN LATERAL (
                SELECT content, timestamp
                FROM chat_messages
                WHERE direct_conversation_id = c.id
                ORDER BY timestamp DESC, id DESC
                LIMIT 1
            ) latest ON TRUE
            WHERE c.id = $1
            "#,
        )
        .bind(conversation_id)
        .bind(user_id)
        .bind(&other_user_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::NotFound)?;

        let is_blocked: bool = metadata.get("is_blocked");
        let is_initiator = user_id == row.initiator_id;
        let can_send = !is_blocked
            && match mode {
                ConversationMode::Mail => state == ConversationState::Open,
                ConversationMode::Realtime => {
                    state == ConversationState::Active
                        || (state == ConversationState::SynAck && is_initiator)
                }
            };
        let expires_at = row.expiry_at().map(|value| value.to_rfc3339());
        let last_message_at: Option<DateTime<Utc>> = metadata.get("last_message_at");
        let archived_at: Option<DateTime<Utc>> = metadata.get("archived_at");
        let can_restart = !is_blocked
            && mode == ConversationMode::Realtime
            && matches!(
                state,
                ConversationState::Declined
                    | ConversationState::Cancelled
                    | ConversationState::Expired
                    | ConversationState::Closed
            );

        Ok(ConversationView {
            id: row.id.to_string(),
            mode,
            state,
            initiator_id: row.initiator_id,
            recipient_id: row.recipient_id,
            other_user_id,
            other_username: metadata.get("other_username"),
            listing_id: row.listing_id,
            listing_title: metadata.get("listing_title"),
            subject: row.subject,
            last_message: metadata.get("last_message"),
            last_message_at: last_message_at.map(|value| value.to_rfc3339()),
            archived: archived_at.is_some(),
            expires_at,
            established_at: row.established_at.map(|value| value.to_rfc3339()),
            closed_at: row.closed_at.map(|value| value.to_rfc3339()),
            close_reason: row.close_reason,
            created_at: row.created_at.to_rfc3339(),
            updated_at: row.updated_at.to_rfc3339(),
            version: row.version,
            is_initiator,
            is_blocked,
            capabilities: ConversationCapabilities {
                can_respond: !is_blocked
                    && mode == ConversationMode::Realtime
                    && state == ConversationState::SynSent
                    && !is_initiator,
                can_ack: !is_blocked
                    && mode == ConversationMode::Realtime
                    && state == ConversationState::SynAck
                    && is_initiator,
                can_send,
                can_close: !is_blocked
                    && mode == ConversationMode::Realtime
                    && state.is_live_realtime(),
                can_archive: true,
                can_restart,
            },
        })
    }

    pub async fn respond(
        &self,
        conversation_id: Uuid,
        user_id: &str,
        decision: ConversationDecision,
    ) -> Result<ConversationView, ApiError> {
        let mut tx = self.begin().await?;
        let mut row = load_conversation_for_update(&mut tx, conversation_id).await?;
        expire_if_due(&mut tx, &mut row).await?;
        if row.mode()? != ConversationMode::Realtime || row.state()? != ConversationState::SynSent {
            return Err(invalid_state(&row.state));
        }
        if row.recipient_id != user_id {
            return Err(ApiError::Forbidden);
        }
        if pair_is_blocked(&mut tx, &row.initiator_id, &row.recipient_id).await? {
            return Err(ApiError::Conflict("conversation_unavailable".to_string()));
        }

        let now = Utc::now();
        let (next_state, ack_expires_at, closed_at, close_reason, event_type) = match decision {
            ConversationDecision::Accept => (
                ConversationState::SynAck,
                Some(now + Duration::minutes(ACK_TTL_MINUTES)),
                None,
                None,
                "conversation_accepted",
            ),
            ConversationDecision::Decline => (
                ConversationState::Declined,
                None,
                Some(now),
                Some("recipient_unavailable"),
                "conversation_declined",
            ),
        };
        sqlx::query(
            "UPDATE chat_conversations
             SET state = $1, ack_expires_at = $2, invite_expires_at = NULL,
                 closed_at = $3, close_reason = $4,
                 updated_at = $5, version = version + 1
             WHERE id = $6",
        )
        .bind(next_state.as_str())
        .bind(ack_expires_at)
        .bind(closed_at)
        .bind(close_reason)
        .bind(now)
        .bind(conversation_id)
        .execute(&mut *tx)
        .await
        .map_err(db_error)?;
        insert_event(
            &mut tx,
            conversation_id,
            Some(user_id),
            event_type,
            Some("syn_sent"),
            next_state.as_str(),
        )
        .await?;
        tx.commit().await.map_err(commit_error)?;
        self.get_conversation(conversation_id, user_id).await
    }

    pub async fn acknowledge(
        &self,
        conversation_id: Uuid,
        user_id: &str,
    ) -> Result<ConversationView, ApiError> {
        let mut tx = self.begin().await?;
        let mut row = load_conversation_for_update(&mut tx, conversation_id).await?;
        expire_if_due(&mut tx, &mut row).await?;
        if row.mode()? != ConversationMode::Realtime || row.state()? != ConversationState::SynAck {
            return Err(invalid_state(&row.state));
        }
        if row.initiator_id != user_id {
            return Err(ApiError::Forbidden);
        }
        activate_realtime(&mut tx, &row, user_id, "conversation_acknowledged").await?;
        tx.commit().await.map_err(commit_error)?;
        self.get_conversation(conversation_id, user_id).await
    }

    pub async fn close(
        &self,
        conversation_id: Uuid,
        user_id: &str,
    ) -> Result<ConversationView, ApiError> {
        let mut tx = self.begin().await?;
        let mut row = load_conversation_for_update(&mut tx, conversation_id).await?;
        expire_if_due(&mut tx, &mut row).await?;
        row.ensure_participant(user_id)?;
        if row.mode()? != ConversationMode::Realtime || !row.state()?.is_live_realtime() {
            return Err(invalid_state(&row.state));
        }
        if row.state()? == ConversationState::SynSent && row.initiator_id != user_id {
            return Err(ApiError::Forbidden);
        }

        let next_state = if row.state()? == ConversationState::SynSent {
            ConversationState::Cancelled
        } else {
            ConversationState::Closed
        };
        let now = Utc::now();
        sqlx::query(
            "UPDATE chat_conversations
             SET state = $1, closed_at = $2, close_reason = 'user_closed',
                 invite_expires_at = NULL, ack_expires_at = NULL, idle_expires_at = NULL,
                 updated_at = $2, version = version + 1
             WHERE id = $3",
        )
        .bind(next_state.as_str())
        .bind(now)
        .bind(conversation_id)
        .execute(&mut *tx)
        .await
        .map_err(db_error)?;
        insert_event(
            &mut tx,
            conversation_id,
            Some(user_id),
            "conversation_closed",
            Some(&row.state),
            next_state.as_str(),
        )
        .await?;
        tx.commit().await.map_err(commit_error)?;
        self.get_conversation(conversation_id, user_id).await
    }

    pub async fn set_archived(
        &self,
        conversation_id: Uuid,
        user_id: &str,
        archived: bool,
    ) -> Result<ConversationView, ApiError> {
        let row = load_conversation(&self.pool, conversation_id).await?;
        row.ensure_participant(user_id)?;
        let result = sqlx::query(
            "UPDATE chat_conversation_members
             SET archived_at = CASE WHEN $1 THEN NOW() ELSE NULL END
             WHERE conversation_id = $2 AND user_id = $3",
        )
        .bind(archived)
        .bind(conversation_id)
        .bind(user_id)
        .execute(&self.pool)
        .await
        .map_err(db_error)?;
        if result.rows_affected() == 0 {
            return Err(ApiError::NotFound);
        }
        self.get_conversation(conversation_id, user_id).await
    }

    pub async fn send_message(
        &self,
        input: SendConversationMessageInput,
    ) -> Result<ConversationMessageRecord, ApiError> {
        if input.content.trim().is_empty() || input.content.chars().count() > 2000 {
            return Err(ApiError::BadRequest(
                "消息长度必须为 1 到 2000 字".to_string(),
            ));
        }
        let mut tx = self.begin().await?;
        let mut row = load_conversation_for_update(&mut tx, input.conversation_id).await?;
        expire_if_due(&mut tx, &mut row).await?;
        row.ensure_participant(&input.sender_id)?;
        let other_user_id = row.other_user_id(&input.sender_id)?.to_string();
        if pair_is_blocked(&mut tx, &input.sender_id, &other_user_id).await? {
            return Err(ApiError::Conflict("conversation_unavailable".to_string()));
        }

        let mode = row.mode()?;
        let state = row.state()?;
        if mode == ConversationMode::Realtime
            && state == ConversationState::SynAck
            && row.initiator_id == input.sender_id
        {
            activate_realtime(
                &mut tx,
                &row,
                &input.sender_id,
                "conversation_acknowledged_by_message",
            )
            .await?;
            row.state = "active".to_string();
        } else if !((mode == ConversationMode::Mail && state == ConversationState::Open)
            || (mode == ConversationMode::Realtime && state == ConversationState::Active))
        {
            return Err(invalid_state(&row.state));
        }

        if let Some(reply_to_message_id) = input.reply_to_message_id {
            ensure_reply_target(&mut tx, input.conversation_id, reply_to_message_id).await?;
        }
        let quote = if let Some(quote) = input.quote.as_ref() {
            Some(resolve_structured_quote(&mut tx, &row, &input.sender_id, quote).await?)
        } else {
            None
        };

        if let Some(existing) =
            find_message_by_client_id(&mut tx, &input.sender_id, input.client_message_id).await?
        {
            tx.commit().await.map_err(commit_error)?;
            let mut message = existing;
            enrich_message_for_user(&self.pool, &input.sender_id, &mut message).await?;
            return Ok(message);
        }

        let inserted = insert_message(
            &mut tx,
            input.conversation_id,
            input.client_message_id,
            row.listing_id.as_deref(),
            &input.sender_id,
            &other_user_id,
            &input.content,
            "message",
            input.reply_to_message_id,
            quote.as_ref(),
            input.image_data.as_deref(),
            input.audio_data.as_deref(),
            input.image_url.as_deref(),
            input.audio_url.as_deref(),
        )
        .await?;
        let now = Utc::now();
        let idle_expires_at = (mode == ConversationMode::Realtime)
            .then_some(now + Duration::hours(ACTIVE_IDLE_HOURS));
        sqlx::query(
            "UPDATE chat_conversations
             SET last_activity_at = $1, updated_at = $1,
                 idle_expires_at = CASE WHEN mode = 'realtime' THEN $2 ELSE idle_expires_at END,
                 version = version + 1
             WHERE id = $3",
        )
        .bind(now)
        .bind(idle_expires_at)
        .bind(input.conversation_id)
        .execute(&mut *tx)
        .await
        .map_err(db_error)?;
        tx.commit().await.map_err(commit_error)?;
        let mut message = inserted;
        enrich_message_for_user(&self.pool, &input.sender_id, &mut message).await?;
        Ok(message)
    }

    pub async fn get_messages(
        &self,
        conversation_id: Uuid,
        user_id: &str,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<ConversationMessageRecord>, i64), ApiError> {
        let row = load_conversation(&self.pool, conversation_id).await?;
        row.ensure_participant(user_id)?;
        let total: i64 = sqlx::query_scalar(
            "SELECT COUNT(*)
             FROM chat_messages cm
             WHERE cm.direct_conversation_id = $1
               AND NOT EXISTS (
                   SELECT 1 FROM chat_message_hidden_members h
                   WHERE h.message_id = cm.id AND h.user_id = $2
               )",
        )
        .bind(conversation_id)
        .bind(user_id)
        .fetch_one(&self.pool)
        .await
        .map_err(db_error)?;
        let rows = sqlx::query(
            "SELECT id, client_message_id, sender, content, reply_to_message_id, timestamp,
                    image_data, audio_data, image_url, audio_url, status, kind, edited_at,
                    quote_kind, quote_ref_id, quote_snapshot
             FROM chat_messages
             WHERE direct_conversation_id = $1
               AND NOT EXISTS (
                   SELECT 1 FROM chat_message_hidden_members h
                   WHERE h.message_id = chat_messages.id AND h.user_id = $4
               )
             ORDER BY timestamp DESC, id DESC
             LIMIT $2 OFFSET $3",
        )
        .bind(conversation_id)
        .bind(limit.clamp(1, 100))
        .bind(offset.max(0))
        .bind(user_id)
        .fetch_all(&self.pool)
        .await
        .map_err(db_error)?;

        let mut messages: Vec<ConversationMessageRecord> = rows
            .into_iter()
            .map(|message| row_to_message(message, conversation_id))
            .collect();
        for message in &mut messages {
            enrich_message_for_user(&self.pool, user_id, message).await?;
        }
        Ok((messages, total))
    }

    pub async fn edit_message(
        &self,
        message_id: i64,
        user_id: &str,
        content: &str,
    ) -> Result<ConversationMessageRecord, ApiError> {
        let content = content.trim();
        if content.is_empty() || content.chars().count() > 2000 {
            return Err(ApiError::BadRequest(
                "消息长度必须为 1 到 2000 字".to_string(),
            ));
        }
        let mut tx = self.begin().await?;
        let row = sqlx::query(
            "SELECT cm.direct_conversation_id, cm.sender, cm.kind, cm.timestamp,
                    c.mode, c.state
             FROM chat_messages cm
             JOIN chat_conversations c ON c.id = cm.direct_conversation_id
             WHERE cm.id = $1
             FOR UPDATE OF cm, c",
        )
        .bind(message_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::NotFound)?;
        let sender: String = row.get("sender");
        let kind: String = row.get("kind");
        let mode: String = row.get("mode");
        let state: String = row.get("state");
        let timestamp: DateTime<Utc> = row.get("timestamp");
        let conversation_id: Uuid = row.get("direct_conversation_id");
        if sender != user_id {
            return Err(ApiError::Forbidden);
        }
        if mode != "realtime" || state != "active" || kind != "message" {
            return Err(ApiError::Conflict("message_is_immutable".to_string()));
        }
        if Utc::now().signed_duration_since(timestamp) > Duration::minutes(15) {
            return Err(ApiError::BadRequest(
                "消息已超过 15 分钟，无法编辑".to_string(),
            ));
        }
        let updated = sqlx::query(
            "UPDATE chat_messages SET content = $1, edited_at = NOW()
             WHERE id = $2
             RETURNING id, client_message_id, sender, content, reply_to_message_id, timestamp,
                       image_data, audio_data, image_url, audio_url, status, kind, edited_at,
                       quote_kind, quote_ref_id, quote_snapshot",
        )
        .bind(content)
        .bind(message_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(db_error)?;
        tx.commit().await.map_err(commit_error)?;
        let mut message = row_to_message(updated, conversation_id);
        enrich_message_for_user(&self.pool, user_id, &mut message).await?;
        Ok(message)
    }

    pub async fn set_reaction(
        &self,
        message_id: i64,
        user_id: &str,
        emoji: &str,
    ) -> Result<ConversationMessageRecord, ApiError> {
        let emoji = emoji.trim();
        if !is_allowed_reaction(emoji) {
            return Err(ApiError::BadRequest("不支持这个反应".to_string()));
        }
        let context = load_visible_direct_message_context(&self.pool, message_id, user_id).await?;
        if pair_is_blocked_pool(&self.pool, user_id, &context.other_user_id).await? {
            return Err(ApiError::Conflict("conversation_unavailable".to_string()));
        }
        sqlx::query(
            "INSERT INTO chat_message_reactions (message_id, user_id, emoji)
             VALUES ($1, $2, $3)
             ON CONFLICT (message_id, user_id)
             DO UPDATE SET emoji = EXCLUDED.emoji, updated_at = NOW()",
        )
        .bind(message_id)
        .bind(user_id)
        .bind(emoji)
        .execute(&self.pool)
        .await
        .map_err(db_error)?;
        load_message_by_id_for_user(&self.pool, message_id, user_id).await
    }

    pub async fn delete_reaction(
        &self,
        message_id: i64,
        user_id: &str,
    ) -> Result<ConversationMessageRecord, ApiError> {
        load_visible_direct_message_context(&self.pool, message_id, user_id).await?;
        sqlx::query("DELETE FROM chat_message_reactions WHERE message_id = $1 AND user_id = $2")
            .bind(message_id)
            .bind(user_id)
            .execute(&self.pool)
            .await
            .map_err(db_error)?;
        load_message_by_id_for_user(&self.pool, message_id, user_id).await
    }

    pub async fn set_message_acknowledgement(
        &self,
        message_id: i64,
        user_id: &str,
        kind: AcknowledgementKind,
    ) -> Result<ConversationMessageRecord, ApiError> {
        let mut tx = self.begin().await?;
        load_acknowledgement_target(&mut tx, message_id, user_id).await?;
        sqlx::query(
            "INSERT INTO chat_message_acknowledgements (message_id, user_id, kind)
             VALUES ($1, $2, $3)
             ON CONFLICT (message_id, user_id)
             DO UPDATE SET kind = EXCLUDED.kind, updated_at = NOW()",
        )
        .bind(message_id)
        .bind(user_id)
        .bind(kind.as_str())
        .execute(&mut *tx)
        .await
        .map_err(db_error)?;
        tx.commit().await.map_err(commit_error)?;
        // Loading through the normal visibility path also returns reactions,
        // reply previews, and the complete acknowledgement list.
        load_message_by_id_for_user(&self.pool, message_id, user_id).await
    }

    pub async fn delete_message_acknowledgement(
        &self,
        message_id: i64,
        user_id: &str,
    ) -> Result<ConversationMessageRecord, ApiError> {
        let mut tx = self.begin().await?;
        load_acknowledgement_target(&mut tx, message_id, user_id).await?;
        sqlx::query(
            "DELETE FROM chat_message_acknowledgements
             WHERE message_id = $1 AND user_id = $2",
        )
        .bind(message_id)
        .bind(user_id)
        .execute(&mut *tx)
        .await
        .map_err(db_error)?;
        tx.commit().await.map_err(commit_error)?;
        load_message_by_id_for_user(&self.pool, message_id, user_id).await
    }

    pub async fn hide_message(&self, message_id: i64, user_id: &str) -> Result<(), ApiError> {
        load_visible_direct_message_context(&self.pool, message_id, user_id).await?;
        sqlx::query(
            "INSERT INTO chat_message_hidden_members (message_id, user_id)
             VALUES ($1, $2) ON CONFLICT DO NOTHING",
        )
        .bind(message_id)
        .bind(user_id)
        .execute(&self.pool)
        .await
        .map_err(db_error)?;
        Ok(())
    }

    pub async fn report_message(
        &self,
        message_id: i64,
        user_id: &str,
        reason: &str,
        details: Option<&str>,
    ) -> Result<Uuid, ApiError> {
        load_visible_direct_message_context(&self.pool, message_id, user_id).await?;
        let reason = reason.trim();
        if reason.is_empty() || reason.chars().count() > 80 {
            return Err(ApiError::BadRequest(
                "举报原因必须为 1 到 80 字".to_string(),
            ));
        }
        let details = details.map(str::trim).filter(|value| !value.is_empty());
        if details
            .as_ref()
            .is_some_and(|value| value.chars().count() > 1000)
        {
            return Err(ApiError::BadRequest("举报说明最多 1000 字".to_string()));
        }
        let mut tx = self.begin().await?;
        let row = sqlx::query(
            "INSERT INTO chat_message_reports (message_id, reporter_id, reason, details)
             VALUES ($1, $2, $3, $4)
             ON CONFLICT (message_id, reporter_id)
             DO UPDATE SET reason = EXCLUDED.reason, details = EXCLUDED.details
             RETURNING id",
        )
        .bind(message_id)
        .bind(user_id)
        .bind(reason)
        .bind(details)
        .fetch_one(&mut *tx)
        .await
        .map_err(db_error)?;
        let report_id = row.get("id");
        create_case_for_report(&mut tx, report_id).await?;
        tx.commit().await.map_err(db_error)?;
        Ok(report_id)
    }

    pub async fn block_user(&self, blocker_id: &str, blocked_id: &str) -> Result<(), ApiError> {
        if blocker_id == blocked_id {
            return Err(ApiError::BadRequest("不能屏蔽自己".to_string()));
        }
        let mut tx = self.begin().await?;
        sqlx::query(
            "INSERT INTO chat_blocks (blocker_id, blocked_id)
             VALUES ($1, $2) ON CONFLICT DO NOTHING",
        )
        .bind(blocker_id)
        .bind(blocked_id)
        .execute(&mut *tx)
        .await
        .map_err(db_error)?;
        let closed = sqlx::query(
            "UPDATE chat_conversations
             SET state = 'closed', closed_at = NOW(), close_reason = 'blocked',
                 invite_expires_at = NULL, ack_expires_at = NULL, idle_expires_at = NULL,
                 updated_at = NOW(), version = version + 1
             WHERE mode = 'realtime' AND state IN ('syn_sent', 'syn_ack', 'active')
               AND ((initiator_id = $1 AND recipient_id = $2)
                 OR (initiator_id = $2 AND recipient_id = $1))
             RETURNING id",
        )
        .bind(blocker_id)
        .bind(blocked_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(db_error)?;
        for row in closed {
            insert_event(
                &mut tx,
                row.get("id"),
                Some(blocker_id),
                "conversation_closed",
                None,
                "closed",
            )
            .await?;
        }
        tx.commit().await.map_err(commit_error)?;
        Ok(())
    }

    pub async fn unblock_user(&self, blocker_id: &str, blocked_id: &str) -> Result<(), ApiError> {
        sqlx::query("DELETE FROM chat_blocks WHERE blocker_id = $1 AND blocked_id = $2")
            .bind(blocker_id)
            .bind(blocked_id)
            .execute(&self.pool)
            .await
            .map_err(db_error)?;
        Ok(())
    }

    pub async fn list_blocks(&self, blocker_id: &str) -> Result<Vec<(String, String)>, ApiError> {
        let rows = sqlx::query(
            "SELECT block.blocked_id, COALESCE(users.username, '') AS username
             FROM chat_blocks block
             LEFT JOIN users ON users.id = block.blocked_id
             WHERE block.blocker_id = $1
             ORDER BY block.created_at DESC",
        )
        .bind(blocker_id)
        .fetch_all(&self.pool)
        .await
        .map_err(db_error)?;
        Ok(rows
            .into_iter()
            .map(|row| (row.get("blocked_id"), row.get("username")))
            .collect())
    }

    pub async fn expire_stale(&self) -> Result<Vec<(Uuid, String, String)>, ApiError> {
        let mut tx = self.begin().await?;
        let rows = sqlx::query(
            "UPDATE chat_conversations
             SET state = 'expired', closed_at = NOW(),
                 close_reason = CASE
                    WHEN state = 'syn_sent' THEN 'invite_timeout'
                    WHEN state = 'syn_ack' THEN 'ack_timeout'
                    ELSE 'idle_timeout'
                 END,
                 invite_expires_at = NULL, ack_expires_at = NULL, idle_expires_at = NULL,
                 updated_at = NOW(), version = version + 1
             WHERE (state = 'syn_sent' AND invite_expires_at <= NOW())
                OR (state = 'syn_ack' AND ack_expires_at <= NOW())
                OR (state = 'active' AND idle_expires_at <= NOW())
             RETURNING id, initiator_id, recipient_id",
        )
        .fetch_all(&mut *tx)
        .await
        .map_err(db_error)?;
        let mut expired = Vec::with_capacity(rows.len());
        for row in rows {
            let id: Uuid = row.get("id");
            insert_event(&mut tx, id, None, "conversation_expired", None, "expired").await?;
            expired.push((id, row.get("initiator_id"), row.get("recipient_id")));
        }
        tx.commit().await.map_err(commit_error)?;
        Ok(expired)
    }

    async fn begin(&self) -> Result<Transaction<'_, Postgres>, ApiError> {
        self.pool.begin().await.map_err(db_error)
    }
}

fn validate_create_input(input: &CreateConversationInput) -> Result<(), ApiError> {
    let content_len = input.content.trim().chars().count();
    if !(1..=2000).contains(&content_len) {
        return Err(ApiError::BadRequest(
            "首条消息长度必须为 1 到 2000 字".to_string(),
        ));
    }
    match input.mode {
        ConversationMode::Realtime if input.subject.is_some() => {
            Err(ApiError::BadRequest("实时会话不使用主题".to_string()))
        }
        ConversationMode::Mail => {
            let subject_len = input
                .subject
                .as_deref()
                .map(str::trim)
                .unwrap_or_default()
                .chars()
                .count();
            if !(1..=120).contains(&subject_len) {
                Err(ApiError::BadRequest(
                    "留言主题长度必须为 1 到 120 字".to_string(),
                ))
            } else {
                Ok(())
            }
        }
        _ => Ok(()),
    }
}

async fn load_conversation(pool: &PgPool, id: Uuid) -> Result<ConversationRow, ApiError> {
    sqlx::query_as::<_, ConversationRow>(
        "SELECT id, mode, state, initiator_id, recipient_id, listing_id, subject,
                invite_expires_at, ack_expires_at, idle_expires_at, established_at,
                closed_at, close_reason, version, created_at, updated_at
         FROM chat_conversations WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(db_error)?
    .ok_or(ApiError::NotFound)
}

async fn load_conversation_for_update(
    tx: &mut Transaction<'_, Postgres>,
    id: Uuid,
) -> Result<ConversationRow, ApiError> {
    sqlx::query_as::<_, ConversationRow>(
        "SELECT id, mode, state, initiator_id, recipient_id, listing_id, subject,
                invite_expires_at, ack_expires_at, idle_expires_at, established_at,
                closed_at, close_reason, version, created_at, updated_at
         FROM chat_conversations WHERE id = $1 FOR UPDATE",
    )
    .bind(id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(db_error)?
    .ok_or(ApiError::NotFound)
}

async fn find_live_realtime(
    tx: &mut Transaction<'_, Postgres>,
    user_a: &str,
    user_b: &str,
    _listing_id: Option<&str>,
    campus_id: Uuid,
) -> Result<Option<ConversationRow>, ApiError> {
    sqlx::query_as::<_, ConversationRow>(
        "SELECT id, mode, state, initiator_id, recipient_id, listing_id, subject,
                invite_expires_at, ack_expires_at, idle_expires_at, established_at,
                closed_at, close_reason, version, created_at, updated_at
         FROM chat_conversations
         WHERE mode = 'realtime' AND state IN ('syn_sent', 'syn_ack', 'active')
           AND ((initiator_id = $1 AND recipient_id = $2)
             OR (initiator_id = $2 AND recipient_id = $1))
           AND campus_id = $3
         FOR UPDATE",
    )
    .bind(user_a)
    .bind(user_b)
    .bind(campus_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(db_error)
}

/// Serialize realtime creation for one campus-scoped peer pair before the
/// lookup/insert sequence. The partial unique index remains the final guard,
/// while this lock turns concurrent duplicate requests into an idempotent
/// lookup instead of a constraint error.
async fn lock_realtime_pair(
    tx: &mut Transaction<'_, Postgres>,
    campus_id: Uuid,
    user_a: &str,
    user_b: &str,
) -> Result<(), ApiError> {
    let (first, second) = if user_a <= user_b {
        (user_a, user_b)
    } else {
        (user_b, user_a)
    };
    let lock_key = format!("{campus_id}:{first}:{second}");
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
        .bind(lock_key)
        .fetch_one(&mut **tx)
        .await
        .map_err(db_error)?;
    Ok(())
}

async fn pair_is_blocked(
    tx: &mut Transaction<'_, Postgres>,
    user_a: &str,
    user_b: &str,
) -> Result<bool, ApiError> {
    sqlx::query_scalar(
        "SELECT EXISTS(
            SELECT 1 FROM chat_blocks
            WHERE (blocker_id = $1 AND blocked_id = $2)
               OR (blocker_id = $2 AND blocked_id = $1)
         )",
    )
    .bind(user_a)
    .bind(user_b)
    .fetch_one(&mut **tx)
    .await
    .map_err(db_error)
}

/// Decide whether a realtime invite may interrupt the recipient.
///
/// A previous established conversation counts as an existing contact.  A
/// stranger must either be explicitly allowed for this peer or be covered by
/// the recipient's opt-in stranger setting.  Busy is a hard stop; mute only
/// suppresses the notification because the request itself remains visible in
/// the inbox when the recipient chooses to return.
async fn evaluate_connection_request(
    tx: &mut Transaction<'_, Postgres>,
    initiator_id: &str,
    recipient_id: &str,
) -> Result<bool, ApiError> {
    let preferences = sqlx::query(
        "SELECT allow_strangers, busy_until
         FROM chat_connection_preferences
         WHERE user_id = $1",
    )
    .bind(recipient_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(db_error)?;
    if preferences
        .as_ref()
        .and_then(|row| row.get::<Option<DateTime<Utc>>, _>("busy_until"))
        .is_some_and(|until| until > Utc::now())
    {
        return Err(ApiError::CodedConflict {
            code: "recipient_busy",
            message: "对方当前设置为忙碌，请先留言".to_string(),
        });
    }

    let explicit_permission = sqlx::query_scalar::<_, bool>(
        "SELECT allow_connection
         FROM chat_contact_permissions
         WHERE owner_id = $1 AND peer_id = $2",
    )
    .bind(recipient_id)
    .bind(initiator_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(db_error)?;
    if explicit_permission == Some(false) {
        return Err(ApiError::CodedConflict {
            code: "connection_not_allowed",
            message: "对方没有允许你的连接请求".to_string(),
        });
    }

    let existing_contact: bool = sqlx::query_scalar(
        "SELECT EXISTS(
            SELECT 1 FROM chat_conversations
            WHERE ((initiator_id = $1 AND recipient_id = $2)
                OR (initiator_id = $2 AND recipient_id = $1))
              AND established_at IS NOT NULL
         )",
    )
    .bind(initiator_id)
    .bind(recipient_id)
    .fetch_one(&mut **tx)
    .await
    .map_err(db_error)?;
    let allow_strangers = preferences
        .as_ref()
        .map(|row| row.get::<bool, _>("allow_strangers"))
        .unwrap_or(false);
    if !existing_contact && explicit_permission != Some(true) && !allow_strangers {
        return Err(ApiError::CodedConflict {
            code: "connection_requires_contact",
            message: "陌生人默认只能留言，请先获得联系人许可".to_string(),
        });
    }

    Ok(!recipient_has_muted_contact(tx, recipient_id, initiator_id).await?)
}

async fn recipient_has_muted_contact(
    tx: &mut Transaction<'_, Postgres>,
    owner_id: &str,
    peer_id: &str,
) -> Result<bool, ApiError> {
    sqlx::query_scalar(
        "SELECT COALESCE(muted_until > NOW(), FALSE)
         FROM chat_contact_permissions
         WHERE owner_id = $1 AND peer_id = $2",
    )
    .bind(owner_id)
    .bind(peer_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(db_error)
    .map(|value| value.unwrap_or(false))
}

async fn enforce_creation_limits(
    tx: &mut Transaction<'_, Postgres>,
    initiator_id: &str,
    recipient_id: &str,
) -> Result<(), ApiError> {
    let total: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM chat_conversations
         WHERE initiator_id = $1 AND created_at > NOW() - INTERVAL '24 hours'",
    )
    .bind(initiator_id)
    .fetch_one(&mut **tx)
    .await
    .map_err(db_error)?;
    let same_recipient: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM chat_conversations
         WHERE initiator_id = $1 AND recipient_id = $2
           AND created_at > NOW() - INTERVAL '24 hours'",
    )
    .bind(initiator_id)
    .bind(recipient_id)
    .fetch_one(&mut **tx)
    .await
    .map_err(db_error)?;
    if total >= DAILY_CONVERSATION_LIMIT || same_recipient >= SAME_RECIPIENT_DAILY_LIMIT {
        Err(ApiError::RateLimitExceeded)
    } else {
        Ok(())
    }
}

async fn activate_realtime(
    tx: &mut Transaction<'_, Postgres>,
    row: &ConversationRow,
    actor_id: &str,
    event_type: &str,
) -> Result<(), ApiError> {
    let now = Utc::now();
    sqlx::query(
        "UPDATE chat_conversations
         SET state = 'active', established_at = COALESCE(established_at, $1),
             ack_expires_at = NULL, idle_expires_at = $2,
             last_activity_at = $1, updated_at = $1, version = version + 1
         WHERE id = $3",
    )
    .bind(now)
    .bind(now + Duration::hours(ACTIVE_IDLE_HOURS))
    .bind(row.id)
    .execute(&mut **tx)
    .await
    .map_err(db_error)?;
    insert_event(
        tx,
        row.id,
        Some(actor_id),
        event_type,
        Some(&row.state),
        "active",
    )
    .await
}

async fn expire_if_due(
    tx: &mut Transaction<'_, Postgres>,
    row: &mut ConversationRow,
) -> Result<(), ApiError> {
    let now = Utc::now();
    let reason = match row.state.as_str() {
        "syn_sent" if row.invite_expires_at.is_some_and(|value| value <= now) => {
            Some("invite_timeout")
        }
        "syn_ack" if row.ack_expires_at.is_some_and(|value| value <= now) => Some("ack_timeout"),
        "active" if row.idle_expires_at.is_some_and(|value| value <= now) => Some("idle_timeout"),
        _ => None,
    };
    if let Some(reason) = reason {
        let previous = row.state.clone();
        sqlx::query(
            "UPDATE chat_conversations
             SET state = 'expired', closed_at = $1, close_reason = $2,
                 invite_expires_at = NULL, ack_expires_at = NULL, idle_expires_at = NULL,
                 updated_at = $1, version = version + 1
             WHERE id = $3",
        )
        .bind(now)
        .bind(reason)
        .bind(row.id)
        .execute(&mut **tx)
        .await
        .map_err(db_error)?;
        insert_event(
            tx,
            row.id,
            None,
            "conversation_expired",
            Some(&previous),
            "expired",
        )
        .await?;
        row.state = "expired".to_string();
        row.closed_at = Some(now);
        row.close_reason = Some(reason.to_string());
        return Err(invalid_state("expired"));
    }
    Ok(())
}

async fn ensure_reply_target(
    tx: &mut Transaction<'_, Postgres>,
    conversation_id: Uuid,
    reply_to_message_id: i64,
) -> Result<(), ApiError> {
    let exists: bool = sqlx::query_scalar(
        "SELECT EXISTS(
            SELECT 1 FROM chat_messages
            WHERE id = $1 AND direct_conversation_id = $2
         )",
    )
    .bind(reply_to_message_id)
    .bind(conversation_id)
    .fetch_one(&mut **tx)
    .await
    .map_err(db_error)?;
    if exists {
        Ok(())
    } else {
        Err(ApiError::BadRequest("引用的消息不属于当前会话".to_string()))
    }
}

async fn load_visible_direct_message_context(
    pool: &PgPool,
    message_id: i64,
    user_id: &str,
) -> Result<DirectMessageContext, ApiError> {
    let row = sqlx::query(
        "SELECT cm.direct_conversation_id, c.initiator_id, c.recipient_id
         FROM chat_messages cm
         JOIN chat_conversations c ON c.id = cm.direct_conversation_id
         WHERE cm.id = $1
           AND NOT EXISTS (
               SELECT 1 FROM chat_message_hidden_members h
               WHERE h.message_id = cm.id AND h.user_id = $2
           )",
    )
    .bind(message_id)
    .bind(user_id)
    .fetch_optional(pool)
    .await
    .map_err(db_error)?
    .ok_or(ApiError::NotFound)?;
    let initiator_id: String = row.get("initiator_id");
    let recipient_id: String = row.get("recipient_id");
    let other_user_id = if user_id == initiator_id {
        recipient_id
    } else if user_id == recipient_id {
        initiator_id
    } else {
        return Err(ApiError::Forbidden);
    };
    Ok(DirectMessageContext { other_user_id })
}

async fn load_acknowledgement_target(
    tx: &mut Transaction<'_, Postgres>,
    message_id: i64,
    user_id: &str,
) -> Result<(), ApiError> {
    let row = sqlx::query(
        "SELECT cm.sender, cm.receiver, c.initiator_id, c.recipient_id
         FROM chat_messages cm
         JOIN chat_conversations c ON c.id = cm.direct_conversation_id
         WHERE cm.id = $1
           AND NOT EXISTS (
               SELECT 1 FROM chat_message_hidden_members h
               WHERE h.message_id = cm.id AND h.user_id = $2
           )
         FOR UPDATE OF cm, c",
    )
    .bind(message_id)
    .bind(user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(db_error)?
    .ok_or(ApiError::NotFound)?;

    let initiator_id: String = row.get("initiator_id");
    let recipient_id: String = row.get("recipient_id");
    if user_id != initiator_id && user_id != recipient_id {
        return Err(ApiError::Forbidden);
    }
    // Only the message receiver can intentionally acknowledge it.  A sender
    // can observe the public acknowledgement but cannot manufacture one.
    let receiver: Option<String> = row.get("receiver");
    if receiver.as_deref() != Some(user_id) {
        return Err(ApiError::Forbidden);
    }
    let sender: String = row.get("sender");
    if pair_is_blocked(tx, &sender, user_id).await? {
        return Err(ApiError::Conflict("conversation_unavailable".to_string()));
    }
    Ok(())
}

async fn pair_is_blocked_pool(pool: &PgPool, one: &str, two: &str) -> Result<bool, ApiError> {
    sqlx::query_scalar(
        "SELECT EXISTS(
            SELECT 1 FROM chat_blocks
            WHERE (blocker_id = $1 AND blocked_id = $2)
               OR (blocker_id = $2 AND blocked_id = $1)
         )",
    )
    .bind(one)
    .bind(two)
    .fetch_one(pool)
    .await
    .map_err(db_error)
}

async fn load_message_by_id_for_user(
    pool: &PgPool,
    message_id: i64,
    user_id: &str,
) -> Result<ConversationMessageRecord, ApiError> {
    let row = sqlx::query(
        "SELECT id, client_message_id, direct_conversation_id, sender, content,
                reply_to_message_id, timestamp, image_data, audio_data,
                image_url, audio_url, status, kind, edited_at,
                quote_kind, quote_ref_id, quote_snapshot
         FROM chat_messages
         WHERE id = $1
           AND direct_conversation_id IS NOT NULL
           AND NOT EXISTS (
               SELECT 1 FROM chat_message_hidden_members h
               WHERE h.message_id = chat_messages.id AND h.user_id = $2
           )",
    )
    .bind(message_id)
    .bind(user_id)
    .fetch_optional(pool)
    .await
    .map_err(db_error)?
    .ok_or(ApiError::NotFound)?;
    let conversation_id: Uuid = row.get("direct_conversation_id");
    let mut message = row_to_message(row, conversation_id);
    enrich_message_for_user(pool, user_id, &mut message).await?;
    Ok(message)
}

async fn enrich_message_for_user(
    pool: &PgPool,
    user_id: &str,
    message: &mut ConversationMessageRecord,
) -> Result<(), ApiError> {
    let hidden: bool = sqlx::query_scalar(
        "SELECT EXISTS(
            SELECT 1 FROM chat_message_hidden_members
            WHERE message_id = $1 AND user_id = $2
         )",
    )
    .bind(message.id)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .map_err(db_error)?;
    message.hidden_for_me = hidden;

    if let Some(reply_to_message_id) = message.reply_to_message_id {
        let preview = sqlx::query(
            "SELECT id, sender, content, kind
             FROM chat_messages
             WHERE id = $1
               AND direct_conversation_id = $2
               AND NOT EXISTS (
                   SELECT 1 FROM chat_message_hidden_members h
                   WHERE h.message_id = chat_messages.id AND h.user_id = $3
               )",
        )
        .bind(reply_to_message_id)
        .bind(Uuid::parse_str(&message.conversation_id).map_err(|error| {
            ApiError::Internal(anyhow::anyhow!("invalid conversation id: {error}"))
        })?)
        .bind(user_id)
        .fetch_optional(pool)
        .await
        .map_err(db_error)?;
        message.reply_preview = preview.map(|row| {
            let content: String = row.get("content");
            MessageReplyPreview {
                id: row.get("id"),
                sender: row.get("sender"),
                content: truncate_chars(&content, 120),
                kind: row.get("kind"),
            }
        });
    }

    let reaction_rows = sqlx::query(
        "SELECT emoji, COUNT(*)::BIGINT AS count,
                BOOL_OR(user_id = $2) AS reacted_by_me
         FROM chat_message_reactions
         WHERE message_id = $1
         GROUP BY emoji
         ORDER BY count DESC, emoji ASC",
    )
    .bind(message.id)
    .bind(user_id)
    .fetch_all(pool)
    .await
    .map_err(db_error)?;
    message.reactions = reaction_rows
        .into_iter()
        .map(|row| MessageReactionSummary {
            emoji: row.get("emoji"),
            count: row.get("count"),
            reacted_by_me: row.get("reacted_by_me"),
        })
        .collect();

    let acknowledgement_rows = sqlx::query(
        "SELECT user_id, kind, created_at, updated_at
         FROM chat_message_acknowledgements
         WHERE message_id = $1
         ORDER BY updated_at ASC, user_id ASC",
    )
    .bind(message.id)
    .fetch_all(pool)
    .await
    .map_err(db_error)?;
    message.acknowledgements = acknowledgement_rows
        .into_iter()
        .map(|row| {
            let kind: String = row.get("kind");
            let created_at: DateTime<Utc> = row.get("created_at");
            let updated_at: DateTime<Utc> = row.get("updated_at");
            Ok(MessageAcknowledgement {
                user_id: row.get("user_id"),
                kind: AcknowledgementKind::parse(&kind)?,
                created_at: created_at.to_rfc3339(),
                updated_at: updated_at.to_rfc3339(),
            })
        })
        .collect::<Result<Vec<_>, ApiError>>()?;
    Ok(())
}

fn is_allowed_reaction(emoji: &str) -> bool {
    matches!(emoji, "👍" | "❤️" | "😂" | "😮" | "😢" | "🙏")
}

fn truncate_chars(value: &str, max_chars: usize) -> String {
    if value.chars().count() <= max_chars {
        value.to_string()
    } else {
        format!("{}…", value.chars().take(max_chars).collect::<String>())
    }
}

async fn resolve_structured_quote(
    tx: &mut Transaction<'_, Postgres>,
    conversation: &ConversationRow,
    sender_id: &str,
    input: &StructuredQuoteInput,
) -> Result<StructuredQuote, ApiError> {
    let ref_id = input.ref_id.trim();
    if ref_id.is_empty() || ref_id.len() > 128 {
        return Err(ApiError::BadRequest("引用目标无效".to_string()));
    }

    let snapshot = match input.kind {
        StructuredQuoteKind::Listing => {
            let row = sqlx::query(
                "SELECT listing.id, listing.title, listing.suggested_price_cny,
                        listing.condition_score, listing.image_url,
                        listing.owner_id, listing.status
                 FROM inventory listing
                 WHERE listing.id = $1
                   AND listing.campus_id = (
                       SELECT campus_id FROM chat_conversations WHERE id = $2
                   )
                 FOR SHARE",
            )
            .bind(ref_id)
            .bind(conversation.id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(db_error)?
            .ok_or(ApiError::NotFound)?;
            let listing_id: String = row.get("id");
            let owner_id: String = row.get("owner_id");
            let status: String = row.get("status");
            let restricted: bool = sqlx::query_scalar("SELECT listing_has_active_restriction($1)")
                .bind(&listing_id)
                .fetch_one(&mut **tx)
                .await
                .map_err(db_error)?;
            if restricted {
                return Err(ApiError::CodedConflict {
                    code: "listing_restricted",
                    message: "该发布受平台限制，不能引用".to_string(),
                });
            }
            let visible = status == "active"
                || conversation.listing_id.as_deref() == Some(&listing_id)
                || owner_id == sender_id;
            if !visible {
                return Err(ApiError::Forbidden);
            }
            json!({
                "id": listing_id,
                "title": row.get::<String, _>("title"),
                "price_cny": cents_to_yuan(row.get::<i64, _>("suggested_price_cny")),
                "condition_score": row.get::<i32, _>("condition_score"),
                "image_url": row.get::<Option<String>, _>("image_url"),
                "status": status,
            })
        }
        StructuredQuoteKind::Order => {
            let row = sqlx::query(
                "SELECT o.id, o.buyer_id, o.seller_id, o.final_price, o.status,
                        i.title AS listing_title
                 FROM orders o
                 JOIN inventory i ON i.id = o.listing_id
                 WHERE o.id = $1
                   AND (
                       o.buyer_id = $2 OR o.seller_id = $2 OR
                       EXISTS (SELECT 1 FROM users u WHERE u.id = $2 AND u.role = 'admin')
                   )",
            )
            .bind(ref_id)
            .bind(sender_id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(db_error)?
            .ok_or(ApiError::Forbidden)?;
            json!({
                "id": row.get::<String, _>("id"),
                "listing_title": row.get::<String, _>("listing_title"),
                "final_price_cny": cents_to_yuan(row.get::<i64, _>("final_price")),
                "status": row.get::<String, _>("status"),
            })
        }
        StructuredQuoteKind::HitlOffer => {
            let row = sqlx::query(
                "SELECT h.id, h.buyer_id, h.seller_id, h.proposed_price,
                        h.counter_price, h.status, h.buyer_action,
                        i.title AS listing_title
                 FROM hitl_requests h
                 JOIN inventory i ON i.id = h.listing_id
                 WHERE h.id = $1
                   AND (
                       h.buyer_id = $2 OR h.seller_id = $2 OR
                       EXISTS (SELECT 1 FROM users u WHERE u.id = $2 AND u.role = 'admin')
                   )",
            )
            .bind(ref_id)
            .bind(sender_id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(db_error)?
            .ok_or(ApiError::Forbidden)?;
            json!({
                "id": row.get::<String, _>("id"),
                "listing_title": row.get::<String, _>("listing_title"),
                "proposed_price_cny": cents_to_yuan(row.get::<i64, _>("proposed_price")),
                "counter_price_cny": row.get::<Option<i64>, _>("counter_price").map(cents_to_yuan),
                "status": row.get::<String, _>("status"),
                "buyer_action": row.get::<Option<String>, _>("buyer_action"),
            })
        }
    };

    Ok(StructuredQuote {
        kind: input.kind.as_str().to_string(),
        ref_id: ref_id.to_string(),
        snapshot,
    })
}

#[allow(clippy::too_many_arguments)]
async fn insert_message(
    tx: &mut Transaction<'_, Postgres>,
    conversation_id: Uuid,
    client_message_id: Uuid,
    listing_id: Option<&str>,
    sender_id: &str,
    receiver_id: &str,
    content: &str,
    kind: &str,
    reply_to_message_id: Option<i64>,
    quote: Option<&StructuredQuote>,
    image_data: Option<&str>,
    audio_data: Option<&str>,
    image_url: Option<&str>,
    audio_url: Option<&str>,
) -> Result<ConversationMessageRecord, ApiError> {
    let row = sqlx::query(
        "INSERT INTO chat_messages (
            conversation_id, direct_conversation_id, client_message_id, listing_id,
            sender, receiver, is_agent, content, kind, reply_to_message_id,
            quote_kind, quote_ref_id, quote_snapshot,
            image_data, audio_data, image_url, audio_url, status
         ) VALUES ($1, $2, $3, $4, $5, $6, FALSE, $7, $8, $9, $10, $11, COALESCE($12, '{}'::jsonb), $13, $14, $15, $16, 'sent')
         RETURNING id, client_message_id, sender, content, reply_to_message_id, timestamp,
                   image_data, audio_data, image_url, audio_url, status, kind, edited_at,
                   quote_kind, quote_ref_id, quote_snapshot",
    )
    .bind(conversation_id.to_string())
    .bind(conversation_id)
    .bind(client_message_id)
    .bind(listing_id.unwrap_or(""))
    .bind(sender_id)
    .bind(receiver_id)
    .bind(content)
    .bind(kind)
    .bind(reply_to_message_id)
    .bind(quote.map(|value| value.kind.as_str()))
    .bind(quote.map(|value| value.ref_id.as_str()))
    .bind(quote.map(|value| value.snapshot.clone()))
    .bind(image_data)
    .bind(audio_data)
    .bind(image_url)
    .bind(audio_url)
    .fetch_one(&mut **tx)
    .await
    .map_err(db_error)?;
    Ok(row_to_message(row, conversation_id))
}

async fn find_message_by_client_id(
    tx: &mut Transaction<'_, Postgres>,
    sender_id: &str,
    client_message_id: Uuid,
) -> Result<Option<ConversationMessageRecord>, ApiError> {
    let row = sqlx::query(
        "SELECT id, client_message_id, direct_conversation_id, sender, content,
                reply_to_message_id, timestamp,
                image_data, audio_data, image_url, audio_url, status, kind, edited_at,
                quote_kind, quote_ref_id, quote_snapshot
         FROM chat_messages WHERE sender = $1 AND client_message_id = $2",
    )
    .bind(sender_id)
    .bind(client_message_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(db_error)?;
    Ok(row.map(|value| {
        let id: Uuid = value.get("direct_conversation_id");
        row_to_message(value, id)
    }))
}

fn row_to_message(row: sqlx::postgres::PgRow, conversation_id: Uuid) -> ConversationMessageRecord {
    let timestamp: DateTime<Utc> = row.get("timestamp");
    let edited_at: Option<DateTime<Utc>> = row.get("edited_at");
    let client_message_id: Option<Uuid> = row.get("client_message_id");
    let raw_status: String = row.get("status");
    let status = match raw_status.as_str() {
        // Legacy facts are intentionally collapsed for new clients.  The
        // database columns stay available during rollback, but the API never
        // presents them as delivery or attention evidence.
        "delivered" | "read" => "sent".to_string(),
        _ => raw_status,
    };
    let quote_kind: Option<String> = row.try_get("quote_kind").ok().flatten();
    let quote_ref_id: Option<String> = row.try_get("quote_ref_id").ok().flatten();
    let quote_snapshot: Value = row.try_get("quote_snapshot").unwrap_or_else(|_| json!({}));
    let quote = quote_kind
        .zip(quote_ref_id)
        .map(|(kind, ref_id)| StructuredQuote {
            kind,
            ref_id,
            snapshot: quote_snapshot,
        });
    ConversationMessageRecord {
        id: row.get("id"),
        client_message_id: client_message_id.map(|value| value.to_string()),
        conversation_id: conversation_id.to_string(),
        sender: row.get("sender"),
        content: row.get("content"),
        reply_to_message_id: row.get("reply_to_message_id"),
        reply_preview: None,
        quote,
        reactions: Vec::new(),
        acknowledgements: Vec::new(),
        hidden_for_me: false,
        can_hide: true,
        can_react: true,
        can_report: true,
        timestamp: timestamp.to_rfc3339(),
        image_data: row.get("image_data"),
        audio_data: row.get("audio_data"),
        image_url: row.get("image_url"),
        audio_url: row.get("audio_url"),
        status,
        kind: row.get("kind"),
        edited_at: edited_at.map(|value| value.to_rfc3339()),
    }
}

async fn insert_event(
    tx: &mut Transaction<'_, Postgres>,
    conversation_id: Uuid,
    actor_id: Option<&str>,
    event_type: &str,
    from_state: Option<&str>,
    to_state: &str,
) -> Result<(), ApiError> {
    sqlx::query(
        "INSERT INTO chat_conversation_events (
            conversation_id, actor_id, event_type, from_state, to_state
         ) VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(conversation_id)
    .bind(actor_id)
    .bind(event_type)
    .bind(from_state)
    .bind(to_state)
    .execute(&mut **tx)
    .await
    .map_err(db_error)?;
    Ok(())
}

fn invalid_state(state: &str) -> ApiError {
    ApiError::Conflict(format!("invalid_conversation_state:{state}"))
}

fn db_error(error: sqlx::Error) -> ApiError {
    ApiError::Internal(anyhow::anyhow!("chat conversation database error: {error}"))
}

fn commit_error(error: sqlx::Error) -> ApiError {
    ApiError::Internal(anyhow::anyhow!("chat conversation commit error: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn realtime_input() -> CreateConversationInput {
        CreateConversationInput {
            client_request_id: Uuid::new_v4(),
            campus_id: Uuid::parse_str("c0000000-0000-0000-0000-000000000001").unwrap(),
            initiator_id: "buyer".to_string(),
            recipient_id: "seller".to_string(),
            listing_id: Some("listing".to_string()),
            mode: ConversationMode::Realtime,
            subject: None,
            content: "请问还在吗？".to_string(),
        }
    }

    #[test]
    fn realtime_create_input_rejects_subject() {
        let mut input = realtime_input();
        input.subject = Some("subject".to_string());
        assert!(validate_create_input(&input).is_err());
    }

    #[test]
    fn mail_create_input_requires_subject() {
        let mut input = realtime_input();
        input.mode = ConversationMode::Mail;
        assert!(validate_create_input(&input).is_err());
        input.subject = Some("关于商品".to_string());
        assert!(validate_create_input(&input).is_ok());
    }

    #[test]
    fn terminal_states_are_not_live() {
        assert!(ConversationState::SynSent.is_live_realtime());
        assert!(ConversationState::SynAck.is_live_realtime());
        assert!(ConversationState::Active.is_live_realtime());
        assert!(!ConversationState::Expired.is_live_realtime());
        assert!(!ConversationState::Closed.is_live_realtime());
    }
}
