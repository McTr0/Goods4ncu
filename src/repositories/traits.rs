//! Repository trait definitions for dependency inversion.
//!
//! Each domain has a trait defining its data access operations.
//! Concrete implementations (e.g., PostgresRepository) implement these traits.

// ---------------------------------------------------------------------------
// Re-exports for convenience
// ---------------------------------------------------------------------------
pub use crate::api::error::ApiError;

// ---------------------------------------------------------------------------
// Listing Repository
// ---------------------------------------------------------------------------

/// A listing item returned from the marketplace.
#[derive(Debug, Clone, serde::Serialize, sqlx::FromRow)]
#[allow(dead_code)]
pub struct Listing {
    pub id: String,
    pub campus_id: uuid::Uuid,
    pub title: String,
    pub category: String,
    pub brand: Option<String>,
    pub direction: String,
    pub condition_score: i32,
    pub suggested_price_cny: i64,
    pub defects: Option<String>,
    pub description: Option<String>,
    pub image_url: Option<String>,
    pub owner_id: String,
    pub status: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Clone, serde::Serialize)]
#[allow(dead_code)]
pub struct CreateListingInput {
    pub campus_id: uuid::Uuid,
    pub title: String,
    pub category: String,
    pub brand: Option<String>,
    pub direction: String,
    pub condition_score: i32,
    pub suggested_price_cny: f64,
    pub defects: Vec<String>,
    pub description: String,
    pub image_url: Option<String>,
    pub owner_id: String,
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct UpdateListingInput {
    pub title: Option<String>,
    pub category: Option<String>,
    pub brand: Option<String>,
    pub condition_score: Option<i32>,
    pub suggested_price_cny: Option<f64>,
    pub defects: Option<Vec<String>>,
    pub description: Option<String>,
    pub status: Option<String>,
}

#[allow(dead_code, async_fn_in_trait)]
pub trait ListingRepository: Send + Sync {
    /// Find listings with optional filters.
    #[allow(clippy::too_many_arguments)]
    async fn find_listings(
        &self,
        campus_id: uuid::Uuid,
        category: Option<&str>,
        categories: Option<&str>, // comma-separated
        search: Option<&str>,
        direction: Option<&str>,
        min_price_cny: Option<f64>,
        max_price_cny: Option<f64>,
        sort: &str, // "newest" | "price_asc" | "price_desc" | "condition_desc"
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<Listing>, i64), ApiError>;

    /// Find a single listing by ID.
    async fn find_by_id(&self, id: &str) -> Result<Option<Listing>, ApiError>;

    /// Find a single listing by ID, joining with owner username in a single query.
    /// Returns (listing, owner_username) to avoid N+1 query pattern.
    async fn find_by_id_with_owner(
        &self,
        id: &str,
    ) -> Result<Option<(Listing, Option<String>)>, ApiError>;

    async fn find_by_id_with_owner_in_campus(
        &self,
        id: &str,
        campus_id: uuid::Uuid,
    ) -> Result<Option<(Listing, Option<String>)>, ApiError>;

    /// Create a new listing.
    async fn create(&self, input: CreateListingInput) -> Result<String, ApiError>;

    /// Update an existing listing (checks ownership).
    async fn update(
        &self,
        id: &str,
        owner_id: &str,
        input: UpdateListingInput,
    ) -> Result<(), ApiError>;

    /// Delete a listing (soft delete by setting status to 'deleted').
    async fn delete(&self, id: &str, owner_id: &str, campus_id: uuid::Uuid)
        -> Result<(), ApiError>;

    /// Relist a sold/deleted/fulfilled item inside the owner's active campus.
    ///
    /// Wanted listings start a new lifecycle epoch when reopened so responses
    /// from the previous round remain read-only history.
    async fn relist(&self, id: &str, owner_id: &str, campus_id: uuid::Uuid)
        -> Result<(), ApiError>;

    /// Mark a listing as sold.
    async fn mark_sold(&self, id: &str, owner_id: &str) -> Result<(), ApiError>;

    /// Get total count of listings.
    async fn count(&self, status: Option<&str>) -> Result<i64, ApiError>;

    /// Get distribution of listings across categories (admin stats).
    async fn get_category_stats(&self) -> Result<Vec<(String, i64)>, ApiError>;
}

// ---------------------------------------------------------------------------
// User Repository
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, serde::Serialize, sqlx::FromRow)]
#[allow(dead_code)]
pub struct User {
    pub id: String,
    pub username: String,
    pub email: Option<String>,
    pub student_id: Option<String>,
    pub password_hash: String,
    pub role: String,
    pub status: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Clone, serde::Serialize)]
#[allow(dead_code)]
pub struct UserDiscoverability {
    pub username: bool,
    pub email: bool,
    pub student_id: bool,
}

#[derive(Debug, Clone, serde::Serialize)]
#[allow(dead_code)]
pub struct UserPaymentQr {
    pub wechat_url: Option<String>,
    pub alipay_url: Option<String>,
    pub show_wechat: bool,
    pub show_alipay: bool,
}

#[derive(Debug, Clone, serde::Serialize)]
#[allow(dead_code)]
pub struct UserProfile {
    pub user_id: String,
    pub username: String,
    pub email: Option<String>,
    pub student_id: Option<String>,
    pub discoverability: UserDiscoverability,
    pub chat_read_receipt_mode: String,
    pub avatar_url: Option<String>,
    pub payment_qr: UserPaymentQr,
    pub role: String,
    pub created_at: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)]
pub enum UserLookupMethod {
    Auto,
    Username,
    Email,
    StudentId,
}

#[derive(Debug, Clone, serde::Serialize)]
#[allow(dead_code)]
pub struct UserLookupResult {
    pub user_id: String,
    pub username: String,
    pub matched_by: String,
    pub masked_identifier: Option<String>,
    pub listing_count: i64,
    pub can_start_conversation: bool,
}

#[allow(dead_code, async_fn_in_trait)]
pub trait UserRepository: Send + Sync {
    /// Find a user by ID.
    async fn find_by_id(&self, id: &str) -> Result<Option<User>, ApiError>;

    /// Find a user by username.
    async fn find_by_username(&self, username: &str) -> Result<Option<User>, ApiError>;

    /// Find a user by email.
    async fn find_by_email(&self, email: &str) -> Result<Option<User>, ApiError>;

    /// Create a new user. Returns user_id on success.
    async fn create(
        &self,
        username: &str,
        email: Option<&str>,
        password_hash: &str,
        role: &str,
    ) -> Result<String, ApiError>;

    /// Get user profile (public info only).
    async fn get_profile(&self, user_id: &str) -> Result<UserProfile, ApiError>;

    /// Get paginated listings by user.
    async fn get_user_listings(
        &self,
        user_id: &str,
        campus_id: uuid::Uuid,
        limit: i64,
        offset: i64,
        status_filter: &str,
        only_approved_media: bool,
    ) -> Result<(Vec<Listing>, i64), ApiError>;

    /// Search users by username prefix.
    async fn search_users(&self, query: &str, limit: i64) -> Result<Vec<UserProfile>, ApiError>;

    /// Search users with their active listing counts (JOIN with inventory).
    async fn search_users_with_listing_count(
        &self,
        campus_id: uuid::Uuid,
        query: Option<&str>,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<(UserProfile, i64)>, i64), ApiError>;

    /// Privacy-aware lookup for starting a direct conversation.
    async fn lookup_users(
        &self,
        requester_id: &str,
        campus_id: uuid::Uuid,
        query: &str,
        method: UserLookupMethod,
        limit: i64,
    ) -> Result<Vec<UserLookupResult>, ApiError>;

    /// Ban a user.
    async fn ban_user(&self, user_id: &str) -> Result<(), ApiError>;

    /// Unban a user.
    async fn unban_user(&self, user_id: &str) -> Result<(), ApiError>;

    /// Update user role.
    async fn update_role(&self, user_id: &str, role: &str) -> Result<(), ApiError>;

    /// Update username. Returns error if new_username already taken.
    async fn update_username(&self, user_id: &str, new_username: &str) -> Result<(), ApiError>;

    /// Update avatar URL for a user.
    async fn update_avatar(&self, user_id: &str, avatar_url: &str) -> Result<(), ApiError>;

    /// Update email for a user. Returns error if new_email already taken.
    async fn update_email(&self, user_id: &str, new_email: &str) -> Result<(), ApiError>;

    /// Update user discovery preferences.
    async fn update_discoverability(
        &self,
        user_id: &str,
        username: Option<bool>,
        email: Option<bool>,
        student_id: Option<bool>,
    ) -> Result<(), ApiError>;

    /// Update global chat read receipt preference.
    async fn update_chat_read_receipt_mode(
        &self,
        user_id: &str,
        mode: &str,
    ) -> Result<(), ApiError>;

    /// Update optional offline payment QR-code URLs and public visibility.
    async fn update_payment_qr(
        &self,
        user_id: &str,
        wechat_url: Option<&str>,
        alipay_url: Option<&str>,
        show_wechat: Option<bool>,
        show_alipay: Option<bool>,
    ) -> Result<(), ApiError>;

    /// Update password hash for a user.
    async fn update_password_hash(
        &self,
        user_id: &str,
        password_hash: &str,
    ) -> Result<(), ApiError>;

    /// Count all users.
    async fn count_users(&self) -> Result<i64, ApiError>;
}

// ---------------------------------------------------------------------------
// Chat Repository
// ---------------------------------------------------------------------------

/// Summary of a conversation for the conversation list.
#[derive(Debug, Clone, serde::Serialize)]
#[allow(dead_code)]
pub struct ConversationSummary {
    pub id: String,
    pub requester_id: String,
    pub other_user_id: String,
    pub other_username: Option<String>,
    pub status: String,
    pub established_at: Option<String>,
    pub created_at: String,
    pub unread_count: i32,
    pub is_receiver: bool,
}

/// A chat message.
#[derive(Debug, Clone, serde::Serialize, sqlx::FromRow)]
#[allow(dead_code)]
pub struct ChatMessage {
    pub id: String,
    pub conversation_id: String,
    pub sender: String,
    pub receiver: Option<String>,
    pub content: String,
    pub image_data: Option<String>,
    pub audio_data: Option<String>,
    pub image_url: Option<String>,
    pub audio_url: Option<String>,
    pub is_agent: bool,
    pub edited_at: Option<chrono::DateTime<chrono::Utc>>,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

#[allow(dead_code, async_fn_in_trait)]
pub trait ChatRepository: Send + Sync {
    /// Log a message to a conversation.
    #[allow(clippy::too_many_arguments)]
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
    ) -> Result<(), ApiError>;

    /// Get conversation history (up to CONVERSATION_HISTORY_LIMIT entries).
    async fn get_conversation_history(
        &self,
        conversation_id: &str,
    ) -> Result<Vec<crate::services::chat::ChatHistoryEntry>, ApiError>;

    /// List all conversations for a user.
    async fn list_conversations(
        &self,
        user_id: &str,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<ConversationSummary>, i64), ApiError>;

    /// Get messages for a conversation (paginated).
    async fn get_conversation_messages(
        &self,
        conversation_id: &str,
        before: Option<i64>,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<ChatMessage>, i64), ApiError>;

    /// Mark all messages in a conversation as read.
    async fn mark_conversation_read(
        &self,
        conversation_id: &str,
        reader_id: &str,
    ) -> Result<(), ApiError>;

    /// Edit a message (sender only, within 15 min).
    async fn edit_message(
        &self,
        message_id: &str,
        sender_id: &str,
        new_content: &str,
    ) -> Result<(), ApiError>;

    /// Mark a message as read.
    async fn mark_message_read(&self, message_id: &str, reader_id: &str) -> Result<(), ApiError>;
}

// ---------------------------------------------------------------------------
// Auth Repository
// ---------------------------------------------------------------------------

#[allow(dead_code, async_fn_in_trait)]
pub trait AuthRepository: Send + Sync {
    /// Find user by username for login.
    async fn find_user_by_username(&self, username: &str) -> Result<Option<User>, ApiError>;

    /// Find user by email for login.
    async fn find_user_by_email(&self, email: &str) -> Result<Option<User>, ApiError>;

    /// Create a new user account.
    async fn create_user(
        &self,
        username: &str,
        email: Option<&str>,
        password_hash: &str,
    ) -> Result<String, ApiError>;

    /// Store a refresh token hash.
    async fn store_refresh_token(
        &self,
        user_id: &str,
        token_hash: &str,
        expires_at: chrono::DateTime<chrono::Utc>,
        campus_id: Option<uuid::Uuid>,
    ) -> Result<(), ApiError>;

    /// Find a refresh token record.
    async fn find_refresh_token(
        &self,
        token_hash: &str,
    ) -> Result<Option<RefreshTokenRecord>, ApiError>;

    /// Revoke a refresh token.
    async fn revoke_refresh_token(&self, token_hash: &str) -> Result<(), ApiError>;

    /// Revoke all refresh tokens for a user.
    async fn revoke_all_user_tokens(&self, user_id: &str) -> Result<(), ApiError>;
}

#[derive(Debug, Clone)]
pub struct RefreshTokenRecord {
    pub user_id: String,
    pub revoked_at: Option<chrono::DateTime<chrono::Utc>>,
    pub expires_at: chrono::DateTime<chrono::Utc>,
    pub campus_id: Option<uuid::Uuid>,
}

// ---------------------------------------------------------------------------
// Order Repository
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, serde::Serialize, sqlx::FromRow)]
#[allow(dead_code)]
pub struct Order {
    pub id: String,
    pub listing_id: String,
    pub buyer_id: String,
    pub seller_id: String,
    pub final_price: i64,
    pub status: String,
    pub cancellation_reason: Option<String>,
    pub paid_at: Option<chrono::DateTime<chrono::Utc>>,
    pub shipped_at: Option<chrono::DateTime<chrono::Utc>>,
    pub completed_at: Option<chrono::DateTime<chrono::Utc>>,
    pub cancelled_at: Option<chrono::DateTime<chrono::Utc>>,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Clone, serde::Serialize)]
#[allow(dead_code)]
pub struct OrderSummary {
    pub id: String,
    pub listing_id: String,
    pub listing_title: String,
    pub buyer_id: String,
    pub buyer_username: String,
    pub seller_id: String,
    pub seller_username: String,
    pub final_price: i64,
    pub status: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

#[allow(dead_code, async_fn_in_trait)]
pub trait OrderRepository: Send + Sync {
    /// Create a new order (caller must handle listing status update).
    async fn create(
        &self,
        id: &str,
        listing_id: &str,
        buyer_id: &str,
        seller_id: &str,
        final_price: i64,
    ) -> Result<(), ApiError>;

    /// Find an order by ID.
    async fn find_by_id(&self, id: &str) -> Result<Option<Order>, ApiError>;

    /// Find an order with buyer/seller/listing details.
    async fn find_with_details(&self, id: &str) -> Result<Option<OrderSummary>, ApiError>;

    /// List orders with filters.
    async fn list_orders(
        &self,
        user_id: Option<&str>,
        role: Option<&str>, // "buyer" | "seller"
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<OrderSummary>, i64), ApiError>;

    /// Update order status and related timestamps.
    async fn update_status(
        &self,
        order_id: &str,
        new_status: &str,
        timestamp_field: &str,
        cancellation_reason: Option<&str>,
    ) -> Result<bool, ApiError>;

    /// Count orders.
    async fn count(&self) -> Result<i64, ApiError>;
}
