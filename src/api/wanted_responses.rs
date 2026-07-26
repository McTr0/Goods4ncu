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
use crate::api::session::Session;
use crate::api::AppState;
use crate::services::notification::NewNotification;

#[derive(Deserialize)]
pub struct ResponseListQuery {
    /// `requester` (default) — responses to my wanted items;
    /// `responder` — recommendations I sent.
    pub role: Option<String>,
    pub status: Option<String>,
    pub limit: Option<i64>,
}

/// GET /api/wanted-responses — the caller's responses, by role.
pub async fn list_wanted_responses(
    State(state): State<AppState>,
    Session(session): Session,
    Query(params): Query<ResponseListQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
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

    let rows = sqlx::query(&format!(
        "SELECT r.id, r.wanted_listing_id, r.offer_listing_id, r.responder_id, r.requester_id,
                r.message, r.status, r.created_at, r.responded_at,
                w.title AS wanted_title, o.title AS offer_title
         FROM wanted_responses r
         JOIN inventory w ON w.id = r.wanted_listing_id
         JOIN inventory o ON o.id = r.offer_listing_id
         WHERE r.{column} = $1 AND ($2::text IS NULL OR r.status = $2)
         ORDER BY r.created_at DESC
         LIMIT $3"
    ))
    .bind(&session.user_id)
    .bind(params.status.as_deref())
    .bind(limit)
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
                "offer_listing_id": row.get::<String, _>("offer_listing_id"),
                "offer_title": row.get::<String, _>("offer_title"),
                "responder_id": row.get::<String, _>("responder_id"),
                "requester_id": row.get::<String, _>("requester_id"),
                "message": row.get::<Option<String>, _>("message"),
                "status": row.get::<String, _>("status"),
                "created_at": row.get::<chrono::DateTime<chrono::Utc>, _>("created_at"),
                "responded_at": row.get::<Option<chrono::DateTime<chrono::Utc>>, _>("responded_at"),
            })
        })
        .collect();

    Ok(Json(serde_json::json!({ "items": items })))
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
}

async fn act_on_response(
    state: &AppState,
    user_id: &str,
    response_id: Uuid,
    action: ResponseAction,
) -> Result<Json<serde_json::Value>, ApiError> {
    // Load first so unauthorized callers get 404 (no response existence leak
    // across users) and so we have the counterpart + titles for notification.
    let row = sqlx::query(
        "SELECT r.campus_id, r.responder_id, r.requester_id, r.status,
                w.title AS wanted_title, o.title AS offer_title
         FROM wanted_responses r
         JOIN inventory w ON w.id = r.wanted_listing_id
         JOIN inventory o ON o.id = r.offer_listing_id
         WHERE r.id = $1",
    )
    .bind(response_id)
    .fetch_optional(&state.infra.db)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
    .ok_or(ApiError::NotFound)?;

    let actor: String = row.get(action.actor_column);
    if actor != user_id {
        return Err(ApiError::NotFound);
    }

    let updated = sqlx::query(&format!(
        "UPDATE wanted_responses
         SET status = $2, responded_at = NOW()
         WHERE id = $1 AND status = 'pending' AND {} = $3",
        action.actor_column
    ))
    .bind(response_id)
    .bind(action.to_status)
    .bind(user_id)
    .execute(&state.infra.db)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
    if updated.rows_affected() == 0 {
        let status: String = row.get("status");
        return Err(ApiError::Conflict(format!(
            "该推荐当前状态为 {}，无法操作",
            status
        )));
    }

    let campus_id: Uuid = row.get("campus_id");
    let counterpart: String = row.get(action.notify_column);
    let offer_title: String = row.get("offer_title");
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
            related_listing_id: None,
            related_conversation_id: None,
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
    Session(session): Session,
    Path(id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    act_on_response(
        &state,
        &session.user_id,
        id,
        ResponseAction {
            to_status: "accepted",
            actor_column: "requester_id",
            notify_column: "responder_id",
            event_type: "wanted_response_accepted",
            title: "你的推荐被采纳了",
            body: |offer| format!("需求方接受了你推荐的“{}”，可以开始联系", offer),
        },
    )
    .await
}

/// POST /api/wanted-responses/{id}/dismiss — requester declines a recommendation.
pub async fn dismiss_wanted_response(
    State(state): State<AppState>,
    Session(session): Session,
    Path(id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    act_on_response(
        &state,
        &session.user_id,
        id,
        ResponseAction {
            to_status: "dismissed",
            actor_column: "requester_id",
            notify_column: "responder_id",
            event_type: "wanted_response_dismissed",
            title: "你的推荐未被采纳",
            body: |offer| format!("需求方暂不需要“{}”，感谢你的推荐", offer),
        },
    )
    .await
}

/// POST /api/wanted-responses/{id}/withdraw — responder retracts their own
/// recommendation.
pub async fn withdraw_wanted_response(
    State(state): State<AppState>,
    Session(session): Session,
    Path(id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    act_on_response(
        &state,
        &session.user_id,
        id,
        ResponseAction {
            to_status: "withdrawn",
            actor_column: "responder_id",
            notify_column: "requester_id",
            event_type: "wanted_response_withdrawn",
            title: "一条推荐已被撤回",
            body: |offer| format!("对方撤回了推荐的“{}”", offer),
        },
    )
    .await
}
