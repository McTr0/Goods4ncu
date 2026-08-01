use crate::repositories::{
    CreateListingInput, ListingRepository, PostgresListingRepository, UpdateListingInput,
};
use crate::services::campus::CampusService;
use crate::services::order::{OrderError, OrderService};
use crate::utils::cents_to_yuan;
use rig::completion::ToolDefinition;
use rig::tool::Tool;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sqlx::PgPool;

// ---------------------------------------------------------------------------
// Shared context for all tools
// ---------------------------------------------------------------------------

/// Shared dependencies injected into every marketplace tool.
#[derive(Clone)]
pub struct ToolContext {
    /// PostgreSQL pool — serves both relational data and vector data (pgvector).
    pub db_pool: PgPool,
    pub current_user_id: Option<String>,
    pub current_campus_id: Option<uuid::Uuid>,
    /// Notification service for sending in-app alerts (e.g., negotiation requests).
    pub notification: crate::services::notification::NotificationService,
}

/// Unified error type for all marketplace tools.
#[derive(Debug, thiserror::Error)]
#[error("Tool error: {0}")]
pub struct ToolError(pub String);

async fn require_verified_campus(
    ctx: &ToolContext,
    user_id: &str,
) -> Result<uuid::Uuid, ToolError> {
    CampusService::new(ctx.db_pool.clone())
        .require_tenant_context_for_session(user_id, ctx.current_campus_id)
        .await
        .map(|tenant| tenant.campus_id)
        .map_err(|_| ToolError("请先完成校园身份验证后再进行此操作".to_string()))
}

/// Create a pending [`agent_action_plans`] row instead of executing a write.
///
/// This is the ActionPlan boundary: the model can *propose* L2/L3 actions but
/// never perform them. Execution happens only after the user confirms through
/// the authenticated plans API, which re-runs full validation. The text
/// returned to the model deliberately excludes the confirmation token — a
/// prompt-injected model must not be able to confirm its own plan.
async fn propose_action_plan<A: serde::Serialize>(
    ctx: &ToolContext,
    action: &str,
    risk_level: &str,
    args: &A,
    summary: String,
) -> Result<String, ToolError> {
    let user_id = ctx
        .current_user_id
        .clone()
        .ok_or_else(|| ToolError("请先登录再进行操作".to_string()))?;
    // Fail fast so unverified users get immediate feedback instead of a plan
    // that can never execute.
    let campus_id = require_verified_campus(ctx, &user_id).await?;
    let args_json =
        serde_json::to_value(args).map_err(|e| ToolError(format!("序列化参数失败: {}", e)))?;

    let plan = crate::services::agent_plan::AgentPlanService::new(ctx.db_pool.clone())
        .create_plan(
            campus_id, &user_id, action, risk_level, &args_json, &summary,
        )
        .await
        .map_err(|e| ToolError(format!("创建待确认操作失败: {}", e)))?;

    Ok(format!(
        "已创建待确认操作：{}。该操作需要你在应用中确认后才会执行（10 分钟内有效，计划编号 {}）。请在“待确认操作”里查看并确认或取消。",
        summary, plan
    ))
}

/// Money on the model-facing boundary, in yuan.
///
/// Internally every price is an integer count of cents, which is the only sane
/// representation for money and matches what the database stores. The tool
/// schema, though, has to speak the units a person speaks — a user says "30
/// 块" and the model passes 30. Naming a field `suggested_price_cny` and then
/// meaning cents produced listings priced at exactly one hundredth of what was
/// asked, every single time, and no amount of "in cents" in a description
/// reliably stops a model doing the natural thing.
///
/// So the unit lives in the field *name* the model sees (`..._yuan`) and the
/// conversion happens here, at the edge.
///
/// Both directions are implemented deliberately. L3 arguments are serialised
/// into `agent_action_plans` and read back at confirmation time; a
/// deserialize-only conversion would multiply by a hundred on every round
/// trip, reintroducing the same bug one step further along.
mod yuan {
    use crate::utils::{cents_to_yuan, yuan_to_cents};
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(cents: &i64, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_f64(cents_to_yuan(*cents))
    }

    /// `yuan_to_cents` rounds to the nearest cent, which matters: a model may
    /// well emit 19.99, or arithmetic that lands on 0.30000000000000004.
    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<i64, D::Error> {
        Ok(yuan_to_cents(f64::deserialize(deserializer)?))
    }

    pub mod option {
        use crate::utils::{cents_to_yuan, yuan_to_cents};
        use serde::{Deserialize, Deserializer, Serializer};

        pub fn serialize<S: Serializer>(
            cents: &Option<i64>,
            serializer: S,
        ) -> Result<S::Ok, S::Error> {
            match cents {
                Some(cents) => serializer.serialize_f64(cents_to_yuan(*cents)),
                None => serializer.serialize_none(),
            }
        }

        pub fn deserialize<'de, D: Deserializer<'de>>(
            deserializer: D,
        ) -> Result<Option<i64>, D::Error> {
            Ok(Option::<f64>::deserialize(deserializer)?.map(yuan_to_cents))
        }
    }
}

async fn resolve_read_campus(ctx: &ToolContext) -> Result<uuid::Uuid, ToolError> {
    let service = CampusService::new(ctx.db_pool.clone());
    match ctx.current_user_id.as_deref() {
        Some(user_id) => {
            service
                .resolve_session_campus(user_id, ctx.current_campus_id)
                .await
        }
        None => service.default_public_campus_id().await,
    }
    .map_err(|_| ToolError("暂时无法确定当前校园".to_string()))
}

// ---------------------------------------------------------------------------
// 1. CreateListingTool
// ---------------------------------------------------------------------------

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
        execute_l2_create_listing(&self.ctx, args, summary).await
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
    {
        let owner = ctx
            .current_user_id
            .clone()
            .ok_or_else(|| ToolError("请先登录再进行操作".to_string()))?;
        let campus_id = require_verified_campus(ctx, &owner).await?;

        // Model-supplied arguments are untrusted input. Mirror the HTTP
        // handler's validation so a polluted tool call cannot slip records
        // past the API-level rules (parameter-pollution defense).
        let title = args.title.trim();
        if title.is_empty() || title.len() > 200 {
            return Err(ToolError("商品标题不能为空且不超过 200 字符".to_string()));
        }
        if args.brand.trim().len() > 100 {
            return Err(ToolError("品牌不能超过 100 字符".to_string()));
        }
        if args.condition_score < 1 || args.condition_score > 10 {
            return Err(ToolError("成色必须在 1 到 10 之间".to_string()));
        }
        if args.suggested_price_cny <= 0 || args.suggested_price_cny > 1_000_000_000 {
            return Err(ToolError("价格必须为正且在合理范围内".to_string()));
        }

        let listing_repo = PostgresListingRepository::new(ctx.db_pool.clone());
        let input = CreateListingInput {
            campus_id,
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

        let listing_id = listing_repo
            .create(input)
            .await
            .map_err(|e| ToolError(format!("DB insert error: {}", e)))?;

        Ok(CreatedListing {
            message: format!(
                "Successfully created listing '{}' (ID: {}, Price: {} CNY, Owner: {})",
                args.title,
                listing_id,
                cents_to_yuan(args.suggested_price_cny),
                owner
            ),
            listing_id,
            campus_id,
        })
    }
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
            return Ok("No fields to update were provided.".to_string());
        }
        let summary = format!("修改商品 {} 的信息", args.listing_id);
        propose_action_plan(&self.ctx, Self::NAME, "L2", &args, summary).await
    }
}

/// Validated execution body for `update_listing`; plan-confirmed only.
pub async fn execute_update_listing(
    ctx: &ToolContext,
    args: UpdateListingArgs,
) -> Result<String, ToolError> {
    {
        let owner_id = ctx
            .current_user_id
            .clone()
            .ok_or_else(|| ToolError("请先登录再进行操作".to_string()))?;
        let campus_id = require_verified_campus(ctx, &owner_id).await?;

        if args.new_price.is_none() && args.new_title.is_none() && args.new_description.is_none() {
            return Ok("No fields to update were provided.".to_string());
        }

        let listing_repo = PostgresListingRepository::new(ctx.db_pool.clone());
        let result = listing_repo
            .update_owned_active(
                &args.listing_id,
                &owner_id,
                campus_id,
                &UpdateListingInput {
                    title: args.new_title,
                    category: None,
                    brand: None,
                    condition_score: None,
                    suggested_price_cny: args.new_price.map(|v| v as f64 / 100.0),
                    defects: None,
                    description: args.new_description,
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
        let summary = format!("下架商品 {}", args.listing_id);
        propose_action_plan(&self.ctx, Self::NAME, "L2", &args, summary).await
    }
}

/// Validated execution body for `delete_listing`; plan-confirmed only.
pub async fn execute_delete_listing(
    ctx: &ToolContext,
    args: DeleteListingArgs,
) -> Result<String, ToolError> {
    {
        let owner_id = ctx
            .current_user_id
            .clone()
            .ok_or_else(|| ToolError("请先登录再进行操作".to_string()))?;
        let campus_id = require_verified_campus(ctx, &owner_id).await?;
        let listing_repo = PostgresListingRepository::new(ctx.db_pool.clone());
        let mut tx = ctx
            .db_pool
            .begin()
            .await
            .map_err(|e| ToolError(format!("Transaction error: {}", e)))?;

        let deleted = listing_repo
            .soft_delete_active_owned_in_tx(&mut tx, &args.listing_id, &owner_id, campus_id)
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
        propose_action_plan(&self.ctx, Self::NAME, "L3", &args, summary).await
    }
}

/// Validated execution body for `purchase_item`; plan-confirmed only.
pub async fn execute_purchase_item(
    ctx: &ToolContext,
    args: PurchaseItemIntentArgs,
) -> Result<String, ToolError> {
    {
        let buyer_id = ctx
            .current_user_id
            .clone()
            .ok_or_else(|| ToolError("请先登录再进行操作".to_string()))?;
        let campus_id = require_verified_campus(ctx, &buyer_id).await?;

        // The service creates only an intent; seller confirmation performs any
        // optional delisting later.
        let listing = sqlx::query_as::<_, ListingCheckRow>(
            "SELECT id, campus_id, owner_id, suggested_price_cny, status
             FROM inventory WHERE id = $1
               AND NOT listing_has_active_restriction(id)",
        )
        .bind(&args.listing_id)
        .fetch_optional(&ctx.db_pool)
        .await
        .map_err(|e| ToolError(format!("Query error: {}", e)))?;

        let listing = match listing {
            Some(l) => l,
            None => return Ok(format!("No listing found with ID: {}", args.listing_id)),
        };

        if listing.campus_id != campus_id {
            return Err(ToolError("只能对当前校园的商品发起成交意向".to_string()));
        }
        CampusService::new(ctx.db_pool.clone())
            .require_verified_in_campus(&listing.owner_id, campus_id)
            .await
            .map_err(|_| ToolError("只能与当前校园的已认证用户成交".to_string()))?;

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

        let order_id = OrderService::new(ctx.db_pool.clone())
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
    type Output = String;

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
        propose_action_plan(&self.ctx, Self::NAME, "L3", &args, summary).await
    }
}

/// Validated execution body for `negotiate_item`; plan-confirmed only.
pub async fn execute_negotiate_item(
    ctx: &ToolContext,
    args: NegotiateItemArgs,
) -> Result<String, ToolError> {
    {
        let buyer_id = ctx
            .current_user_id
            .clone()
            .ok_or_else(|| ToolError("请先登录再进行操作".to_string()))?;
        let campus_id = require_verified_campus(ctx, &buyer_id).await?;

        let mut tx = ctx
            .db_pool
            .begin()
            .await
            .map_err(|e| ToolError(format!("Transaction error: {}", e)))?;

        // Inventory is the first lock. This serializes eligibility, duplicate
        // detection and HITL insertion against takedown and concurrent retries.
        let listing_row = sqlx::query_as::<_, ListingCheckRow>(
            "SELECT id, campus_id, owner_id, suggested_price_cny, status
             FROM inventory WHERE id = $1 AND campus_id = $2 FOR UPDATE",
        )
        .bind(&args.listing_id)
        .bind(campus_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|e| ToolError(format!("DB error: {}", e)))?;

        let listing = match listing_row {
            Some(l) => l,
            None => return Err(ToolError("当前校园未找到可议价的商品".to_string())),
        };

        if buyer_id == listing.owner_id {
            return Err(ToolError("不能对自己的商品发起还价".to_string()));
        }

        CampusService::new(ctx.db_pool.clone())
            .require_verified_in_campus(&listing.owner_id, campus_id)
            .await
            .map_err(|_| ToolError("只能与当前校园的已认证用户议价".to_string()))?;

        let restricted: bool = sqlx::query_scalar("SELECT listing_has_active_restriction($1)")
            .bind(&args.listing_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(|e| ToolError(format!("DB error: {}", e)))?;
        if restricted {
            return Err(ToolError("该商品受平台限制，无法发起还价".to_string()));
        }
        if listing.status != "active" {
            return Ok(format!("商品 {} 已下架或售出，无法还价", args.listing_id));
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
        .fetch_optional(&mut *tx)
        .await
        .map_err(|e| ToolError(format!("DB error: {}", e)))?;
        if existing.is_some() {
            return Ok("你已对该商品发起过还价，请等待卖家响应后再发起新还价".to_string());
        }

        // Create the HITL request in the database
        let hitl_id = uuid::Uuid::new_v4().to_string();
        sqlx::query(
            r#"INSERT INTO hitl_requests
               (id, campus_id, listing_id, buyer_id, seller_id, proposed_price, reason, status, expires_at)
               VALUES ($1, $2, $3, $4, $5, $6, $7, 'pending', CURRENT_TIMESTAMP + INTERVAL '48 hours')"#,
        )
        .bind(&hitl_id)
        .bind(campus_id)
        .bind(&args.listing_id)
        .bind(&buyer_id)
        .bind(&listing.owner_id)
        .bind(args.offered_price)
        .bind(&args.reason)
        .execute(&mut *tx)
        .await
        .map_err(|e| ToolError(format!("DB error: {}", e)))?;

        tx.commit()
            .await
            .map_err(|e| ToolError(format!("Commit error: {}", e)))?;

        // Notify the seller immediately
        let _ = ctx
            .notification
            .create(crate::services::notification::NewNotification {
                campus_id,
                user_id: &listing.owner_id,
                event_type: "negotiation_request",
                title: "有新的还价请求",
                body: &format!(
                    "买家出价 ¥{:.2}，理由：{}",
                    cents_to_yuan(args.offered_price),
                    args.reason
                ),
                related_order_id: Some(&hitl_id),
                related_listing_id: Some(&args.listing_id),
                related_conversation_id: None,
                related_space_id: None,
            })
            .await;

        Ok(format!(
            "你的还价 ¥{:.2} 已发送给卖家，等待确认中。\
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
    campus_id: uuid::Uuid,
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

    fn tool_context(pool: sqlx::PgPool, current_user_id: Option<String>) -> ToolContext {
        ToolContext {
            db_pool: pool.clone(),
            current_user_id,
            current_campus_id: None,
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
        sqlx::query(
            "INSERT INTO campus_memberships (
                campus_id, user_id, status, verification_method, verified_at
             )
             SELECT id, $1, 'verified', 'test_fixture', NOW()
             FROM campuses WHERE slug = 'ncu'",
        )
        .bind(id)
        .execute(pool)
        .await
        .expect("insert campus membership");
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
            "price_yuan": 5000,
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
            "price_yuan": 50,
            "defects": [],
            "original_description": "Like new"
        }"#;
        let args: CreateListingArgs = serde_json::from_str(json).unwrap();
        assert!(args.defects.is_empty());
    }

    // -----------------------------------------------------------------------
    // Money units on the model-facing boundary
    //
    // The tool schema used to name a field `suggested_price_cny`, describe it
    // as "Price in CNY", and then treat the number as cents. A user asking for
    // 30 元 got a listing priced at ¥0.30 — every time, silently, because the
    // model did the natural thing. These pin both halves of the fix: the model
    // speaks yuan, and the value survives a round trip through storage.
    // -----------------------------------------------------------------------

    #[test]
    fn model_supplied_yuan_becomes_cents() {
        let json = r#"{
            "title": "宿舍小台灯",
            "category": "home",
            "brand": "无",
            "condition_score": 9,
            "price_yuan": 30,
            "defects": [],
            "original_description": "九成新"
        }"#;
        let args: CreateListingArgs = serde_json::from_str(json).unwrap();
        assert_eq!(
            args.suggested_price_cny, 3000,
            "30 元 must be 3000 cents, not 30",
        );
    }

    #[test]
    fn fractional_yuan_rounds_to_the_nearest_cent() {
        for (yuan, cents) in [(19.99, 1999_i64), (0.1, 10), (12.345, 1235), (0.005, 1)] {
            let json = format!(
                r#"{{"title":"t","category":"c","brand":"b","condition_score":9,
                     "price_yuan":{yuan},"defects":[],"original_description":"d"}}"#
            );
            let args: CreateListingArgs = serde_json::from_str(&json).unwrap();
            assert_eq!(args.suggested_price_cny, cents, "{yuan} 元");
        }
    }

    #[test]
    fn price_survives_the_action_plan_round_trip() {
        // L3 arguments are serialised into agent_action_plans and read back at
        // confirmation. A deserialize-only conversion would multiply by a
        // hundred on the way back, moving the bug rather than fixing it.
        let original = PurchaseItemIntentArgs {
            listing_id: "listing-1".to_string(),
            offered_price: 28_050, // ¥280.50
        };
        let stored = serde_json::to_value(&original).unwrap();
        assert_eq!(
            stored["offered_price_yuan"], 280.5,
            "stored form must be yuan, matching what the model sent",
        );

        let restored: PurchaseItemIntentArgs = serde_json::from_value(stored).unwrap();
        assert_eq!(restored.offered_price, original.offered_price);
    }

    #[test]
    fn optional_prices_round_trip_and_stay_absent_when_unset() {
        let json = r#"{"listing_id":"l1","new_price_yuan":45.5}"#;
        let args: UpdateListingArgs = serde_json::from_str(json).unwrap();
        assert_eq!(args.new_price, Some(4550));

        let restored: UpdateListingArgs =
            serde_json::from_value(serde_json::to_value(&args).unwrap()).unwrap();
        assert_eq!(restored.new_price, Some(4550));

        let absent: SearchInventoryArgs = serde_json::from_str(r#"{"keyword":"x"}"#).unwrap();
        assert_eq!(absent.max_price, None);
    }

    /// Every tool's live parameter schema, paired with its name.
    ///
    /// Built from the real `Tool::definition` outputs so the assertions below
    /// cannot drift from what is actually sent to the provider.
    async fn all_tool_schemas(ctx: &ToolContext) -> Vec<(String, serde_json::Value)> {
        macro_rules! defs {
            ($($tool:ident),+ $(,)?) => {
                vec![$({
                    let d = $tool { ctx: ctx.clone() }.definition(String::new()).await;
                    (d.name, d.parameters)
                }),+]
            };
        }
        defs!(
            CreateListingTool,
            SearchInventoryTool,
            GetListingDetailsTool,
            UpdateListingTool,
            DeleteListingTool,
            PurchaseItemIntentTool,
            NegotiateItemTool,
            GetMyListingsTool,
        )
    }

    fn stub_ctx() -> ToolContext {
        // Definitions are pure — they never touch the pool — so a lazily
        // connected pool is enough and keeps this a unit test.
        let pool = PgPool::connect_lazy("postgres://unused/unused").expect("lazy pool");
        ToolContext {
            db_pool: pool.clone(),
            current_user_id: None,
            current_campus_id: None,
            notification: crate::services::notification::NotificationService::new(pool),
        }
    }

    #[tokio::test]
    async fn every_required_parameter_is_declared_in_properties() {
        // Gemini rejects the whole tool list with a 400 when `required` names a
        // property that does not exist, so one stale entry disables the
        // assistant entirely. Renaming a parameter and missing one `required`
        // list did exactly that, and nothing caught it until a live request.
        let ctx = stub_ctx();
        for (name, schema) in all_tool_schemas(&ctx).await {
            let properties = schema["properties"]
                .as_object()
                .unwrap_or_else(|| panic!("{name}: parameters must have properties"));
            let required = schema["required"].as_array().unwrap_or_else(|| {
                panic!("{name}: parameters must declare a required list, even if empty")
            });
            for entry in required {
                let field = entry.as_str().expect("required entries are strings");
                assert!(
                    properties.contains_key(field),
                    "{name}: required parameter '{field}' is not in properties",
                );
            }
        }
    }

    #[tokio::test]
    async fn every_money_parameter_names_its_unit() {
        // The original defect was a name that did not say what it meant:
        // `suggested_price_cny` described as "Price in CNY" but read as cents.
        // Any parameter that looks like money must carry its unit in the name
        // the model sees.
        let ctx = stub_ctx();
        for (name, schema) in all_tool_schemas(&ctx).await {
            for field in schema["properties"].as_object().unwrap().keys() {
                if field.contains("price") {
                    assert!(
                        field.ends_with("_yuan"),
                        "{name}: money parameter '{field}' must name its unit \
                         (e.g. '{field}_yuan'), or a model will guess wrong",
                    );
                }
            }
        }
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
            "max_price_yuan": 5000,
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
        let json = r#"{"listing_id": "listing-456", "new_price_yuan": 4500}"#;
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
            "new_price_yuan": 4000,
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
        let json = r#"{"listing_id": "listing-buy-1", "offered_price_yuan": 4500}"#;
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

            let ctx = tool_context(pool.clone(), Some(buyer_id.clone()));
            let result = execute_purchase_item(
                &ctx,
                PurchaseItemIntentArgs {
                    listing_id: listing_id.clone(),
                    offered_price: 10_000,
                },
            )
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

            let ctx = tool_context(pool.clone(), Some(buyer_id));
            let result = execute_purchase_item(
                &ctx,
                PurchaseItemIntentArgs {
                    listing_id: listing_id.clone(),
                    offered_price: 10_000,
                },
            )
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

            insert_tool_user(&pool, &owner_id, "tool_listing_owner").await;

            let ctx = ToolContext {
                db_pool: pool.clone(),
                current_user_id: Some(owner_id.clone()),
                current_campus_id: None,
                notification: crate::services::notification::NotificationService::new(
                    pool.clone(),
                ),
            };

            let result = execute_create_listing(
                &ctx,
                CreateListingArgs {
                    title: "Shadow Tool Listing".to_string(),
                    category: "electronics".to_string(),
                    brand: "Acme".to_string(),
                    condition_score: 8,
                    suggested_price_cny: 12_345,
                    defects: vec!["scuff".to_string()],
                    original_description: "Tool-created listing".to_string(),
                },
            )
            .await
            .expect("create listing");
            assert!(result.message.contains("Shadow Tool Listing"));
            assert!(!result.listing_id.is_empty());

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
