//! Negotiation HITL service — manages seller/buyer negotiation workflows,
//! counter-offers, offline order conversion, and negotiation chat messages.

use chrono::{DateTime, Utc};
use serde::Serialize;
use sqlx::{PgPool, Postgres, Row, Transaction};
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::services::order::{OrderError, OrderService};

#[derive(Debug, Clone, Serialize)]
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

#[derive(Debug, Clone)]
pub struct RespondNegotiationOutcome {
    pub new_status: String,
    pub campus_id: Uuid,
    pub buyer_id: String,
    pub listing_id: String,
    pub notif_title: String,
    pub notif_body: String,
    pub order_created: bool,
}

#[derive(Debug, Clone)]
pub struct AcceptCounterOutcome {
    pub campus_id: Uuid,
    pub seller_id: String,
    pub listing_id: String,
}

#[derive(Debug, Clone)]
pub struct RejectCounterOutcome {
    pub campus_id: Uuid,
    pub seller_id: String,
    pub listing_id: String,
}

fn map_order_creation_error(error: OrderError) -> ApiError {
    match error {
        OrderError::AlreadySold => ApiError::Conflict("此商品已经售出".to_string()),
        other => {
            tracing::error!(%other, "Failed to create order for negotiation");
            ApiError::Internal(anyhow::anyhow!("Failed to create order"))
        }
    }
}

async fn create_confirmed_offline_order_in_tx(
    order_service: &OrderService,
    tx: &mut Transaction<'_, Postgres>,
    listing_id: &str,
    buyer_id: &str,
    seller_id: &str,
    final_price: i64,
    confirmed_by: &str,
) -> Result<String, ApiError> {
    let order_id = order_service
        .create_order_in_tx(tx, listing_id, buyer_id, seller_id, final_price)
        .await
        .map_err(map_order_creation_error)?;

    let updated = sqlx::query(
        "UPDATE inventory SET status = 'sold'
         WHERE id = $1 AND status = 'active'
           AND NOT listing_has_active_restriction(id)",
    )
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

#[derive(Clone)]
pub struct NegotiateService {
    db: PgPool,
    order_service: OrderService,
}

impl NegotiateService {
    pub fn new(db: PgPool, order_service: OrderService) -> Self {
        Self { db, order_service }
    }

    /// List the current user's negotiation requests.
    pub async fn list_negotiations(&self, user_id: &str) -> Result<Vec<HitlRequestItem>, ApiError> {
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
        .bind(user_id)
        .fetch_all(&self.db)
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
                    .try_get::<DateTime<Utc>, _>("created_at")
                    .map(|dt| dt.to_rfc3339())
                    .unwrap_or_default(),
                expires_at: row
                    .try_get::<Option<DateTime<Utc>>, _>("expires_at")
                    .ok()
                    .flatten()
                    .map(|dt| dt.to_rfc3339()),
            })
            .collect();

        Ok(items)
    }

    /// Seller responds to a pending negotiation request (approve, reject, counter).
    pub async fn respond_negotiation(
        &self,
        user_id: &str,
        id: &str,
        action: &str,
        counter_price_input: Option<i64>,
    ) -> Result<RespondNegotiationOutcome, ApiError> {
        let mut tx = self
            .db
            .begin()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let requires_eligible_listing = match action {
            "approve" | "counter" => true,
            "reject" => false,
            _ => {
                return Err(ApiError::BadRequest(
                    "action 必须是 approve/reject/counter".to_string(),
                ))
            }
        };

        if requires_eligible_listing {
            let link = sqlx::query(
                "SELECT listing_id, campus_id FROM hitl_requests
                 WHERE id = $1 AND seller_id = $2",
            )
            .bind(id)
            .bind(user_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
            .ok_or(ApiError::NotFound)?;
            let listing_id: String = link.get("listing_id");
            let campus_id: Uuid = link.get("campus_id");
            let listing_status = sqlx::query_scalar::<_, String>(
                "SELECT status FROM inventory
                 WHERE id = $1 AND campus_id = $2 FOR UPDATE",
            )
            .bind(&listing_id)
            .bind(campus_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
            .ok_or(ApiError::NotFound)?;
            let listing_restricted: bool =
                sqlx::query_scalar("SELECT listing_has_active_restriction($1)")
                    .bind(&listing_id)
                    .fetch_one(&mut *tx)
                    .await
                    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
            if listing_restricted {
                return Err(ApiError::CodedConflict {
                    code: "listing_restricted",
                    message: "该商品当前不可继续议价".to_string(),
                });
            }
            if listing_status != "active" {
                return Err(ApiError::CodedConflict {
                    code: "listing_action_stale",
                    message: "商品状态已变化，无法继续议价".to_string(),
                });
            }
        }

        let row = sqlx::query(
            "SELECT id, campus_id, seller_id, listing_id, buyer_id, status, proposed_price
             FROM hitl_requests WHERE id = $1 FOR UPDATE",
        )
        .bind(id)
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
        let campus_id: Uuid = row.get("campus_id");
        let buyer_id: String = row.get("buyer_id");
        let proposed_price: i64 = row.get("proposed_price");

        let (new_status, counter_price) = match action {
            "approve" => ("approved", None),
            "reject" => ("rejected", None),
            "counter" => {
                let cp = counter_price_input.ok_or_else(|| {
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
                        "系统：卖家接受了你的还价 ¥{:.2}，线下成交已确认",
                        crate::utils::cents_to_yuan(price)
                    ),
                    Some(price),
                )
            }
            "rejected" => ("系统：卖家拒绝了你的还价，交易取消".to_string(), None),
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
                &self.order_service,
                &mut tx,
                &listing_id,
                &buyer_id,
                user_id,
                price,
                user_id,
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
        .bind(id)
        .execute(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let conversation_id = format!("negotiate:{}", listing_id);
        sqlx::query(
            r#"INSERT INTO chat_messages (conversation_id, sender, receiver, is_agent, content, listing_id)
               VALUES ($1, $2, $3, TRUE, $4, $5)"#,
        )
        .bind(&conversation_id)
        .bind(user_id)
        .bind(&buyer_id)
        .bind(&system_content)
        .bind(&listing_id)
        .execute(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        tx.commit()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let (notif_title, notif_body): (String, String) = match new_status {
            "approved" => (
                "卖家接受了你的还价".to_string(),
                "卖家接受了你的还价，线下成交已确认".to_string(),
            ),
            "rejected" => (
                "卖家拒绝了你的还价".to_string(),
                "抱歉，卖家未能接受你的还价".to_string(),
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

        Ok(RespondNegotiationOutcome {
            new_status: new_status.to_string(),
            campus_id,
            buyer_id,
            listing_id,
            notif_title,
            notif_body,
            order_created: final_price_for_deal.is_some(),
        })
    }

    /// Buyer accepts seller's counter-offer.
    pub async fn accept_counter(
        &self,
        user_id: &str,
        id: &str,
    ) -> Result<AcceptCounterOutcome, ApiError> {
        let mut tx = self
            .db
            .begin()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let row = sqlx::query(
            "SELECT id, campus_id, buyer_id, seller_id, listing_id, status, counter_price
             FROM hitl_requests WHERE id = $1 FOR UPDATE",
        )
        .bind(id)
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
        let campus_id: Uuid = row.get("campus_id");
        let seller_id: String = row.get("seller_id");

        create_confirmed_offline_order_in_tx(
            &self.order_service,
            &mut tx,
            &listing_id,
            &buyer_id,
            &seller_id,
            counter_price,
            &buyer_id,
        )
        .await?;

        sqlx::query(
            r#"UPDATE hitl_requests
               SET status = 'approved', buyer_action = 'accepted', resolved_at = CURRENT_TIMESTAMP
               WHERE id = $1 AND status = 'countered'"#,
        )
        .bind(id)
        .execute(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

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

        Ok(AcceptCounterOutcome {
            campus_id,
            seller_id,
            listing_id,
        })
    }

    /// Buyer rejects seller's counter-offer.
    pub async fn reject_counter(
        &self,
        user_id: &str,
        id: &str,
    ) -> Result<RejectCounterOutcome, ApiError> {
        let mut tx = self
            .db
            .begin()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let row = sqlx::query(
            "SELECT id, campus_id, buyer_id, seller_id, listing_id, status
             FROM hitl_requests WHERE id = $1 FOR UPDATE",
        )
        .bind(id)
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
        let campus_id: Uuid = row.get("campus_id");
        let seller_id: String = row.get("seller_id");

        sqlx::query(
            r#"UPDATE hitl_requests
               SET status = 'rejected', buyer_action = 'rejected', resolved_at = CURRENT_TIMESTAMP
               WHERE id = $1 AND status = 'countered'"#,
        )
        .bind(id)
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

        Ok(RejectCounterOutcome {
            campus_id,
            seller_id,
            listing_id,
        })
    }
}
