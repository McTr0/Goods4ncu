use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::Row;

use crate::api::error::ApiError;
use crate::api::request_context::idempotency_key_from_headers;
use crate::api::session::{OptionalSession, Session, VerifiedTenant};
use crate::api::AppState;
use crate::categories::MARKETPLACE_CATEGORIES;
#[cfg(test)]
use crate::repositories::CreateListingInput;
use crate::repositories::{ListingRepository, UpdateOwnedResult};
use crate::services::campus::CampusService;
use crate::services::listing_command::{
    CreateListingDraft, ListingCommandService, UpdateListingDraft,
};
use crate::services::notification::NewNotification;
use crate::services::wanted_match::WantedMatchService;
use crate::utils::cents_to_yuan;

// ---------------------------------------------------------------------------
// Query params
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct ListingQuery {
    pub limit: Option<i64>,
    pub offset: Option<i64>,
    /// Single category filter.
    pub category: Option<String>,
    /// Multiple categories filter, comma-separated (e.g. "electronics,books").
    pub categories: Option<String>,
    pub search: Option<String>,
    pub sort: Option<String>, // "newest" (default), "price_asc", "price_desc", "condition_desc"
    /// Listing direction: "offer" (default), "wanted", or "all".
    pub direction: Option<String>,
    /// Minimum price in CNY (inclusive).
    pub min_price_cny: Option<f64>,
    /// Maximum price in CNY (inclusive).
    pub max_price_cny: Option<f64>,
}

// ---------------------------------------------------------------------------
// Response types
// ---------------------------------------------------------------------------

/// Summary view returned by GET /api/listings (browse grid)
#[derive(Serialize)]
pub struct ListingSummary {
    pub id: String,
    pub title: String,
    pub category: String,
    pub brand: String,
    pub direction: String,
    pub condition_score: i32,
    pub suggested_price_cny: f64,
    pub status: String,
    pub image_url: Option<String>,
    /// First defect description, useful as a quick condition hint for buyers.
    pub defect_hint: Option<String>,
}

#[derive(Serialize)]
pub struct ListingsResponse {
    pub items: Vec<ListingSummary>,
    pub total: i64,
    pub limit: i64,
    pub offset: i64,
}

/// Version of the deterministic hard constraints and per-viewer ordering used
/// by the legacy wanted-listing match surface.
pub const WANTED_MATCH_RANKING_VERSION: &str = "2026.07-wanted-feedback-v1";

/// A wanted-match item is additive to the ordinary browse shape. Keeping this
/// wrapper separate prevents browse/search results from acquiring meaningless
/// recommendation fields.
#[derive(Serialize)]
pub struct WantedMatchItem {
    #[serde(flatten)]
    pub listing: ListingSummary,
    pub rank_reason: &'static str,
    pub match_summary: Vec<&'static str>,
    pub source: &'static str,
    pub ranking_version: &'static str,
}

#[derive(Serialize)]
pub struct WantedMatchesResponse {
    pub items: Vec<WantedMatchItem>,
    pub total: i64,
    pub limit: i64,
    pub offset: i64,
    pub ranking_version: &'static str,
}

/// Full detail returned by GET /api/listings/:id
#[derive(Serialize)]
pub struct ListingDetail {
    pub id: String,
    pub title: String,
    pub category: String,
    pub brand: String,
    pub direction: String,
    pub condition_score: i32,
    pub suggested_price_cny: f64,
    pub defects: Vec<String>,
    pub description: Option<String>,
    pub image_url: Option<String>,
    /// Only visible to the listing owner; None for other viewers.
    pub owner_id: Option<String>,
    pub owner_username: Option<String>,
    pub status: String,
    pub restricted: bool,
    pub restriction_state: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub restriction: Option<ListingRestrictionDetail>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub restriction_reason: Option<String>,
    pub available_actions: Vec<&'static str>,
    pub created_at: String,
}

#[derive(Serialize)]
pub struct ListingRestrictionDetail {
    pub public_reason: String,
    pub restricted_at: chrono::DateTime<chrono::Utc>,
    pub moderation_case_id: uuid::Uuid,
    pub can_appeal: bool,
}

/// Request body for POST /api/listings
#[derive(Deserialize)]
pub struct CreateListingRequest {
    pub title: String,
    pub category: String,
    pub brand: String,
    pub direction: Option<String>,
    pub condition_score: i32,
    pub suggested_price_cny: f64,
    pub defects: Vec<String>,
    pub description: Option<String>,
    pub image_url: Option<String>,
}

#[derive(Serialize)]
pub struct CreateListingResponse {
    pub id: String,
    pub message: String,
    pub replayed: bool,
}

#[derive(Deserialize)]
pub struct WantedResponseRequest {
    pub offer_listing_id: String,
    pub message: Option<String>,
}

#[derive(Serialize)]
pub struct WantedResponseResult {
    pub id: String,
    pub message: String,
    pub replayed: bool,
}

#[derive(Deserialize)]
pub struct UpdateListingRequest {
    pub title: Option<String>,
    pub category: Option<String>,
    pub brand: Option<String>,
    pub condition_score: Option<i32>,
    pub suggested_price_cny: Option<f64>,
    pub defects: Option<Vec<String>>,
    pub description: Option<String>,
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

fn normalize_direction(value: Option<&str>, default: &str) -> Result<String, ApiError> {
    let direction = value.unwrap_or(default).trim();
    match direction {
        "offer" | "wanted" | "all" => Ok(direction.to_string()),
        _ => Err(ApiError::BadRequest(
            "无效的 direction 参数，可选值：offer, wanted, all".to_string(),
        )),
    }
}

#[cfg(test)]
fn create_listing_request_hash(input: &CreateListingInput) -> Result<String, ApiError> {
    crate::services::listing_command::create_listing_request_hash(input)
}

fn wanted_response_request_hash(
    wanted_listing_id: &str,
    offer_listing_id: &str,
    message: Option<&str>,
) -> Result<String, ApiError> {
    let canonical = serde_json::to_vec(&serde_json::json!({
        "wanted_listing_id": wanted_listing_id,
        "offer_listing_id": offer_listing_id,
        "message": message,
    }))
    .map_err(|e| {
        ApiError::Internal(anyhow::anyhow!(
            "Failed to serialize normalized wanted response input: {}",
            e
        ))
    })?;
    Ok(hex::encode(Sha256::digest(canonical)))
}

fn listing_summary_from_listing(listing: crate::repositories::Listing) -> ListingSummary {
    let defects = listing
        .defects
        .as_ref()
        .and_then(|t| serde_json::from_str::<Vec<String>>(t).ok())
        .unwrap_or_default();
    let defect_hint = defects.first().cloned();
    ListingSummary {
        id: listing.id,
        title: listing.title,
        category: listing.category,
        brand: listing.brand.unwrap_or_default(),
        direction: listing.direction,
        condition_score: listing.condition_score,
        suggested_price_cny: cents_to_yuan(listing.suggested_price_cny),
        status: listing.status,
        image_url: listing.image_url,
        defect_hint,
    }
}

fn wanted_match_item_from_listing(listing: crate::repositories::Listing) -> WantedMatchItem {
    WantedMatchItem {
        listing: listing_summary_from_listing(listing),
        // Every returned row passed all three public, deterministic hard
        // constraints below. This says no more than the server can prove.
        rank_reason: "known_slots_compatible",
        match_summary: vec![
            "category_match",
            "price_within_constraint",
            "condition_at_least_requested",
        ],
        source: "wanted_match",
        ranking_version: WANTED_MATCH_RANKING_VERSION,
    }
}

/// GET /api/listings — public browse with optional category/categories filter,
/// full-text search, price range, and sort.
pub async fn get_listings(
    State(state): State<AppState>,
    OptionalSession(session): OptionalSession,
    Query(params): Query<ListingQuery>,
) -> Result<Json<ListingsResponse>, ApiError> {
    let limit = params.limit.unwrap_or(20).clamp(1, 100);
    let offset = params.offset.unwrap_or(0).max(0);
    let sort = params.sort.as_deref().unwrap_or("newest");
    let direction = normalize_direction(params.direction.as_deref(), "offer")?;
    let campus_service = CampusService::new(state.infra.db.clone());
    let campus_id = match session {
        Some(session) => {
            campus_service
                .resolve_session_campus(&session.user_id, session.campus_id)
                .await?
        }
        None => campus_service.default_public_campus_id().await?,
    };

    // Validate search query length
    if let Some(ref srch) = params.search {
        if srch.len() > 200 {
            return Err(ApiError::BadRequest(
                "搜索关键词不能超过200个字符".to_string(),
            ));
        }
    }

    let (listings, total) = state
        .listing_repo
        .find_listings(
            campus_id,
            params.category.as_deref(),
            params.categories.as_deref(),
            params.search.as_deref(),
            Some(direction.as_str()),
            params.min_price_cny,
            params.max_price_cny,
            sort,
            limit,
            offset,
        )
        .await?;

    let items: Vec<ListingSummary> = listings
        .into_iter()
        .map(listing_summary_from_listing)
        .collect();

    // Private-bucket deployments serve approved media as presigned URLs; the
    // moderation gate already nulled anything unapproved.
    let items = items
        .into_iter()
        .map(|mut item| {
            item.image_url = state.public_media_url(item.image_url);
            item
        })
        .collect::<Vec<_>>();
    Ok(Json(ListingsResponse {
        items,
        total,
        limit,
        offset,
    }))
}

/// GET /api/listings/:id — public; listing info is not sensitive
pub async fn get_listing(
    State(state): State<AppState>,
    OptionalSession(session): OptionalSession,
    Path(id): Path<String>,
) -> Result<Json<ListingDetail>, ApiError> {
    // Auth optional — guests can browse listing details. The only owner info
    // exposed is username (no email/phone), which is appropriate for a marketplace.
    let viewer_id = session.as_ref().map(|session| session.user_id.clone());
    let campus_service = CampusService::new(state.infra.db.clone());
    let campus_id = match session {
        Some(session) => {
            campus_service
                .resolve_session_campus(&session.user_id, session.campus_id)
                .await?
        }
        None => campus_service.default_public_campus_id().await?,
    };

    // Single query with JOIN to fetch listing and owner username together (avoids N+1)
    let (listing, owner_username) = state
        .listing_repo
        .find_by_id_with_owner_in_campus(&id, campus_id)
        .await?
        .ok_or(ApiError::NotFound)?;

    let defects = listing
        .defects
        .as_ref()
        .and_then(|t| serde_json::from_str::<Vec<String>>(t).ok())
        .unwrap_or_default();

    let created_at = listing.created_at.to_rfc3339();
    let is_owner = viewer_id.as_deref() == Some(listing.owner_id.as_str());
    let restriction = sqlx::query(
        "SELECT COUNT(*) AS count,
                (ARRAY_AGG(moderation_case.public_reason ORDER BY effect.imposed_at DESC))[1]
                    AS public_reason,
                (ARRAY_AGG(effect.imposed_at ORDER BY effect.imposed_at DESC))[1]
                    AS restricted_at,
                (ARRAY_AGG(effect.case_id ORDER BY effect.imposed_at DESC))[1]
                    AS moderation_case_id,
                (ARRAY_AGG(
                    moderation_case.status IN ('actioned', 'resolved')
                    AND moderation_case.resolution = 'content_restricted'
                    AND NOT EXISTS (
                        SELECT 1 FROM moderation_appeals appeal
                        WHERE appeal.case_id = moderation_case.id
                          AND appeal.appellant_id = moderation_case.subject_user_id
                    )
                    ORDER BY effect.imposed_at DESC
                ))[1] AS can_appeal
         FROM listing_restriction_effects effect
         JOIN moderation_cases moderation_case ON moderation_case.id = effect.case_id
         WHERE effect.listing_id = $1 AND effect.campus_id = $2
           AND effect.released_at IS NULL",
    )
    .bind(&listing.id)
    .bind(campus_id)
    .fetch_one(&state.infra.db)
    .await
    .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
    let restriction_count: i64 = restriction.get("count");
    let restricted = restriction_count > 0;
    if restricted && !is_owner {
        return Err(ApiError::NotFound);
    }
    let restriction_reason = if is_owner && restricted {
        restriction
            .try_get::<Option<String>, _>("public_reason")
            .ok()
            .flatten()
    } else {
        None
    };
    let restriction = if is_owner && restricted {
        Some(ListingRestrictionDetail {
            public_reason: restriction_reason
                .clone()
                .unwrap_or_else(|| "该发布受平台限制".to_string()),
            restricted_at: restriction.get("restricted_at"),
            moderation_case_id: restriction.get("moderation_case_id"),
            can_appeal: restriction.get("can_appeal"),
        })
    } else {
        None
    };
    let available_actions = if is_owner {
        match (listing.status.as_str(), restricted) {
            (status, true) => {
                let mut actions = if matches!(status, "active" | "fulfilled") {
                    vec!["delete"]
                } else {
                    Vec::new()
                };
                if restriction.as_ref().is_some_and(|item| item.can_appeal) {
                    actions.push("appeal");
                }
                actions
            }
            ("active", false) if listing.direction == "wanted" => {
                vec!["edit", "delete", "fulfill"]
            }
            ("active", false) => vec!["edit", "delete"],
            ("sold" | "deleted" | "fulfilled", false) => vec!["relist"],
            _ => Vec::new(),
        }
    } else if listing.status == "active" && listing.direction == "wanted" {
        vec!["contact", "recommend_offer", "report"]
    } else if listing.status == "active" {
        vec![
            "contact",
            "buy",
            "create_order",
            "start_price_discovery",
            "report",
        ]
    } else {
        vec!["report"]
    };

    Ok(Json(ListingDetail {
        id: listing.id,
        title: listing.title,
        category: listing.category,
        brand: listing.brand.unwrap_or_default(),
        direction: listing.direction,
        condition_score: listing.condition_score,
        suggested_price_cny: cents_to_yuan(listing.suggested_price_cny),
        defects,
        description: listing.description,
        image_url: state.public_media_url(listing.image_url),
        // Reveal owner_id to all authenticated users so they can contact the seller via chat
        owner_id: viewer_id.as_ref().map(|_| listing.owner_id.clone()),
        owner_username,
        status: listing.status,
        restricted,
        restriction_state: if restricted { "restricted" } else { "clear" },
        restriction,
        restriction_reason,
        available_actions,
        created_at,
    }))
}

/// POST /api/listings — auth required; bypasses agent for form-based creation
pub async fn create_listing(
    State(state): State<AppState>,
    headers: HeaderMap,
    tenant: VerifiedTenant,
    Json(payload): Json<CreateListingRequest>,
) -> Result<Json<CreateListingResponse>, ApiError> {
    let session = tenant.session.clone();
    let idempotency_key = idempotency_key_from_headers(&headers)?;
    let command =
        ListingCommandService::new(state.infra.db.clone(), state.infra.moderation.clone());
    let mut tx = state
        .infra
        .db
        .begin()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
    let create_result = command
        .create_in_tx(
            &mut tx,
            CreateListingDraft {
                campus_id: tenant.campus_id,
                owner_id: session.user_id,
                title: payload.title,
                category: payload.category,
                brand: payload.brand,
                direction: payload.direction,
                condition_score: payload.condition_score,
                suggested_price_cny: payload.suggested_price_cny,
                defects: payload.defects,
                description: payload.description,
                image_url: payload.image_url,
            },
            idempotency_key.as_deref(),
        )
        .await?;
    tx.commit()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    Ok(Json(CreateListingResponse {
        id: create_result.id,
        message: if create_result.direction == "wanted" {
            "需求发布成功".to_string()
        } else {
            "商品发布成功".to_string()
        },
        replayed: create_result.replayed,
    }))
}

/// GET /api/listings/:id/matches — matching active offers for a wanted listing.
pub async fn get_wanted_matches(
    State(state): State<AppState>,
    OptionalSession(session): OptionalSession,
    Path(id): Path<String>,
) -> Result<Json<WantedMatchesResponse>, ApiError> {
    let campus_service = CampusService::new(state.infra.db.clone());
    let (viewer_id, campus_id) = match session {
        Some(session) => {
            let campus_id = campus_service
                .resolve_session_campus(&session.user_id, session.campus_id)
                .await?;
            (Some(session.user_id), campus_id)
        }
        None => (None, campus_service.default_public_campus_id().await?),
    };

    let matches = WantedMatchService::new(state.infra.db.clone())
        .matches(campus_id, viewer_id.as_deref(), &id)
        .await?;
    let items = matches
        .into_iter()
        .map(wanted_match_item_from_listing)
        .map(|mut item| {
            item.listing.image_url = state.public_media_url(item.listing.image_url);
            item
        })
        .collect::<Vec<_>>();
    let total = items.len() as i64;
    Ok(Json(WantedMatchesResponse {
        items,
        total,
        limit: 20,
        offset: 0,
        ranking_version: WANTED_MATCH_RANKING_VERSION,
    }))
}

/// POST /api/listings/:id/responses — recommend one of my active offers to a wanted listing.
pub async fn respond_to_wanted(
    State(state): State<AppState>,
    headers: HeaderMap,
    tenant: VerifiedTenant,
    Path(id): Path<String>,
    Json(payload): Json<WantedResponseRequest>,
) -> Result<Json<WantedResponseResult>, ApiError> {
    let message = payload
        .message
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    if message.as_ref().is_some_and(|value| value.len() > 500) {
        return Err(ApiError::BadRequest(
            "推荐留言不能超过500个字符".to_string(),
        ));
    }
    let idempotency_key = idempotency_key_from_headers(&headers)?;
    let request_hash = idempotency_key
        .as_ref()
        .map(|_| {
            wanted_response_request_hash(&id, payload.offer_listing_id.trim(), message.as_deref())
        })
        .transpose()?;
    let user_id = &tenant.session.user_id;

    let mut tx = state
        .infra
        .db
        .begin()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    // A completed attempt replays even if the wanted has since closed or
    // reopened. Idempotency describes the original mutation, not today's
    // eligibility. The request hash prevents a key from changing meaning.
    if let Some(key) = idempotency_key.as_deref() {
        if let Some((existing_id, existing_hash)) =
            sqlx::query_as::<_, (uuid::Uuid, Option<String>)>(
                "SELECT id, idempotency_hash
                 FROM wanted_responses
                 WHERE campus_id = $1 AND responder_id = $2 AND idempotency_key = $3",
            )
            .bind(tenant.campus_id)
            .bind(user_id)
            .bind(key)
            .fetch_optional(&mut *tx)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        {
            if existing_hash.as_deref() != request_hash.as_deref() {
                return Err(ApiError::Conflict(
                    "Idempotency-Key 已用于不同的推荐内容".to_string(),
                ));
            }
            tx.commit()
                .await
                .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
            return Ok(Json(WantedResponseResult {
                id: existing_id.to_string(),
                message: "已推荐给需求方".to_string(),
                replayed: true,
            }));
        }
    }

    // All lifecycle mutations lock the wanted row first. Response actions use
    // the same wanted -> offer -> response order, preventing a create/fulfill/
    // reopen race from validating one round and writing into another.
    let wanted = sqlx::query(
        "SELECT id, title, owner_id, status, direction, lifecycle_epoch
         FROM inventory
         WHERE id = $1 AND campus_id = $2
         FOR UPDATE",
    )
    .bind(&id)
    .bind(tenant.campus_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
    .ok_or(ApiError::NotFound)?;
    let wanted_id: String = wanted.get("id");
    let wanted_title: String = wanted.get("title");
    let wanted_owner_id: String = wanted.get("owner_id");
    let wanted_status: String = wanted.get("status");
    let wanted_direction: String = wanted.get("direction");
    let lifecycle_epoch: i64 = wanted.get("lifecycle_epoch");
    let wanted_restricted: bool = sqlx::query_scalar("SELECT listing_has_active_restriction($1)")
        .bind(&wanted_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    if wanted_restricted {
        return Err(ApiError::CodedConflict {
            code: "wanted_response_round_closed",
            message: "该收物需求已受平台限制，当前轮次不可响应".to_string(),
        });
    }
    if wanted_direction != "wanted" || wanted_status != "active" {
        return Err(ApiError::BadRequest("这不是可响应的收物需求".to_string()));
    }
    if wanted_owner_id == *user_id {
        return Err(ApiError::BadRequest("不能给自己的需求推荐商品".to_string()));
    }

    // Preserve the existing "both people are verified in the same active
    // campus" trust boundary while keeping the listing state decision inside
    // this transaction.
    let requester_is_verified: bool = sqlx::query_scalar(
        "SELECT EXISTS(
            SELECT 1
            FROM campus_memberships AS membership
            JOIN campuses AS campus
              ON campus.id = membership.campus_id AND campus.status = 'active'
            WHERE membership.campus_id = $1
              AND membership.user_id = $2
              AND membership.status = 'verified'
         )",
    )
    .bind(tenant.campus_id)
    .bind(&wanted_owner_id)
    .fetch_one(&mut *tx)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
    if !requester_is_verified {
        return Err(ApiError::CampusScopeMismatch);
    }

    let offer = sqlx::query(
        "SELECT id, title, owner_id, status, direction
         FROM inventory
         WHERE id = $1 AND campus_id = $2
         FOR UPDATE",
    )
    .bind(payload.offer_listing_id.trim())
    .bind(tenant.campus_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
    .ok_or(ApiError::NotFound)?;
    let offer_id: String = offer.get("id");
    let offer_title: String = offer.get("title");
    let offer_owner_id: String = offer.get("owner_id");
    let offer_status: String = offer.get("status");
    let offer_direction: String = offer.get("direction");
    let offer_restricted: bool = sqlx::query_scalar("SELECT listing_has_active_restriction($1)")
        .bind(&offer_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    if offer_restricted {
        return Err(ApiError::CodedConflict {
            code: "listing_restricted",
            message: "推荐商品已受平台限制".to_string(),
        });
    }
    if offer_direction != "offer" || offer_status != "active" {
        return Err(ApiError::BadRequest("只能推荐正在出的商品".to_string()));
    }
    if offer_owner_id != *user_id {
        return Err(ApiError::Forbidden);
    }

    let inserted = sqlx::query_scalar::<_, uuid::Uuid>(
        r#"
        INSERT INTO wanted_responses (
            campus_id, wanted_listing_id, offer_listing_id, responder_id,
            requester_id, message, lifecycle_epoch,
            idempotency_key, idempotency_hash
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        ON CONFLICT DO NOTHING
        RETURNING id
        "#,
    )
    .bind(tenant.campus_id)
    .bind(&wanted_id)
    .bind(&offer_id)
    .bind(user_id)
    .bind(&wanted_owner_id)
    .bind(&message)
    .bind(lifecycle_epoch)
    .bind(idempotency_key.as_deref())
    .bind(request_hash.as_deref())
    .fetch_optional(&mut *tx)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    let (response_id, replayed) = if let Some(response_id) = inserted {
        (response_id, false)
    } else if let Some(key) = idempotency_key.as_deref() {
        match sqlx::query_as::<_, (uuid::Uuid, Option<String>)>(
            "SELECT id, idempotency_hash
             FROM wanted_responses
             WHERE campus_id = $1 AND responder_id = $2 AND idempotency_key = $3",
        )
        .bind(tenant.campus_id)
        .bind(user_id)
        .bind(key)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        {
            Some((existing_id, existing_hash))
                if existing_hash.as_deref() == request_hash.as_deref() =>
            {
                (existing_id, true)
            }
            Some(_) => {
                return Err(ApiError::Conflict(
                    "Idempotency-Key 已用于不同的推荐内容".to_string(),
                ))
            }
            None => return Err(ApiError::BadRequest("本轮已经推荐过这件商品".to_string())),
        }
    } else {
        return Err(ApiError::BadRequest("本轮已经推荐过这件商品".to_string()));
    };

    tx.commit()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    if replayed {
        return Ok(Json(WantedResponseResult {
            id: response_id.to_string(),
            message: "已推荐给需求方".to_string(),
            replayed: true,
        }));
    }

    // Discretionary: posting a wanted listing invites answers, but nothing
    // stops one person recommending fifty different items to it, so the push
    // is budgeted. Over budget the recommendation still lands in the inbox —
    // it is the interruption that is rationed, not the message.
    let reason = format!("你在找“{}”，有人推荐了“{}”", wanted_title, offer_title);
    let decision = crate::services::interruption::InterruptionService::new(state.infra.db.clone())
        .request(crate::services::interruption::InterruptionRequest {
            campus_id: tenant.campus_id,
            user_id: &wanted_owner_id,
            channel: "in_app",
            topic: crate::services::interruption::topics::WANTED_RESPONSE,
            reason: &reason,
            // A human deliberately matched an item to a stated need, which is
            // about as relevant as unsolicited outreach gets.
            expected_value: 0.8,
        })
        .await;

    let decision = match decision {
        Ok(decision) => {
            if let crate::services::interruption::Decision::Withheld { reason, .. } = &decision {
                tracing::debug!(
                    ?reason, wanted_id = %wanted_id,
                    "wanted response held back from push",
                );
            }
            decision
        }
        Err(e) => {
            // Budget bookkeeping must never cost the user their
            // recommendation, and must never fail open into a spam vector.
            tracing::warn!(%e, wanted_id = %wanted_id, "interruption budget check failed");
            crate::services::interruption::Decision::Unavailable
        }
    };

    if let Err(e) = state
        .infra
        .notification
        .create_budgeted(
            &decision,
            NewNotification {
                campus_id: tenant.campus_id,
                user_id: &wanted_owner_id,
                event_type: crate::services::interruption::topics::WANTED_RESPONSE,
                title: "有人给你的收物需求推荐了商品",
                body: &format!("“{}”收到一个匹配推荐：{}", wanted_title, offer_title),
                related_order_id: None,
                related_listing_id: Some(&wanted_id),
                related_conversation_id: None,
                related_space_id: None,
            },
        )
        .await
    {
        tracing::warn!(%e, wanted_id = %wanted_id, offer_id = %offer_id, "Failed to create wanted response notification");
    }

    Ok(Json(WantedResponseResult {
        id: response_id.to_string(),
        message: "已推荐给需求方".to_string(),
        replayed: false,
    }))
}

/// POST /api/listings/:id/fulfill — owner marks a wanted item as fulfilled.
///
/// Fulfilled items disappear from feeds, search and wanted matching (all of
/// which filter `status = 'active'`); existing threads, responses and deal
/// records are preserved. `POST /api/listings/:id/relist` reopens it.
pub async fn fulfill_wanted(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let user_id = &tenant.session.user_id;
    let mut tx = state
        .infra
        .db
        .begin()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
    let listing = sqlx::query(
        "SELECT owner_id, title, status, direction, lifecycle_epoch
         FROM inventory
         WHERE id = $1 AND campus_id = $2
         FOR UPDATE",
    )
    .bind(&id)
    .bind(tenant.campus_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
    .ok_or(ApiError::NotFound)?;
    let owner_id: String = listing.get("owner_id");
    let title: String = listing.get("title");
    let status: String = listing.get("status");
    let direction: String = listing.get("direction");
    let lifecycle_epoch: i64 = listing.get("lifecycle_epoch");
    let restricted: bool = sqlx::query_scalar("SELECT listing_has_active_restriction($1)")
        .bind(&id)
        .fetch_one(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    if owner_id != *user_id {
        return Err(ApiError::Forbidden);
    }
    if direction != "wanted" {
        return Err(ApiError::BadRequest(
            "只有收物需求可以标记为已完成".to_string(),
        ));
    }
    if restricted {
        return Err(ApiError::CodedConflict {
            code: "listing_restricted",
            message: "该发布受平台限制，不能标记完成".to_string(),
        });
    }
    if status != "active" {
        return Err(ApiError::Conflict(format!(
            "当前状态为'{}'，无法标记完成",
            status
        )));
    }

    // The row lock is shared with response creation/actions/reopen. Once this
    // transition commits, no response can be inserted or acted on in this
    // round using an eligibility decision made before fulfillment.
    let updated = sqlx::query(
        "UPDATE inventory SET status = 'fulfilled'
         WHERE id = $1
           AND campus_id = $2
           AND owner_id = $3
           AND direction = 'wanted'
           AND status = 'active'
           AND lifecycle_epoch = $4",
    )
    .bind(&id)
    .bind(tenant.campus_id)
    .bind(user_id)
    .bind(lifecycle_epoch)
    .execute(&mut *tx)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
    if updated.rows_affected() == 0 {
        return Err(ApiError::Conflict(
            "收物需求状态已发生变化，无法标记完成".to_string(),
        ));
    }

    // Tell only this round's pending responders. The response status remains
    // truthful history (`pending`); list/action APIs derive that the round is
    // now closed from the parent state and epoch.
    let pending_responders: Vec<String> = sqlx::query_scalar(
        "SELECT DISTINCT responder_id FROM wanted_responses
         WHERE wanted_listing_id = $1
           AND campus_id = $2
           AND lifecycle_epoch = $3
           AND status = 'pending'",
    )
    .bind(&id)
    .bind(tenant.campus_id)
    .bind(lifecycle_epoch)
    .fetch_all(&mut *tx)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
    tx.commit()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    for responder in pending_responders {
        if let Err(e) = state
            .infra
            .notification
            .create(NewNotification {
                campus_id: tenant.campus_id,
                user_id: &responder,
                event_type: "wanted_fulfilled",
                title: "对方的收物需求已完成",
                body: &format!("“{}”已标记完成，感谢你的推荐", title),
                related_order_id: None,
                related_listing_id: Some(&id),
                related_conversation_id: None,
                related_space_id: None,
            })
            .await
        {
            tracing::warn!(%e, wanted_id = %id, "Failed to notify responder of fulfillment");
        }
    }

    tracing::info!(
        listing_id = %id,
        owner_id = %user_id,
        lifecycle_epoch,
        "Wanted marked fulfilled"
    );
    Ok(Json(serde_json::json!({
        "message": "收物需求已标记完成",
        "id": id,
        "status": "fulfilled"
    })))
}

/// PUT /api/listings/:id - update a listing (owner only)
pub async fn update_listing(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(id): Path<String>,
    Json(payload): Json<UpdateListingRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let user_id = tenant.session.user_id.clone();
    let command =
        ListingCommandService::new(state.infra.db.clone(), state.infra.moderation.clone());
    let mut tx = state
        .infra
        .db
        .begin()
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
    let update_result = command
        .update_with_state_in_tx(
            &mut tx,
            &id,
            &user_id,
            tenant.campus_id,
            UpdateListingDraft {
                title: payload.title,
                category: payload.category,
                brand: payload.brand,
                condition_score: payload.condition_score,
                suggested_price_cny: payload.suggested_price_cny,
                defects: payload.defects,
                description: payload.description,
            },
        )
        .await?;
    match update_result {
        UpdateOwnedResult::Updated => {}
        UpdateOwnedResult::NotFound => return Err(ApiError::NotFound),
        UpdateOwnedResult::Inactive => {
            return Err(ApiError::CodedConflict {
                code: "listing_action_stale",
                message: "只有正在展示的发布可以编辑".to_string(),
            });
        }
    }
    tx.commit()
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;

    tracing::info!(listing_id = %id, updated_by = %user_id, "Listing updated");

    Ok(Json(serde_json::json!({
        "message": "商品更新成功",
        "id": id
    })))
}

/// DELETE /api/listings/:id - delete a listing (owner only)
pub async fn delete_listing(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let user_id = tenant.session.user_id.clone();
    let command =
        ListingCommandService::new(state.infra.db.clone(), state.infra.moderation.clone());
    let mut tx = state
        .infra
        .db
        .begin()
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
    command
        .delete_in_tx(&mut tx, &id, &user_id, tenant.campus_id)
        .await?;
    tx.commit()
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;

    tracing::info!(listing_id = %id, deleted_by = %user_id, "Listing deleted");

    Ok(Json(serde_json::json!({
        "message": "商品已删除",
        "id": id
    })))
}

/// POST /api/listings/:id/relist — reactivate a sold or deleted listing (seller only)
pub async fn relist_listing(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let user_id = tenant.session.user_id.clone();

    state
        .listing_repo
        .relist(&id, &user_id, tenant.campus_id)
        .await?;

    tracing::info!(listing_id = %id, relisted_by = %user_id, "Listing relisted");

    Ok(Json(serde_json::json!({
        "message": "商品已重新上架",
        "id": id,
        "status": "active"
    })))
}

// ---------------------------------------------------------------------------
// Item recognition from image
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct RecognizeRequest {
    pub image_base64: String,
}

#[derive(Serialize, Deserialize)]
pub struct RecognizedItem {
    pub title: String,
    pub category: String,
    pub brand: String,
    pub condition_score: i32,
    pub defects: Vec<String>,
    pub description: String,
}

/// POST /api/listings/recognize — auth required; uses Gemini Vision to analyze product image
pub async fn recognize_item(
    State(state): State<AppState>,
    _session: Session,
    Json(payload): Json<RecognizeRequest>,
) -> Result<Json<RecognizedItem>, ApiError> {
    if payload.image_base64.is_empty() {
        return Err(ApiError::BadRequest("image_base64 is required".to_string()));
    }

    // Detect image type from magic bytes
    let mime_type = if let Ok(decoded) = base64::Engine::decode(
        &base64::engine::general_purpose::STANDARD,
        &payload.image_base64[..payload.image_base64.len().min(50)],
    ) {
        if decoded.starts_with(&[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            "image/png"
        } else if decoded.starts_with(&[0xFF, 0xD8, 0xFF]) {
            "image/jpeg"
        } else if decoded.starts_with(b"GIF87a") || decoded.starts_with(b"GIF89a") {
            "image/gif"
        } else {
            "image/jpeg" // fallback
        }
    } else {
        "image/jpeg"
    };

    let prompt = r#"You are a secondhand marketplace listing assistant. Analyze the product image and return a JSON object with the following structure (no markdown, just pure JSON):
{
  "title": "Product name in Chinese, e.g. iPhone 13 Pro Max",
  "category": "One of: electronics, books, digitalAccessories, dailyGoods, clothingShoes, other",
  "brand": "Brand name in Chinese, e.g. Apple",
  "condition_score": 1-10 integer estimate (9=new, 7=good, 5=fair, 3=worn),
  "defects": ["defect1", "defect2"] or empty array,
  "description": "Brief description in Chinese about the item condition and features"
}
Be honest about defects. If you cannot identify the item, return category="other" and generic values."#;

    let request_body = serde_json::json!({
        "contents": [{
            "parts": [
                {"text": prompt},
                {
                    "inline_data": {
                        "mime_type": mime_type,
                        "data": payload.image_base64
                    }
                }
            ]
        }],
        "generationConfig": {
            "temperature": 0.3,
            "maxOutputTokens": 1000
        }
    });

    let url = format!(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent?key={}",
        state.secrets.gemini_api_key
    );

    let client = reqwest::Client::new();
    let response = client
        .post(&url)
        .json(&request_body)
        .timeout(std::time::Duration::from_secs(30))
        .send()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("Failed to call Gemini: {}", e)))?;

    let response_text = response
        .text()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("Failed to read response: {}", e)))?;

    let parsed: serde_json::Value = serde_json::from_str(&response_text).map_err(|e| {
        ApiError::Internal(anyhow::anyhow!(
            "Failed to parse response: {} - {}",
            e,
            response_text
        ))
    })?;

    let json_str = parsed["candidates"][0]["content"]["parts"][0]["text"]
        .as_str()
        .ok_or_else(|| {
            ApiError::Internal(anyhow::anyhow!("No text in response: {}", response_text))
        })?
        .trim();

    // Parse the JSON response from Gemini
    let recognized: RecognizedItem = serde_json::from_str(json_str).map_err(|e| {
        ApiError::Internal(anyhow::anyhow!(
            "Failed to parse item JSON: {} - JSON was: {}",
            e,
            json_str
        ))
    })?;

    // Moderate AI-generated content before returning it to the user.
    let ai_text = format!(
        "{}\n{}\n{}\n{}",
        recognized.title,
        recognized.brand,
        recognized.description,
        recognized.defects.join(" "),
    );
    let mod_result = state.infra.moderation.check_text(&ai_text);
    if !mod_result.passed {
        tracing::warn!(reason = ?mod_result.reason, "AI-generated content flagged by moderation");
        // Don't block the response — just log and continue.
        // The user can still use the suggestion as a starting point.
    }

    Ok(Json(recognized))
}

/// GET /api/categories - returns valid marketplace categories
pub async fn get_categories() -> Json<Vec<&'static str>> {
    Json(MARKETPLACE_CATEGORIES.to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_marketplace_categories_defined() {
        assert_eq!(MARKETPLACE_CATEGORIES.len(), 6);
        assert!(MARKETPLACE_CATEGORIES.contains(&"electronics"));
        assert!(MARKETPLACE_CATEGORIES.contains(&"books"));
        assert!(MARKETPLACE_CATEGORIES.contains(&"digitalAccessories"));
        assert!(MARKETPLACE_CATEGORIES.contains(&"dailyGoods"));
        assert!(MARKETPLACE_CATEGORIES.contains(&"clothingShoes"));
        assert!(MARKETPLACE_CATEGORIES.contains(&"other"));
    }

    #[test]
    fn test_valid_category_strings() {
        for cat in MARKETPLACE_CATEGORIES {
            assert!(!cat.is_empty());
            assert!(cat.len() < 50);
        }
    }

    #[test]
    fn test_listing_query_defaults() {
        let query: ListingQuery = serde_json::from_str(r#"{}"#).unwrap();
        assert_eq!(query.limit, None);
        assert_eq!(query.offset, None);
        assert_eq!(query.category, None);
        assert_eq!(query.search, None);
        assert_eq!(query.sort, None);
    }

    #[test]
    fn test_listing_query_with_sort() {
        let query: ListingQuery = serde_json::from_str(r#"{"sort": "price_asc"}"#).unwrap();
        assert_eq!(query.sort, Some("price_asc".to_string()));

        let query2: ListingQuery = serde_json::from_str(r#"{"sort": "price_desc"}"#).unwrap();
        assert_eq!(query2.sort, Some("price_desc".to_string()));

        let query3: ListingQuery = serde_json::from_str(r#"{"sort": "condition_desc"}"#).unwrap();
        assert_eq!(query3.sort, Some("condition_desc".to_string()));
    }

    #[test]
    fn test_listing_query_with_all_params() {
        let query: ListingQuery = serde_json::from_str(
            r#"{"limit": 10, "offset": 20, "category": "electronics", "search": "iphone", "sort": "newest"}"#,
        )
        .unwrap();
        assert_eq!(query.limit, Some(10));
        assert_eq!(query.offset, Some(20));
        assert_eq!(query.category, Some("electronics".to_string()));
        assert_eq!(query.search, Some("iphone".to_string()));
        assert_eq!(query.sort, Some("newest".to_string()));
    }

    #[test]
    fn test_create_listing_request_deserialization() {
        let json = r#"{
            "title": "iPhone 13",
            "category": "electronics",
            "brand": "Apple",
            "condition_score": 8,
            "suggested_price_cny": 4999.0,
            "defects": ["Minor scratch"],
            "description": "Like new"
        }"#;
        let req: CreateListingRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.title, "iPhone 13");
        assert_eq!(req.category, "electronics");
        assert_eq!(req.brand, "Apple");
        assert_eq!(req.condition_score, 8);
        assert_eq!(req.suggested_price_cny, 4999.0);
        assert_eq!(req.defects.len(), 1);
        assert_eq!(req.description, Some("Like new".to_string()));
    }

    #[test]
    fn test_create_listing_request_without_optional_fields() {
        let json = r#"{
            "title": "Book",
            "category": "books",
            "brand": "Publisher",
            "condition_score": 7,
            "suggested_price_cny": 99.0,
            "defects": []
        }"#;
        let req: CreateListingRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.title, "Book");
        assert_eq!(req.description, None);
        assert!(req.defects.is_empty());
    }

    #[test]
    fn test_create_listing_response_serialization() {
        let resp = CreateListingResponse {
            id: "listing-123".to_string(),
            message: "商品发布成功".to_string(),
            replayed: false,
        };
        let json = serde_json::to_string(&resp).unwrap();
        assert!(json.contains("listing-123"));
        assert!(json.contains("商品发布成功"));
        assert!(json.contains("\"replayed\":false"));
    }

    #[test]
    fn idempotency_key_validation_accepts_uuid_and_rejects_spaces() {
        let mut headers = HeaderMap::new();
        headers.insert(
            "Idempotency-Key",
            "d9bf5f9b-4d9d-4f11-9976-cf2c0c71f120".parse().unwrap(),
        );
        assert_eq!(
            idempotency_key_from_headers(&headers).unwrap().as_deref(),
            Some("d9bf5f9b-4d9d-4f11-9976-cf2c0c71f120")
        );

        headers.insert("Idempotency-Key", "not allowed".parse().unwrap());
        assert!(matches!(
            idempotency_key_from_headers(&headers),
            Err(ApiError::BadRequest(_))
        ));
    }

    #[test]
    fn normalized_listing_hash_is_stable_and_content_sensitive() {
        let input = CreateListingInput {
            campus_id: uuid::Uuid::parse_str("c0000000-0000-0000-0000-000000000001").unwrap(),
            title: "Desk".to_string(),
            category: "other".to_string(),
            brand: Some("Campus".to_string()),
            direction: "offer".to_string(),
            condition_score: 8,
            suggested_price_cny: 123.45,
            defects: vec!["scratch".to_string()],
            description: "usable".to_string(),
            image_url: None,
            owner_id: "owner".to_string(),
        };
        let first = create_listing_request_hash(&input).unwrap();
        let second = create_listing_request_hash(&input).unwrap();
        let mut changed = input.clone();
        changed.title = "Different desk".to_string();

        assert_eq!(first, second);
        assert_eq!(first.len(), 64);
        assert_ne!(first, create_listing_request_hash(&changed).unwrap());
    }

    #[test]
    fn test_listing_summary_serialization() {
        let summary = ListingSummary {
            id: "listing-456".to_string(),
            title: "MacBook Pro".to_string(),
            category: "electronics".to_string(),
            brand: "Apple".to_string(),
            direction: "offer".to_string(),
            condition_score: 9,
            suggested_price_cny: 12999.0,
            status: "active".to_string(),
            image_url: Some("https://cdn.example.com/macbook.jpg".to_string()),
            defect_hint: Some("屏幕有轻微划痕".to_string()),
        };
        let json = serde_json::to_string(&summary).unwrap();
        assert!(json.contains("MacBook Pro"));
        assert!(json.contains("Apple"));
        assert!(json.contains("\"status\":\"active\""));
        assert!(json.contains("\"image_url\":\"https://cdn.example.com/macbook.jpg\""));
        assert!(json.contains("12999"));
        assert!(json.contains("defect_hint"));
        assert!(json.contains("屏幕有轻微划痕"));
    }

    #[test]
    fn test_listing_summary_without_defect_hint() {
        let summary = ListingSummary {
            id: "listing-789".to_string(),
            title: "Book".to_string(),
            category: "books".to_string(),
            brand: "Publisher".to_string(),
            direction: "offer".to_string(),
            condition_score: 5,
            suggested_price_cny: 99.0,
            status: "active".to_string(),
            image_url: None,
            defect_hint: None,
        };
        let json = serde_json::to_string(&summary).unwrap();
        assert!(json.contains("Book"));
        assert!(json.contains("\"defect_hint\":null"));
    }

    #[test]
    fn test_listings_response_serialization() {
        let response = ListingsResponse {
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
    fn wanted_match_response_is_additive_versioned_and_private() {
        let response = WantedMatchesResponse {
            items: vec![WantedMatchItem {
                listing: ListingSummary {
                    id: "offer-1".to_string(),
                    title: "Matching offer".to_string(),
                    category: "electronics".to_string(),
                    brand: "Campus Brand".to_string(),
                    direction: "offer".to_string(),
                    condition_score: 9,
                    suggested_price_cny: 299.0,
                    status: "active".to_string(),
                    image_url: None,
                    defect_hint: None,
                },
                rank_reason: "known_slots_compatible",
                match_summary: vec![
                    "category_match",
                    "price_within_constraint",
                    "condition_at_least_requested",
                ],
                source: "wanted_match",
                ranking_version: WANTED_MATCH_RANKING_VERSION,
            }],
            total: 1,
            limit: 20,
            offset: 0,
            ranking_version: WANTED_MATCH_RANKING_VERSION,
        };

        let json = serde_json::to_value(response).expect("wanted matches serialize");
        assert_eq!(json["ranking_version"], "2026.07-wanted-feedback-v1");
        let item = &json["items"][0];
        assert_eq!(item["id"], "offer-1");
        assert_eq!(item["rank_reason"], "known_slots_compatible");
        assert_eq!(
            item["match_summary"],
            serde_json::json!([
                "category_match",
                "price_within_constraint",
                "condition_at_least_requested"
            ])
        );
        assert_eq!(item["source"], "wanted_match");
        assert_eq!(item["ranking_version"], json["ranking_version"]);
        for private_key in [
            "owner_id",
            "campus_id",
            "embedding",
            "distance",
            "brand_key",
            "weight",
        ] {
            assert!(
                item.get(private_key).is_none(),
                "{private_key} must not cross the wanted-match boundary"
            );
        }
    }

    #[test]
    fn empty_wanted_match_response_keeps_ranking_version() {
        let response = WantedMatchesResponse {
            items: Vec::new(),
            total: 0,
            limit: 20,
            offset: 0,
            ranking_version: WANTED_MATCH_RANKING_VERSION,
        };
        let json = serde_json::to_value(response).expect("empty wanted matches serialize");
        assert_eq!(json["items"], serde_json::json!([]));
        assert_eq!(json["ranking_version"], "2026.07-wanted-feedback-v1");
    }

    #[test]
    fn test_listing_detail_serialization() {
        let detail = ListingDetail {
            id: "listing-detail-1".to_string(),
            title: "iPhone 15".to_string(),
            category: "electronics".to_string(),
            brand: "Apple".to_string(),
            direction: "offer".to_string(),
            condition_score: 10,
            suggested_price_cny: 7999.0,
            defects: vec!["None".to_string()],
            description: Some("Brand new".to_string()),
            image_url: Some("https://cdn.example.com/iphone.jpg".to_string()),
            owner_id: Some("user-owner".to_string()),
            owner_username: Some("seller1".to_string()),
            status: "active".to_string(),
            restricted: false,
            restriction_state: "clear",
            restriction: None,
            restriction_reason: None,
            available_actions: vec!["contact", "buy"],
            created_at: "2024-01-01T00:00:00Z".to_string(),
        };
        let json = serde_json::to_string(&detail).unwrap();
        assert!(json.contains("iPhone 15"));
        assert!(json.contains("seller1"));
        assert!(json.contains("https://cdn.example.com/iphone.jpg"));
        assert!(json.contains("\"defects\":[\"None\"]"));
    }

    #[test]
    fn test_update_listing_request_deserialization() {
        let json = r#"{"title": "Updated Title", "description": "New description"}"#;
        let req: UpdateListingRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.title, Some("Updated Title".to_string()));
        assert_eq!(req.description, Some("New description".to_string()));
        assert_eq!(req.category, None);
        assert_eq!(req.brand, None);
    }

    #[test]
    fn test_update_listing_request_partial() {
        let json = r#"{"suggested_price_cny": 4500.0}"#;
        let req: UpdateListingRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.suggested_price_cny, Some(4500.0));
        assert_eq!(req.title, None);
        assert_eq!(req.description, None);
    }

    #[test]
    fn test_update_listing_request_all_fields() {
        let json = r#"{
            "title": "New Title",
            "category": "electronics",
            "brand": "Apple",
            "condition_score": 9,
            "suggested_price_cny": 5999.0,
            "defects": ["Scratched"],
            "description": "Updated desc"
        }"#;
        let req: UpdateListingRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.title, Some("New Title".to_string()));
        assert_eq!(req.category, Some("electronics".to_string()));
        assert_eq!(req.brand, Some("Apple".to_string()));
        assert_eq!(req.condition_score, Some(9));
        assert_eq!(req.suggested_price_cny, Some(5999.0));
        assert_eq!(req.defects, Some(vec!["Scratched".to_string()]));
        assert_eq!(req.description, Some("Updated desc".to_string()));
    }
}
