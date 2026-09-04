use super::common::yuan;
use super::common::*;
use crate::agents::runtime::envelope::ToolResultEnvelope;
use crate::api::error::ApiError;
use crate::llm::UiAction;
use crate::services::listing_command::{ListingCommandService, UpdateListingDraft};
use crate::utils::cents_to_yuan;
use rig::completion::ToolDefinition;
use rig::tool::Tool;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sqlx::{Postgres, Transaction};
#[derive(Serialize, Deserialize)]
pub struct CreateListingArgs {
    pub title: String,
    pub category: String,
    pub brand: String,
    pub condition_score: u8,
    /// Cents internally; the model sends `price_yuan`.
    #[serde(rename = "price_yuan", with = "yuan")]
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
    type Output = ToolResultEnvelope;

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
                    "price_yuan": { "type": "number", "description": "价格，单位：元（例如 30 表示 30 元，可带小数）" },
                    "defects": { "type": "array", "items": { "type": "string" }, "description": "Any defects" },
                    "original_description": { "type": "string", "description": "User's original description" }
                },
                "required": ["title", "category", "brand", "condition_score", "price_yuan", "defects", "original_description"]
            }),
        }
    }

    async fn call(&self, args: Self::Args) -> Result<Self::Output, Self::Error> {
        let summary = format!(
            "发布商品《{}》，价格 ¥{:.2}",
            args.title,
            cents_to_yuan(args.suggested_price_cny)
        );
        // L2: execute now, stay undoable. Publishing is recoverable — the
        // listing can be retracted while nobody has acted on it — so charging
        // a confirmation dialog for every publish costs more than it saves.
        // L3 (money, identity) still confirms up front in `propose_action_plan`.
        let res = execute_l2_create_listing(&self.ctx, args, summary).await?;
        Ok(ToolResultEnvelope::success(res))
    }
}

/// Publish immediately and register the result as undoable.
///
/// A failure to register the undo affordance does not fail the publish: the
/// listing is live and the user was told so. Losing the undo button is a
/// degraded experience; rolling back a successful publish because bookkeeping
/// failed would be a worse surprise.
async fn execute_l2_create_listing(
    ctx: &ToolContext,
    args: CreateListingArgs,
    summary: String,
) -> Result<String, ToolError> {
    let user_id = ctx
        .current_user_id
        .clone()
        .ok_or_else(|| ToolError("请先登录再进行操作".to_string()))?;

    let created = execute_create_listing(ctx, args).await?;

    let registration = crate::services::undo::UndoService::new(ctx.db_pool.clone())
        .register(
            created.campus_id,
            &user_id,
            crate::services::undo::kinds::LISTING_CREATE,
            "inventory",
            &created.listing_id,
            &summary,
            // Guard: retract only while the listing still sits exactly where
            // publishing left it.
            serde_json::json!({ "status": "active" }),
            serde_json::json!({ "existed": false }),
        )
        .await;

    match registration {
        Ok(_) => Ok(format!(
            "{}。如果不是你想要的，{} 分钟内可以撤销。",
            created.message,
            crate::services::undo::UNDO_WINDOW_MINUTES
        )),
        Err(error) => {
            tracing::warn!(
                listing_id = %created.listing_id,
                error = %error,
                "listing published but undo registration failed",
            );
            Ok(created.message)
        }
    }
}

/// A published listing, with the identifiers the caller needs to make the
/// action undoable.
#[derive(Debug)]
pub struct CreatedListing {
    pub listing_id: String,
    pub campus_id: uuid::Uuid,
    pub message: String,
}

/// Validated execution body for `create_listing`.
///
/// Reached both from the L2 immediate path above and from a previously
/// confirmed [`AgentActionPlan`](crate::services::agent_plan), so plans
/// created before the L2 switch still execute correctly.
pub async fn execute_create_listing(
    ctx: &ToolContext,
    args: CreateListingArgs,
) -> Result<CreatedListing, ToolError> {
    let owner = ctx
        .current_user_id
        .clone()
        .ok_or_else(|| ToolError("请先登录再进行操作".to_string()))?;
    let campus_id = require_verified_campus(ctx, &owner).await?;
    let mut tx = ctx
        .db_pool
        .begin()
        .await
        .map_err(|error| ToolError(format!("Transaction error: {}", error)))?;
    if !lock_verified_membership_in_tx(&mut tx, &owner, campus_id).await? {
        return Err(ToolError("请先完成校园身份验证后再进行此操作".to_string()));
    }
    let created = execute_create_listing_in_tx(ctx, &mut tx, &owner, campus_id, args).await?;
    tx.commit()
        .await
        .map_err(|error| ToolError(format!("Commit error: {}", error)))?;
    Ok(created)
}

pub(crate) async fn execute_create_listing_in_tx(
    ctx: &ToolContext,
    tx: &mut Transaction<'_, Postgres>,
    owner: &str,
    campus_id: uuid::Uuid,
    args: CreateListingArgs,
) -> Result<CreatedListing, ToolError> {
    let title = args.title.clone();
    let price_cents = args.suggested_price_cny;

    let post_service =
        crate::services::post::PostService::new(ctx.db_pool.clone(), ctx.moderation.clone());

    let cmd = crate::services::post::PublishPostCommand {
        campus_id,
        author_id: owner.to_string(),
        title: title.clone(),
        body: if args.original_description.trim().is_empty() {
            title.clone()
        } else {
            args.original_description.clone()
        },
        kind: crate::services::post::PostKind::Offer(
            crate::services::post::CreatePostMarketplaceInput {
                category: args.category,
                brand: args.brand,
                condition_score: args.condition_score as i32,
                suggested_price_cny: price_cents as f64 / 100.0,
                defects: args.defects,
                description: Some(args.original_description),
            },
        ),
        tags: vec![],
        cover_image_url: None,
        space_id: None,
        idempotency_key: None,
    };

    let post = post_service
        .publish_in_tx(tx, cmd)
        .await
        .map_err(|error| ToolError(format!("发布帖子失败: {:?}", error)))?;

    let listing_id = post.listing_id.unwrap_or_default();

    Ok(CreatedListing {
        message: format!(
            "Successfully created listing '{}' (ID: {}, Price: {} CNY, Owner: {})",
            title,
            listing_id,
            cents_to_yuan(price_cents),
            owner
        ),
        listing_id,
        campus_id,
    })
}

// ---------------------------------------------------------------------------
// 2. SearchInventoryTool
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct SearchInventoryArgs {
    pub keyword: Option<String>,
    pub category: Option<String>,
    /// Cents internally; the model sends `max_price_yuan`.
    #[serde(rename = "max_price_yuan", with = "yuan::option", default)]
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
    type Output = ToolResultEnvelope;

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
                    "max_price_yuan": { "type": "number", "description": "价格上限，单位：元" },
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

        let campus_id = resolve_read_campus(&self.ctx).await?;
        let mut sql = String::from("SELECT id, title, brand, category, condition_score, suggested_price_cny FROM inventory WHERE status = 'active' AND campus_id = $1 AND NOT listing_has_active_restriction(id)");
        let mut param_idx: usize = 2;

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

        let mut query = sqlx::query_as::<_, InventoryRow>(&sql).bind(campus_id);

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

        // Search telemetry is an aggregate-only AgentRun event.  It is
        // best-effort so a rollout/migration issue never turns a safe read
        // tool into a user-visible failure; no keyword or title is persisted.
        if let (Some(user_id), Some(trace_id)) = (
            self.ctx.current_user_id.as_deref(),
            crate::api::request_context::current_request_id(),
        ) {
            let resource_ids = rows.iter().map(|row| row.id.clone()).collect();
            if let Err(error) =
                crate::services::agent_run::AgentRunService::new(self.ctx.db_pool.clone())
                    .record_retrieval(
                        &trace_id,
                        campus_id,
                        user_id,
                        Self::NAME,
                        rows.len() as i32,
                        None,
                        resource_ids,
                    )
                    .await
            {
                tracing::warn!(%error, "failed to record AgentRun retrieval event");
            }
        }

        // Session memory (goal §36): remember the current topic and result
        // ids so follow-up turns resolve without restating the query.
        if let Some(user_id) = self.ctx.current_user_id.as_deref() {
            let ids: Vec<String> = rows.iter().map(|row| row.id.clone()).collect();
            if let Err(error) =
                crate::services::agent_memory::AgentMemoryService::new(self.ctx.db_pool.clone())
                    .record_session_search(user_id, args.keyword.as_deref(), &ids)
                    .await
            {
                tracing::warn!(%error, "failed to record agent session search");
            }
        }

        if rows.is_empty() {
            return Ok(ToolResultEnvelope::success(
                "No items found matching your criteria.",
            ));
        }

        let ids: Vec<String> = rows.iter().map(|r| r.id.clone()).collect();
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
        Ok(ToolResultEnvelope::success(result)
            .with_action(UiAction::show_posts(ids.clone()))
            .with_resources(ids))
    }
}

#[derive(sqlx::FromRow)]
struct InventoryRow {
    id: String,
    title: String,
    brand: String,
    category: String,
    condition_score: i32,
    suggested_price_cny: i64,
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
    type Output = ToolResultEnvelope;

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
        let campus_id = resolve_read_campus(&self.ctx).await?;
        let row = sqlx::query_as::<_, FullListingRow>(
            "SELECT id, title, category, brand, condition_score, suggested_price_cny,
                    defects, description, owner_id, status
             FROM inventory WHERE id = $1 AND campus_id = $2
               AND NOT listing_has_active_restriction(id)",
        )
        .bind(&args.listing_id)
        .bind(campus_id)
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

                // Session memory (goal §36): the post the user is inspecting.
                if let Some(user_id) = self.ctx.current_user_id.as_deref() {
                    if let Err(error) = crate::services::agent_memory::AgentMemoryService::new(
                        self.ctx.db_pool.clone(),
                    )
                    .record_session_view(user_id, &r.id)
                    .await
                    {
                        tracing::warn!(%error, "failed to record agent session view");
                    }
                }

                let text = format!(
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
                );
                Ok(ToolResultEnvelope::success(text)
                    .with_action(UiAction::scroll_to_post(&r.id))
                    .with_resource(&r.id))
            }
            None => Ok(ToolResultEnvelope::success(format!(
                "No listing found with ID: {}",
                args.listing_id
            ))),
        }
    }
}

#[derive(sqlx::FromRow)]
struct FullListingRow {
    id: String,
    title: String,
    category: String,
    brand: String,
    condition_score: i32,
    suggested_price_cny: i64,
    defects: String,
    description: Option<String>,
    owner_id: String,
    status: String,
}

// ---------------------------------------------------------------------------
// 4. UpdateListingTool
// ---------------------------------------------------------------------------

#[derive(Serialize, Deserialize)]
pub struct UpdateListingArgs {
    pub listing_id: String,
    /// Cents internally; the model sends `new_price_yuan`.
    #[serde(rename = "new_price_yuan", with = "yuan::option", default)]
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
    type Output = ToolResultEnvelope;

    async fn definition(&self, _prompt: String) -> ToolDefinition {
        ToolDefinition {
            name: "update_listing".to_string(),
            description: "修改商品的价格、标题或描述。当卖家想更新自己的商品信息时使用。"
                .to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "listing_id": { "type": "string", "description": "The listing ID to update" },
                    "new_price_yuan": { "type": "number", "description": "新价格，单位：元" },
                    "new_title": { "type": "string", "description": "New title" },
                    "new_description": { "type": "string", "description": "New description" }
                },
                "required": ["listing_id"]
            }),
        }
    }

    async fn call(&self, args: Self::Args) -> Result<Self::Output, Self::Error> {
        if args.new_price.is_none() && args.new_title.is_none() && args.new_description.is_none() {
            return Ok(ToolResultEnvelope::success(
                "No fields to update were provided.",
            ));
        }
        let summary = format!("修改商品 {} 的信息", args.listing_id);
        let res = propose_action_plan(&self.ctx, Self::NAME, "L2", &args, summary).await?;
        Ok(ToolResultEnvelope::success(res))
    }
}

/// Validated execution body for `update_listing`; plan-confirmed only.
#[allow(dead_code)] // retained as a transaction-owning wrapper for direct callers/tests
pub async fn execute_update_listing(
    ctx: &ToolContext,
    args: UpdateListingArgs,
) -> Result<String, ToolError> {
    let owner_id = ctx
        .current_user_id
        .clone()
        .ok_or_else(|| ToolError("请先登录再进行操作".to_string()))?;
    let campus_id = require_verified_campus(ctx, &owner_id).await?;
    let mut tx = ctx
        .db_pool
        .begin()
        .await
        .map_err(|error| ToolError(format!("Transaction error: {}", error)))?;
    if !lock_verified_membership_in_tx(&mut tx, &owner_id, campus_id).await? {
        return Err(ToolError("请先完成校园身份验证后再进行此操作".to_string()));
    }
    let result =
        execute_update_listing_in_tx(ctx, &mut tx, &owner_id, campus_id, args, None).await?;
    tx.commit()
        .await
        .map_err(|error| ToolError(format!("Commit error: {}", error)))?;
    Ok(result)
}

pub(crate) async fn execute_update_listing_in_tx(
    ctx: &ToolContext,
    tx: &mut Transaction<'_, Postgres>,
    owner_id: &str,
    campus_id: uuid::Uuid,
    args: UpdateListingArgs,
    expected_content_revision: Option<i64>,
) -> Result<String, ToolError> {
    if args.new_price.is_none() && args.new_title.is_none() && args.new_description.is_none() {
        return Ok("No fields to update were provided.".to_string());
    }

    let listing_id = args.listing_id.clone();
    let result = ListingCommandService::new(ctx.db_pool.clone(), ctx.moderation.clone())
        .update_with_state_and_revision_in_tx(
            tx,
            &listing_id,
            owner_id,
            campus_id,
            UpdateListingDraft {
                title: args.new_title,
                category: None,
                brand: None,
                condition_score: None,
                suggested_price_cny: args.new_price.map(|value| value as f64 / 100.0),
                defects: None,
                description: args.new_description,
            },
            expected_content_revision,
        )
        .await
        .map_err(|error| ToolError(format!("更新校验失败: {}", error)))?;

    match result {
        crate::repositories::UpdateOwnedResult::Updated => {
            Ok(format!("Successfully updated listing {}", listing_id))
        }
        crate::repositories::UpdateOwnedResult::NotFound
        | crate::repositories::UpdateOwnedResult::Inactive => Ok(format!(
            "No active listing found with ID: {} (or you don't own it)",
            listing_id
        )),
    }
}

// ---------------------------------------------------------------------------
// 5. DeleteListingTool
// ---------------------------------------------------------------------------

#[derive(Serialize, Deserialize)]
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
    type Output = ToolResultEnvelope;

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
        let summary = format!("下架商品 {}", args.listing_id);
        let res = propose_action_plan(&self.ctx, Self::NAME, "L2", &args, summary).await?;
        Ok(ToolResultEnvelope::success(res))
    }
}

/// Validated execution body for `delete_listing`; plan-confirmed only.
#[allow(dead_code)] // retained as a transaction-owning wrapper for direct callers/tests
pub async fn execute_delete_listing(
    ctx: &ToolContext,
    args: DeleteListingArgs,
) -> Result<String, ToolError> {
    let owner_id = ctx
        .current_user_id
        .clone()
        .ok_or_else(|| ToolError("请先登录再进行操作".to_string()))?;
    let campus_id = require_verified_campus(ctx, &owner_id).await?;
    let mut tx = ctx
        .db_pool
        .begin()
        .await
        .map_err(|error| ToolError(format!("Transaction error: {}", error)))?;
    if !lock_verified_membership_in_tx(&mut tx, &owner_id, campus_id).await? {
        return Err(ToolError("请先完成校园身份验证后再进行此操作".to_string()));
    }
    let result =
        execute_delete_listing_in_tx(ctx, &mut tx, &owner_id, campus_id, args, None).await?;
    tx.commit()
        .await
        .map_err(|error| ToolError(format!("Commit error: {}", error)))?;
    Ok(result)
}

pub(crate) async fn execute_delete_listing_in_tx(
    ctx: &ToolContext,
    tx: &mut Transaction<'_, Postgres>,
    owner_id: &str,
    campus_id: uuid::Uuid,
    args: DeleteListingArgs,
    expected_content_revision: Option<i64>,
) -> Result<String, ToolError> {
    // Owners may remove their own restricted content. Restriction blocks
    // editing or commerce, not the safety-improving act of taking it down.
    let deleted = match ListingCommandService::new(ctx.db_pool.clone(), ctx.moderation.clone())
        .delete_with_revision_in_tx(
            tx,
            &args.listing_id,
            owner_id,
            campus_id,
            expected_content_revision,
        )
        .await
    {
        Ok(result) => result,
        Err(ApiError::NotFound) | Err(ApiError::BadRequest(_)) => {
            return Ok(format!(
                "No active listing found with ID: {} (or you don't own it)",
                args.listing_id
            ));
        }
        Err(error) => return Err(ToolError(format!("删除校验失败: {}", error))),
    };

    // Migration 0057 enqueues a durable projection tombstone from the status
    // transition, so this path no longer performs a one-off documents delete.
    match deleted {
        crate::repositories::DeleteOwnedResult::Deleted
        | crate::repositories::DeleteOwnedResult::AlreadyDeleted => {
            Ok(format!("Successfully removed listing {}", args.listing_id))
        }
    }
}

// ---------------------------------------------------------------------------
// 6. PurchaseItemIntentTool
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct GetMyListingsArgs {}

#[derive(Clone)]
pub struct GetMyListingsTool {
    pub ctx: ToolContext,
}

// ---------------------------------------------------------------------------
// 9. GetUserPostsTool
// ---------------------------------------------------------------------------

impl Tool for GetMyListingsTool {
    const NAME: &'static str = "get_my_listings";
    type Error = ToolError;
    type Args = GetMyListingsArgs;
    type Output = ToolResultEnvelope;

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
            return Ok(ToolResultEnvelope::success(format!(
                "No listings found for user: {}",
                owner_id
            )));
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
        Ok(ToolResultEnvelope::success(result))
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
