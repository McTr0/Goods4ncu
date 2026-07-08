use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::services::chat_conversation::{
    ChatThreadDetail, ChatThreadView, ConversationDecision, ConversationMessageRecord,
    ConversationMode, ConversationView,
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

#[derive(Debug, Serialize)]
pub struct MarkReadResponse {
    pub conversation_id: String,
    pub marked_count: i64,
}

#[derive(Debug, Deserialize)]
pub struct ReadPreferenceBody {
    pub mode: String,
}

#[derive(Debug, Deserialize)]
pub struct EditMessageBody {
    pub content: String,
}

#[derive(Debug, Deserialize)]
pub struct MessageReactionBody {
    pub emoji: String,
}

#[derive(Debug, Serialize)]
pub struct HideMessageResponse {
    pub message_id: i64,
    pub hidden: bool,
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReplySuggestion {
    pub tone: String,
    pub text: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ReplySuggestionsResponse {
    pub suggestions: Vec<ReplySuggestion>,
}
use crate::services::chat_conversation::StructuredQuoteInput;
