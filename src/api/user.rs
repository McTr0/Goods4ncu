use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;

use crate::api::auth::extract_user_id_from_token_with_fallback;
use crate::api::error::ApiError;
use crate::api::AppState;
use crate::repositories::{
    Listing, UserLookupMethod, UserLookupResult, UserProfile, UserRepository,
};

// ---------------------------------------------------------------------------
// Response types
// ---------------------------------------------------------------------------

// UserProfile is imported from repositories::UserProfile

#[derive(Serialize)]
pub struct ListingItem {
    pub id: String,
    pub title: String,
    pub category: String,
    pub brand: String,
    pub direction: String,
    pub condition_score: i32,
    pub suggested_price_cny: f64,
    pub description: Option<String>,
    pub image_url: Option<String>,
    pub status: String,
}

#[derive(Deserialize)]
pub struct PaginationParams {
    pub limit: Option<i64>,
    pub offset: Option<i64>,
    /// Optional filter: "active", "sold", "deleted", or "all" (default: "active")
    pub status: Option<String>,
}

#[derive(Serialize)]
pub struct PaginatedListings {
    pub items: Vec<ListingItem>,
    pub total: i64,
    pub limit: i64,
    pub offset: i64,
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET /api/user/profile
pub async fn get_profile(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<UserProfile>, ApiError> {
    let user_id = extract_user_id_from_token_with_fallback(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)?;

    let profile = state.user_repo.get_profile(&user_id).await?;

    Ok(Json(profile))
}

/// PATCH /api/user/profile — update current user's profile
#[derive(Deserialize)]
pub struct UpdateProfileRequest {
    pub username: Option<String>,
    pub email: Option<String>,
    pub avatar_url: Option<String>,
    pub discoverability: Option<UpdateDiscoverabilityRequest>,
    pub chat_read_receipt_mode: Option<String>,
    pub payment_qr: Option<UpdatePaymentQrRequest>,
}

#[derive(Deserialize)]
pub struct UpdateDiscoverabilityRequest {
    pub username: Option<bool>,
    pub email: Option<bool>,
    pub student_id: Option<bool>,
}

#[derive(Deserialize)]
pub struct UpdatePaymentQrRequest {
    pub wechat_url: Option<String>,
    pub alipay_url: Option<String>,
    pub show_wechat: Option<bool>,
    pub show_alipay: Option<bool>,
}

fn validate_optional_image_url(value: &str, label: &str) -> Result<(), ApiError> {
    if value.is_empty() {
        return Ok(());
    }
    if value.len() > 2048 {
        return Err(ApiError::BadRequest(format!(
            "{label}URL不能超过2048个字符"
        )));
    }
    if !value.starts_with("http://") && !value.starts_with("https://") {
        return Err(ApiError::BadRequest(format!("{label}URL格式无效")));
    }
    Ok(())
}

pub async fn update_profile(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<UpdateProfileRequest>,
) -> Result<Json<UserProfile>, ApiError> {
    let user_id = extract_user_id_from_token_with_fallback(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)?;

    if let Some(username) = &body.username {
        if username.is_empty() {
            return Err(ApiError::BadRequest("用户名不能为空".to_string()));
        }
        if username.len() > 50 {
            return Err(ApiError::BadRequest("用户名不能超过50个字符".to_string()));
        }
        // Text content moderation — block prohibited content in username.
        let mod_result = state.infra.moderation.check_text(username);
        if !mod_result.passed {
            return Err(ApiError::ContentViolation(
                mod_result.reason.unwrap_or_default(),
            ));
        }
        state.user_repo.update_username(&user_id, username).await?;
    }

    if let Some(email) = &body.email {
        if email.is_empty() {
            return Err(ApiError::BadRequest("邮箱不能为空".to_string()));
        }
        if !email.ends_with("@email.ncu.edu.cn") {
            return Err(ApiError::BadRequest(
                "必须使用 @email.ncu.edu.cn 邮箱".to_string(),
            ));
        }
        if email.len() > 100 {
            return Err(ApiError::BadRequest("邮箱不能超过100个字符".to_string()));
        }
        state.user_repo.update_email(&user_id, email).await?;
    }

    if let Some(discoverability) = &body.discoverability {
        state
            .user_repo
            .update_discoverability(
                &user_id,
                discoverability.username,
                discoverability.email,
                discoverability.student_id,
            )
            .await?;
    }

    if let Some(mode) = &body.chat_read_receipt_mode {
        state
            .user_repo
            .update_chat_read_receipt_mode(&user_id, mode)
            .await?;
    }

    if let Some(avatar_url) = &body.avatar_url {
        if avatar_url.is_empty() {
            return Err(ApiError::BadRequest("头像URL不能为空".to_string()));
        }
        // Basic URL validation
        if !avatar_url.starts_with("http://") && !avatar_url.starts_with("https://") {
            return Err(ApiError::BadRequest("头像URL格式无效".to_string()));
        }
        // Submit avatar image for async moderation.
        state
            .infra
            .moderation
            .submit_image_job(&state.infra.db, &user_id, avatar_url, "avatar")
            .await
            .ok();
        state.user_repo.update_avatar(&user_id, avatar_url).await?;
    }

    if let Some(payment_qr) = &body.payment_qr {
        if let Some(url) = &payment_qr.wechat_url {
            validate_optional_image_url(url, "微信收款码")?;
        }
        if let Some(url) = &payment_qr.alipay_url {
            validate_optional_image_url(url, "支付宝收款码")?;
        }
        state
            .user_repo
            .update_payment_qr(
                &user_id,
                payment_qr.wechat_url.as_deref(),
                payment_qr.alipay_url.as_deref(),
                payment_qr.show_wechat,
                payment_qr.show_alipay,
            )
            .await?;
    }

    let profile = state.user_repo.get_profile(&user_id).await?;
    Ok(Json(profile))
}

/// GET /api/user/listings?limit=20&offset=0&status=active
pub async fn get_user_listings(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(params): Query<PaginationParams>,
) -> Result<Json<PaginatedListings>, ApiError> {
    let user_id = extract_user_id_from_token_with_fallback(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)?;

    let limit = params.limit.unwrap_or(20).min(100);
    let offset = params.offset.unwrap_or(0).max(0);
    let status_filter = params.status.as_deref().unwrap_or("active");
    if !["active", "sold", "deleted", "all"].contains(&status_filter) {
        return Err(ApiError::BadRequest(
            "无效的 status 参数，可选值：active, sold, deleted, all".to_string(),
        ));
    }

    let (listings, total) = state
        .user_repo
        .get_user_listings(&user_id, limit, offset, status_filter)
        .await?;

    let items: Vec<ListingItem> = listings
        .into_iter()
        .map(|listing: Listing| {
            // Parse defects JSON array into description string
            let description = listing
                .defects
                .and_then(|d| serde_json::from_str::<Vec<String>>(&d).ok())
                .map(|defects| {
                    if defects.is_empty() {
                        String::new()
                    } else {
                        defects.join(", ")
                    }
                });
            ListingItem {
                id: listing.id,
                title: listing.title,
                category: listing.category,
                brand: listing.brand.unwrap_or_default(),
                direction: listing.direction,
                condition_score: listing.condition_score,
                suggested_price_cny: listing.suggested_price_cny as f64 / 100.0,
                description,
                image_url: listing.image_url,
                status: listing.status,
            }
        })
        .collect();

    Ok(Json(PaginatedListings {
        items,
        total,
        limit,
        offset,
    }))
}

#[derive(Deserialize)]
pub struct UserSearchQuery {
    pub q: Option<String>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

#[derive(Serialize)]
pub struct UserSummary {
    pub user_id: String,
    pub username: String,
    pub listing_count: i64,
}

#[derive(Serialize)]
pub struct UserSearchResponse {
    pub items: Vec<UserSummary>,
    pub total: i64,
}

#[derive(Deserialize)]
pub struct UserLookupQuery {
    pub q: String,
    pub method: Option<String>,
    pub limit: Option<i64>,
}

#[derive(Serialize)]
pub struct UserLookupResponse {
    pub items: Vec<UserLookupResult>,
}

/// GET /api/users/search?q=keyword - search/browse users
pub async fn search_users(
    State(state): State<AppState>,
    Query(params): Query<UserSearchQuery>,
) -> Result<Json<UserSearchResponse>, ApiError> {
    let limit = params.limit.unwrap_or(20).min(50);
    let offset = params.offset.unwrap_or(0).max(0);

    // Reject oversized search patterns before they can trigger slow ILIKE scans on large tables.
    if let Some(ref q) = params.q {
        if q.len() > 50 {
            return Err(ApiError::BadRequest(
                "搜索关键词不能超过50个字符".to_string(),
            ));
        }
    }

    let query_param = params.q.as_deref();
    let (profiles_with_counts, total): (Vec<(crate::repositories::UserProfile, i64)>, i64) = state
        .user_repo
        .search_users_with_listing_count(query_param, limit, offset)
        .await?;

    let items: Vec<UserSummary> = profiles_with_counts
        .into_iter()
        .map(|(profile, listing_count)| UserSummary {
            user_id: profile.user_id,
            username: profile.username,
            listing_count,
        })
        .collect();

    Ok(Json(UserSearchResponse { items, total }))
}

/// GET /api/users/lookup?q=keyword&method=auto|username|email|student_id
pub async fn lookup_users(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(params): Query<UserLookupQuery>,
) -> Result<Json<UserLookupResponse>, ApiError> {
    let requester_id = extract_user_id_from_token_with_fallback(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)?;

    let query = params.q.trim();
    if query.is_empty() {
        return Ok(Json(UserLookupResponse { items: Vec::new() }));
    }
    if query.len() > 100 {
        return Err(ApiError::BadRequest(
            "搜索关键词不能超过100个字符".to_string(),
        ));
    }

    let method = match params.method.as_deref().unwrap_or("auto") {
        "auto" => UserLookupMethod::Auto,
        "username" => UserLookupMethod::Username,
        "email" => UserLookupMethod::Email,
        "student_id" => UserLookupMethod::StudentId,
        _ => {
            return Err(ApiError::BadRequest(
                "无效的 method 参数，可选值：auto, username, email, student_id".to_string(),
            ))
        }
    };

    if matches!(method, UserLookupMethod::Email) && !query.contains('@') {
        return Ok(Json(UserLookupResponse { items: Vec::new() }));
    }
    if matches!(method, UserLookupMethod::StudentId)
        && !((8..=12).contains(&query.len()) && query.chars().all(|ch| ch.is_ascii_digit()))
    {
        return Ok(Json(UserLookupResponse { items: Vec::new() }));
    }

    let items = state
        .user_repo
        .lookup_users(&requester_id, query, method, params.limit.unwrap_or(10))
        .await?;

    Ok(Json(UserLookupResponse { items }))
}

#[derive(Serialize)]
pub struct UserPublicProfile {
    pub user_id: String,
    pub username: String,
    pub avatar_url: Option<String>,
    pub listing_count: i64,
    pub joined_at: String,
    pub payment_qr: UserPublicPaymentQr,
}

#[derive(Serialize)]
pub struct UserPublicPaymentQr {
    pub wechat_url: Option<String>,
    pub alipay_url: Option<String>,
}

/// GET /api/users/:id - public user profile (no auth required)
pub async fn get_user_profile(
    State(state): State<AppState>,
    Path(user_id): Path<String>,
) -> Result<Json<UserPublicProfile>, ApiError> {
    let row = sqlx::query(
        r#"
        SELECT u.id as user_id, u.username, u.created_at,
               u.avatar_url,
               CASE
                   WHEN u.show_wechat_pay_qr = TRUE THEN u.wechat_pay_qr_url
                   ELSE NULL
               END AS public_wechat_pay_qr_url,
               CASE
                   WHEN u.show_alipay_qr = TRUE THEN u.alipay_qr_url
                   ELSE NULL
               END AS public_alipay_qr_url,
               COUNT(i.id) as listing_count
        FROM users u
        LEFT JOIN inventory i ON u.id = i.owner_id AND i.status = 'active'
        WHERE u.id = $1
        GROUP BY u.id, u.username, u.created_at, u.avatar_url,
                 u.show_wechat_pay_qr, u.wechat_pay_qr_url,
                 u.show_alipay_qr, u.alipay_qr_url
        "#,
    )
    .bind(&user_id)
    .fetch_optional(&state.infra.db)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
    .ok_or(ApiError::NotFound)?;

    let created_at: String = row
        .try_get::<sqlx::types::chrono::DateTime<sqlx::types::chrono::Utc>, _>("created_at")
        .map(|dt| dt.to_rfc3339())
        .unwrap_or_else(|_| String::new());

    Ok(Json(UserPublicProfile {
        user_id: row.get("user_id"),
        username: row.get("username"),
        avatar_url: row.get("avatar_url"),
        listing_count: row.get("listing_count"),
        joined_at: created_at,
        payment_qr: UserPublicPaymentQr {
            wechat_url: row.get("public_wechat_pay_qr_url"),
            alipay_url: row.get("public_alipay_qr_url"),
        },
    }))
}

/// GET /api/users/:id/listings - public active listings for a user
pub async fn get_public_user_listings(
    State(state): State<AppState>,
    Path(user_id): Path<String>,
    Query(params): Query<PaginationParams>,
) -> Result<Json<PaginatedListings>, ApiError> {
    let limit = params.limit.unwrap_or(20).clamp(1, 50);
    let offset = params.offset.unwrap_or(0).max(0);
    let (listings, total) = state
        .user_repo
        .get_user_listings(&user_id, limit, offset, "active")
        .await?;

    let items = listings
        .into_iter()
        .map(|listing| {
            let description = listing
                .defects
                .and_then(|d| serde_json::from_str::<Vec<String>>(&d).ok())
                .map(|defects| defects.join(", "));
            ListingItem {
                id: listing.id,
                title: listing.title,
                category: listing.category,
                brand: listing.brand.unwrap_or_default(),
                direction: listing.direction,
                condition_score: listing.condition_score,
                suggested_price_cny: listing.suggested_price_cny as f64 / 100.0,
                description,
                image_url: listing.image_url,
                status: listing.status,
            }
        })
        .collect();

    Ok(Json(PaginatedListings {
        items,
        total,
        limit,
        offset,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_pagination_params_defaults() {
        let params: PaginationParams = serde_json::from_str(r#"{}"#).unwrap();
        assert_eq!(params.limit, None);
        assert_eq!(params.offset, None);
    }

    #[test]
    fn test_pagination_params_with_values() {
        let params: PaginationParams =
            serde_json::from_str(r#"{"limit": 10, "offset": 20}"#).unwrap();
        assert_eq!(params.limit, Some(10));
        assert_eq!(params.offset, Some(20));
    }

    #[test]
    fn test_user_search_query_defaults() {
        let query: UserSearchQuery = serde_json::from_str(r#"{}"#).unwrap();
        assert_eq!(query.q, None);
        assert_eq!(query.limit, None);
        assert_eq!(query.offset, None);
    }

    #[test]
    fn test_user_search_query_with_search() {
        let query: UserSearchQuery = serde_json::from_str(r#"{"q": "john", "limit": 5}"#).unwrap();
        assert_eq!(query.q, Some("john".to_string()));
        assert_eq!(query.limit, Some(5));
    }

    #[test]
    fn test_user_profile_serialization() {
        let profile = UserProfile {
            user_id: "user-123".to_string(),
            username: "testuser".to_string(),
            email: Some("test@email.ncu.edu.cn".to_string()),
            student_id: None,
            discoverability: crate::repositories::UserDiscoverability {
                username: true,
                email: false,
                student_id: false,
            },
            chat_read_receipt_mode: "auto".to_string(),
            avatar_url: None,
            payment_qr: crate::repositories::UserPaymentQr {
                wechat_url: None,
                alipay_url: None,
                show_wechat: false,
                show_alipay: false,
            },
            role: "user".to_string(),
            created_at: "2024-01-01T00:00:00Z".to_string(),
        };
        let json = serde_json::to_string(&profile).unwrap();
        assert!(json.contains("user-123"));
        assert!(json.contains("testuser"));
        assert!(json.contains("\"role\":\"user\""));
    }

    #[test]
    fn test_listing_item_serialization() {
        let item = ListingItem {
            id: "listing-1".to_string(),
            title: "iPhone 13".to_string(),
            category: "electronics".to_string(),
            brand: "Apple".to_string(),
            direction: "offer".to_string(),
            condition_score: 8,
            suggested_price_cny: 4999.0,
            description: Some("Good condition".to_string()),
            image_url: Some("https://cdn.example.test/item.jpg".to_string()),
            status: "active".to_string(),
        };
        let json = serde_json::to_string(&item).unwrap();
        assert!(json.contains("iPhone 13"));
        assert!(json.contains("Apple"));
        assert!(json.contains("\"status\":\"active\""));
    }

    #[test]
    fn test_listing_item_without_description() {
        let item = ListingItem {
            id: "listing-2".to_string(),
            title: "Book".to_string(),
            category: "books".to_string(),
            brand: "Publisher".to_string(),
            direction: "offer".to_string(),
            condition_score: 5,
            suggested_price_cny: 99.0,
            description: None,
            image_url: None,
            status: "active".to_string(),
        };
        let json = serde_json::to_string(&item).unwrap();
        assert!(json.contains("Book"));
        assert!(json.contains("\"description\":null"));
    }

    #[test]
    fn test_paginated_listings_serialization() {
        let response = PaginatedListings {
            items: vec![],
            total: 0,
            limit: 20,
            offset: 0,
        };
        let json = serde_json::to_string(&response).unwrap();
        assert!(json.contains("\"items\":[]"));
        assert!(json.contains("\"total\":0"));
    }

    #[test]
    fn test_user_summary_serialization() {
        let summary = UserSummary {
            user_id: "user-456".to_string(),
            username: "seller1".to_string(),
            listing_count: 10,
        };
        let json = serde_json::to_string(&summary).unwrap();
        assert!(json.contains("user-456"));
        assert!(json.contains("seller1"));
        assert!(json.contains("10"));
    }

    #[test]
    fn test_user_search_response_serialization() {
        let response = UserSearchResponse {
            items: vec![],
            total: 0,
        };
        let json = serde_json::to_string(&response).unwrap();
        assert!(json.contains("\"items\":[]"));
        assert!(json.contains("\"total\":0"));
    }

    #[test]
    fn test_user_public_profile_serialization() {
        let profile = UserPublicProfile {
            user_id: "user-789".to_string(),
            username: "publicuser".to_string(),
            avatar_url: Some("https://cdn.example.test/avatar.jpg".to_string()),
            listing_count: 5,
            joined_at: "2024-01-15T00:00:00Z".to_string(),
            payment_qr: UserPublicPaymentQr {
                wechat_url: Some("https://cdn.example.test/wechat.jpg".to_string()),
                alipay_url: None,
            },
        };
        let json = serde_json::to_string(&profile).unwrap();
        assert!(json.contains("user-789"));
        assert!(json.contains("publicuser"));
        assert!(json.contains("\"listing_count\":5"));
        assert!(json.contains("joined_at"));
        assert!(json.contains("wechat_url"));
    }
}
