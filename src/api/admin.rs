use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;
use uuid::Uuid;

use crate::api::auth::{
    extract_auth_session_from_token_with_fallback, generate_access_token_for_campus,
    revoke_access_token_jti,
};
use crate::api::error::ApiError;
use crate::api::AppState;
use crate::repositories::traits::{AuthRepository, ListingRepository, UserRepository};
use crate::services::admin::NewAuditLog;
use crate::services::campus::CampusService;
use crate::services::moderation_case::{
    AppealDecision, CaseReviewAction, ModerationAppealRecord, ModerationCaseRecord,
    ModerationCaseService,
};
use crate::services::order::OrderStatus;

#[derive(Debug, Default, Deserialize)]
pub struct AdminScopeQuery {
    pub campus_id: Option<Uuid>,
    pub reason: Option<String>,
}

#[derive(Debug)]
struct AdminScope {
    actor_id: String,
    campus_id: Uuid,
    scope_reason: Option<String>,
    is_platform_admin: bool,
    recent_authentication_valid: bool,
    recent_authentication_expires_at: Option<chrono::DateTime<chrono::Utc>>,
}

async fn active_campus_exists(state: &AppState, campus_id: Uuid) -> Result<bool, ApiError> {
    sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM campuses WHERE id = $1 AND status = 'active')")
        .bind(campus_id)
        .fetch_one(&state.infra.db)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))
}

async fn require_admin_scope(
    state: &AppState,
    headers: &HeaderMap,
    requested_campus_id: Option<Uuid>,
    reason: Option<&str>,
    require_platform_admin: bool,
) -> Result<AdminScope, ApiError> {
    let session = extract_auth_session_from_token_with_fallback(
        headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)?;
    let campus_service = CampusService::new(state.infra.db.clone());
    let actor = sqlx::query("SELECT role, status FROM users WHERE id = $1")
        .bind(&session.user_id)
        .fetch_optional(&state.infra.db)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?
        .ok_or(ApiError::Unauthorized)?;
    let actor_role: String = actor.get("role");
    let actor_status: String = actor.get("status");
    if actor_status != "active" {
        return Err(ApiError::Forbidden);
    }
    let is_platform_admin = session.role == "admin" && actor_role == "admin";

    if require_platform_admin && !is_platform_admin {
        return Err(ApiError::Forbidden);
    }
    let recent_authentication_expires_at = session.recent_auth_expires_at();
    let recent_authentication_valid = session.has_recent_authentication();
    if require_platform_admin && !recent_authentication_valid {
        return Err(ApiError::RecentAuthenticationRequired);
    }

    let active_campus_id = if let Some(campus_id) = session.campus_id {
        if !active_campus_exists(state, campus_id).await? {
            return Err(ApiError::CampusScopeMismatch);
        }
        campus_id
    } else if is_platform_admin {
        match campus_service
            .resolve_session_campus(&session.user_id, None)
            .await
        {
            Ok(campus_id) => campus_id,
            Err(ApiError::CampusVerificationRequired) => {
                campus_service.default_public_campus_id().await?
            }
            Err(error) => return Err(error),
        }
    } else {
        campus_service
            .require_tenant_context_for_session(&session.user_id, None)
            .await?
            .campus_id
    };

    let campus_id = requested_campus_id.unwrap_or(active_campus_id);
    if !active_campus_exists(state, campus_id).await? {
        return Err(ApiError::NotFound);
    }

    let scope_reason = if campus_id != active_campus_id {
        if !is_platform_admin {
            return Err(ApiError::CampusScopeMismatch);
        }
        let reason = reason
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| ApiError::BadRequest("跨校园后台访问必须填写 reason".to_string()))?;
        Some(reason.to_string())
    } else {
        None
    };

    if !is_platform_admin {
        let membership_role = sqlx::query_scalar::<_, String>(
            "SELECT role FROM campus_memberships
             WHERE user_id = $1 AND campus_id = $2 AND status = 'verified'",
        )
        .bind(&session.user_id)
        .bind(campus_id)
        .fetch_optional(&state.infra.db)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
        if !matches!(membership_role.as_deref(), Some("operator" | "admin")) {
            return Err(ApiError::Forbidden);
        }
    }

    Ok(AdminScope {
        actor_id: session.user_id,
        campus_id,
        scope_reason,
        is_platform_admin,
        recent_authentication_valid,
        recent_authentication_expires_at,
    })
}

async fn require_user_in_scope(
    state: &AppState,
    user_id: &str,
    campus_id: Uuid,
) -> Result<(), ApiError> {
    let in_scope: bool = sqlx::query_scalar(
        "SELECT EXISTS(
            SELECT 1 FROM campus_memberships
            WHERE user_id = $1 AND campus_id = $2 AND status <> 'revoked'
         )",
    )
    .bind(user_id)
    .bind(campus_id)
    .fetch_one(&state.infra.db)
    .await
    .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
    if !in_scope {
        return Err(ApiError::NotFound);
    }
    Ok(())
}

async fn record_audit(
    state: &AppState,
    scope: &AdminScope,
    action: &str,
    target_id: Option<&str>,
    old_value: Option<&str>,
    new_value: Option<&str>,
    memo: Option<&str>,
) {
    if let Err(error) = state
        .infra
        .admin_service
        .log_action(NewAuditLog {
            campus_id: scope.campus_id,
            admin_id: &scope.actor_id,
            action,
            target_id,
            old_value,
            new_value,
            memo,
            scope_reason: scope.scope_reason.as_deref(),
        })
        .await
    {
        tracing::error!(%error, action, "failed to persist admin audit log");
    }
}

async fn record_cross_campus_read(state: &AppState, scope: &AdminScope, resource: &str) {
    if scope.scope_reason.is_none() {
        return;
    }
    let target_id = scope.campus_id.to_string();
    let action = format!("cross_campus_read_{}", resource);
    record_audit(state, scope, &action, Some(&target_id), None, None, None).await;
}

#[derive(Serialize)]
pub struct AdminStats {
    pub campus_id: Uuid,
    pub total_listings: i64,
    pub active_listings: i64,
    pub total_users: i64,
    pub total_orders: i64,
    pub admin_users: i64,
    pub categories: Vec<CategoryCount>,
}

#[derive(Serialize)]
pub struct AdminCapabilities {
    pub campus_id: Uuid,
    pub is_platform_admin: bool,
    pub can_read: bool,
    pub can_review: bool,
    pub can_cross_campus: bool,
    pub recent_authentication_required: bool,
    pub recent_authentication_valid: bool,
    pub recent_authentication_expires_at: Option<chrono::DateTime<chrono::Utc>>,
}

/// GET /api/admin/capabilities - authoritative active-campus admin access.
pub async fn get_admin_capabilities(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AdminScopeQuery>,
) -> Result<Json<AdminCapabilities>, ApiError> {
    let scope = require_admin_scope(
        &state,
        &headers,
        query.campus_id,
        query.reason.as_deref(),
        false,
    )
    .await?;
    record_cross_campus_read(&state, &scope, "capabilities").await;
    Ok(Json(AdminCapabilities {
        campus_id: scope.campus_id,
        is_platform_admin: scope.is_platform_admin,
        can_read: true,
        can_review: scope.is_platform_admin,
        can_cross_campus: scope.is_platform_admin,
        recent_authentication_required: scope.is_platform_admin
            && !scope.recent_authentication_valid,
        recent_authentication_valid: scope.recent_authentication_valid,
        recent_authentication_expires_at: scope.recent_authentication_expires_at,
    }))
}

#[derive(Serialize)]
pub struct CategoryCount {
    pub category: String,
    pub count: i64,
}

/// POST /api/admin/spaces/form — run space formation now for one campus.
///
/// The worker sweeps hourly, which is right for steady state and wrong at the
/// start: while the pool is thin an operator wants to see whether the intents
/// that exist are enough to put anyone together, without waiting out the clock.
///
/// Returns the refusals as well as the spaces. A run that keeps declining for
/// `too_familiar` is the campus fragmenting into cliques, and that is the
/// number worth watching — it does not show up anywhere else.
pub async fn form_spaces_now(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AdminScopeQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let scope = require_admin_scope(
        &state,
        &headers,
        query.campus_id,
        query.reason.as_deref(),
        false,
    )
    .await?;

    let service = crate::services::aggregation::AggregationService::new(state.infra.db.clone());
    // Archive first, so a room whose job is done is not counted as company for
    // the formation decisions in this same run.
    let archived = service.archive_spent().await.map_err(ApiError::Internal)?;

    let mut formed = Vec::new();
    let mut declined = Vec::new();
    for kind in [
        crate::services::intent::kinds::COMPANION,
        crate::services::intent::kinds::ACTIVITY,
        crate::services::intent::kinds::HELP,
    ] {
        let (spaces, refusals) = service
            .form_spaces(scope.campus_id, kind)
            .await
            .map_err(ApiError::Internal)?;
        for space in spaces {
            formed.push(serde_json::json!({
                "space_id": space.space_id,
                "kind": kind,
                "name": space.name,
                "members": space.members.len(),
                "reason": space.formation_reason,
            }));
        }
        for refusal in refusals {
            declined.push(serde_json::json!({
                "kind": kind,
                "reason": format!("{:?}", refusal),
            }));
        }
    }

    Ok(Json(serde_json::json!({
        "archived": archived,
        "formed": formed,
        "declined": declined,
    })))
}

/// GET /api/admin/community-health — outcome metrics for the selected campus.
///
/// Kept apart from [`get_admin_stats`] on purpose. That endpoint reports how
/// much stuff exists — listings, members, orders — which is the wrong thing to
/// steer by: every one of those numbers rises when a community turns into a
/// feed. This one reports whether the place works. Whether posts get answered,
/// whether arrangements actually happen, whether strangers come back to each
/// other, whether newcomers stay, whether proactive notifications earn the
/// interruption.
///
/// Relationship figures are counts only. On a single campus, *which* people
/// deal with each other is sensitive, and an operations dashboard has no
/// business surfacing it.
pub async fn get_community_health(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<CommunityHealthQuery>,
) -> Result<Json<crate::services::community_health::CommunityHealth>, ApiError> {
    let scope = require_admin_scope(
        &state,
        &headers,
        query.scope.campus_id,
        query.scope.reason.as_deref(),
        false,
    )
    .await?;
    record_cross_campus_read(&state, &scope, "community_health").await;

    let health =
        crate::services::community_health::CommunityHealthService::new(state.infra.db.clone())
            .measure(scope.campus_id, query.days.unwrap_or(30))
            .await
            .map_err(ApiError::Internal)?;

    Ok(Json(health))
}

#[derive(Deserialize)]
pub struct CommunityHealthQuery {
    #[serde(flatten)]
    pub scope: AdminScopeQuery,
    /// Look-back window in days; clamped to 1–365 by the service.
    pub days: Option<i64>,
}

/// GET /api/admin/stats - statistics for the selected administrative campus.
pub async fn get_admin_stats(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AdminScopeQuery>,
) -> Result<Json<AdminStats>, ApiError> {
    let scope = require_admin_scope(
        &state,
        &headers,
        query.campus_id,
        query.reason.as_deref(),
        false,
    )
    .await?;
    record_cross_campus_read(&state, &scope, "stats").await;

    let row = sqlx::query(
        "SELECT
            (SELECT COUNT(*) FROM inventory WHERE campus_id = $1) AS total_listings,
            (SELECT COUNT(*) FROM inventory WHERE campus_id = $1 AND status = 'active') AS active_listings,
            (SELECT COUNT(*) FROM campus_memberships WHERE campus_id = $1 AND status <> 'revoked') AS total_users,
            (SELECT COUNT(*) FROM orders WHERE campus_id = $1) AS total_orders,
            (SELECT COUNT(*) FROM campus_memberships membership
             JOIN users u ON u.id = membership.user_id
             WHERE membership.campus_id = $1 AND membership.status <> 'revoked'
               AND (membership.role IN ('operator', 'admin') OR u.role = 'admin')) AS admin_users",
    )
    .bind(scope.campus_id)
    .fetch_one(&state.infra.db)
    .await
    .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;

    let categories = sqlx::query(
        "SELECT category, COUNT(*) AS count
         FROM inventory WHERE campus_id = $1
         GROUP BY category ORDER BY count DESC, category ASC",
    )
    .bind(scope.campus_id)
    .fetch_all(&state.infra.db)
    .await
    .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?
    .into_iter()
    .map(|category| CategoryCount {
        category: category.get("category"),
        count: category.get("count"),
    })
    .collect();

    Ok(Json(AdminStats {
        campus_id: scope.campus_id,
        total_listings: row.get("total_listings"),
        active_listings: row.get("active_listings"),
        total_users: row.get("total_users"),
        total_orders: row.get("total_orders"),
        admin_users: row.get("admin_users"),
        categories,
    }))
}

#[derive(Default, Deserialize)]
pub struct AdminListQuery {
    pub offset: Option<i64>,
    pub limit: Option<i64>,
    pub status: Option<String>,
    pub q: Option<String>,
    pub campus_id: Option<Uuid>,
    pub reason: Option<String>,
}

impl AdminListQuery {
    fn limit(&self) -> i64 {
        self.limit.unwrap_or(50).clamp(1, 100)
    }

    fn offset(&self) -> i64 {
        self.offset.unwrap_or(0).max(0)
    }
}

#[derive(Serialize)]
pub struct AdminUsersResponse {
    pub campus_id: Uuid,
    pub total: i64,
    pub users: Vec<UserInfo>,
}

#[derive(Serialize)]
pub struct UserInfo {
    pub id: String,
    pub username: String,
    pub role: String,
    pub membership_role: String,
    pub membership_status: String,
    pub status: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub listing_count: i64,
}

/// GET /api/admin/users - users belonging to the selected campus.
pub async fn get_admin_users(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AdminListQuery>,
) -> Result<Json<AdminUsersResponse>, ApiError> {
    let scope = require_admin_scope(
        &state,
        &headers,
        query.campus_id,
        query.reason.as_deref(),
        false,
    )
    .await?;
    record_cross_campus_read(&state, &scope, "users").await;
    let search_term = query.q.as_deref().map(str::trim).filter(|q| !q.is_empty());
    let users = sqlx::query(
        "SELECT u.id, u.username, u.role, u.status, u.created_at,
                membership.role AS membership_role,
                membership.status AS membership_status,
                COUNT(i.id) AS listing_count
         FROM campus_memberships membership
         JOIN users u ON u.id = membership.user_id
         LEFT JOIN inventory i ON i.owner_id = u.id AND i.campus_id = membership.campus_id
         WHERE membership.campus_id = $1 AND membership.status <> 'revoked'
           AND ($2::TEXT IS NULL
                OR STRPOS(LOWER(u.username), LOWER($2)) > 0
                OR STRPOS(LOWER(u.id), LOWER($2)) > 0)
         GROUP BY u.id, u.username, u.role, u.status, u.created_at,
                  membership.role, membership.status
         ORDER BY u.created_at DESC
         LIMIT $3 OFFSET $4",
    )
    .bind(scope.campus_id)
    .bind(search_term)
    .bind(query.limit())
    .bind(query.offset())
    .fetch_all(&state.infra.db)
    .await
    .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
    let total = sqlx::query_scalar(
        "SELECT COUNT(*)
         FROM campus_memberships membership
         JOIN users u ON u.id = membership.user_id
         WHERE membership.campus_id = $1 AND membership.status <> 'revoked'
           AND ($2::TEXT IS NULL
                OR STRPOS(LOWER(u.username), LOWER($2)) > 0
                OR STRPOS(LOWER(u.id), LOWER($2)) > 0)",
    )
    .bind(scope.campus_id)
    .bind(search_term)
    .fetch_one(&state.infra.db)
    .await
    .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;

    Ok(Json(AdminUsersResponse {
        campus_id: scope.campus_id,
        total,
        users: users
            .into_iter()
            .map(|row| UserInfo {
                id: row.get("id"),
                username: row.get("username"),
                role: row.get("role"),
                membership_role: row.get("membership_role"),
                membership_status: row.get("membership_status"),
                status: row.get("status"),
                created_at: row.get("created_at"),
                listing_count: row.get("listing_count"),
            })
            .collect(),
    }))
}

#[derive(Serialize)]
pub struct AdminListingsResponse {
    pub campus_id: Uuid,
    pub total: i64,
    pub listings: Vec<ListingInfo>,
}

#[derive(Serialize)]
pub struct ListingInfo {
    pub id: String,
    pub title: String,
    pub category: String,
    pub brand: String,
    pub direction: String,
    pub condition_score: i32,
    pub suggested_price_cny: f64,
    pub description: Option<String>,
    pub status: String,
    pub owner_id: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

/// GET /api/admin/listings - listings owned by the selected campus.
pub async fn get_admin_listings(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AdminListQuery>,
) -> Result<Json<AdminListingsResponse>, ApiError> {
    let scope = require_admin_scope(
        &state,
        &headers,
        query.campus_id,
        query.reason.as_deref(),
        false,
    )
    .await?;
    record_cross_campus_read(&state, &scope, "listings").await;
    let listings = sqlx::query(
        "SELECT id, title, category, COALESCE(brand, '') AS brand, direction, condition_score,
                suggested_price_cny, description, status, owner_id, created_at
         FROM inventory
         WHERE campus_id = $1 AND ($2::text IS NULL OR status = $2)
         ORDER BY created_at DESC LIMIT $3 OFFSET $4",
    )
    .bind(scope.campus_id)
    .bind(query.status.as_deref())
    .bind(query.limit())
    .bind(query.offset())
    .fetch_all(&state.infra.db)
    .await
    .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
    let total = sqlx::query_scalar(
        "SELECT COUNT(*) FROM inventory
         WHERE campus_id = $1 AND ($2::text IS NULL OR status = $2)",
    )
    .bind(scope.campus_id)
    .bind(query.status.as_deref())
    .fetch_one(&state.infra.db)
    .await
    .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;

    Ok(Json(AdminListingsResponse {
        campus_id: scope.campus_id,
        total,
        listings: listings
            .into_iter()
            .map(|row| ListingInfo {
                id: row.get("id"),
                title: row.get("title"),
                category: row.get("category"),
                brand: row.get("brand"),
                direction: row.get("direction"),
                condition_score: row.get("condition_score"),
                suggested_price_cny: row.get::<i64, _>("suggested_price_cny") as f64 / 100.0,
                description: row.try_get("description").ok(),
                status: row.get("status"),
                owner_id: row.get("owner_id"),
                created_at: row.get("created_at"),
            })
            .collect(),
    }))
}

#[derive(Serialize)]
pub struct AdminOrdersResponse {
    pub campus_id: Uuid,
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

pub async fn get_admin_orders(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AdminListQuery>,
) -> Result<Json<AdminOrdersResponse>, ApiError> {
    let scope = require_admin_scope(
        &state,
        &headers,
        query.campus_id,
        query.reason.as_deref(),
        false,
    )
    .await?;
    record_cross_campus_read(&state, &scope, "orders").await;
    let (items, total) = state
        .infra
        .order_service
        .admin_list_orders(
            scope.campus_id,
            query.status.as_deref(),
            query.limit(),
            query.offset(),
        )
        .await
        .map_err(|error| {
            ApiError::Internal(anyhow::anyhow!("Failed to fetch orders: {}", error))
        })?;
    Ok(Json(AdminOrdersResponse {
        campus_id: scope.campus_id,
        total,
        orders: items
            .into_iter()
            .map(|row| OrderInfo {
                id: row.id,
                listing_id: row.listing_id,
                listing_title: row.listing_title,
                buyer_id: row.buyer_id,
                buyer_username: row.buyer_username,
                seller_id: row.seller_id,
                seller_username: row.seller_username,
                final_price: row.final_price as f64 / 100.0,
                status: row.status,
                auto_delist: row.auto_delist,
                confirmed_at: row.confirmed_at,
                auto_delisted_at: row.auto_delisted_at,
                listing_status: row.listing_status,
                created_at: row.created_at,
            })
            .collect(),
    }))
}

#[derive(Serialize, sqlx::FromRow)]
pub struct ModerationJobInfo {
    pub id: String,
    pub campus_id: Uuid,
    pub resource_type: String,
    pub resource_id: String,
    pub image_url: String,
    pub status: String,
    pub reject_reason: Option<String>,
    pub retry_count: i32,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub processed_at: Option<chrono::DateTime<chrono::Utc>>,
}

#[derive(Serialize)]
pub struct ModerationJobsResponse {
    pub campus_id: Uuid,
    pub total: i64,
    pub jobs: Vec<ModerationJobInfo>,
}

/// GET /api/admin/moderation/jobs - campus-scoped asynchronous moderation queue.
pub async fn get_moderation_jobs(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AdminListQuery>,
) -> Result<Json<ModerationJobsResponse>, ApiError> {
    let scope = require_admin_scope(
        &state,
        &headers,
        query.campus_id,
        query.reason.as_deref(),
        false,
    )
    .await?;
    record_cross_campus_read(&state, &scope, "moderation_jobs").await;
    let jobs = sqlx::query_as::<_, ModerationJobInfo>(
        "SELECT id, campus_id, resource_type, resource_id, image_url, status,
                reject_reason, retry_count, created_at, processed_at
         FROM moderation_jobs
         WHERE campus_id = $1 AND ($2::text IS NULL OR status = $2)
         ORDER BY created_at DESC LIMIT $3 OFFSET $4",
    )
    .bind(scope.campus_id)
    .bind(query.status.as_deref())
    .bind(query.limit())
    .bind(query.offset())
    .fetch_all(&state.infra.db)
    .await
    .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
    let total = sqlx::query_scalar(
        "SELECT COUNT(*) FROM moderation_jobs
         WHERE campus_id = $1 AND ($2::text IS NULL OR status = $2)",
    )
    .bind(scope.campus_id)
    .bind(query.status.as_deref())
    .fetch_one(&state.infra.db)
    .await
    .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
    Ok(Json(ModerationJobsResponse {
        campus_id: scope.campus_id,
        total,
        jobs,
    }))
}

#[derive(Serialize)]
pub struct AdminModerationCasesResponse {
    pub campus_id: Uuid,
    pub total: i64,
    pub cases: Vec<ModerationCaseRecord>,
}

/// GET /api/admin/moderation/cases - campus-scoped case queue.
pub async fn get_moderation_cases(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AdminListQuery>,
) -> Result<Json<AdminModerationCasesResponse>, ApiError> {
    let scope = require_admin_scope(
        &state,
        &headers,
        query.campus_id,
        query.reason.as_deref(),
        false,
    )
    .await?;
    record_cross_campus_read(&state, &scope, "moderation_cases").await;
    let (cases, total) = ModerationCaseService::new(state.infra.db.clone())
        .list_for_admin(
            scope.campus_id,
            query.status.as_deref(),
            query.limit(),
            query.offset(),
        )
        .await?;
    Ok(Json(AdminModerationCasesResponse {
        campus_id: scope.campus_id,
        total,
        cases,
    }))
}

#[derive(Deserialize)]
pub struct ReviewModerationCaseBody {
    pub action: String,
    pub note: Option<String>,
    pub public_reason: Option<String>,
}

/// POST /api/admin/moderation/cases/{id}/review - platform moderation decision.
pub async fn review_moderation_case(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(case_id): Path<Uuid>,
    Query(query): Query<AdminScopeQuery>,
    Json(body): Json<ReviewModerationCaseBody>,
) -> Result<Json<ModerationCaseRecord>, ApiError> {
    let scope = require_admin_scope(
        &state,
        &headers,
        query.campus_id,
        query.reason.as_deref(),
        true,
    )
    .await?;
    let action = match body.action.as_str() {
        "start_review" => CaseReviewAction::StartReview,
        "restrict" => CaseReviewAction::Restrict,
        "dismiss" => CaseReviewAction::Dismiss,
        "restore" => CaseReviewAction::Restore,
        _ => return Err(ApiError::BadRequest("无效的案件处置动作".to_string())),
    };
    let old_status = sqlx::query_scalar::<_, String>(
        "SELECT status FROM moderation_cases WHERE id = $1 AND campus_id = $2",
    )
    .bind(case_id)
    .bind(scope.campus_id)
    .fetch_optional(&state.infra.db)
    .await
    .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?
    .ok_or(ApiError::NotFound)?;
    let moderation_case = ModerationCaseService::new(state.infra.db.clone())
        .review_case(
            case_id,
            scope.campus_id,
            &scope.actor_id,
            action,
            body.note.as_deref(),
            body.public_reason.as_deref(),
        )
        .await?;
    let case_target = case_id.to_string();
    let audit_action = format!("moderation_case_{}", body.action);
    record_audit(
        &state,
        &scope,
        &audit_action,
        Some(&case_target),
        Some(&old_status),
        Some(&moderation_case.status),
        body.note.as_deref(),
    )
    .await;
    Ok(Json(moderation_case))
}

#[derive(Deserialize)]
pub struct ReviewModerationAppealBody {
    pub decision: String,
    pub note: String,
}

/// POST /api/admin/moderation/appeals/{id}/review - independent appeal review.
pub async fn review_moderation_appeal(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(appeal_id): Path<Uuid>,
    Query(query): Query<AdminScopeQuery>,
    Json(body): Json<ReviewModerationAppealBody>,
) -> Result<Json<ModerationAppealRecord>, ApiError> {
    let scope = require_admin_scope(
        &state,
        &headers,
        query.campus_id,
        query.reason.as_deref(),
        true,
    )
    .await?;
    let decision = match body.decision.as_str() {
        "uphold" => AppealDecision::Uphold,
        "overturn" => AppealDecision::Overturn,
        _ => return Err(ApiError::BadRequest("无效的申诉决定".to_string())),
    };
    let appeal = ModerationCaseService::new(state.infra.db.clone())
        .review_appeal(
            appeal_id,
            scope.campus_id,
            &scope.actor_id,
            decision,
            &body.note,
        )
        .await?;
    let appeal_target = appeal_id.to_string();
    let audit_action = format!("moderation_appeal_{}", body.decision);
    record_audit(
        &state,
        &scope,
        &audit_action,
        Some(&appeal_target),
        Some("pending"),
        Some(&appeal.status),
        Some(&body.note),
    )
    .await;
    Ok(Json(appeal))
}

pub async fn ban_user(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(target_user_id): Path<String>,
    Query(query): Query<AdminScopeQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let scope = require_admin_scope(
        &state,
        &headers,
        query.campus_id,
        query.reason.as_deref(),
        true,
    )
    .await?;
    require_user_in_scope(&state, &target_user_id, scope.campus_id).await?;
    if scope.actor_id == target_user_id {
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
    record_audit(
        &state,
        &scope,
        "ban_user",
        Some(&target_user_id),
        Some(&target_user.status),
        Some("banned"),
        None,
    )
    .await;
    Ok(Json(serde_json::json!({ "message": "用户已被封禁" })))
}

pub async fn unban_user(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(target_user_id): Path<String>,
    Query(query): Query<AdminScopeQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let scope = require_admin_scope(
        &state,
        &headers,
        query.campus_id,
        query.reason.as_deref(),
        true,
    )
    .await?;
    require_user_in_scope(&state, &target_user_id, scope.campus_id).await?;
    if scope.actor_id == target_user_id {
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
    state.user_repo.unban_user(&target_user_id).await?;
    record_audit(
        &state,
        &scope,
        "unban_user",
        Some(&target_user_id),
        Some(&target_user.status),
        Some("active"),
        None,
    )
    .await;
    Ok(Json(serde_json::json!({ "message": "用户已解封" })))
}

#[derive(serde::Deserialize)]
pub struct CreateCampusRequest {
    pub slug: String,
    pub name_zh: String,
    pub name_en: String,
    pub email_domains: Vec<String>,
}

/// POST /api/admin/campuses — platform-admin campus onboarding (Phase 4).
///
/// New campuses are created `inactive`: invisible to the public list,
/// ineligible for registration and membership verification. Activation is a
/// separate audited step, so a half-configured campus can never accept users.
pub async fn create_campus(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AdminScopeQuery>,
    Json(payload): Json<CreateCampusRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let scope = require_admin_scope(
        &state,
        &headers,
        query.campus_id,
        query.reason.as_deref(),
        true,
    )
    .await?;

    let slug = payload.slug.trim().to_ascii_lowercase();
    if payload.name_zh.trim().is_empty() || payload.name_en.trim().is_empty() {
        return Err(ApiError::BadRequest("校园名称不能为空".to_string()));
    }
    if payload.email_domains.is_empty() || payload.email_domains.len() > 8 {
        return Err(ApiError::BadRequest(
            "必须提供 1-8 个校园邮箱域名".to_string(),
        ));
    }
    let mut domains = Vec::with_capacity(payload.email_domains.len());
    for domain in &payload.email_domains {
        let domain = domain.trim().to_ascii_lowercase();
        if domain.is_empty()
            || domain.contains('@')
            || !domain.contains('.')
            || !domain
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-'))
        {
            return Err(ApiError::BadRequest(format!("无效的邮箱域名: {domain}")));
        }
        domains.push(domain);
    }

    let campus_id: Uuid = sqlx::query_scalar(
        "INSERT INTO campuses (id, slug, name_zh, name_en, email_domains, status)
         VALUES (gen_random_uuid(), $1, $2, $3, $4, 'inactive')
         RETURNING id",
    )
    .bind(&slug)
    .bind(payload.name_zh.trim())
    .bind(payload.name_en.trim())
    .bind(&domains)
    .fetch_one(&state.infra.db)
    .await
    .map_err(|e| {
        if e.as_database_error()
            .and_then(|db| db.code())
            .is_some_and(|code| code == "23505")
        {
            ApiError::Conflict("该校园 slug 已存在".to_string())
        } else if e
            .as_database_error()
            .and_then(|db| db.code())
            .is_some_and(|code| code == "23514")
        {
            ApiError::BadRequest("slug 只能是小写字母、数字和连字符".to_string())
        } else {
            ApiError::Internal(anyhow::anyhow!("DB error: {}", e))
        }
    })?;

    record_audit(
        &state,
        &scope,
        "create_campus",
        Some(&campus_id.to_string()),
        None,
        Some(&slug),
        None,
    )
    .await;

    Ok(Json(serde_json::json!({
        "id": campus_id.to_string(),
        "slug": slug,
        "status": "inactive",
    })))
}

/// POST /api/admin/campuses/{id}/activate | /deactivate — audited status flip.
pub async fn set_campus_status(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((campus_id, action)): Path<(Uuid, String)>,
    Query(query): Query<AdminScopeQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let scope = require_admin_scope(
        &state,
        &headers,
        query.campus_id,
        query.reason.as_deref(),
        true,
    )
    .await?;
    let new_status = match action.as_str() {
        "activate" => "active",
        "deactivate" => "inactive",
        _ => return Err(ApiError::NotFound),
    };

    let old_status: String = sqlx::query_scalar(
        "UPDATE campuses SET status = $2, updated_at = NOW()
         WHERE id = $1
         RETURNING (SELECT status FROM campuses WHERE id = $1)",
    )
    .bind(campus_id)
    .bind(new_status)
    .fetch_optional(&state.infra.db)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
    .ok_or(ApiError::NotFound)?;

    record_audit(
        &state,
        &scope,
        "set_campus_status",
        Some(&campus_id.to_string()),
        Some(&old_status),
        Some(new_status),
        None,
    )
    .await;

    Ok(Json(serde_json::json!({
        "id": campus_id.to_string(),
        "status": new_status,
    })))
}

pub async fn takedown_listing(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(listing_id): Path<String>,
    Query(query): Query<AdminScopeQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let scope = require_admin_scope(
        &state,
        &headers,
        query.campus_id,
        query.reason.as_deref(),
        true,
    )
    .await?;
    let listing = state
        .listing_repo
        .find_by_id(&listing_id)
        .await?
        .filter(|listing| listing.campus_id == scope.campus_id)
        .ok_or(ApiError::NotFound)?;
    state
        .listing_repo
        .delete(&listing_id, &listing.owner_id)
        .await?;
    record_audit(
        &state,
        &scope,
        "takedown_listing",
        Some(&listing_id),
        Some(&listing.status),
        Some("deleted"),
        None,
    )
    .await;
    Ok(Json(serde_json::json!({ "message": "商品已下架" })))
}

pub async fn impersonate_user(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(target_user_id): Path<String>,
    Query(query): Query<AdminScopeQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let scope = require_admin_scope(
        &state,
        &headers,
        query.campus_id,
        query.reason.as_deref(),
        true,
    )
    .await?;
    require_user_in_scope(&state, &target_user_id, scope.campus_id).await?;
    let user = state
        .user_repo
        .find_by_id(&target_user_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    if user.role == "admin" || user.status != "active" {
        return Err(ApiError::Forbidden);
    }
    let (token, jti, exp) = generate_access_token_for_campus(
        &user.id,
        &user.role,
        Some(scope.campus_id),
        &state.secrets.jwt_secret,
        1800,
    )
    .map_err(|error| ApiError::Internal(anyhow::anyhow!("Failed to generate token: {}", error)))?;
    let memo = format!("Impersonating user {}", user.username);
    record_audit(
        &state,
        &scope,
        "impersonate",
        Some(&user.id),
        None,
        None,
        Some(&memo),
    )
    .await;
    Ok(Json(serde_json::json!({
        "token": token,
        "jti": jti,
        "exp": exp,
        "user_id": user.id,
        "username": user.username,
        "role": user.role,
        "status": user.status,
        "campus_id": scope.campus_id,
        "message": "已以该用户身份登录"
    })))
}

pub async fn revoke_token(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(jti): Path<String>,
    Query(query): Query<AdminScopeQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let scope = require_admin_scope(
        &state,
        &headers,
        query.campus_id,
        query.reason.as_deref(),
        true,
    )
    .await?;
    let expires_at = chrono::Utc::now() + chrono::Duration::hours(24);
    revoke_access_token_jti(&state, &jti, expires_at).await?;
    let memo = format!("Revoked token jti={}", jti);
    record_audit(
        &state,
        &scope,
        "revoke_token",
        None,
        None,
        None,
        Some(&memo),
    )
    .await;
    Ok(Json(serde_json::json!({
        "jti": jti,
        "revoked": true,
        "message": "Token已吊销"
    })))
}

#[derive(Deserialize)]
pub struct UpdateOrderStatusRequest {
    pub status: String,
    pub auto_delist: Option<bool>,
    pub reason: Option<String>,
}

pub async fn update_order_status(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(order_id): Path<String>,
    Query(query): Query<AdminScopeQuery>,
    Json(payload): Json<UpdateOrderStatusRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let scope = require_admin_scope(
        &state,
        &headers,
        query.campus_id,
        query.reason.as_deref(),
        true,
    )
    .await?;
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
    let order = sqlx::query("SELECT status, campus_id FROM orders WHERE id = $1")
        .bind(&order_id)
        .fetch_optional(&state.infra.db)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?
        .ok_or(ApiError::NotFound)?;
    let current_status_raw: String = order.get("status");
    let order_campus_id: Uuid = order.get("campus_id");
    if order_campus_id != scope.campus_id {
        return Err(ApiError::NotFound);
    }
    let success = match next_status {
        OrderStatus::Confirmed => {
            state
                .infra
                .order_service
                .confirm_order(
                    &order_id,
                    &scope.actor_id,
                    payload.auto_delist.unwrap_or(true),
                    true,
                )
                .await
        }
        OrderStatus::Cancelled => {
            state
                .infra
                .order_service
                .cancel_order(
                    &order_id,
                    &scope.actor_id,
                    payload.reason.as_deref(),
                    true,
                    true,
                )
                .await
        }
        OrderStatus::IntentPending => unreachable!("pending is rejected above"),
    }
    .map_err(|error| match error {
        crate::services::order::OrderError::NotFound => ApiError::NotFound,
        crate::services::order::OrderError::AlreadySold => {
            ApiError::Conflict("此商品已经不可售".to_string())
        }
        other => ApiError::Internal(anyhow::anyhow!("Failed to update order status: {}", other)),
    })?;
    if !success {
        return Err(ApiError::Conflict(
            "当前成交记录状态不可执行该操作".to_string(),
        ));
    }
    record_audit(
        &state,
        &scope,
        "update_order_status",
        Some(&order_id),
        Some(&current_status_raw),
        Some(requested_status),
        payload.reason.as_deref(),
    )
    .await;
    Ok(Json(serde_json::json!({
        "message": "成交记录状态已更新",
        "status": requested_status
    })))
}

#[derive(Deserialize)]
pub struct UpdateRoleRequest {
    pub role: String,
}

pub async fn update_user_role(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(user_id): Path<String>,
    Query(query): Query<AdminScopeQuery>,
    Json(payload): Json<UpdateRoleRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let scope = require_admin_scope(
        &state,
        &headers,
        query.campus_id,
        query.reason.as_deref(),
        true,
    )
    .await?;
    require_user_in_scope(&state, &user_id, scope.campus_id).await?;
    if scope.actor_id == user_id {
        return Err(ApiError::Forbidden);
    }
    let valid_roles = ["user", "buyer", "seller", "admin"];
    if !valid_roles.contains(&payload.role.as_str()) {
        return Err(ApiError::BadRequest(
            "Invalid role: must be user, buyer, seller, or admin".to_string(),
        ));
    }
    let old_role = state
        .user_repo
        .find_by_id(&user_id)
        .await?
        .ok_or(ApiError::NotFound)?
        .role;
    state.user_repo.update_role(&user_id, &payload.role).await?;
    record_audit(
        &state,
        &scope,
        "update_role",
        Some(&user_id),
        Some(&old_role),
        Some(&payload.role),
        None,
    )
    .await;
    Ok(Json(serde_json::json!({ "message": "用户角色已更新" })))
}

#[derive(Default, Deserialize)]
pub struct AdminAuditLogsQuery {
    pub limit: Option<i64>,
    pub offset: Option<i64>,
    pub campus_id: Option<Uuid>,
    pub reason: Option<String>,
}

#[derive(Serialize)]
pub struct AdminAuditLogsResponse {
    pub campus_id: Uuid,
    pub total: i64,
    pub logs: Vec<crate::services::admin::AuditLogEntry>,
}

pub async fn get_admin_audit_logs(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AdminAuditLogsQuery>,
) -> Result<Json<AdminAuditLogsResponse>, ApiError> {
    let scope = require_admin_scope(
        &state,
        &headers,
        query.campus_id,
        query.reason.as_deref(),
        false,
    )
    .await?;
    record_cross_campus_read(&state, &scope, "audit_logs").await;
    let (logs, total) = state
        .infra
        .admin_service
        .list_audit_logs(
            scope.campus_id,
            query.limit.unwrap_or(50).clamp(1, 100),
            query.offset.unwrap_or(0).max(0),
        )
        .await
        .map_err(|error| {
            ApiError::Internal(anyhow::anyhow!("Failed to fetch audit logs: {}", error))
        })?;
    Ok(Json(AdminAuditLogsResponse {
        campus_id: scope.campus_id,
        total,
        logs,
    }))
}
