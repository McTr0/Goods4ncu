use crate::repositories::{CreateListingInput, PostgresListingRepository, UpdateListingInput};
use crate::services::order::{OrderError, OrderService};
use crate::utils::cents_to_yuan;
use async_trait::async_trait;
use rig::completion::ToolDefinition;
use rig::tool::Tool;
use serde::Deserialize;
use serde_json::json;
use sqlx::{PgConnection, PgPool};
use std::sync::Arc;
use tokio::runtime::Handle;
use tokio::task::spawn_blocking;

// ---------------------------------------------------------------------------
// Shared context for all tools
// ---------------------------------------------------------------------------

/// EmbedUpdater enables atomic re-embedding of listing content within a DB transaction.
///
/// The `embed_and_update` method is called from INSIDE a `spawn_blocking` closure
/// in `UpdateListingTool.call()`, where the `!Send` PgConnection can safely be used.
/// Using `#[async_trait(?Send)]` on the impl allows the async HTTP call to generate
/// a `!Send` future without conflicting with the `Tool::call()` `Send` bound.
#[async_trait(?Send)]
pub trait EmbedUpdater: Send + Sync {
    async fn embed_and_update(
        &self,
        content: String,
        listing_id: String,
        conn: &mut PgConnection,
    ) -> Result<(), ToolError>;
}

/// Shared dependencies injected into every marketplace tool.
#[derive(Clone)]
pub struct ToolContext {
    /// PostgreSQL pool — serves both relational data and vector data (pgvector).
    pub db_pool: PgPool,
    /// Re-embed and update a listing's vector document within a DB transaction.
    /// Called from spawn_blocking in UpdateListingTool so the !Send PgConnection
    /// is safe to use without affecting the Tool::call() Send bound.
    pub embed_updater: Arc<dyn EmbedUpdater>,
    pub current_user_id: Option<String>,
    /// Notification service for sending in-app alerts (e.g., negotiation requests).
    pub notification: crate::services::notification::NotificationService,
}

/// Unified error type for all marketplace tools.
#[derive(Debug, thiserror::Error)]
#[error("Tool error: {0}")]
pub struct ToolError(pub String);

// ---------------------------------------------------------------------------
// 1. CreateListingTool
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct CreateListingArgs {
    pub title: String,
    pub category: String,
    pub brand: String,
    pub condition_score: u8,
    pub suggested_price_cny: i64,
    pub defects: Vec<String>,
    pub original_description: String,
}

#[derive(Clone)]
pub struct CreateListingTool {
    pub ctx: ToolContext,
}

impl Tool for CreateListingTool {
    const NAME: &'static str = "create_listing";
    type Error = ToolError;
    type Args = CreateListingArgs;
    type Output = String;

    async fn definition(&self, _prompt: String) -> ToolDefinition {
        ToolDefinition {
            name: "create_listing".to_string(),
            description: "发布新的二手商品。当用户想要出售商品时使用。".to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "title": { "type": "string", "description": "A short title for the item" },
                    "category": { "type": "string", "description": "Item category" },
                    "brand": { "type": "string", "description": "Item brand" },
                    "condition_score": { "type": "integer", "description": "Condition from 1 to 10" },
                    "suggested_price_cny": { "type": "number", "description": "Price in CNY" },
                    "defects": { "type": "array", "items": { "type": "string" }, "description": "Any defects" },
                    "original_description": { "type": "string", "description": "User's original description" }
                },
                "required": ["title", "category", "brand", "condition_score", "suggested_price_cny", "defects", "original_description"]
            }),
        }
    }

    async fn call(&self, args: Self::Args) -> Result<Self::Output, Self::Error> {
        let owner = self
            .ctx
            .current_user_id
            .clone()
            .ok_or_else(|| ToolError("请先登录再进行操作".to_string()))?;

        let content_to_embed = format!(
            "Title: {}\nCategory: {}\nBrand: {}\nCondition: {}/10\nDescription: {}",
            args.title, args.category, args.brand, args.condition_score, args.original_description
        );

        let db_pool = self.ctx.db_pool.clone();
        let listing_repo = PostgresListingRepository::new(self.ctx.db_pool.clone());
        let embed_updater = self.ctx.embed_updater.clone();
        let input = CreateListingInput {
            title: args.title.clone(),
            category: args.category.clone(),
            brand: Some(args.brand.clone()),
            direction: "offer".to_string(),
            condition_score: args.condition_score as i32,
            suggested_price_cny: args.suggested_price_cny as f64 / 100.0,
            defects: args.defects.clone(),
            description: args.original_description.clone(),
            image_url: None,
            owner_id: owner.clone(),
        };

        let listing_id = spawn_blocking(move || {
            let rt = Handle::current();
            rt.block_on(async move {
                let mut tx: sqlx::Transaction<'_, sqlx::Postgres> = db_pool
                    .begin()
                    .await
                    .map_err(|e| ToolError(format!("Transaction error: {}", e)))?;

                let listing_id = listing_repo
                    .create_in_tx(&mut tx, input)
                    .await
                    .map_err(|e| ToolError(format!("DB insert error: {}", e)))?;

                #[allow(clippy::explicit_auto_deref)]
                embed_updater
                    .embed_and_update(content_to_embed, listing_id.clone(), &mut *tx)
                    .await
                    .map_err(|e| ToolError(format!("Embedding error: {}", e)))?;

                tx.commit()
                    .await
                    .map_err(|e| ToolError(format!("Commit error: {}", e)))?;

                Ok::<String, ToolError>(listing_id)
            })
        })
        .await
        .map_err(|e| ToolError(format!("Spawn error: {}", e)))??;

        Ok(format!(
            "Successfully created listing '{}' (ID: {}, Price: {} CNY, Owner: {})",
            args.title,
            listing_id,
            cents_to_yuan(args.suggested_price_cny),
            owner
        ))
    }
}

// ---------------------------------------------------------------------------
// 2. SearchInventoryTool
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct SearchInventoryArgs {
    pub keyword: Option<String>,
    pub category: Option<String>,
    pub max_price: Option<i64>,
    pub min_condition: Option<u8>,
}

#[derive(Clone)]
pub struct SearchInventoryTool {
    pub ctx: ToolContext,
}

impl Tool for SearchInventoryTool {
    const NAME: &'static str = "search_inventory";
    type Error = ToolError;
    type Args = SearchInventoryArgs;
    type Output = String;

    async fn definition(&self, _prompt: String) -> ToolDefinition {
        ToolDefinition {
            name: "search_inventory".to_string(),
            description: "搜索商品列表，支持关键词、分类、价格区间筛选。当用户想找特定商品时使用。"
                .to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "keyword": { "type": "string", "description": "Search keyword to match against title or description" },
                    "category": { "type": "string", "description": "Filter by category" },
                    "max_price": { "type": "number", "description": "Maximum price in CNY" },
                    "min_condition": { "type": "integer", "description": "Minimum condition score (1-10)" }
                },
                "required": []
            }),
        }
    }

    async fn call(&self, args: Self::Args) -> Result<Self::Output, Self::Error> {
        // Reject oversized keywords before they can cause performance issues with LIKE on large tables.
        const MAX_KEYWORD_LEN: usize = 200;
        if let Some(ref kw) = args.keyword {
            if kw.len() > MAX_KEYWORD_LEN {
                return Err(ToolError(format!(
                    "搜索关键词不能超过{}个字符",
                    MAX_KEYWORD_LEN
                )));
            }
        }

        let mut sql = String::from("SELECT id, title, brand, category, condition_score, suggested_price_cny FROM inventory WHERE status = 'active'");
        let mut param_idx: usize = 1;

        if args.keyword.is_some() {
            sql.push_str(&format!(
                " AND (title LIKE ${} OR description LIKE ${})",
                param_idx,
                param_idx + 1
            ));
            param_idx += 2;
        }
        if args.category.is_some() {
            sql.push_str(&format!(" AND category LIKE ${}", param_idx));
            param_idx += 1;
        }
        if args.max_price.is_some() {
            sql.push_str(&format!(" AND suggested_price_cny <= ${}", param_idx));
            param_idx += 1;
        }
        if args.min_condition.is_some() {
            sql.push_str(&format!(" AND condition_score >= ${}", param_idx));
        }
        sql.push_str(" LIMIT 10");

        let mut query = sqlx::query_as::<_, InventoryRow>(&sql);

        if let Some(ref kw) = args.keyword {
            query = query.bind(format!("%{}%", kw)).bind(format!("%{}%", kw));
        }
        if let Some(ref cat) = args.category {
            query = query.bind(format!("%{}%", cat));
        }
        if let Some(max_p) = args.max_price {
            query = query.bind(max_p);
        }
        if let Some(min_c) = args.min_condition {
            query = query.bind(min_c as i32);
        }

        let rows = query
            .fetch_all(&self.ctx.db_pool)
            .await
            .map_err(|e| ToolError(format!("Search query error: {}", e)))?;

        if rows.is_empty() {
            return Ok("No items found matching your criteria.".to_string());
        }

        let mut result = format!("Found {} item(s):\n", rows.len());
        for r in &rows {
            result.push_str(&format!(
                "- [{}] {} (Brand: {}, Category: {}, Condition: {}/10, Price: {} CNY)\n",
                r.id,
                r.title,
                r.brand,
                r.category,
                r.condition_score,
                cents_to_yuan(r.suggested_price_cny)
            ));
        }
        Ok(result)
    }
}

#[derive(sqlx::FromRow)]
struct InventoryRow {
    id: String,
    title: String,
    brand: String,
    category: String,
    condition_score: i64,
    suggested_price_cny: i64,
}

/// Lightweight row for fetching existing listing data before re-embedding.
#[derive(sqlx::FromRow)]
struct ExistingListingRow {
    title: String,
    category: String,
    brand: String,
    condition_score: i64,
    description: String,
}

// ---------------------------------------------------------------------------
// 3. GetListingDetailsTool
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct GetListingDetailsArgs {
    pub listing_id: String,
}

#[derive(Clone)]
pub struct GetListingDetailsTool {
    pub ctx: ToolContext,
}

impl Tool for GetListingDetailsTool {
    const NAME: &'static str = "get_listing_details";
    type Error = ToolError;
    type Args = GetListingDetailsArgs;
    type Output = String;

    async fn definition(&self, _prompt: String) -> ToolDefinition {
        ToolDefinition {
            name: "get_listing_details".to_string(),
            description: "获取指定商品的完整详情。".to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "listing_id": { "type": "string", "description": "The ID of the listing" }
                },
                "required": ["listing_id"]
            }),
        }
    }

    async fn call(&self, args: Self::Args) -> Result<Self::Output, Self::Error> {
        let row = sqlx::query_as::<_, FullListingRow>(
            "SELECT id, title, category, brand, condition_score, suggested_price_cny, defects, description, owner_id, status FROM inventory WHERE id = $1",
        )
        .bind(&args.listing_id)
        .fetch_optional(&self.ctx.db_pool)
        .await
        .map_err(|e| ToolError(format!("Query error: {}", e)))?;

        match row {
            Some(r) => {
                // Only show owner_id if the current user is the owner
                let owner_display = if Some(&r.owner_id) == self.ctx.current_user_id.as_ref() {
                    r.owner_id.clone()
                } else {
                    "[hidden]".to_string()
                };
                Ok(format!(
                    "Listing Details:\n\
                     ID: {}\nTitle: {}\nCategory: {}\nBrand: {}\n\
                     Condition: {}/10\nPrice: {} CNY\nDefects: {}\n\
                     Description: {}\nOwner: {}\nStatus: {}",
                    r.id,
                    r.title,
                    r.category,
                    r.brand,
                    r.condition_score,
                    cents_to_yuan(r.suggested_price_cny),
                    r.defects,
                    r.description.unwrap_or_default(),
                    owner_display,
                    r.status
                ))
            }
            None => Ok(format!("No listing found with ID: {}", args.listing_id)),
        }
    }
}

#[derive(sqlx::FromRow)]
struct FullListingRow {
    id: String,
    title: String,
    category: String,
    brand: String,
    condition_score: i64,
    suggested_price_cny: i64,
    defects: String,
    description: Option<String>,
    owner_id: String,
    status: String,
}

// ---------------------------------------------------------------------------
// 4. UpdateListingTool
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct UpdateListingArgs {
    pub listing_id: String,
    pub new_price: Option<i64>,
    pub new_title: Option<String>,
    pub new_description: Option<String>,
}

#[derive(Clone)]
pub struct UpdateListingTool {
    pub ctx: ToolContext,
}

impl Tool for UpdateListingTool {
    const NAME: &'static str = "update_listing";
    type Error = ToolError;
    type Args = UpdateListingArgs;
    type Output = String;

    async fn definition(&self, _prompt: String) -> ToolDefinition {
        ToolDefinition {
            name: "update_listing".to_string(),
            description: "修改商品的价格、标题或描述。当卖家想更新自己的商品信息时使用。"
                .to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "listing_id": { "type": "string", "description": "The listing ID to update" },
                    "new_price": { "type": "number", "description": "New price in CNY" },
                    "new_title": { "type": "string", "description": "New title" },
                    "new_description": { "type": "string", "description": "New description" }
                },
                "required": ["listing_id"]
            }),
        }
    }

    async fn call(&self, args: Self::Args) -> Result<Self::Output, Self::Error> {
        let owner_id = self
            .ctx
            .current_user_id
            .clone()
            .ok_or_else(|| ToolError("请先登录再进行操作".to_string()))?;

        if args.new_price.is_none() && args.new_title.is_none() && args.new_description.is_none() {
            return Ok("No fields to update were provided.".to_string());
        }

        let needs_reembedding = args.new_title.is_some() || args.new_description.is_some();

        // If title or description changed, we must re-embed atomically within the same transaction.
        // The spawn_blocking + block_on pattern lets us use the async EmbedUpdater
        // (whose future is !Send due to PgConnection borrow) without violating Tool::call()'s Send bound.
        if needs_reembedding {
            // First fetch the current listing so we can build accurate content for re-embedding.
            let existing = sqlx::query_as::<_, ExistingListingRow>(
                "SELECT title, category, brand, condition_score, description \
                 FROM inventory WHERE id = $1 AND owner_id = $2 AND status = 'active'",
            )
            .bind(&args.listing_id)
            .bind(&owner_id)
            .fetch_optional(&self.ctx.db_pool)
            .await
            .map_err(|e| ToolError(format!("Fetch listing error: {}", e)))?;

            let (title, category, brand, condition_score, description) = match existing {
                Some(row) => (
                    row.title,
                    row.category,
                    row.brand,
                    row.condition_score,
                    row.description,
                ),
                None => {
                    return Ok(format!(
                        "No active listing found with ID: {} (or you don't own it)",
                        args.listing_id
                    ));
                }
            };

            // Apply updates to the fetched fields for accurate content_to_embed
            let final_title = args.new_title.as_deref().unwrap_or(&title);
            let final_description = args.new_description.as_deref().unwrap_or(&description);

            let content_to_embed = format!(
                "Title: {}\nCategory: {}\nBrand: {}\nCondition: {}/10\nDescription: {}",
                final_title, category, brand, condition_score, final_description
            );

            let db_pool = self.ctx.db_pool.clone();
            let listing_repo = PostgresListingRepository::new(self.ctx.db_pool.clone());
            let embed_updater = self.ctx.embed_updater.clone();
            let listing_id = args.listing_id.clone();
            let owner_id_clone = owner_id.clone();
            let new_price = args.new_price;
            let new_title = args.new_title.clone();
            let new_description = args.new_description.clone();

            let update_result = spawn_blocking(move || {
                let rt = Handle::current();
                let result: Result<bool, ToolError> = rt.block_on(async move {
                    let mut tx: sqlx::Transaction<'_, sqlx::Postgres> = db_pool
                        .begin()
                        .await
                        .map_err(|e| ToolError(format!("Transaction error: {}", e)))?;

                    // Re-embed: same transaction so documents.id matches the listing_id
                    // Note: &mut *tx is required because Transaction doesn't implement Executor,
                    // but PoolConnection (what tx wraps) does.
                    #[allow(clippy::explicit_auto_deref)]
                    embed_updater
                        .embed_and_update(content_to_embed, listing_id.clone(), &mut *tx)
                        .await
                        .map_err(|e| ToolError(format!("Re-embedding error: {}", e)))?;

                    let update_result = listing_repo
                        .update_owned_active_in_tx(
                            &mut tx,
                            &listing_id,
                            &owner_id_clone,
                            &UpdateListingInput {
                                title: new_title,
                                category: None,
                                brand: None,
                                condition_score: None,
                                suggested_price_cny: new_price.map(|v| v as f64 / 100.0),
                                defects: None,
                                description: new_description,
                                status: None,
                            },
                        )
                        .await
                        .map_err(|e| ToolError(format!("Update error: {}", e)))?;

                    if !update_result {
                        tx.rollback()
                            .await
                            .map_err(|e| ToolError(format!("Rollback error: {}", e)))?;
                        Ok(false)
                    } else {
                        tx.commit()
                            .await
                            .map_err(|e| ToolError(format!("Commit error: {}", e)))?;
                        Ok(true)
                    }
                });
                result
            })
            .await
            .map_err(|e| ToolError(format!("Spawn error: {}", e)))??;

            if update_result {
                Ok(format!(
                    "Successfully updated listing {} (re-embedded)",
                    args.listing_id
                ))
            } else {
                Ok(format!(
                    "No active listing found with ID: {} (or you don't own it)",
                    args.listing_id
                ))
            }
        } else {
            // Price-only update — no re-embedding needed; keep it simple
            let listing_repo = PostgresListingRepository::new(self.ctx.db_pool.clone());
            let result = listing_repo
                .update_owned_active(
                    &args.listing_id,
                    &owner_id,
                    &UpdateListingInput {
                        title: None,
                        category: None,
                        brand: None,
                        condition_score: None,
                        suggested_price_cny: args.new_price.map(|v| v as f64 / 100.0),
                        defects: None,
                        description: None,
                        status: None,
                    },
                )
                .await
                .map_err(|e| ToolError(format!("Update error: {}", e)))?;

            if !result {
                Ok(format!(
                    "No active listing found with ID: {} (or you don't own it)",
                    args.listing_id
                ))
            } else {
                Ok(format!("Successfully updated listing {}", args.listing_id))
            }
        }
    }
}

// ---------------------------------------------------------------------------
// 5. DeleteListingTool
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct DeleteListingArgs {
    pub listing_id: String,
}

#[derive(Clone)]
pub struct DeleteListingTool {
    pub ctx: ToolContext,
}

impl Tool for DeleteListingTool {
    const NAME: &'static str = "delete_listing";
    type Error = ToolError;
    type Args = DeleteListingArgs;
    type Output = String;

    async fn definition(&self, _prompt: String) -> ToolDefinition {
        ToolDefinition {
            name: "delete_listing".to_string(),
            description: "删除（软删除）一个商品。当卖家想下架自己的商品时使用。".to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "listing_id": { "type": "string", "description": "The listing ID to remove" }
                },
                "required": ["listing_id"]
            }),
        }
    }

    async fn call(&self, args: Self::Args) -> Result<Self::Output, Self::Error> {
        let owner_id = self
            .ctx
            .current_user_id
            .clone()
            .ok_or_else(|| ToolError("请先登录再进行操作".to_string()))?;
        let listing_repo = PostgresListingRepository::new(self.ctx.db_pool.clone());
        let mut tx = self
            .ctx
            .db_pool
            .begin()
            .await
            .map_err(|e| ToolError(format!("Transaction error: {}", e)))?;

        let deleted = listing_repo
            .soft_delete_active_owned_in_tx(&mut tx, &args.listing_id, &owner_id)
            .await
            .map_err(|e| ToolError(format!("Delete error: {}", e)))?;

        if !deleted {
            tx.rollback()
                .await
                .map_err(|e| ToolError(format!("Rollback error: {}", e)))?;
            return Ok(format!(
                "No active listing found with ID: {} (or you don't own it)",
                args.listing_id
            ));
        }

        // Sync vector store: remove stale embedding so RAG won't surface deleted listings.
        // pgvector stores documents in the same 'documents' table, so we use SQL DELETE.
        sqlx::query("DELETE FROM documents WHERE id = $1")
            .bind(&args.listing_id)
            .execute(&mut *tx)
            .await
            .map_err(|e| ToolError(format!("Vector cleanup error: {}", e)))?;

        tx.commit()
            .await
            .map_err(|e| ToolError(format!("Commit error: {}", e)))?;

        Ok(format!("Successfully removed listing {}", args.listing_id))
    }
}

// ---------------------------------------------------------------------------
// 6. PurchaseItemIntentTool
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct PurchaseItemIntentArgs {
    pub listing_id: String,
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
    type Output = String;

    async fn definition(&self, _prompt: String) -> ToolDefinition {
        ToolDefinition {
            name: "purchase_item".to_string(),
            description: "发起线下成交意向。平台只记录意向，不托管资金；卖家确认后才视为成交。"
                .to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "listing_id": { "type": "string", "description": "The listing ID for the deal intent" },
                    "offered_price": { "type": "number", "description": "The proposed offline deal price in CNY" }
                },
                "required": ["listing_id", "offered_price"]
            }),
        }
    }

    async fn call(&self, args: Self::Args) -> Result<Self::Output, Self::Error> {
        let buyer_id = self
            .ctx
            .current_user_id
            .clone()
            .ok_or_else(|| ToolError("请先登录再进行操作".to_string()))?;

        // The service creates only an intent; seller confirmation performs any
        // optional delisting later.
        let listing = sqlx::query_as::<_, ListingCheckRow>(
            "SELECT id, owner_id, suggested_price_cny, status FROM inventory WHERE id = $1",
        )
        .bind(&args.listing_id)
        .fetch_optional(&self.ctx.db_pool)
        .await
        .map_err(|e| ToolError(format!("Query error: {}", e)))?;

        let listing = match listing {
            Some(l) => l,
            None => return Ok(format!("No listing found with ID: {}", args.listing_id)),
        };

        if listing.status != "active" {
            return Ok(format!(
                "Listing {} is no longer available (status: {})",
                args.listing_id, listing.status
            ));
        }

        // Cannot buy your own listing
        if buyer_id == listing.owner_id {
            return Err(ToolError("不能购买自己发布的商品".to_string()));
        }

        // Validate offered price is within reasonable range of suggested price (±50%).
        // This prevents both unrealistic lowballs and accidentally overpaying.
        const PRICE_TOLERANCE: f64 = 0.50;
        let min_price = (listing.suggested_price_cny as f64 * (1.0 - PRICE_TOLERANCE)) as i64;
        let max_price = (listing.suggested_price_cny as f64 * (1.0 + PRICE_TOLERANCE)) as i64;
        if args.offered_price < min_price || args.offered_price > max_price {
            return Err(ToolError(format!(
                "出价 ¥{:.2} 不在合理范围内（¥{:.2} - ¥{:.2}）。商品标价 ¥{:.2}。",
                cents_to_yuan(args.offered_price),
                cents_to_yuan(min_price),
                cents_to_yuan(max_price),
                cents_to_yuan(listing.suggested_price_cny),
            )));
        }

        let order_id = OrderService::new(self.ctx.db_pool.clone())
            .create_order(
                &args.listing_id,
                &buyer_id,
                &listing.owner_id,
                args.offered_price,
            )
            .await
            .map_err(|e| match e {
                OrderError::AlreadySold => ToolError(format!(
                    "Listing {} is no longer available",
                    args.listing_id
                )),
                other => {
                    tracing::error!(%other, listing_id = %args.listing_id, "Failed to create order from purchase tool");
                    ToolError("订单创建失败，请稍后再试".to_string())
                }
            })?;

        Ok(format!(
            "Deal intent sent! Record ID: {}. Listing: '{}'. Buyer: {}, Seller: {}, Price: {:.2} CNY. The seller must confirm before the item is considered sold; Goods4ncu does not escrow funds.",
            order_id,
            args.listing_id,
            buyer_id,
            listing.owner_id,
            cents_to_yuan(args.offered_price)
        ))
    }
}

// ---------------------------------------------------------------------------
// 6b. NegotiateItemTool —发起还价请求，卖家 HITL 确认
// ---------------------------------------------------------------------------

/// Args for the negotiate_item tool.
/// The seller will receive a notification and must approve/reject/counter via
/// PATCH /api/negotiations/{id}/respond. The deal only proceeds if the seller approves.
#[derive(Deserialize)]
pub struct NegotiateItemArgs {
    /// The listing the buyer wants to negotiate on
    pub listing_id: String,
    /// The buyer's proposed price (in CNY cents)
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
    type Output = String;

    async fn definition(&self, _prompt: String) -> ToolDefinition {
        ToolDefinition {
            name: Self::NAME.to_string(),
            description: "发起还价请求。买家对某件商品提出还价时使用，系统会通知卖家审批。只有卖家批准后才会创建订单。注意：不要对已经active的同一商品重复发起还价。".to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "listing_id": { "type": "string", "description": "The listing ID to negotiate on" },
                    "offered_price": { "type": "number", "description": "The offered price in CNY cents" },
                    "reason": { "type": "string", "description": "Short reason for the offer" }
                },
                "required": ["listing_id", "offered_price", "reason"]
            }),
        }
    }

    async fn call(&self, args: Self::Args) -> Result<Self::Output, Self::Error> {
        let buyer_id = self
            .ctx
            .current_user_id
            .clone()
            .ok_or_else(|| ToolError("请先登录再进行操作".to_string()))?;

        // Fetch the listing to get the seller and check it's active
        let listing_row = sqlx::query_as::<_, ListingCheckRow>(
            "SELECT id, owner_id, suggested_price_cny, status FROM inventory WHERE id = $1",
        )
        .bind(&args.listing_id)
        .fetch_optional(&self.ctx.db_pool)
        .await
        .map_err(|e| ToolError(format!("DB error: {}", e)))?;

        let listing = match listing_row {
            Some(l) => l,
            None => return Ok(format!("No listing found with ID: {}", args.listing_id)),
        };

        if listing.status != "active" {
            return Ok(format!("商品 {} 已下架或售出，无法还价", args.listing_id));
        }

        if buyer_id == listing.owner_id {
            return Err(ToolError("不能对自己的商品发起还价".to_string()));
        }

        // Validate offered price is within a reasonable range (±50% of asking price)
        const PRICE_TOLERANCE: f64 = 0.50;
        let min_price = (listing.suggested_price_cny as f64 * (1.0 - PRICE_TOLERANCE)) as i64;
        let max_price = (listing.suggested_price_cny as f64 * (1.0 + PRICE_TOLERANCE)) as i64;
        if args.offered_price < min_price || args.offered_price > max_price {
            return Err(ToolError(format!(
                "还价 ¥{:.2} 不在合理范围 ¥{:.2} - ¥{:.2} 内",
                cents_to_yuan(args.offered_price),
                cents_to_yuan(min_price),
                cents_to_yuan(max_price),
            )));
        }

        // Check if there's already a pending negotiation for this buyer+listing
        let existing = sqlx::query(
            "SELECT id FROM hitl_requests WHERE listing_id = $1 AND buyer_id = $2 AND status = 'pending'",
        )
        .bind(&args.listing_id)
        .bind(&buyer_id)
        .fetch_optional(&self.ctx.db_pool)
        .await
        .map_err(|e| ToolError(format!("DB error: {}", e)))?;
        if existing.is_some() {
            return Ok("您已对该商品发起过还价，请等待卖家响应后再发起新还价".to_string());
        }

        // Create the HITL request in the database
        let hitl_id = uuid::Uuid::new_v4().to_string();
        sqlx::query(
            r#"INSERT INTO hitl_requests
               (id, listing_id, buyer_id, seller_id, proposed_price, reason, status, expires_at)
               VALUES ($1, $2, $3, $4, $5, $6, 'pending', CURRENT_TIMESTAMP + INTERVAL '48 hours')"#,
        )
        .bind(&hitl_id)
        .bind(&args.listing_id)
        .bind(&buyer_id)
        .bind(&listing.owner_id)
        .bind(args.offered_price)
        .bind(&args.reason)
        .execute(&self.ctx.db_pool)
        .await
        .map_err(|e| ToolError(format!("DB error: {}", e)))?;

        // Notify the seller immediately
        let _ = self
            .ctx
            .notification
            .create(
                &listing.owner_id,
                "negotiation_request",
                "有新的还价请求",
                &format!(
                    "买家出价 ¥{:.2}，理由：{}",
                    cents_to_yuan(args.offered_price),
                    args.reason
                ),
                Some(&hitl_id),
                Some(&args.listing_id),
            )
            .await;

        Ok(format!(
            "您的还价 ¥{:.2} 已发送给卖家，等待确认中。\
             卖家同意后订单将自动创建。\
             请留意通知。",
            cents_to_yuan(args.offered_price)
        ))
    }
}

#[derive(sqlx::FromRow)]
struct ListingCheckRow {
    #[sqlx(rename = "id")]
    _id: String,
    owner_id: String,
    suggested_price_cny: i64,
    status: String,
}

// ---------------------------------------------------------------------------
// 7. GetMyListingsTool
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct GetMyListingsArgs {}

#[derive(Clone)]
pub struct GetMyListingsTool {
    pub ctx: ToolContext,
}

impl Tool for GetMyListingsTool {
    const NAME: &'static str = "get_my_listings";
    type Error = ToolError;
    type Args = GetMyListingsArgs;
    type Output = String;

    async fn definition(&self, _prompt: String) -> ToolDefinition {
        ToolDefinition {
            name: "get_my_listings".to_string(),
            description: "获取当前用户发布的所有商品列表。当用户想查看或管理自己的商品时使用。"
                .to_string(),
            parameters: json!({
                "type": "object",
                "properties": {},
                "required": []
            }),
        }
    }

    async fn call(&self, _args: Self::Args) -> Result<Self::Output, Self::Error> {
        let owner_id = self
            .ctx
            .current_user_id
            .clone()
            .ok_or_else(|| ToolError("请先登录再进行操作".to_string()))?;

        let rows = sqlx::query_as::<_, MyListingRow>(
            "SELECT id, title, status, suggested_price_cny FROM inventory WHERE owner_id = $1 ORDER BY status",
        )
        .bind(&owner_id)
        .fetch_all(&self.ctx.db_pool)
        .await
        .map_err(|e| ToolError(format!("Query error: {}", e)))?;

        if rows.is_empty() {
            return Ok(format!("No listings found for user: {}", owner_id));
        }

        let mut result = format!("Your listings ({} total):\n", rows.len());
        for r in &rows {
            let status_emoji = match r.status.as_str() {
                "active" => "\u{1F7E2}",
                "sold" => "\u{1F534}",
                "deleted" => "\u{26AB}",
                _ => "\u{26AA}",
            };
            result.push_str(&format!(
                "{} [{}] {} - {} CNY ({})\n",
                status_emoji,
                r.id,
                r.title,
                cents_to_yuan(r.suggested_price_cny),
                r.status
            ));
        }
        Ok(result)
    }
}

#[derive(sqlx::FromRow)]
struct MyListingRow {
    id: String,
    title: String,
    status: String,
    suggested_price_cny: i64,
}

// ---------------------------------------------------------------------------
// Unit tests (no DB required)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_infra::with_test_pool;
    use sqlx::Row;
    use uuid::Uuid;

    struct NoopEmbedUpdater;

    #[async_trait(?Send)]
    impl EmbedUpdater for NoopEmbedUpdater {
        async fn embed_and_update(
            &self,
            _content: String,
            _listing_id: String,
            _conn: &mut PgConnection,
        ) -> Result<(), ToolError> {
            Ok(())
        }
    }

    fn tool_context(pool: sqlx::PgPool, current_user_id: Option<String>) -> ToolContext {
        ToolContext {
            db_pool: pool.clone(),
            embed_updater: Arc::new(NoopEmbedUpdater),
            current_user_id,
            notification: crate::services::notification::NotificationService::new(pool),
        }
    }

    async fn insert_tool_user(pool: &sqlx::PgPool, id: &str, username: &str) {
        sqlx::query(
            "INSERT INTO users (id, username, password_hash, role) VALUES ($1, $2, 'hash', 'user')",
        )
        .bind(id)
        .bind(username)
        .execute(pool)
        .await
        .expect("insert user");
    }

    async fn insert_tool_listing(
        pool: &sqlx::PgPool,
        listing_id: &str,
        owner_id: &str,
        suggested_price_cny: i64,
        status: &str,
    ) {
        sqlx::query(
            "INSERT INTO inventory (id, title, category, brand, condition_score, suggested_price_cny, defects, owner_id, status) \
             VALUES ($1, 'Tool Listing', 'electronics', 'Acme', 8, $2, '[]', $3, $4)",
        )
        .bind(listing_id)
        .bind(suggested_price_cny)
        .bind(owner_id)
        .bind(status)
        .execute(pool)
        .await
        .expect("insert listing");
    }

    #[test]
    fn test_tool_error_display() {
        let err = ToolError("test error message".to_string());
        assert_eq!(err.to_string(), "Tool error: test error message");
    }

    #[test]
    fn test_tool_error_debug() {
        let err = ToolError("debug test".to_string());
        let debug_str = format!("{:?}", err);
        assert!(debug_str.contains("ToolError"));
        assert!(debug_str.contains("debug test"));
    }

    #[test]
    fn test_create_listing_args_deserialization() {
        let json = r#"{
            "title": "iPhone 13",
            "category": "electronics",
            "brand": "Apple",
            "condition_score": 8,
            "suggested_price_cny": 500000,
            "defects": ["Minor scratch"],
            "original_description": "Barely used"
        }"#;
        let args: CreateListingArgs = serde_json::from_str(json).unwrap();
        assert_eq!(args.title, "iPhone 13");
        assert_eq!(args.category, "electronics");
        assert_eq!(args.brand, "Apple");
        assert_eq!(args.condition_score, 8);
        assert_eq!(args.suggested_price_cny, 500000);
        assert!(args.defects.contains(&"Minor scratch".to_string()));
        assert_eq!(args.original_description, "Barely used");
    }

    #[test]
    fn test_create_listing_args_empty_defects() {
        let json = r#"{
            "title": "Book",
            "category": "books",
            "brand": "Publisher",
            "condition_score": 7,
            "suggested_price_cny": 5000,
            "defects": [],
            "original_description": "Like new"
        }"#;
        let args: CreateListingArgs = serde_json::from_str(json).unwrap();
        assert!(args.defects.is_empty());
    }

    #[test]
    fn test_search_inventory_args_partial() {
        // Only keyword provided
        let json = r#"{"keyword": "iphone"}"#;
        let args: SearchInventoryArgs = serde_json::from_str(json).unwrap();
        assert_eq!(args.keyword, Some("iphone".to_string()));
        assert_eq!(args.category, None);
        assert_eq!(args.max_price, None);
        assert_eq!(args.min_condition, None);
    }

    #[test]
    fn test_search_inventory_args_all_filters() {
        let json = r#"{
            "keyword": "laptop",
            "category": "electronics",
            "max_price": 500000,
            "min_condition": 7
        }"#;
        let args: SearchInventoryArgs = serde_json::from_str(json).unwrap();
        assert_eq!(args.keyword, Some("laptop".to_string()));
        assert_eq!(args.category, Some("electronics".to_string()));
        assert_eq!(args.max_price, Some(500000));
        assert_eq!(args.min_condition, Some(7));
    }

    #[test]
    fn test_search_inventory_args_empty() {
        let json = r#"{}"#;
        let args: SearchInventoryArgs = serde_json::from_str(json).unwrap();
        assert_eq!(args.keyword, None);
        assert_eq!(args.category, None);
        assert_eq!(args.max_price, None);
        assert_eq!(args.min_condition, None);
    }

    #[test]
    fn test_get_listing_details_args() {
        let json = r#"{"listing_id": "listing-123"}"#;
        let args: GetListingDetailsArgs = serde_json::from_str(json).unwrap();
        assert_eq!(args.listing_id, "listing-123");
    }

    #[test]
    fn test_update_listing_args_partial() {
        // Only new_price provided
        let json = r#"{"listing_id": "listing-456", "new_price": 450000}"#;
        let args: UpdateListingArgs = serde_json::from_str(json).unwrap();
        assert_eq!(args.listing_id, "listing-456");
        assert_eq!(args.new_price, Some(450000));
        assert_eq!(args.new_title, None);
        assert_eq!(args.new_description, None);
    }

    #[test]
    fn test_update_listing_args_all_fields() {
        let json = r#"{
            "listing_id": "listing-789",
            "new_price": 400000,
            "new_title": "Updated Title",
            "new_description": "New description"
        }"#;
        let args: UpdateListingArgs = serde_json::from_str(json).unwrap();
        assert_eq!(args.listing_id, "listing-789");
        assert_eq!(args.new_price, Some(400000));
        assert_eq!(args.new_title, Some("Updated Title".to_string()));
        assert_eq!(args.new_description, Some("New description".to_string()));
    }

    #[test]
    fn test_delete_listing_args() {
        let json = r#"{"listing_id": "listing-delete-1"}"#;
        let args: DeleteListingArgs = serde_json::from_str(json).unwrap();
        assert_eq!(args.listing_id, "listing-delete-1");
    }

    #[test]
    fn test_purchase_item_intent_args() {
        let json = r#"{"listing_id": "listing-buy-1", "offered_price": 450000}"#;
        let args: PurchaseItemIntentArgs = serde_json::from_str(json).unwrap();
        assert_eq!(args.listing_id, "listing-buy-1");
        assert_eq!(args.offered_price, 450000);
    }

    #[tokio::test]
    async fn purchase_item_tool_creates_deal_intent_without_marking_listing_sold() {
        with_test_pool(|pool| async move {
            let seller_id = Uuid::new_v4().to_string();
            let buyer_id = Uuid::new_v4().to_string();
            let listing_id = Uuid::new_v4().to_string();

            insert_tool_user(&pool, &seller_id, "purchase_seller").await;
            insert_tool_user(&pool, &buyer_id, "purchase_buyer").await;
            insert_tool_listing(&pool, &listing_id, &seller_id, 10_000, "active").await;

            let tool = PurchaseItemIntentTool {
                ctx: tool_context(pool.clone(), Some(buyer_id.clone())),
            };

            let result = tool
                .call(PurchaseItemIntentArgs {
                    listing_id: listing_id.clone(),
                    offered_price: 10_000,
                })
                .await
                .expect("purchase listing");

            assert!(result.contains("Deal intent sent!"));
            assert!(result.contains("Record ID:"));

            let order = sqlx::query(
                "SELECT listing_id, buyer_id, seller_id, final_price, status FROM orders WHERE listing_id = $1",
            )
            .bind(&listing_id)
            .fetch_one(&pool)
            .await
            .expect("select created order");

            assert_eq!(order.get::<String, _>("listing_id"), listing_id);
            assert_eq!(order.get::<String, _>("buyer_id"), buyer_id);
            assert_eq!(order.get::<String, _>("seller_id"), seller_id);
            assert_eq!(order.get::<i64, _>("final_price"), 10_000);
            assert_eq!(order.get::<String, _>("status"), "intent_pending");

            let listing_status: String =
                sqlx::query_scalar("SELECT status FROM inventory WHERE id = $1")
                    .bind(&listing_id)
                    .fetch_one(&pool)
                    .await
                    .expect("select listing status");
            assert_eq!(listing_status, "active");
        })
        .await;
    }

    #[tokio::test]
    async fn purchase_item_tool_reports_sold_listing_without_second_order() {
        with_test_pool(|pool| async move {
            let seller_id = Uuid::new_v4().to_string();
            let buyer_id = Uuid::new_v4().to_string();
            let listing_id = Uuid::new_v4().to_string();

            insert_tool_user(&pool, &seller_id, "sold_seller").await;
            insert_tool_user(&pool, &buyer_id, "sold_buyer").await;
            insert_tool_listing(&pool, &listing_id, &seller_id, 10_000, "sold").await;

            let tool = PurchaseItemIntentTool {
                ctx: tool_context(pool.clone(), Some(buyer_id)),
            };

            let result = tool
                .call(PurchaseItemIntentArgs {
                    listing_id: listing_id.clone(),
                    offered_price: 10_000,
                })
                .await
                .expect("sold listing produces user-facing response");

            assert!(result.contains("no longer available"));

            let order_count: i64 =
                sqlx::query_scalar("SELECT COUNT(*) FROM orders WHERE listing_id = $1")
                    .bind(&listing_id)
                    .fetch_one(&pool)
                    .await
                    .expect("count orders");
            assert_eq!(order_count, 0);
        })
        .await;
    }

    #[test]
    fn test_get_my_listings_args_empty() {
        let json = r#"{}"#;
        let args: GetMyListingsArgs = serde_json::from_str(json).unwrap();
        // Empty struct deserializes successfully
        let _ = args;
    }

    #[test]
    fn test_tool_context_clone() {
        // ToolContext is Clone, verify it compiles
        fn assert_clone<T: Clone>() {}
        assert_clone::<ToolContext>();
    }

    #[test]
    fn test_create_listing_tool_clone() {
        // CreateListingTool is Clone, verify it compiles
        fn assert_clone<T: Clone>() {}
        assert_clone::<CreateListingTool>();
    }

    #[test]
    fn test_search_inventory_tool_clone() {
        // SearchInventoryTool is Clone, verify it compiles
        fn assert_clone<T: Clone>() {}
        assert_clone::<SearchInventoryTool>();
    }

    #[tokio::test]
    async fn create_listing_tool_dual_writes_shadow_uuid_columns() {
        with_test_pool(|pool| async move {
            let owner_id = Uuid::new_v4().to_string();

            sqlx::query(
                "INSERT INTO users (id, username, password_hash, role) VALUES ($1, $2, 'hash', 'user')",
            )
            .bind(&owner_id)
            .bind("tool_listing_owner")
            .execute(&pool)
            .await
            .expect("insert owner");

            let tool = CreateListingTool {
                ctx: ToolContext {
                    db_pool: pool.clone(),
                    embed_updater: Arc::new(NoopEmbedUpdater),
                    current_user_id: Some(owner_id.clone()),
                    notification: crate::services::notification::NotificationService::new(
                        pool.clone(),
                    ),
                },
            };

            let result = tool
                .call(CreateListingArgs {
                    title: "Shadow Tool Listing".to_string(),
                    category: "electronics".to_string(),
                    brand: "Acme".to_string(),
                    condition_score: 8,
                    suggested_price_cny: 12_345,
                    defects: vec!["scuff".to_string()],
                    original_description: "Tool-created listing".to_string(),
                })
                .await
                .expect("create listing");
            assert!(result.contains("Shadow Tool Listing"));

            let row = sqlx::query(
                "SELECT id, new_id, owner_id, new_owner_id, suggested_price_cny FROM inventory WHERE title = $1",
            )
            .bind("Shadow Tool Listing")
            .fetch_one(&pool)
            .await
            .expect("select listing");
            let owner_uuid: Uuid = sqlx::query_scalar("SELECT new_id FROM users WHERE id = $1")
                .bind(&owner_id)
                .fetch_one(&pool)
                .await
                .expect("select owner uuid");

            let listing_id: String = row.get("id");
            assert_eq!(row.get::<Uuid, _>("new_id"), Uuid::parse_str(&listing_id).unwrap());
            assert_eq!(row.get::<String, _>("owner_id"), owner_id);
            assert_eq!(row.get::<Uuid, _>("new_owner_id"), owner_uuid);
            assert_eq!(row.get::<i64, _>("suggested_price_cny"), 12_345);
        })
        .await;
    }
}
