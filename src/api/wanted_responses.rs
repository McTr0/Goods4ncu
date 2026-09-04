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
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::api::session::VerifiedTenant;
use crate::api::AppState;
use crate::services::notification::NewNotification;
use crate::services::wanted_response::{
    ActionWantedResponseParams, ListWantedResponsesParams, WantedResponseService,
};

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

    let service = WantedResponseService::new(state.infra.db.clone());
    let (rows, total) = service
        .list_responses(ListWantedResponsesParams {
            column,
            user_id: &session.user_id,
            campus_id: tenant.campus_id,
            status: params.status.as_deref(),
            wanted_listing_id,
            limit,
            offset,
        })
        .await?;

    let items: Vec<serde_json::Value> = rows
        .into_iter()
        .map(|row| {
            let round_is_current = row.lifecycle_epoch == Some(row.current_lifecycle_epoch)
                && row.wanted_status == "active"
                && !row.wanted_restricted;
            let available_actions: Vec<&str> = if row.status == "pending" && round_is_current {
                match role {
                    "requester" => {
                        if row.offer_status == "active" && !row.offer_restricted {
                            vec!["accept", "dismiss"]
                        } else {
                            vec!["dismiss"]
                        }
                    }
                    "responder" if row.offer_status == "active" && !row.offer_restricted => {
                        vec!["withdraw"]
                    }
                    "responder" => Vec::new(),
                    _ => Vec::new(),
                }
            } else {
                Vec::new()
            };
            serde_json::json!({
                "id": row.id.to_string(),
                "wanted_listing_id": row.wanted_listing_id,
                "wanted_title": row.wanted_title,
                "wanted_status": row.wanted_status,
                "offer_listing_id": row.offer_listing_id,
                "offer_title": row.offer_title,
                "offer_status": row.offer_status,
                "responder_id": row.responder_id,
                "requester_id": row.requester_id,
                "message": row.message,
                "status": row.status,
                "created_at": row.created_at,
                "responded_at": row.responded_at,
                "lifecycle_epoch": row.lifecycle_epoch,
                "current_lifecycle_epoch": row.current_lifecycle_epoch,
                "round_state": if round_is_current { "current" } else { "closed" },
                "available_actions": available_actions,
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
    require_offer_active: bool,
}

async fn act_on_response(
    state: &AppState,
    user_id: &str,
    campus_id: Uuid,
    response_id: Uuid,
    action: ResponseAction,
) -> Result<Json<serde_json::Value>, ApiError> {
    let service = WantedResponseService::new(state.infra.db.clone());
    let outcome = service
        .action_response(ActionWantedResponseParams {
            user_id,
            campus_id,
            response_id,
            actor_column: action.actor_column,
            to_status: action.to_status,
            require_offer_active: action.require_offer_active,
            notify_column: action.notify_column,
        })
        .await?;

    if let Err(e) = state
        .infra
        .notification
        .create(NewNotification {
            campus_id,
            user_id: &outcome.counterpart_id,
            event_type: action.event_type,
            title: action.title,
            body: &(action.body)(&outcome.offer_title),
            related_order_id: None,
            related_listing_id: Some(&outcome.wanted_listing_id),
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
            require_offer_active: false,
        },
    )
    .await
}
