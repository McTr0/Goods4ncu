use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::services::chat_conversation::{
    AcknowledgementKind, ChatSharedObjectView, ChatThreadDetail, ChatThreadView,
    ConversationDecision, ConversationMessageRecord, ConversationMode, ConversationView,
    RelationshipSpaceConnectionView, RelationshipSpaceEventView, RelationshipSpacePinView,
    RelationshipSpaceSharedObjectView, RelationshipSpaceView, SharedObjectKind,
    StructuredQuoteInput,
};

#[derive(Debug, Deserialize)]
pub struct CreateConversationBody {
    pub client_request_id: Uuid,
    pub recipient_id: String,
    pub listing_id: Option<String>,
    pub mode: ConversationMode,
    pub subject: Option<String>,
    pub content: String,
}

#[derive(Debug, Deserialize)]
pub struct ConversationListQuery {
    pub mode: Option<ConversationMode>,
    pub cursor: Option<Uuid>,
    pub limit: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct ConversationListResponse {
    pub items: Vec<ConversationView>,
    pub next_cursor: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ThreadListQuery {
    pub mode: Option<String>,
    pub limit: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct ThreadListResponse {
    pub items: Vec<ChatThreadView>,
}

#[derive(Debug, Serialize)]
pub struct ThreadDetailResponse {
    pub thread: ChatThreadView,
    pub conversations: Vec<ConversationView>,
}

impl From<ChatThreadDetail> for ThreadDetailResponse {
    fn from(value: ChatThreadDetail) -> Self {
        Self {
            thread: value.thread,
            conversations: value.conversations,
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct SpaceEventQuery {
    pub cursor: Option<String>,
    pub limit: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct RelationshipSpaceResponse {
    pub relationship_key: String,
    pub events: Vec<RelationshipSpaceEventView>,
    pub pins: Vec<RelationshipSpacePinView>,
    pub shared_objects: Vec<RelationshipSpaceSharedObjectView>,
    pub recent_connection: Option<RelationshipSpaceConnectionView>,
    pub next_cursor: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct CreateSharedObjectBody {
    pub kind: SharedObjectKind,
    pub title: String,
    pub mime_type: Option<String>,
    pub size_bytes: Option<i64>,
    pub canonical_url: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct SharedObjectResponse {
    #[serde(flatten)]
    pub object: ChatSharedObjectView,
    /// A relative media endpoint.  The endpoint performs the participant,
    /// status and platform-storage checks before returning a short-lived URL.
    pub download_path: Option<String>,
}

impl From<RelationshipSpaceView> for RelationshipSpaceResponse {
    fn from(value: RelationshipSpaceView) -> Self {
        Self {
            relationship_key: value.relationship_key,
            events: value.events,
            pins: value.pins,
            shared_objects: value.shared_objects,
            recent_connection: value.recent_connection,
            next_cursor: value.next_cursor,
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct RespondConversationBody {
    pub decision: ConversationDecision,
}

#[derive(Debug, Deserialize)]
pub struct ArchiveConversationBody {
    pub archived: bool,
}

#[derive(Debug, Deserialize)]
pub struct SendMessageBody {
    pub client_message_id: Uuid,
    pub content: String,
    pub reply_to_message_id: Option<i64>,
    pub quote: Option<StructuredQuoteInput>,
    pub image_base64: Option<String>,
    pub audio_base64: Option<String>,
    pub image_url: Option<String>,
    pub audio_url: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct MessageListQuery {
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct MessageListResponse {
    pub conversation_id: String,
    pub messages: Vec<ConversationMessageRecord>,
    pub total: i64,
}

#[derive(Debug, Deserialize)]
pub struct EditMessageBody {
    pub content: String,
}

#[derive(Debug, Deserialize)]
pub struct MessageReactionBody {
    pub emoji: String,
}

#[derive(Debug, Deserialize)]
pub struct MessageAcknowledgementBody {
    pub kind: AcknowledgementKind,
}

#[derive(Debug, Serialize)]
pub struct HideMessageResponse {
    pub message_id: i64,
    pub hidden: bool,
}

#[derive(Debug, Serialize)]
pub struct RelationshipPinResponse {
    pub message_id: i64,
    pub pinned: bool,
}

#[derive(Debug, Deserialize)]
pub struct ReportMessageBody {
    pub reason: String,
    pub details: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ReportMessageResponse {
    pub report_id: String,
}

#[derive(Debug, Deserialize)]
pub struct BlockUserBody {
    pub user_id: String,
}

#[derive(Debug, Serialize)]
pub struct BlockedUserEntry {
    pub user_id: String,
    pub username: String,
}

#[derive(Debug, Serialize)]
pub struct BlockListResponse {
    pub items: Vec<BlockedUserEntry>,
}

#[derive(Debug, Deserialize)]
pub struct ConnectionPreferencesBody {
    pub allow_strangers: bool,
    pub busy_until: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ContactPermissionBody {
    pub allow_connection: bool,
    pub muted_until: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReplySuggestion {
    pub tone: String,
    pub text: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ReplySuggestionsResponse {
    pub suggestions: Vec<ReplySuggestion>,
}
