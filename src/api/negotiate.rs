//! Negotiation HITL API — seller approval via REST instead of CLI channel.
//!
//! Flow: marketplace agent calls NegotiationItemTool → creates pending HITL request
//! → seller gets notified (via /api/notifications) → responds via PATCH /api/negotiations/{id}
//! → HITL request resolved → notification sent to buyer.

use axum::{
    extract::{Path, State},
    Json,
};
use serde::{Deserialize, Serialize};

use crate::api::error::ApiError;
use crate::api::session::Session;
use crate::api::AppState;
use crate::services::negotiate::{HitlRequestItem, NegotiateService};
use crate::services::notification::NewNotification;

fn record_order_created_metric() {
    if let Some(metrics) = crate::api::metrics::GLOBAL_METRICS.get() {
        metrics.record_deal_intent_created();
    }
}

#[derive(Deserialize)]
pub struct ListNegotiationsParams {}

#[derive(Serialize)]
pub struct ListNegotiationsResponse {
    pub items: Vec<HitlRequestItem>,
}

/// GET /api/negotiations — list the current user's pending negotiation requests
/// (for sellers: requests awaiting their approval; for buyers: their sent offers)
pub async fn list_negotiations(
    State(state): State<AppState>,
    Session(session): Session,
    Json(_params): Json<ListNegotiationsParams>,
) -> Result<Json<ListNegotiationsResponse>, ApiError> {
    let service = NegotiateService::new(state.infra.db.clone(), state.infra.order_service.clone());
    let items = service.list_negotiations(&session.user_id).await?;
    Ok(Json(ListNegotiationsResponse { items }))
}

/// PATCH /api/negotiations/{id}/respond — seller responds to a pending negotiation request
///
/// body: { "action": "approve" | "reject" | "counter", "counter_price": 180000 }
pub async fn respond_negotiation(
    State(state): State<AppState>,
    Session(session): Session,
    Path(id): Path<String>,
    Json(payload): Json<NegotiationResponse>,
) -> Result<Json<NegotiationResponseResult>, ApiError> {
    let service = NegotiateService::new(state.infra.db.clone(), state.infra.order_service.clone());
    let outcome = service
        .respond_negotiation(
            &session.user_id,
            &id,
            &payload.action,
            payload.counter_price,
        )
        .await?;

    if outcome.order_created {
        record_order_created_metric();
    }

    // Notify the buyer after commit; notification delivery is best-effort.
    let _ = state
        .infra
        .notification
        .create(NewNotification {
            campus_id: outcome.campus_id,
            user_id: &outcome.buyer_id,
            event_type: "negotiation_response",
            title: &outcome.notif_title,
            body: &outcome.notif_body,
            related_order_id: Some(&id),
            related_listing_id: Some(&outcome.listing_id),
            related_conversation_id: None,
            related_space_id: None,
        })
        .await;

    Ok(Json(NegotiationResponseResult {
        status: outcome.new_status.clone(),
        message: format!("议价请求已更新为 {}", outcome.new_status),
    }))
}

/// PATCH /api/negotiations/{id}/accept — buyer accepts seller's counter-offer
///
/// After seller counters (status = 'countered'), buyer can accept the counter_price.
/// This creates the order in the same transaction and notifies the seller.
pub async fn accept_counter_negotiation(
    State(state): State<AppState>,
    Session(session): Session,
    Path(id): Path<String>,
) -> Result<Json<NegotiationResponseResult>, ApiError> {
    let service = NegotiateService::new(state.infra.db.clone(), state.infra.order_service.clone());
    let outcome = service.accept_counter(&session.user_id, &id).await?;

    record_order_created_metric();

    // Notify seller.
    let _ = state
        .infra
        .notification
        .create(NewNotification {
            campus_id: outcome.campus_id,
            user_id: &outcome.seller_id,
            event_type: "negotiation_buyer_accepted",
            title: "买家接受了你的还价",
            body: "买家接受了你的还价，线下成交已确认",
            related_order_id: Some(&id),
            related_listing_id: Some(&outcome.listing_id),
            related_conversation_id: None,
            related_space_id: None,
        })
        .await;

    Ok(Json(NegotiationResponseResult {
        status: "buyer_accepted".to_string(),
        message: "已接受卖家还价，线下成交已确认".to_string(),
    }))
}

/// PATCH /api/negotiations/{id}/reject — buyer rejects seller's counter-offer
///
/// After seller counters, buyer can reject. The negotiation closes without a deal.
pub async fn reject_counter_negotiation(
    State(state): State<AppState>,
    Session(session): Session,
    Path(id): Path<String>,
) -> Result<Json<NegotiationResponseResult>, ApiError> {
    let service = NegotiateService::new(state.infra.db.clone(), state.infra.order_service.clone());
    let outcome = service.reject_counter(&session.user_id, &id).await?;

    let _ = state
        .infra
        .notification
        .create(NewNotification {
            campus_id: outcome.campus_id,
            user_id: &outcome.seller_id,
            event_type: "negotiation_buyer_rejected",
            title: "买家拒绝了你的还价",
            body: "抱歉，买家未能接受你的还价",
            related_order_id: Some(&id),
            related_listing_id: Some(&outcome.listing_id),
            related_conversation_id: None,
            related_space_id: None,
        })
        .await;

    Ok(Json(NegotiationResponseResult {
        status: "buyer_rejected".to_string(),
        message: "已拒绝卖家还价".to_string(),
    }))
}

#[derive(Deserialize)]
pub struct NegotiationResponse {
    pub action: String,
    #[serde(default)]
    pub counter_price: Option<i64>,
}

#[derive(Serialize)]
pub struct NegotiationResponseResult {
    pub status: String,
    pub message: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hitl_request_item_serialization() {
        let item = HitlRequestItem {
            id: "req-1".to_string(),
            listing_id: "listing-1".to_string(),
            buyer_id: "buyer-1".to_string(),
            seller_id: "seller-1".to_string(),
            proposed_price: 180.50,
            reason: "Too expensive".to_string(),
            status: "pending".to_string(),
            counter_price: None,
            created_at: "2024-01-01T00:00:00Z".to_string(),
            expires_at: Some("2024-01-03T00:00:00Z".to_string()),
        };
        let json = serde_json::to_string(&item).unwrap();
        assert!(json.contains("\"proposed_price\":180.5"));
        assert!(json.contains("\"status\":\"pending\""));
        assert!(json.contains("\"expires_at\""));
    }

    #[test]
    fn test_negotiation_response_deserialize_approve() {
        let json = r#"{"action": "approve"}"#;
        let resp: NegotiationResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.action, "approve");
        assert_eq!(resp.counter_price, None);
    }

    #[test]
    fn test_negotiation_response_deserialize_counter() {
        let json = r#"{"action": "counter", "counter_price": 170000}"#;
        let resp: NegotiationResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.action, "counter");
        assert_eq!(resp.counter_price, Some(170000));
    }

    #[test]
    fn test_negotiation_response_result_serialization() {
        let result = NegotiationResponseResult {
            status: "approved".to_string(),
            message: "议价请求已更新为 approved".to_string(),
        };
        let json = serde_json::to_string(&result).unwrap();
        assert!(json.contains("approved"));
    }
}
