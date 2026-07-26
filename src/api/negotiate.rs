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
use sqlx::{Postgres, Row, Transaction};

use crate::api::error::ApiError;
use crate::api::session::Session;
use crate::api::AppState;
use crate::services::notification::NewNotification;
use crate::services::order::OrderError;

fn map_order_creation_error(error: OrderError) -> ApiError {
    match error {
        OrderError::AlreadySold => ApiError::Conflict("此商品已经售出".to_string()),
        other => {
            tracing::error!(%other, "Failed to create order for negotiation");
            ApiError::Internal(anyhow::anyhow!("Failed to create order"))
        }
    }
}

fn record_order_created_metric() {
    if let Some(metrics) = crate::api::metrics::GLOBAL_METRICS.get() {
        metrics.record_deal_intent_created();
    }
}

async fn create_confirmed_offline_order_in_tx(
    state: &AppState,
    tx: &mut Transaction<'_, Postgres>,
    listing_id: &str,
    buyer_id: &str,
    seller_id: &str,
    final_price: i64,
    confirmed_by: &str,
) -> Result<String, ApiError> {
    let order_id = state
        .infra
        .order_service
        .create_order_in_tx(tx, listing_id, buyer_id, seller_id, final_price)
        .await
        .map_err(map_order_creation_error)?;

    let updated =
        sqlx::query("UPDATE inventory SET status = 'sold' WHERE id = $1 AND status = 'active'")
            .bind(listing_id)
            .execute(&mut **tx)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    if updated.rows_affected() == 0 {
        return Err(ApiError::Conflict("此商品已经不可售".to_string()));
    }

    sqlx::query(
        r#"
        UPDATE orders
        SET status = 'confirmed',
            confirmed_at = NOW(),
            confirmed_by = $2,
            auto_delist = TRUE,
            auto_delisted_at = NOW()
        WHERE id = $1
          AND status IN ('intent_pending', 'pending')
        "#,
    )
    .bind(&order_id)
    .bind(confirmed_by)
    .execute(&mut **tx)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    Ok(order_id)
}

#[derive(Serialize)]
pub struct HitlRequestItem {
    pub id: String,
    pub listing_id: String,
    pub buyer_id: String,
    pub seller_id: String,
    pub proposed_price: f64,
    pub reason: String,
    pub status: String,
    pub counter_price: Option<f64>,
    pub created_at: String,
    /// When this pending request will automatically expire (ISO 8601).
    /// Null for non-pending statuses.
    pub expires_at: Option<String>,
}

/// GET /api/negotiations — list the current user's pending negotiation requests
/// (for sellers: requests awaiting their approval; for buyers: their sent offers)
pub async fn list_negotiations(
    State(state): State<AppState>,
    Session(session): Session,
    Json(_params): Json<ListNegotiationsParams>,
) -> Result<Json<ListNegotiationsResponse>, ApiError> {
    let user_id = session.user_id.clone();

    // Sellers see: pending (awaiting their response) and expired (auto-cancelled).
    // Buyers see: countered (awaiting their accept/reject), approved/rejected (final),
    // and expired (auto-cancelled).
    let rows = sqlx::query(
        r#"
        SELECT id, listing_id, buyer_id, seller_id, proposed_price, reason, status,
               counter_price, created_at, expires_at
        FROM hitl_requests
        WHERE seller_id = $1 AND status IN ('pending', 'expired')
        UNION ALL
        SELECT id, listing_id, buyer_id, seller_id, proposed_price, reason, status,
               counter_price, created_at, expires_at
        FROM hitl_requests
        WHERE buyer_id = $1 AND status IN ('countered', 'approved', 'rejected', 'expired')
        ORDER BY created_at DESC
        LIMIT 20
        "#,
    )
    .bind(&user_id)
    .fetch_all(&state.infra.db)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    let items: Vec<HitlRequestItem> = rows
        .iter()
        .map(|row| HitlRequestItem {
            id: row.get("id"),
            listing_id: row.get("listing_id"),
            buyer_id: row.get("buyer_id"),
            seller_id: row.get("seller_id"),
            proposed_price: crate::utils::cents_to_yuan(row.get::<i64, _>("proposed_price")),
            reason: row.get("reason"),
            status: row.get("status"),
            counter_price: row
                .try_get::<Option<i64>, _>("counter_price")
                .ok()
                .flatten()
                .map(crate::utils::cents_to_yuan),
            created_at: row
                .try_get::<sqlx::types::chrono::DateTime<sqlx::types::chrono::Utc>, _>("created_at")
                .map(|dt| dt.to_rfc3339())
                .unwrap_or_else(|_| String::new()),
            expires_at: row
                .try_get::<Option<sqlx::types::chrono::DateTime<sqlx::types::chrono::Utc>>, _>(
                    "expires_at",
                )
                .ok()
                .flatten()
                .map(|dt| dt.to_rfc3339()),
        })
        .collect();

    Ok(Json(ListNegotiationsResponse { items }))
}

#[derive(Deserialize)]
pub struct ListNegotiationsParams {}

#[derive(Serialize)]
pub struct ListNegotiationsResponse {
    pub items: Vec<HitlRequestItem>,
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
    let user_id = session.user_id.clone();

    let mut tx = state
        .infra
        .db
        .begin()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    // Fetch the request and verify ownership while locking the HITL row.
    let row = sqlx::query(
        "SELECT id, campus_id, seller_id, listing_id, buyer_id, status, proposed_price
         FROM hitl_requests WHERE id = $1 FOR UPDATE",
    )
    .bind(&id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
    .ok_or(ApiError::NotFound)?;

    let owner_id: String = row.get("seller_id");
    if owner_id != user_id {
        return Err(ApiError::Forbidden);
    }

    let current_status: String = row.get("status");
    if current_status != "pending" {
        return Err(ApiError::BadRequest("该议价请求已处理".to_string()));
    }

    let listing_id: String = row.get("listing_id");
    let campus_id: uuid::Uuid = row.get("campus_id");
    let buyer_id: String = row.get("buyer_id");
    let proposed_price: i64 = row.get("proposed_price");

    let (new_status, counter_price) = match payload.action.as_str() {
        "approve" => ("approved", None),
        "reject" => ("rejected", None),
        "counter" => {
            let cp = payload.counter_price.ok_or_else(|| {
                ApiError::BadRequest("counter 操作需要提供 counter_price".to_string())
            })?;
            ("countered", Some(cp))
        }
        _ => {
            return Err(ApiError::BadRequest(
                "action 必须是 approve/reject/counter".to_string(),
            ))
        }
    };

    let (system_content, final_price_for_deal): (String, Option<i64>) = match new_status {
        "approved" => {
            let price = proposed_price;
            (
                format!(
                    "系统：卖家接受了您的还价 ¥{:.2}，线下成交已确认",
                    crate::utils::cents_to_yuan(price)
                ),
                Some(price),
            )
        }
        "rejected" => ("系统：卖家拒绝了您的还价，交易取消".to_string(), None),
        "countered" => (
            format!(
                "系统：卖家还价 ¥{:.2}",
                crate::utils::cents_to_yuan(counter_price.unwrap())
            ),
            None,
        ),
        _ => unreachable!(),
    };

    if let Some(price) = final_price_for_deal {
        create_confirmed_offline_order_in_tx(
            &state,
            &mut tx,
            &listing_id,
            &buyer_id,
            &user_id,
            price,
            &user_id,
        )
        .await?;
    }

    sqlx::query(
        r#"UPDATE hitl_requests
           SET status = $1, counter_price = $2, resolved_at = CURRENT_TIMESTAMP
           WHERE id = $3 AND status = 'pending'"#,
    )
    .bind(new_status)
    .bind(counter_price)
    .bind(&id)
    .execute(&mut *tx)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    // Persist as an agent/system-style message while keeping sender FK-safe.
    let conversation_id = format!("negotiate:{}", listing_id);
    sqlx::query(
        r#"INSERT INTO chat_messages (conversation_id, sender, receiver, is_agent, content, listing_id)
           VALUES ($1, $2, $3, TRUE, $4, $5)"#,
    )
    .bind(&conversation_id)
    .bind(&user_id)
    .bind(&buyer_id)
    .bind(&system_content)
    .bind(&listing_id)
    .execute(&mut *tx)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    tx.commit()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    if final_price_for_deal.is_some() {
        record_order_created_metric();
    }

    // Notify the buyer after commit; notification delivery is best-effort.
    let (notif_title, notif_body): (String, String) = match new_status {
        "approved" => (
            "卖家接受了您的还价".to_string(),
            "卖家接受了您的还价，线下成交已确认".to_string(),
        ),
        "rejected" => (
            "卖家拒绝了您的还价".to_string(),
            "抱歉，卖家未能接受您的还价".to_string(),
        ),
        "countered" => (
            "卖家还价了".to_string(),
            format!(
                "卖家提出还价 ¥{:.2}",
                crate::utils::cents_to_yuan(counter_price.unwrap())
            ),
        ),
        _ => unreachable!(),
    };

    let _ = state
        .infra
        .notification
        .create(NewNotification {
            campus_id,
            user_id: &buyer_id,
            event_type: "negotiation_response",
            title: &notif_title,
            body: &notif_body,
            related_order_id: Some(&id),
            related_listing_id: Some(&listing_id),
            related_conversation_id: None,
            related_space_id: None,
        })
        .await;

    Ok(Json(NegotiationResponseResult {
        status: new_status.to_string(),
        message: format!("议价请求已更新为 {}", new_status),
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
    let user_id = session.user_id.clone();

    let mut tx = state
        .infra
        .db
        .begin()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    // Fetch the request and verify the buyer owns it.
    let row = sqlx::query(
        "SELECT id, campus_id, buyer_id, seller_id, listing_id, status, counter_price
         FROM hitl_requests WHERE id = $1 FOR UPDATE",
    )
    .bind(&id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
    .ok_or(ApiError::NotFound)?;

    let buyer_id: String = row.get("buyer_id");
    if buyer_id != user_id {
        return Err(ApiError::Forbidden);
    }

    let status: String = row.get("status");
    if status != "countered" {
        return Err(ApiError::BadRequest(
            "只能接受卖家的还价（状态必须为 countered）".to_string(),
        ));
    }

    let counter_price: i64 = row
        .get::<Option<i64>, _>("counter_price")
        .ok_or_else(|| ApiError::BadRequest("还价缺少 counter_price".to_string()))?;
    let listing_id: String = row.get("listing_id");
    let campus_id: uuid::Uuid = row.get("campus_id");
    let seller_id: String = row.get("seller_id");

    create_confirmed_offline_order_in_tx(
        &state,
        &mut tx,
        &listing_id,
        &buyer_id,
        &seller_id,
        counter_price,
        &buyer_id,
    )
    .await?;

    // Record buyer's acceptance.
    sqlx::query(
        r#"UPDATE hitl_requests
           SET status = 'approved', buyer_action = 'accepted', resolved_at = CURRENT_TIMESTAMP
           WHERE id = $1 AND status = 'countered'"#,
    )
    .bind(&id)
    .execute(&mut *tx)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    // Inject system message into conversation.
    let system_content = format!(
        "系统：买家接受了卖家的还价 ¥{:.2}，线下成交已确认",
        crate::utils::cents_to_yuan(counter_price)
    );
    let conversation_id = format!("negotiate:{}", listing_id);
    sqlx::query(
        r#"INSERT INTO chat_messages (conversation_id, sender, receiver, is_agent, content, listing_id)
           VALUES ($1, $2, $3, TRUE, $4, $5)"#,
    )
    .bind(&conversation_id)
    .bind(&buyer_id)
    .bind(&seller_id)
    .bind(&system_content)
    .bind(&listing_id)
    .execute(&mut *tx)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    tx.commit()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    record_order_created_metric();

    // Notify seller.
    let _ = state
        .infra
        .notification
        .create(NewNotification {
            campus_id,
            user_id: &seller_id,
            event_type: "negotiation_buyer_accepted",
            title: "买家接受了您的还价",
            body: "买家接受了您的还价，线下成交已确认",
            related_order_id: Some(&id),
            related_listing_id: Some(&listing_id),
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
    let user_id = session.user_id.clone();

    let mut tx = state
        .infra
        .db
        .begin()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    let row = sqlx::query(
        "SELECT id, campus_id, buyer_id, seller_id, listing_id, status
         FROM hitl_requests WHERE id = $1 FOR UPDATE",
    )
    .bind(&id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
    .ok_or(ApiError::NotFound)?;

    let buyer_id: String = row.get("buyer_id");
    if buyer_id != user_id {
        return Err(ApiError::Forbidden);
    }

    let status: String = row.get("status");
    if status != "countered" {
        return Err(ApiError::BadRequest(
            "只能拒绝卖家的还价（状态必须为 countered）".to_string(),
        ));
    }

    let listing_id: String = row.get("listing_id");
    let campus_id: uuid::Uuid = row.get("campus_id");
    let seller_id: String = row.get("seller_id");

    sqlx::query(
        r#"UPDATE hitl_requests
           SET status = 'rejected', buyer_action = 'rejected', resolved_at = CURRENT_TIMESTAMP
           WHERE id = $1 AND status = 'countered'"#,
    )
    .bind(&id)
    .execute(&mut *tx)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    let system_content = "系统：买家拒绝了卖家的还价，交易取消".to_string();
    let conversation_id = format!("negotiate:{}", listing_id);
    let _ = sqlx::query(
        r#"INSERT INTO chat_messages (conversation_id, sender, receiver, is_agent, content, listing_id)
           VALUES ($1, $2, $3, TRUE, $4, $5)"#,
    )
    .bind(&conversation_id)
    .bind(&buyer_id)
    .bind(&seller_id)
    .bind(&system_content)
    .bind(&listing_id)
    .execute(&mut *tx)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    tx.commit()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    let _ = state
        .infra
        .notification
        .create(NewNotification {
            campus_id,
            user_id: &seller_id,
            event_type: "negotiation_buyer_rejected",
            title: "买家拒绝了您的还价",
            body: "抱歉，买家未能接受您的还价",
            related_order_id: Some(&id),
            related_listing_id: Some(&listing_id),
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
