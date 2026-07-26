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
use crate::api::session::Session;
use crate::api::AppState;
use crate::services::campus::CampusService;
use crate::services::order::OrderError;
use crate::utils::cents_to_yuan;

#[derive(Deserialize)]
pub struct OrderQuery {
    pub role: Option<String>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

#[derive(Serialize)]
pub struct OrderSummary {
    pub id: String,
    pub listing_id: String,
    pub listing_title: String,
    pub buyer_id: String,
    pub seller_id: String,
    pub buyer_username: String,
    pub seller_username: String,
    pub final_price_cny: f64,
    pub status: String,
    pub auto_delist: bool,
    pub confirmed_at: Option<String>,
    pub auto_delisted_at: Option<String>,
    pub listing_status: String,
    pub created_at: String,
}

impl From<crate::services::order::OrderSummaryRow> for OrderSummary {
    fn from(r: crate::services::order::OrderSummaryRow) -> Self {
        Self {
            id: r.id,
            listing_id: r.listing_id,
            listing_title: r.listing_title,
            buyer_id: r.buyer_id,
            seller_id: r.seller_id,
            buyer_username: r.buyer_username,
            seller_username: r.seller_username,
            final_price_cny: r.final_price as f64 / 100.0,
            status: r.status,
            auto_delist: r.auto_delist,
            confirmed_at: r.confirmed_at.map(|dt| dt.to_rfc3339()),
            auto_delisted_at: r.auto_delisted_at.map(|dt| dt.to_rfc3339()),
            listing_status: r.listing_status,
            created_at: r.created_at.to_rfc3339(),
        }
    }
}

#[derive(Serialize)]
pub struct OrdersResponse {
    pub items: Vec<OrderSummary>,
    pub total: i64,
    pub limit: i64,
    pub offset: i64,
}

#[derive(Serialize)]
pub struct OrderCapabilities {
    pub can_confirm: bool,
    pub can_cancel: bool,
    pub can_choose_auto_delist: bool,
}

#[derive(Serialize)]
pub struct OrderDetail {
    pub id: String,
    pub listing_id: String,
    pub listing_title: String,
    pub buyer_id: String,
    pub seller_id: String,
    pub buyer_username: String,
    pub seller_username: String,
    pub final_price_cny: f64,
    pub status: String,
    pub auto_delist: bool,
    pub confirmed_at: Option<String>,
    pub confirmed_by: Option<String>,
    pub auto_delisted_at: Option<String>,
    pub listing_status: String,
    pub created_at: String,
    pub paid_at: Option<String>,
    pub shipped_at: Option<String>,
    pub completed_at: Option<String>,
    pub cancelled_at: Option<String>,
    pub cancellation_reason: Option<String>,
    pub capabilities: OrderCapabilities,
}

impl OrderDetail {
    fn from_row(r: crate::services::order::SqlxOrderRow, viewer_id: &str) -> Self {
        let is_buyer = r.buyer_id == viewer_id;
        let is_seller = r.seller_id == viewer_id;
        let can_confirm = is_seller && r.status == "intent_pending";
        let can_cancel = (is_buyer || is_seller) && r.status == "intent_pending";

        Self {
            id: r.id,
            listing_id: r.listing_id,
            listing_title: r.listing_title,
            buyer_id: r.buyer_id,
            seller_id: r.seller_id,
            buyer_username: r.buyer_username,
            seller_username: r.seller_username,
            final_price_cny: r.final_price as f64 / 100.0,
            status: r.status,
            auto_delist: r.auto_delist,
            confirmed_at: r.confirmed_at.map(|dt| dt.to_rfc3339()),
            confirmed_by: r.confirmed_by,
            auto_delisted_at: r.auto_delisted_at.map(|dt| dt.to_rfc3339()),
            listing_status: r.listing_status,
            created_at: r.created_at.to_rfc3339(),
            paid_at: r.paid_at.map(|dt| dt.to_rfc3339()),
            shipped_at: r.shipped_at.map(|dt| dt.to_rfc3339()),
            completed_at: r.completed_at.map(|dt| dt.to_rfc3339()),
            cancelled_at: r.cancelled_at.map(|dt| dt.to_rfc3339()),
            cancellation_reason: r.cancellation_reason,
            capabilities: OrderCapabilities {
                can_confirm,
                can_cancel,
                can_choose_auto_delist: can_confirm,
            },
        }
    }
}

pub async fn get_orders(
    State(state): State<AppState>,
    Session(session): Session,
    Query(params): Query<OrderQuery>,
) -> Result<Json<OrdersResponse>, ApiError> {
    let user_id = session.user_id.clone();

    let limit = params.limit.unwrap_or(20).clamp(1, 100);
    let offset = params.offset.unwrap_or(0).max(0);

    let (items, total) = state
        .infra
        .order_service
        .list_orders(&user_id, params.role.as_deref(), limit, offset)
        .await
        .map_err(|e| {
            tracing::error!("get_orders error: {}", e);
            ApiError::Internal(anyhow::anyhow!("Failed to fetch orders"))
        })?;

    Ok(Json(OrdersResponse {
        items: items.into_iter().map(OrderSummary::from).collect(),
        total,
        limit,
        offset,
    }))
}

pub async fn get_order(
    State(state): State<AppState>,
    Session(session): Session,
    Path(order_id): Path<String>,
) -> Result<Json<OrderDetail>, ApiError> {
    let user_id = session.user_id.clone();

    let has_access = state
        .infra
        .order_service
        .verify_order_access(&order_id, &user_id)
        .await
        .map_err(|e| {
            tracing::error!("verify_order_access error: {}", e);
            ApiError::Internal(anyhow::anyhow!("Failed to verify order access"))
        })?;

    if !has_access {
        return Err(ApiError::Forbidden);
    }

    let order = state
        .infra
        .order_service
        .get_order_with_details(&order_id)
        .await
        .map_err(|e| {
            tracing::error!("get_order error: {}", e);
            ApiError::Internal(anyhow::anyhow!("Failed to fetch order"))
        })?
        .ok_or(ApiError::NotFound)?;

    Ok(Json(OrderDetail::from_row(order, &user_id)))
}

#[derive(Deserialize)]
pub struct CreateOrderRequest {
    pub listing_id: String,
    pub offered_price_cny: f64,
    pub message: Option<String>,
}

pub async fn create_order(
    State(state): State<AppState>,
    Session(session): Session,
    Json(payload): Json<CreateOrderRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let listing_row = sqlx::query(
        "SELECT owner_id, suggested_price_cny, status, campus_id FROM inventory WHERE id = $1",
    )
    .bind(&payload.listing_id)
    .fetch_optional(&state.infra.db)
    .await
    .map_err(|e| {
        tracing::error!("fetch listing error: {}", e);
        ApiError::Internal(anyhow::anyhow!("Failed to fetch listing"))
    })?;

    let (seller_id, suggested_price, listing_status, campus_id): (String, i64, String, uuid::Uuid) =
        match listing_row {
            Some(row) => (
                row.get("owner_id"),
                row.get("suggested_price_cny"),
                row.get("status"),
                row.get("campus_id"),
            ),
            None => return Err(ApiError::NotFound),
        };

    let tenant = CampusService::new(state.infra.db.clone())
        .require_shared_verified_campus_for_session(&session.user_id, &seller_id, session.campus_id)
        .await?;
    if tenant.campus_id != campus_id {
        return Err(ApiError::CampusScopeMismatch);
    }

    if seller_id == session.user_id {
        return Err(ApiError::BadRequest(
            "Cannot create a deal intent for your own listing".to_string(),
        ));
    }
    if listing_status != "active" {
        return Err(ApiError::Conflict("此商品暂不可发起成交意向".to_string()));
    }
    if let Some(message) = payload.message.as_deref() {
        if message.len() > 1000 {
            return Err(ApiError::BadRequest(
                "成交意向备注不能超过1000个字符".to_string(),
            ));
        }
    }

    let final_price_cents = (payload.offered_price_cny * 100.0).round() as i64;
    const PRICE_TOLERANCE: f64 = 0.50;
    let min_price = (suggested_price as f64 * (1.0 - PRICE_TOLERANCE)) as i64;
    let max_price = (suggested_price as f64 * (1.0 + PRICE_TOLERANCE)) as i64;
    if final_price_cents < min_price || final_price_cents > max_price {
        return Err(ApiError::BadRequest(format!(
            "Offered price must be within ±50% of suggested price ({} - {})",
            cents_to_yuan(min_price),
            cents_to_yuan(max_price)
        )));
    }

    let order_id = state
        .infra
        .order_service
        .create_order(
            &payload.listing_id,
            &session.user_id,
            &seller_id,
            final_price_cents,
        )
        .await
        .map_err(|e| match e {
            OrderError::AlreadySold => ApiError::Conflict("此商品暂不可发起成交意向".to_string()),
            OrderError::NotFound => ApiError::NotFound,
            other => {
                tracing::error!("create_order error: {}", other);
                ApiError::Internal(anyhow::anyhow!("Failed to create deal intent"))
            }
        })?;

    Ok(Json(serde_json::json!({
        "id": order_id,
        "status": "intent_pending",
        "message": "成交意向已发送，等待卖家确认"
    })))
}

#[derive(Deserialize)]
pub struct OrderActionRequest {
    pub reason: Option<String>,
}

#[derive(Deserialize, Default)]
pub struct ConfirmOrderRequest {
    pub auto_delist: Option<bool>,
}

fn confirm_request_hash(order_id: &str, auto_delist: bool) -> String {
    let canonical = serde_json::json!({
        "order_id": order_id,
        "auto_delist": auto_delist,
    });
    hex::encode(Sha256::digest(canonical.to_string().as_bytes()))
}

pub async fn pay_order(
    State(_state): State<AppState>,
    _headers: HeaderMap,
    Path(_order_id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    Err(ApiError::BadRequest(
        "平台不负责资金中转，请在线下自行确认付款方式".to_string(),
    ))
}

pub async fn ship_order(
    State(_state): State<AppState>,
    _headers: HeaderMap,
    Path(_order_id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    Err(ApiError::BadRequest(
        "平台不跟踪物流发货，请双方在线下约定交接方式".to_string(),
    ))
}

pub async fn confirm_order(
    State(state): State<AppState>,
    headers: HeaderMap,
    Session(session): Session,
    Path(order_id): Path<String>,
    payload: Option<Json<ConfirmOrderRequest>>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let user_id = session.user_id.clone();

    let auto_delist = payload
        .map(|Json(payload)| payload.auto_delist.unwrap_or(true))
        .unwrap_or(true);
    let idempotency_key = idempotency_key_from_headers(&headers)?;
    let request_hash = idempotency_key
        .as_deref()
        .map(|_| confirm_request_hash(&order_id, auto_delist));

    let success = state
        .infra
        .order_service
        .confirm_order_with_idempotency(
            &order_id,
            &user_id,
            auto_delist,
            false,
            idempotency_key.as_deref(),
            request_hash.as_deref(),
        )
        .await
        .map_err(|e| match e {
            OrderError::NotFound => ApiError::NotFound,
            OrderError::Forbidden => ApiError::Forbidden,
            OrderError::AlreadySold => ApiError::Conflict("此商品已经不可售".to_string()),
            OrderError::IdempotencyConflict => {
                ApiError::Conflict("Idempotency-Key 已用于不同的确认内容".to_string())
            }
            other => {
                tracing::error!("confirm_order error: {}", other);
                ApiError::Internal(anyhow::anyhow!("Failed to confirm deal intent"))
            }
        })?;

    if !success {
        return Err(ApiError::Conflict("当前成交意向状态不可确认".to_string()));
    }

    Ok(Json(serde_json::json!({
        "status": "confirmed",
        "auto_delist": auto_delist
    })))
}

pub async fn cancel_order(
    State(state): State<AppState>,
    Session(session): Session,
    Path(order_id): Path<String>,
    Json(payload): Json<OrderActionRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let user_id = session.user_id.clone();

    let success = state
        .infra
        .order_service
        .cancel_order(&order_id, &user_id, payload.reason.as_deref(), false, false)
        .await
        .map_err(|e| match e {
            OrderError::NotFound => ApiError::NotFound,
            OrderError::Forbidden => ApiError::Forbidden,
            other => {
                tracing::error!("cancel_order error: {}", other);
                ApiError::Internal(anyhow::anyhow!("Failed to cancel deal intent"))
            }
        })?;

    if !success {
        return Err(ApiError::Conflict("当前成交意向状态不可取消".to_string()));
    }

    Ok(Json(serde_json::json!({ "status": "cancelled" })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_order_summary_from_row() {
        let row = crate::services::order::OrderSummaryRow {
            id: "order-1".into(),
            listing_id: "listing-1".into(),
            listing_title: "iPhone 13".into(),
            buyer_id: "buyer-1".into(),
            seller_id: "seller-1".into(),
            final_price: 499900,
            status: "intent_pending".into(),
            auto_delist: true,
            confirmed_at: None,
            auto_delisted_at: None,
            created_at: chrono::Utc::now(),
            buyer_username: "buyeruser".into(),
            seller_username: "selleruser".into(),
            listing_status: "active".into(),
        };
        let summary = OrderSummary::from(row);
        assert_eq!(summary.final_price_cny, 4999.0);
        assert_eq!(summary.status, "intent_pending");
        assert_eq!(summary.listing_status, "active");
    }

    #[test]
    fn test_order_query_defaults() {
        let query: OrderQuery = serde_json::from_str(r#"{}"#).unwrap();
        assert_eq!(query.role, None);
        assert_eq!(query.limit, None);
        assert_eq!(query.offset, None);
    }

    #[test]
    fn test_order_query_with_filters() {
        let query: OrderQuery =
            serde_json::from_str(r#"{"role": "buyer", "limit": 10, "offset": 20}"#).unwrap();
        assert_eq!(query.role, Some("buyer".to_string()));
        assert_eq!(query.limit, Some(10));
        assert_eq!(query.offset, Some(20));
    }

    #[test]
    fn test_confirm_request_hash_covers_order_and_auto_delist_choice() {
        assert_eq!(
            confirm_request_hash("order-1", true),
            confirm_request_hash("order-1", true)
        );
        assert_ne!(
            confirm_request_hash("order-1", true),
            confirm_request_hash("order-1", false)
        );
        assert_ne!(
            confirm_request_hash("order-1", true),
            confirm_request_hash("order-2", true)
        );
    }
}
