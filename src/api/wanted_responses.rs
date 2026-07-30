//! Wanted-response lifecycle (Phase 2): the requester accepts or dismisses a
//! recommendation, the responder can withdraw one, and both sides can list
//! their own responses. Every transition starts from `pending` via a
//! conditional update, so concurrent actions on the same response resolve to
//! exactly one winner.

use axum::{
    extract::{Path, Query, State},
    Json,
};
use serde::Deserialize;
use sqlx::Row;
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::api::session::VerifiedTenant;
use crate::api::AppState;
use crate::services::notification::NewNotification;

#[derive(Deserialize)]
pub struct ResponseListQuery {
    /// `requester` (default) — responses to my wanted items;
    /// `responder` — recommendations I sent.
    pub role: Option<String>,
    pub status: Option<String>,
    pub wanted_listing_id: Option<String>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

/// GET /api/wanted-responses — the caller's responses, by role.
pub async fn list_wanted_responses(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Query(params): Query<ResponseListQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let session = tenant.session;
    let role = params.role.as_deref().unwrap_or("requester");
    let column = match role {
        "requester" => "requester_id",
        "responder" => "responder_id",
        _ => {
            return Err(ApiError::BadRequest(
                "role 只能是 requester 或 responder".to_string(),
            ))
        }
    };
    if let Some(status) = params.status.as_deref() {
        if !matches!(status, "pending" | "accepted" | "dismissed" | "withdrawn") {
            return Err(ApiError::BadRequest("无效的 status 过滤".to_string()));
        }
    }
    let limit = params.limit.unwrap_or(20).clamp(1, 100);
    let offset = params.offset.unwrap_or(0).max(0);
    let wanted_listing_id = params
        .wanted_listing_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty());

    let filter = format!(
        "FROM wanted_responses r
         WHERE r.{column} = $1
           AND r.campus_id = $2
           AND ($3::text IS NULL OR r.status = $3)
           AND ($4::text IS NULL OR r.wanted_listing_id = $4)"
    );
    let total: i64 = sqlx::query_scalar(&format!("SELECT COUNT(*) {filter}"))
        .bind(&session.user_id)
        .bind(tenant.campus_id)
        .bind(params.status.as_deref())
        .bind(wanted_listing_id)
        .fetch_one(&state.infra.db)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    let rows = sqlx::query(&format!(
        "SELECT r.id, r.wanted_listing_id, r.offer_listing_id, r.responder_id, r.requester_id,
                r.message, r.status, r.created_at, r.responded_at,
                w.title AS wanted_title, w.status AS wanted_status,
                o.title AS offer_title, o.status AS offer_status
         FROM wanted_responses r
         JOIN inventory w ON w.id = r.wanted_listing_id
         JOIN inventory o ON o.id = r.offer_listing_id
         WHERE r.{column} = $1
           AND r.campus_id = $2
           AND ($3::text IS NULL OR r.status = $3)
           AND ($4::text IS NULL OR r.wanted_listing_id = $4)
         ORDER BY r.created_at DESC
         LIMIT $5 OFFSET $6"
    ))
    .bind(&session.user_id)
    .bind(tenant.campus_id)
    .bind(params.status.as_deref())
    .bind(wanted_listing_id)
    .bind(limit)
    .bind(offset)
    .fetch_all(&state.infra.db)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    let items: Vec<serde_json::Value> = rows
        .iter()
        .map(|row| {
            serde_json::json!({
                "id": row.get::<Uuid, _>("id").to_string(),
                "wanted_listing_id": row.get::<String, _>("wanted_listing_id"),
                "wanted_title": row.get::<String, _>("wanted_title"),
                "wanted_status": row.get::<String, _>("wanted_status"),
                "offer_listing_id": row.get::<String, _>("offer_listing_id"),
                "offer_title": row.get::<String, _>("offer_title"),
                "offer_status": row.get::<String, _>("offer_status"),
                "responder_id": row.get::<String, _>("responder_id"),
                "requester_id": row.get::<String, _>("requester_id"),
                "message": row.get::<Option<String>, _>("message"),
                "status": row.get::<String, _>("status"),
                "created_at": row.get::<chrono::DateTime<chrono::Utc>, _>("created_at"),
                "responded_at": row.get::<Option<chrono::DateTime<chrono::Utc>>, _>("responded_at"),
            })
        })
        .collect();

    Ok(Json(serde_json::json!({
        "items": items,
        "total": total,
        "limit": limit,
        "offset": offset,
    })))
}

struct ResponseAction {
    /// New status this action produces.
    to_status: &'static str,
    /// Which party may perform it.
    actor_column: &'static str,
    /// Notification target is the other party.
    notify_column: &'static str,
    event_type: &'static str,
    title: &'static str,
    body: fn(&str) -> String,
    require_wanted_active: bool,
    require_offer_active: bool,
}

async fn act_on_response(
    state: &AppState,
    user_id: &str,
    campus_id: Uuid,
    response_id: Uuid,
    action: ResponseAction,
) -> Result<Json<serde_json::Value>, ApiError> {
    let mut tx = state
        .infra
        .db
        .begin()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    // Scope both the lookup and transition to the verified active campus. This
    // keeps a guessed response id from revealing another campus's data, even
    // when the caller happens to be one of its parties. Lock all three state
    // rows so fulfillment, sale and another response action serialize with the
    // eligibility decision rather than racing a preflight read.
    let row = sqlx::query(&format!(
        "SELECT r.responder_id, r.requester_id, r.status, r.wanted_listing_id,
                w.status AS wanted_status, o.status AS offer_status,
                o.title AS offer_title
         FROM wanted_responses r
         JOIN inventory w ON w.id = r.wanted_listing_id
         JOIN inventory o ON o.id = r.offer_listing_id
         WHERE r.id = $1 AND r.campus_id = $2 AND r.{} = $3
         FOR UPDATE OF r, w, o",
        action.actor_column
    ))
    .bind(response_id)
    .bind(campus_id)
    .bind(user_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
    .ok_or(ApiError::NotFound)?;

    let status: String = row.get("status");
    let wanted_status: String = row.get("wanted_status");
    let offer_status: String = row.get("offer_status");
    let ineligible_reason = if status != "pending" {
        Some(format!("该推荐当前状态为 {status}，无法操作"))
    } else if action.require_wanted_active && wanted_status != "active" {
        Some(format!("收物需求当前状态为 {wanted_status}，无法操作"))
    } else if action.require_offer_active && offer_status != "active" {
        Some(format!("推荐商品当前状态为 {offer_status}，无法操作"))
    } else {
        None
    };
    if let Some(reason) = ineligible_reason {
        return Err(ApiError::Conflict(reason));
    }

    // Keep the same predicates on the write as defense in depth. The locked
    // rows make the cross-table decision atomic; these predicates also protect
    // the transition if this query is later reused without the preflight.
    let updated = sqlx::query(&format!(
        "UPDATE wanted_responses AS r
         SET status = $2, responded_at = NOW()
         FROM inventory AS w, inventory AS o
         WHERE r.id = $1
           AND r.status = 'pending'
           AND r.{} = $3
           AND r.campus_id = $4
           AND w.id = r.wanted_listing_id
           AND w.campus_id = r.campus_id
           AND o.id = r.offer_listing_id
           AND o.campus_id = r.campus_id
           AND (NOT $5::boolean OR w.status = 'active')
           AND (NOT $6::boolean OR o.status = 'active')",
        action.actor_column
    ))
    .bind(response_id)
    .bind(action.to_status)
    .bind(user_id)
    .bind(campus_id)
    .bind(action.require_wanted_active)
    .bind(action.require_offer_active)
    .execute(&mut *tx)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
    if updated.rows_affected() == 0 {
        return Err(ApiError::Conflict(
            "该推荐状态已发生变化，无法操作".to_string(),
        ));
    }
    tx.commit()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    let counterpart: String = row.get(action.notify_column);
    let offer_title: String = row.get("offer_title");
    let wanted_listing_id: String = row.get("wanted_listing_id");
    if let Err(e) = state
        .infra
        .notification
        .create(NewNotification {
            campus_id,
            user_id: &counterpart,
            event_type: action.event_type,
            title: action.title,
            body: &(action.body)(&offer_title),
            related_order_id: None,
            related_listing_id: Some(&wanted_listing_id),
            related_conversation_id: None,
            related_space_id: None,
        })
        .await
    {
        tracing::warn!(%e, response_id = %response_id, "Failed to notify response counterpart");
    }

    Ok(Json(serde_json::json!({
        "id": response_id.to_string(),
        "status": action.to_status,
    })))
}

/// POST /api/wanted-responses/{id}/accept — requester accepts a recommendation.
pub async fn accept_wanted_response(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    act_on_response(
        &state,
        &tenant.session.user_id,
        tenant.campus_id,
        id,
        ResponseAction {
            to_status: "accepted",
            actor_column: "requester_id",
            notify_column: "responder_id",
            event_type: "wanted_response_accepted",
            title: "你的推荐被采纳了",
            body: |offer| format!("需求方接受了你推荐的“{}”，可以开始联系", offer),
            require_wanted_active: true,
            require_offer_active: true,
        },
    )
    .await
}

/// POST /api/wanted-responses/{id}/dismiss — requester declines a recommendation.
pub async fn dismiss_wanted_response(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    act_on_response(
        &state,
        &tenant.session.user_id,
        tenant.campus_id,
        id,
        ResponseAction {
            to_status: "dismissed",
            actor_column: "requester_id",
            notify_column: "responder_id",
            event_type: "wanted_response_dismissed",
            title: "你的推荐未被采纳",
            body: |offer| format!("需求方暂不需要“{}”，感谢你的推荐", offer),
            require_wanted_active: true,
            require_offer_active: false,
        },
    )
    .await
}

/// POST /api/wanted-responses/{id}/withdraw — responder retracts their own
/// recommendation.
pub async fn withdraw_wanted_response(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    act_on_response(
        &state,
        &tenant.session.user_id,
        tenant.campus_id,
        id,
        ResponseAction {
            to_status: "withdrawn",
            actor_column: "responder_id",
            notify_column: "requester_id",
            event_type: "wanted_response_withdrawn",
            title: "一条推荐已被撤回",
            body: |offer| format!("对方撤回了推荐的“{}”", offer),
            require_wanted_active: false,
            require_offer_active: false,
        },
    )
    .await
}
