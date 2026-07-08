use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;

use crate::api::auth::{generate_access_token, revoke_access_token_jti};
use crate::api::error::ApiError;
use crate::api::AppState;
use crate::middleware::admin::require_admin;
use crate::services::order::OrderStatus;

use crate::repositories::traits::{
    AuthRepository, ListingRepository, OrderRepository, UserRepository,
};

/// GET /api/admin/stats - admin marketplace statistics (requires admin role)
pub async fn get_admin_stats(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<AdminStats>, ApiError> {
    let _admin_id = require_admin(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )?;

    let total_listings = state.listing_repo.count(None).await?;
    let active_listings = state.listing_repo.count(Some("active")).await?;
    let total_users = state.user_repo.count_users().await?;
    let total_orders = state.order_repo.count().await?;

    // We don't have a direct count_admins in user_repo yet, but we can search for them
    // or better: add count_by_role to UserRepository.
    // For now, let's keep the raw query for the complex bit if repo doesn't serve it.
    // Actually, I'll use repo.search_users_with_listing_count with a filter if possible? No.
    // I'll stick to repo for simple counts.
    let admin_users: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM users WHERE role = 'admin'")
        .fetch_one(&state.infra.db)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    let cat_stats = state.listing_repo.get_category_stats().await?;

    let categories: Vec<CategoryCount> = cat_stats
        .into_iter()
        .map(|(category, count)| CategoryCount { category, count })
        .collect();

    Ok(Json(AdminStats {
        total_listings,
        active_listings,
        total_users,
        total_orders,
        admin_users,
        categories,
    }))
}

#[derive(Serialize)]
pub struct AdminStats {
    pub total_listings: i64,
    pub active_listings: i64,
    pub total_users: i64,
    pub total_orders: i64,
    pub admin_users: i64,
    pub categories: Vec<CategoryCount>,
}

#[derive(Serialize)]
pub struct CategoryCount {
    pub category: String,
    pub count: i64,
}

/// Query parameters for admin list endpoints
#[derive(Deserialize)]
pub struct AdminListQuery {
    pub offset: Option<i64>,
    pub limit: Option<i64>,
    pub status: Option<String>,
}

impl AdminListQuery {
    fn limit(&self) -> i64 {
        self.limit.unwrap_or(50).min(100)
    }
    fn offset(&self) -> i64 {
        self.offset.unwrap_or(0)
    }
}

/// GET /api/admin/users - list all users (requires admin role)
pub async fn get_admin_users(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AdminListQuery>,
) -> Result<Json<AdminUsersResponse>, ApiError> {
    let _admin_id = require_admin(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )?;

    let users = sqlx::query(
        r#"
        SELECT u.id, u.username, u.role, u.status, u.created_at,
               COUNT(i.id) as listing_count
        FROM users u
        LEFT JOIN inventory i ON u.id = i.owner_id
        GROUP BY u.id, u.username, u.role, u.status, u.created_at
        ORDER BY u.created_at DESC
        LIMIT $1 OFFSET $2
        "#,
    )
    .bind(query.limit())
    .bind(query.offset())
    .fetch_all(&state.infra.db)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    let total: i64 = sqlx::query("SELECT COUNT(*) as cnt FROM users")
        .fetch_one(&state.infra.db)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        .try_get("cnt")
        .map_err(|_| ApiError::Internal(anyhow::anyhow!("Failed to parse count")))?;

    let users: Vec<UserInfo> = users
        .iter()
        .map(|row| UserInfo {
            id: row.get("id"),
            username: row.get("username"),
            role: row.get("role"),
            status: row.get("status"),
            created_at: row.get("created_at"),
            listing_count: row.try_get("listing_count").unwrap_or(0),
        })
        .collect();

    Ok(Json(AdminUsersResponse { total, users }))
}

#[derive(Serialize)]
pub struct AdminUsersResponse {
    pub total: i64,
    pub users: Vec<UserInfo>,
}

#[derive(Serialize)]
pub struct UserInfo {
    pub id: String,
    pub username: String,
    pub role: String,
    pub status: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub listing_count: i64,
}

/// GET /api/admin/listings - list all listings (requires admin role)
pub async fn get_admin_listings(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AdminListQuery>,
) -> Result<Json<AdminListingsResponse>, ApiError> {
    let _admin_id = require_admin(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )?;

    let listings = sqlx::query(
        "SELECT id, title, category, brand, condition_score, suggested_price_cny, description, status, owner_id, created_at FROM inventory ORDER BY created_at DESC LIMIT $1 OFFSET $2"
    )
    .bind(query.limit())
    .bind(query.offset())
    .fetch_all(&state.infra.db)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    let total: i64 = sqlx::query("SELECT COUNT(*) as cnt FROM inventory")
        .fetch_one(&state.infra.db)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        .try_get("cnt")
        .map_err(|_| ApiError::Internal(anyhow::anyhow!("Failed to parse count")))?;

    let listings: Vec<ListingInfo> = listings
        .iter()
        .map(|row| ListingInfo {
            id: row.get("id"),
            title: row.get("title"),
            category: row.get("category"),
            brand: row.get("brand"),
            condition_score: row.get("condition_score"),
            suggested_price_cny: row.get::<i32, _>("suggested_price_cny") as f64 / 100.0,
            description: row.try_get("description").ok(),
            status: row.get("status"),
            owner_id: row.get("owner_id"),
            created_at: row.get("created_at"),
        })
        .collect();

    Ok(Json(AdminListingsResponse { total, listings }))
}

#[derive(Serialize)]
pub struct AdminListingsResponse {
    pub total: i64,
    pub listings: Vec<ListingInfo>,
}

#[derive(Serialize)]
pub struct ListingInfo {
    pub id: String,
    pub title: String,
    pub category: String,
    pub brand: String,
    pub condition_score: i32,
    pub suggested_price_cny: f64,
    pub description: Option<String>,
    pub status: String,
    pub owner_id: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

/// GET /api/admin/orders - list all orders (Admin only)
pub async fn get_admin_orders(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AdminListQuery>,
) -> Result<Json<AdminOrdersResponse>, ApiError> {
    let _admin_id = require_admin(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )?;

    let (items, total) = state
        .infra
        .order_service
        .admin_list_orders(query.status.as_deref(), query.limit(), query.offset())
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("Failed to fetch orders: {}", e)))?;

    let orders: Vec<OrderInfo> = items
        .into_iter()
        .map(|r| OrderInfo {
            id: r.id,
            listing_id: r.listing_id,
            listing_title: r.listing_title,
            buyer_id: r.buyer_id,
            buyer_username: r.buyer_username,
            seller_id: r.seller_id,
            seller_username: r.seller_username,
            final_price: r.final_price as f64 / 100.0,
            status: r.status,
            auto_delist: r.auto_delist,
            confirmed_at: r.confirmed_at,
            auto_delisted_at: r.auto_delisted_at,
            listing_status: r.listing_status,
            created_at: r.created_at,
        })
        .collect();

    Ok(Json(AdminOrdersResponse { total, orders }))
}

#[derive(Serialize)]
#[allow(dead_code)]
pub struct AdminOrdersResponse {
    pub total: i64,
    pub orders: Vec<OrderInfo>,
}

#[derive(Serialize)]
pub struct OrderInfo {
    pub id: String,
    pub listing_id: String,
    pub listing_title: String,
    pub buyer_id: String,
    pub buyer_username: String,
    pub seller_id: String,
    pub seller_username: String,
    pub final_price: f64,
    pub status: String,
    pub auto_delist: bool,
    pub confirmed_at: Option<chrono::DateTime<chrono::Utc>>,
    pub auto_delisted_at: Option<chrono::DateTime<chrono::Utc>>,
    pub listing_status: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

/// POST /api/admin/users/:user_id/ban - ban a user (requires admin role)
pub async fn ban_user(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(target_user_id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let admin_id = require_admin(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )?;

    if admin_id == target_user_id {
        return Err(ApiError::Forbidden);
    }

    let target_user = state
        .user_repo
        .find_by_id(&target_user_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    if target_user.role == "admin" {
        return Err(ApiError::Forbidden);
    }

    state.user_repo.ban_user(&target_user_id).await?;
    state
        .auth_repo
        .revoke_all_user_tokens(&target_user_id)
        .await?;

    // Log audit trail
    let _ = state
        .infra
        .admin_service
        .log_action(
            &admin_id,
            "ban_user",
            Some(&target_user_id),
            Some("active"),
            Some("banned"),
            None,
        )
        .await;

    tracing::info!(
        admin_id = %admin_id,
        target_user_id = %target_user_id,
        "Admin banned user"
    );

    Ok(Json(serde_json::json!({ "message": "用户已被封禁" })))
}

/// POST /api/admin/users/:user_id/unban - unban a user (requires admin role)
pub async fn unban_user(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(target_user_id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let admin_id = require_admin(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )?;

    if admin_id == target_user_id {
        return Err(ApiError::Forbidden);
    }

    state.user_repo.unban_user(&target_user_id).await?;

    tracing::info!(
        admin_id = %admin_id,
        target_user_id = %target_user_id,
        "Admin unbanned user"
    );

    Ok(Json(serde_json::json!({ "message": "用户已解封" })))
}

/// POST /api/admin/listings/:listing_id/takedown - takedown a listing (requires admin role)
pub async fn takedown_listing(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(listing_id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let admin_id = require_admin(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )?;

    // Fetch listing to get owner_id for repo.delete
    let listing = state
        .listing_repo
        .find_by_id(&listing_id)
        .await?
        .ok_or(ApiError::NotFound)?;

    state
        .listing_repo
        .delete(&listing_id, &listing.owner_id)
        .await?;

    // Log audit trail
    let _ = state
        .infra
        .admin_service
        .log_action(
            &admin_id,
            "takedown_listing",
            Some(&listing_id),
            Some(&listing.status),
            Some("deleted"),
            None,
        )
        .await;

    tracing::info!(
        admin_id = %admin_id,
        listing_id = %listing_id,
        "Admin took down listing"
    );

    Ok(Json(serde_json::json!({ "message": "商品已下架" })))
}

/// POST /api/admin/users/:user_id/impersonate - generate a JWT as any user (admin only)
/// WARNING: This logs an audit trail. Use with caution.
pub async fn impersonate_user(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(target_user_id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let admin_id = require_admin(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )?;

    // Use repository to fetch user info
    let user = state
        .user_repo
        .find_by_id(&target_user_id)
        .await?
        .ok_or(ApiError::NotFound)?;

    // Admins cannot impersonate other admins (security boundary)
    if user.role == "admin" {
        return Err(ApiError::Forbidden);
    }
    if user.status != "active" {
        return Err(ApiError::Forbidden);
    }

    // Generate JWT for target user (shorter TTL: 30 minutes for impersonation)
    let (token, jti, exp) = generate_access_token(
        &user.id,
        &user.role,
        &state.secrets.jwt_secret,
        1800, // 30 min TTL
    )
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("Failed to generate token: {}", e)))?;

    // Log audit trail (sensitive action!)
    let _ = state
        .infra
        .admin_service
        .log_action(
            &admin_id,
            "impersonate",
            Some(&user.id),
            None,
            None,
            Some(&format!("Impersonating user {}", user.username)),
        )
        .await;

    tracing::info!(
        admin_id = %admin_id,
        target_user_id = %user.id,
        target_username = %user.username,
        jti = %jti,
        "Admin impersonated user"
    );

    Ok(Json(serde_json::json!({
        "token": token,
        "jti": jti,
        "exp": exp,
        "user_id": user.id,
        "username": user.username,
        "role": user.role,
        "status": user.status,
        "message": "已以该用户身份登录"
    })))
}

/// POST /api/admin/tokens/:jti/revoke - revoke an access token by its JTI (admin only)
pub async fn revoke_token(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(jti): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let admin_id = require_admin(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )?;

    let expires_at = chrono::Utc::now() + chrono::Duration::hours(24);
    revoke_access_token_jti(&state, &jti, expires_at).await?;

    let _ = state
        .infra
        .admin_service
        .log_action(
            &admin_id,
            "revoke_token",
            None,
            None,
            None,
            Some(&format!("Revoked token jti={}", jti)),
        )
        .await;

    tracing::info!(admin_id = %admin_id, jti = %jti, "Admin revoked access token");

    Ok(Json(serde_json::json!({
        "jti": jti,
        "revoked": true,
        "message": "Token已吊销"
    })))
}

#[derive(Deserialize)]
#[allow(dead_code)]
pub struct UpdateOrderStatusRequest {
    pub status: String,
    pub auto_delist: Option<bool>,
    pub reason: Option<String>,
}

/// POST /api/admin/orders/:order_id/status - admin force-sets order status
pub async fn update_order_status(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(order_id): Path<String>,
    Json(payload): Json<UpdateOrderStatusRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let admin_id = require_admin(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )?;

    let requested_status_raw = payload.status.trim();
    let requested_status = match requested_status_raw {
        "completed" => "confirmed",
        value => value,
    };
    let next_status = OrderStatus::parse_status(requested_status).ok_or_else(|| {
        ApiError::BadRequest("Invalid status: must be confirmed or cancelled".to_string())
    })?;

    if next_status == OrderStatus::IntentPending {
        return Err(ApiError::BadRequest(
            "Admin endpoint does not support moving records back to pending".to_string(),
        ));
    }

    if matches!(requested_status_raw, "paid" | "shipped") {
        return Err(ApiError::BadRequest(
            "平台不负责资金中转或物流状态，后台只能确认成交或取消记录".to_string(),
        ));
    }

    let current_status_raw: String = sqlx::query_scalar("SELECT status FROM orders WHERE id = $1")
        .bind(&order_id)
        .fetch_optional(&state.infra.db)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        .ok_or(ApiError::NotFound)?;

    let success = match next_status {
        OrderStatus::Confirmed => {
            state
                .infra
                .order_service
                .confirm_order(
                    &order_id,
                    &admin_id,
                    payload.auto_delist.unwrap_or(true),
                    true,
                )
                .await
        }
        OrderStatus::Cancelled => {
            state
                .infra
                .order_service
                .cancel_order(&order_id, &admin_id, payload.reason.as_deref(), true, true)
                .await
        }
        OrderStatus::IntentPending => unreachable!("pending is rejected above"),
    }
    .map_err(|e| match e {
        crate::services::order::OrderError::NotFound => ApiError::NotFound,
        crate::services::order::OrderError::AlreadySold => {
            ApiError::Conflict("此商品已经不可售".to_string())
        }
        other => {
            tracing::error!("admin update_order_status error: {}", other);
            ApiError::Internal(anyhow::anyhow!("Failed to update order status"))
        }
    })?;

    if !success {
        return Err(ApiError::Conflict(
            "当前成交记录状态不可执行该操作".to_string(),
        ));
    }

    // Log audit trail
    let _ = state
        .infra
        .admin_service
        .log_action(
            &admin_id,
            "update_order_status",
            Some(&order_id),
            Some(&current_status_raw),
            Some(requested_status),
            None,
        )
        .await;

    tracing::info!(
        admin_id = %admin_id,
        order_id = %order_id,
        new_status = %requested_status,
        "Admin force-updated order status"
    );

    Ok(Json(
        serde_json::json!({ "message": "成交记录状态已更新", "status": requested_status }),
    ))
}

/// POST /api/admin/users/:user_id/role - admin changes user role
#[derive(Deserialize)]
pub struct UpdateRoleRequest {
    pub role: String,
}

pub async fn update_user_role(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(user_id): Path<String>,
    Json(payload): Json<UpdateRoleRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let admin_id = require_admin(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )?;

    if admin_id == user_id {
        return Err(ApiError::Forbidden);
    }

    let valid_roles = ["buyer", "seller", "admin"]; // Support adding admins too
    if !valid_roles.contains(&payload.role.as_str()) {
        return Err(ApiError::BadRequest(
            "Invalid role: must be 'buyer', 'seller', or 'admin'".to_string(),
        ));
    }

    state.user_repo.update_role(&user_id, &payload.role).await?;

    // Log audit trail
    let _ = state
        .infra
        .admin_service
        .log_action(
            &admin_id,
            "update_role",
            Some(&user_id),
            None,
            Some(&payload.role),
            None,
        )
        .await;

    tracing::info!(
        admin_id = %admin_id,
        target_user_id = %user_id,
        new_role = %payload.role,
        "Admin changed user role"
    );

    Ok(Json(serde_json::json!({ "message": "用户角色已更新" })))
}

#[derive(Deserialize)]
pub struct AdminAuditLogsQuery {
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

#[derive(Serialize)]
pub struct AdminAuditLogsResponse {
    pub total: i64,
    pub logs: Vec<crate::services::admin::AuditLogEntry>,
}

/// GET /api/admin/audit-logs - list all admin audit logs
pub async fn get_admin_audit_logs(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AdminAuditLogsQuery>,
) -> Result<Json<AdminAuditLogsResponse>, ApiError> {
    let _admin_id = require_admin(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )?;

    let limit = query.limit.unwrap_or(50);
    let offset = query.offset.unwrap_or(0);

    let (logs, total) = state
        .infra
        .admin_service
        .list_audit_logs(limit, offset)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("Failed to fetch audit logs: {}", e)))?;

    Ok(Json(AdminAuditLogsResponse { total, logs }))
}
