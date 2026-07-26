//! Private-reservation price matching endpoints.
//!
//! Every response here is a [`SessionView`], which by construction contains no
//! reservation and no hint of the gap. That is deliberate: the safety property
//! lives in the type rather than in each handler remembering what to omit.
//!
//! The rule is stated in the response so the interface can show it. A pricing
//! black box is worse than haggling — at least haggling is legible — so a user
//! must be able to read why the number is what it is.

use axum::{
    extract::{Path, State},
    Json,
};
use serde::Deserialize;
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::api::session::VerifiedTenant;
use crate::api::AppState;
use crate::services::price_discovery::{Outcome, PriceDiscoveryService};

/// The rule, in the words a user should be able to repeat back.
const RULE_ZH: &str = "双方各自私下说出自己的价格底线：买家最多愿意付多少，卖家最少愿意收多少。\
如果买家的上限不低于卖家的下限，成交价取两者的中点；否则只告诉双方「这次没谈拢」，\
不会透露差多少。任何一方都看不到对方的数字。";

#[derive(Deserialize)]
pub struct ProposeRequest {
    pub listing_id: String,
}

/// POST /api/price-discovery — ask the other side to settle it this way.
///
/// Either party may propose; the listing's owner is the seller and the caller
/// the buyer, or the reverse when the owner proposes.
pub async fn propose(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Json(payload): Json<ProposeRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let owner: Option<String> = sqlx::query_scalar(
        "SELECT owner_id FROM inventory
         WHERE id = $1 AND campus_id = $2 AND status = 'active'",
    )
    .bind(&payload.listing_id)
    .bind(tenant.campus_id)
    .fetch_optional(&state.infra.db)
    .await
    .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
    let owner = owner.ok_or(ApiError::NotFound)?;

    if owner == tenant.session.user_id {
        // The seller cannot open a session with themselves, and this endpoint
        // has no way to know which buyer they mean.
        return Err(ApiError::BadRequest(
            "请从对话里向具体的买家发起".to_string(),
        ));
    }

    let service = PriceDiscoveryService::new(state.infra.db.clone());
    let id = service
        .propose(
            tenant.campus_id,
            &payload.listing_id,
            &owner,
            &tenant.session.user_id,
        )
        .await
        .map_err(ApiError::Internal)?;

    Ok(Json(
        serde_json::json!({ "session_id": id, "rule": RULE_ZH }),
    ))
}

/// POST /api/price-discovery/{id}/accept — agree to settle this way.
pub async fn accept(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(session_id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let service = PriceDiscoveryService::new(state.infra.db.clone());
    if !service
        .accept(session_id, &tenant.session.user_id)
        .await
        .map_err(ApiError::Internal)?
    {
        return Err(ApiError::NotFound);
    }
    view_response(&service, session_id, &tenant.session.user_id).await
}

/// POST /api/price-discovery/{id}/decline — keep haggling instead.
pub async fn decline(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(session_id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let service = PriceDiscoveryService::new(state.infra.db.clone());
    if !service
        .decline(session_id, &tenant.session.user_id)
        .await
        .map_err(ApiError::Internal)?
    {
        return Err(ApiError::NotFound);
    }
    view_response(&service, session_id, &tenant.session.user_id).await
}

#[derive(Deserialize)]
pub struct LimitRequest {
    /// The buyer's most, or the seller's least, in cents.
    pub cents: i64,
}

/// POST /api/price-discovery/{id}/limit — state your limit.
///
/// The request body is the only place this number appears. It is never echoed,
/// never logged, and never returned — including in the error paths, which is
/// why they are all the same shape.
pub async fn state_limit(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(session_id): Path<Uuid>,
    Json(payload): Json<LimitRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    if payload.cents < 0 || payload.cents > 1_000_000_000 {
        return Err(ApiError::BadRequest("价格超出合理范围".to_string()));
    }

    let service = PriceDiscoveryService::new(state.infra.db.clone());
    let outcome = service
        .state_limit(session_id, &tenant.session.user_id, payload.cents)
        .await
        .map_err(ApiError::Internal)?
        // Not a participant, not open, or unknown — one answer for all three, so
        // this cannot be used to learn a session's state without being in it.
        .ok_or(ApiError::NotFound)?;

    let outcome_label = match outcome {
        Outcome::WaitingForOther => "waiting",
        Outcome::Matched { .. } => "matched",
        Outcome::NoDeal => "no_deal",
    };
    // The price comes from the view rather than the outcome, so there is exactly
    // one place that decides what a participant may see.
    let mut body = view_body(&service, session_id, &tenant.session.user_id).await?;
    if let Some(object) = body.as_object_mut() {
        object.insert("outcome".to_string(), outcome_label.into());
    }
    Ok(Json(body))
}

/// GET /api/price-discovery/{id} — what the caller may know.
pub async fn get_session(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(session_id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let service = PriceDiscoveryService::new(state.infra.db.clone());
    view_response(&service, session_id, &tenant.session.user_id).await
}

async fn view_body(
    service: &PriceDiscoveryService,
    session_id: Uuid,
    user_id: &str,
) -> Result<serde_json::Value, ApiError> {
    let view = service
        .view(session_id, user_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or(ApiError::NotFound)?;
    Ok(serde_json::json!({ "session": view, "rule": RULE_ZH }))
}

async fn view_response(
    service: &PriceDiscoveryService,
    session_id: Uuid,
    user_id: &str,
) -> Result<Json<serde_json::Value>, ApiError> {
    view_body(service, session_id, user_id).await.map(Json)
}
