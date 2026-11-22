//! Shared repository data-transfer types.
//!
//! The old dependency-inversion traits (ListingRepository, UserRepository,
//! AuthRepository, OrderRepository) were removed: nothing used them as
//! objects or generic bounds, and they pinned an `ApiError`-returning
//! convention that conflicts with the target pattern — repositories are
//! pure persistence returning `sqlx::Result`, with transaction-taking
//! methods accepting `&mut Transaction<'_, Postgres>` (see
//! `repositories/watchlist_repo.rs` and `services/watchlist.rs` for the
//! reference shape). Concrete repositories expose their live methods as
//! inherent impls.

// ---------------------------------------------------------------------------
// Listing
// ---------------------------------------------------------------------------

/// A listing item returned from the marketplace.
#[derive(Debug, Clone, serde::Serialize, sqlx::FromRow)]
pub struct Listing {
    pub id: String,
    pub campus_id: uuid::Uuid,
    /// Database-owned optimistic-concurrency version. It advances whenever
    /// the listing's visible facts or effective visibility change.
    pub content_revision: i64,
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

// ---------------------------------------------------------------------------
// User
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, serde::Serialize, sqlx::FromRow)]
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
pub struct UserDiscoverability {
    pub username: bool,
    pub email: bool,
    pub student_id: bool,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct UserPaymentQr {
    pub wechat_url: Option<String>,
    pub alipay_url: Option<String>,
    pub show_wechat: bool,
    pub show_alipay: bool,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct UserProfile {
    pub user_id: String,
    pub username: String,
    pub email: Option<String>,
    pub student_id: Option<String>,
    pub discoverability: UserDiscoverability,
    pub avatar_url: Option<String>,
    pub payment_qr: UserPaymentQr,
    pub role: String,
    pub created_at: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UserLookupMethod {
    Auto,
    Username,
    Email,
    StudentId,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct UserLookupResult {
    pub user_id: String,
    pub username: String,
    pub matched_by: String,
    pub masked_identifier: Option<String>,
    pub listing_count: i64,
    pub can_start_conversation: bool,
}

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct RefreshTokenRecord {
    pub user_id: String,
    pub revoked_at: Option<chrono::DateTime<chrono::Utc>>,
    pub expires_at: chrono::DateTime<chrono::Utc>,
    pub campus_id: Option<uuid::Uuid>,
}
