use super::common::*;
use crate::agents::runtime::envelope::ToolResultEnvelope;
use crate::services::order::{OrderError, OrderService};
use crate::utils::cents_to_yuan;
use rig::completion::ToolDefinition;
use rig::tool::Tool;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sqlx::{Postgres, Transaction};

#[derive(Serialize, Deserialize)]
pub struct PurchaseItemIntentArgs {
    pub listing_id: String,
    /// Cents internally; the model sends `offered_price_yuan`.
    #[serde(rename = "offered_price_yuan", with = "yuan")]
    pub offered_price: i64,
}

#[derive(Clone)]
pub struct PurchaseItemIntentTool {
    pub ctx: ToolContext,
}

impl Tool for PurchaseItemIntentTool {
    const NAME: &'static str = "purchase_item";
    type Error = ToolError;
    type Args = PurchaseItemIntentArgs;
    type Output = ToolResultEnvelope;

    async fn definition(&self, _prompt: String) -> ToolDefinition {
        ToolDefinition {
            name: "purchase_item".to_string(),
            description: "发起线下成交意向。平台只记录意向，不托管资金；卖家确认后才视为成交。"
                .to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "listing_id": { "type": "string", "description": "The listing ID for the deal intent" },
                    "offered_price_yuan": { "type": "number", "description": "线下面交出价，单位：元" }
                },
                "required": ["listing_id", "offered_price_yuan"]
            }),
        }
    }

    async fn call(&self, args: Self::Args) -> Result<Self::Output, Self::Error> {
        let summary = format!(
            "对商品 {} 发起线下成交意向，出价 ¥{:.2}",
            args.listing_id,
            cents_to_yuan(args.offered_price)
        );
        let res = propose_action_plan(&self.ctx, Self::NAME, "L3", &args, summary).await?;
        Ok(ToolResultEnvelope::success(res))
    }
}

/// Validated execution body for `purchase_item`; plan-confirmed only.
#[allow(dead_code)] // retained as a transaction-owning wrapper for direct callers/tests
pub async fn execute_purchase_item(
    ctx: &ToolContext,
    args: PurchaseItemIntentArgs,
) -> Result<String, ToolError> {
    let buyer_id = ctx
        .current_user_id
        .clone()
        .ok_or_else(|| ToolError("请先登录再进行操作".to_string()))?;
    let campus_id = require_verified_campus(ctx, &buyer_id).await?;
    let mut tx = ctx
        .db_pool
        .begin()
        .await
        .map_err(|error| ToolError(format!("Transaction error: {}", error)))?;
    if !lock_verified_membership_in_tx(&mut tx, &buyer_id, campus_id).await? {
        return Err(ToolError("请先完成校园身份验证后再进行此操作".to_string()));
    }
    let (message, recorded_intent) =
        execute_purchase_item_in_tx(ctx, &mut tx, &buyer_id, campus_id, args, None).await?;
    tx.commit()
        .await
        .map_err(|error| ToolError(format!("Commit error: {}", error)))?;
    if recorded_intent {
        if let Some(metrics) = crate::api::metrics::GLOBAL_METRICS.get() {
            metrics.record_deal_intent_created();
        }
    }
    Ok(message)
}

fn reasonable_offer_bounds(current_price: i64) -> (i64, i64) {
    (current_price / 2, current_price.saturating_mul(3) / 2)
}

fn purchase_intent_message(
    order_id: &str,
    listing_id: &str,
    buyer_id: &str,
    seller_id: &str,
    price: i64,
) -> String {
    format!(
        "Deal intent sent! Record ID: {}. Listing: '{}'. Buyer: {}, Seller: {}, Price: {:.2} CNY. The seller must confirm before the item is considered sold; Goods4ncu does not escrow funds.",
        order_id,
        listing_id,
        buyer_id,
        seller_id,
        cents_to_yuan(price)
    )
}

pub(crate) async fn execute_purchase_item_in_tx(
    ctx: &ToolContext,
    tx: &mut Transaction<'_, Postgres>,
    buyer_id: &str,
    campus_id: uuid::Uuid,
    args: PurchaseItemIntentArgs,
    expected_content_revision: Option<i64>,
) -> Result<(String, bool), ToolError> {
    // Lock the listing before reading owner, state and the price used for the
    // tolerance check. OrderService locks it again in this same transaction;
    // that is harmless and keeps its standalone invariant intact.
    let listing = sqlx::query_as::<_, ListingCheckRow>(
        "SELECT id, campus_id, owner_id, suggested_price_cny, status, content_revision
         FROM inventory WHERE id = $1 FOR UPDATE",
    )
    .bind(&args.listing_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(|error| ToolError(format!("Query error: {}", error)))?;
    let Some(listing) = listing else {
        return Ok((
            format!("No listing found with ID: {}", args.listing_id),
            false,
        ));
    };
    if let Some(expected) = expected_content_revision {
        if expected <= 0 {
            return Err(ToolError("资源版本必须为正整数".to_string()));
        }
        if expected != listing.content_revision {
            return Err(ToolError(format!(
                "商品内容已变化（期望版本 {}，当前版本 {}），请刷新后重新发起成交意向",
                expected, listing.content_revision
            )));
        }
    }

    let restricted: bool = sqlx::query_scalar("SELECT listing_has_active_restriction($1)")
        .bind(&args.listing_id)
        .fetch_one(&mut **tx)
        .await
        .map_err(|error| ToolError(format!("Query error: {}", error)))?;
    // Preserve the public tool's non-enumerating response for restricted rows.
    if restricted {
        return Ok((
            format!("No listing found with ID: {}", args.listing_id),
            false,
        ));
    }
    if listing.campus_id != campus_id {
        return Err(ToolError("只能对当前校园的商品发起成交意向".to_string()));
    }
    if !lock_verified_membership_in_tx(tx, &listing.owner_id, campus_id).await? {
        return Err(ToolError("只能与当前校园的已认证用户成交".to_string()));
    }
    if listing.status != "active" {
        return Ok((
            format!(
                "Listing {} is no longer available (status: {})",
                args.listing_id, listing.status
            ),
            false,
        ));
    }
    if buyer_id == listing.owner_id {
        return Err(ToolError("不能购买自己发布的商品".to_string()));
    }

    let (min_price, max_price) = reasonable_offer_bounds(listing.suggested_price_cny);
    if args.offered_price < min_price || args.offered_price > max_price {
        return Err(ToolError(format!(
            "出价 ¥{:.2} 不在合理范围内（¥{:.2} - ¥{:.2}）。商品标价 ¥{:.2}。",
            cents_to_yuan(args.offered_price),
            cents_to_yuan(min_price),
            cents_to_yuan(max_price),
            cents_to_yuan(listing.suggested_price_cny),
        )));
    }

    // A pending intent is idempotent only when it represents the same price.
    // Without comparing final_price, a newly confirmed amount could appear in
    // the result text while the database still held an older amount.
    if let Some((existing_id, existing_price)) = sqlx::query_as::<_, (String, i64)>(
        "SELECT id, final_price
         FROM orders
         WHERE listing_id = $1 AND buyer_id = $2 AND status = 'intent_pending'
         ORDER BY created_at DESC
         LIMIT 1
         FOR UPDATE",
    )
    .bind(&args.listing_id)
    .bind(buyer_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(|error| ToolError(format!("订单重复校验失败: {}", error)))?
    {
        if existing_price != args.offered_price {
            return Err(ToolError(format!(
                "你已对该商品发起过 ¥{:.2} 的待确认成交意向；请先处理该意向，再以 ¥{:.2} 重新发起",
                cents_to_yuan(existing_price),
                cents_to_yuan(args.offered_price)
            )));
        }
        return Ok((
            purchase_intent_message(
                &existing_id,
                &args.listing_id,
                buyer_id,
                &listing.owner_id,
                existing_price,
            ),
            false,
        ));
    }

    let order_id = OrderService::new(ctx.db_pool.clone())
        .create_order_in_tx(
            tx,
            &args.listing_id,
            buyer_id,
            &listing.owner_id,
            args.offered_price,
        )
        .await
        .map_err(|error| match error {
            OrderError::AlreadySold => ToolError(format!(
                "Listing {} is no longer available",
                args.listing_id
            )),
            OrderError::ListingRestricted | OrderError::NotFound => {
                ToolError(format!("No listing found with ID: {}", args.listing_id))
            }
            other => {
                tracing::error!(%other, listing_id = %args.listing_id, "Failed to create order from purchase tool");
                ToolError("订单创建失败，请稍后再试".to_string())
            }
        })?;

    Ok((
        purchase_intent_message(
            &order_id,
            &args.listing_id,
            buyer_id,
            &listing.owner_id,
            args.offered_price,
        ),
        true,
    ))
}

// ---------------------------------------------------------------------------
// 6b. NegotiateItemTool —发起还价请求，卖家 HITL 确认
// ---------------------------------------------------------------------------

/// Args for the negotiate_item tool.
/// The seller will receive a notification and must approve/reject/counter via
/// PATCH /api/negotiations/{id}/respond. The deal only proceeds if the seller approves.
#[derive(Serialize, Deserialize)]
pub struct NegotiateItemArgs {
    /// The listing the buyer wants to negotiate on
    pub listing_id: String,
    /// The buyer's proposed price (in CNY cents)
    /// Cents internally; the model sends `offered_price_yuan`.
    #[serde(rename = "offered_price_yuan", with = "yuan")]
    pub offered_price: i64,
    /// Short reason for the offer (e.g., "lightly used", "market price dropped")
    pub reason: String,
}

#[derive(Clone)]
pub struct NegotiateItemTool {
    pub ctx: ToolContext,
}

impl Tool for NegotiateItemTool {
    const NAME: &'static str = "negotiate_item";
    type Error = ToolError;
    type Args = NegotiateItemArgs;
    type Output = ToolResultEnvelope;

    async fn definition(&self, _prompt: String) -> ToolDefinition {
        ToolDefinition {
            name: Self::NAME.to_string(),
            description: "发起还价请求。买家对某件商品提出还价时使用，系统会通知卖家审批。只有卖家批准后才会创建订单。注意：不要对已经active的同一商品重复发起还价。".to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "listing_id": { "type": "string", "description": "The listing ID to negotiate on" },
                    "offered_price_yuan": { "type": "number", "description": "出价，单位：元" },
                    "reason": { "type": "string", "description": "Short reason for the offer" }
                },
                "required": ["listing_id", "offered_price_yuan", "reason"]
            }),
        }
    }

    async fn call(&self, args: Self::Args) -> Result<Self::Output, Self::Error> {
        let summary = format!(
            "对商品 {} 发起还价 ¥{:.2}",
            args.listing_id,
            cents_to_yuan(args.offered_price)
        );
        let res = propose_action_plan(&self.ctx, Self::NAME, "L3", &args, summary).await?;
        Ok(ToolResultEnvelope::success(res))
    }
}

/// Validated execution body for `negotiate_item`; plan-confirmed only.
#[allow(dead_code)] // retained as a transaction-owning wrapper for direct callers/tests
pub async fn execute_negotiate_item(
    ctx: &ToolContext,
    args: NegotiateItemArgs,
) -> Result<String, ToolError> {
    let buyer_id = ctx
        .current_user_id
        .clone()
        .ok_or_else(|| ToolError("请先登录再进行操作".to_string()))?;
    let campus_id = require_verified_campus(ctx, &buyer_id).await?;
    let mut tx = ctx
        .db_pool
        .begin()
        .await
        .map_err(|error| ToolError(format!("Transaction error: {}", error)))?;
    if !lock_verified_membership_in_tx(&mut tx, &buyer_id, campus_id).await? {
        return Err(ToolError("请先完成校园身份验证后再进行此操作".to_string()));
    }
    let message =
        execute_negotiate_item_in_tx(ctx, &mut tx, &buyer_id, campus_id, args, None).await?;
    tx.commit()
        .await
        .map_err(|error| ToolError(format!("Commit error: {}", error)))?;
    Ok(message)
}

pub(crate) async fn execute_negotiate_item_in_tx(
    ctx: &ToolContext,
    tx: &mut Transaction<'_, Postgres>,
    buyer_id: &str,
    campus_id: uuid::Uuid,
    args: NegotiateItemArgs,
    expected_content_revision: Option<i64>,
) -> Result<String, ToolError> {
    // Inventory is the first business-fact lock. This serializes eligibility,
    // duplicate detection and HITL insertion against takedown and retries.
    let listing = sqlx::query_as::<_, ListingCheckRow>(
        "SELECT id, campus_id, owner_id, suggested_price_cny, status, content_revision
         FROM inventory WHERE id = $1 AND campus_id = $2 FOR UPDATE",
    )
    .bind(&args.listing_id)
    .bind(campus_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(|error| ToolError(format!("DB error: {}", error)))?;
    let Some(listing) = listing else {
        return Err(ToolError("当前校园未找到可议价的商品".to_string()));
    };
    if let Some(expected) = expected_content_revision {
        if expected <= 0 {
            return Err(ToolError("资源版本必须为正整数".to_string()));
        }
        if expected != listing.content_revision {
            return Err(ToolError(format!(
                "商品内容已变化（期望版本 {}，当前版本 {}），请刷新后重新发起还价",
                expected, listing.content_revision
            )));
        }
    }

    if buyer_id == listing.owner_id {
        return Err(ToolError("不能对自己的商品发起还价".to_string()));
    }
    if !lock_verified_membership_in_tx(tx, &listing.owner_id, campus_id).await? {
        return Err(ToolError("只能与当前校园的已认证用户议价".to_string()));
    }

    let restricted: bool = sqlx::query_scalar("SELECT listing_has_active_restriction($1)")
        .bind(&args.listing_id)
        .fetch_one(&mut **tx)
        .await
        .map_err(|error| ToolError(format!("DB error: {}", error)))?;
    if restricted {
        return Err(ToolError("该商品受平台限制，无法发起还价".to_string()));
    }
    if listing.status != "active" {
        return Ok(format!("商品 {} 已下架或售出，无法还价", args.listing_id));
    }

    let (min_price, max_price) = reasonable_offer_bounds(listing.suggested_price_cny);
    if args.offered_price < min_price || args.offered_price > max_price {
        return Err(ToolError(format!(
            "还价 ¥{:.2} 不在合理范围 ¥{:.2} - ¥{:.2} 内",
            cents_to_yuan(args.offered_price),
            cents_to_yuan(min_price),
            cents_to_yuan(max_price),
        )));
    }

    let existing = sqlx::query(
        "SELECT id FROM hitl_requests
         WHERE listing_id = $1 AND buyer_id = $2 AND status = 'pending'",
    )
    .bind(&args.listing_id)
    .bind(buyer_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(|error| ToolError(format!("DB error: {}", error)))?;
    if existing.is_some() {
        return Ok("你已对该商品发起过还价，请等待卖家响应后再发起新还价".to_string());
    }

    let hitl_id = uuid::Uuid::new_v4().to_string();
    sqlx::query(
        r#"INSERT INTO hitl_requests
           (id, campus_id, listing_id, buyer_id, seller_id, proposed_price, reason, status, expires_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, 'pending', CURRENT_TIMESTAMP + INTERVAL '48 hours')"#,
    )
    .bind(&hitl_id)
    .bind(campus_id)
    .bind(&args.listing_id)
    .bind(buyer_id)
    .bind(&listing.owner_id)
    .bind(args.offered_price)
    .bind(&args.reason)
    .execute(&mut **tx)
    .await
    .map_err(|error| ToolError(format!("DB error: {}", error)))?;

    let notification_body = format!(
        "买家出价 ¥{:.2}，理由：{}",
        cents_to_yuan(args.offered_price),
        args.reason
    );
    ctx.notification
        .create_in_tx(
            tx,
            crate::services::notification::NewNotification {
                campus_id,
                user_id: &listing.owner_id,
                event_type: "negotiation_request",
                title: "有新的还价请求",
                body: &notification_body,
                related_order_id: Some(&hitl_id),
                related_listing_id: Some(&args.listing_id),
                related_conversation_id: None,
                related_space_id: None,
            },
        )
        .await
        .map_err(|error| ToolError(format!("通知创建失败: {}", error)))?;

    Ok(format!(
        "你的还价 ¥{:.2} 已发送给卖家，等待确认中。\
         卖家同意后订单将自动创建。\
         请留意通知。",
        cents_to_yuan(args.offered_price)
    ))
}

#[derive(sqlx::FromRow)]
struct ListingCheckRow {
    #[sqlx(rename = "id")]
    _id: String,
    campus_id: uuid::Uuid,
    owner_id: String,
    suggested_price_cny: i64,
    status: String,
    content_revision: i64,
}

// ---------------------------------------------------------------------------
// 7. GetMyListingsTool
// ---------------------------------------------------------------------------
