use crate::api::error::ApiError;
use crate::services::campus::CampusService;
use crate::services::listing_command::{
    CreateListingDraft, ListingCommandService, UpdateListingDraft,
};
use crate::services::moderation::ModerationService;
use crate::services::order::{OrderError, OrderService};
use crate::utils::cents_to_yuan;
use rig::completion::ToolDefinition;
use rig::tool::Tool;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sqlx::{PgPool, Postgres, Transaction};

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
    /// Optional retry key from the authenticated chat request. It is only
    /// used to deduplicate a proposal; it never enters model-visible text.
    pub proposal_idempotency_key: Option<String>,
    /// Configured content policy shared with the HTTP listing command path.
    pub moderation: ModerationService,
    /// Notification service for sending in-app alerts (e.g., negotiation requests).
    pub notification: crate::services::notification::NotificationService,
}

/// Unified error type for all marketplace tools.
#[derive(Debug, thiserror::Error)]
#[error("Tool error: {0}")]
pub struct ToolError(pub String);

/// Lock and validate a campus membership in the caller's transaction.
///
/// A plan is bound to the campus captured when it was proposed. Re-reading the
/// membership through the pool would leave a race where it could be revoked
/// between validation and the planned write, so both the membership and campus
/// rows are share-locked until the caller commits or rolls back.
async fn lock_verified_membership_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
    campus_id: uuid::Uuid,
) -> Result<bool, ToolError> {
    let row = sqlx::query_as::<_, (String, String)>(
        "SELECT membership.status, campus.status
         FROM campus_memberships membership
         JOIN campuses campus ON campus.id = membership.campus_id
         WHERE membership.user_id = $1 AND membership.campus_id = $2
         FOR SHARE OF membership, campus",
    )
    .bind(user_id)
    .bind(campus_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(|error| ToolError(format!("校园身份校验失败: {}", error)))?;

    Ok(matches!(
        row.as_ref()
            .map(|(membership, campus)| (membership.as_str(), campus.as_str())),
        Some(("verified", "active"))
    ))
}

async fn require_planned_actor_in_tx(
    ctx: &ToolContext,
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
    campus_id: uuid::Uuid,
) -> Result<(), ToolError> {
    if ctx.current_user_id.as_deref() != Some(user_id) {
        return Err(ToolError("待确认操作与当前登录用户不匹配".to_string()));
    }
    if ctx
        .current_campus_id
        .is_some_and(|current| current != campus_id)
    {
        return Err(ToolError(
            "当前校园与原计划校园不一致，请切回原校园或重新发起操作".to_string(),
        ));
    }
    if !lock_verified_membership_in_tx(tx, user_id, campus_id).await? {
        return Err(ToolError(
            "原计划校园的身份已失效，请重新发起操作".to_string(),
        ));
    }
    Ok(())
}

/// Execute a legacy action plan wholly inside the caller's transaction.
///
/// This function never begins, commits, or rolls back a transaction. The plan
/// lifecycle row and every business side effect can therefore be committed as
/// one unit by `AgentPlanService`. All model-supplied arguments are parsed and
/// all mutable facts are re-locked and revalidated at execution time.
pub(crate) async fn execute_planned_action_in_tx(
    ctx: &ToolContext,
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    user_id: &str,
    campus_id: uuid::Uuid,
    action: &str,
    args: serde_json::Value,
) -> Result<String, ToolError> {
    fn parse<T: serde::de::DeserializeOwned>(args: serde_json::Value) -> Result<T, ToolError> {
        serde_json::from_value(args)
            .map_err(|error| ToolError(format!("计划参数已失效，无法安全执行: {}", error)))
    }

    require_planned_actor_in_tx(ctx, tx, user_id, campus_id).await?;

    match action {
        "create_listing" => execute_create_listing_in_tx(ctx, tx, user_id, campus_id, parse(args)?)
            .await
            .map(|created| created.message),
        "update_listing" => {
            let (args, expected_revision) = parse_planned_args(args)?;
            execute_update_listing_in_tx(ctx, tx, user_id, campus_id, args, expected_revision).await
        }
        "delete_listing" => {
            let (args, expected_revision) = parse_planned_args(args)?;
            execute_delete_listing_in_tx(ctx, tx, user_id, campus_id, args, expected_revision).await
        }
        "purchase_item" => {
            let (args, expected_revision) = parse_planned_args(args)?;
            execute_purchase_item_in_tx(ctx, tx, user_id, campus_id, args, expected_revision)
                .await
                .map(|(message, _)| message)
        }
        "negotiate_item" => {
            let (args, expected_revision) = parse_planned_args(args)?;
            execute_negotiate_item_in_tx(ctx, tx, user_id, campus_id, args, expected_revision).await
        }
        other => Err(ToolError(format!("未知的计划动作: {}", other))),
    }
}

/// Plan rows created before the version snapshot rollout remain executable.
/// New plans carry this internal field in their JSON args, but it is removed
/// before deserializing the model-facing tool arguments so the capability is
/// never part of the model's public schema.
fn parse_planned_args<T: serde::de::DeserializeOwned>(
    mut args: serde_json::Value,
) -> Result<(T, Option<i64>), ToolError> {
    let expected_revision = args
        .as_object_mut()
        .and_then(|object| object.remove("expected_content_revision"))
        .map(|value| {
            value
                .as_i64()
                .ok_or_else(|| ToolError("计划参数已失效，资源版本不是整数".to_string()))
        })
        .transpose()?
        .map(|revision| {
            if revision > 0 {
                Ok(revision)
            } else {
                Err(ToolError(
                    "计划参数已失效，资源版本必须为正整数".to_string(),
                ))
            }
        })
        .transpose()?;
    let parsed = serde_json::from_value(args)
        .map_err(|error| ToolError(format!("计划参数已失效，无法安全执行: {}", error)))?;
    Ok((parsed, expected_revision))
}

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
    let mut args_json =
        serde_json::to_value(args).map_err(|e| ToolError(format!("序列化参数失败: {}", e)))?;
    attach_listing_revision_snapshot(ctx, &user_id, campus_id, action, &mut args_json).await?;

    let plan = crate::services::agent_plan::AgentPlanService::new(ctx.db_pool.clone())
        .create_plan(crate::services::agent_plan::CreatePlanInput {
            campus_id,
            user_id: &user_id,
            action,
            risk_level,
            args: &args_json,
            summary: &summary,
            proposal_idempotency_key: ctx.proposal_idempotency_key.as_deref(),
        })
        .await
        .map_err(|e| ToolError(format!("创建待确认操作失败: {}", e)))?;

    if let Some(trace_id) = crate::api::request_context::current_request_id() {
        if let Err(error) = crate::services::agent_run::AgentRunService::new(ctx.db_pool.clone())
            .record_tool(
                &trace_id,
                campus_id,
                &user_id,
                action,
                Some(risk_level),
                "proposal_created",
            )
            .await
        {
            tracing::warn!(%error, "failed to record AgentRun action event");
        }
    }

    Ok(format!(
        "已创建待确认操作：{}。该操作需要你在应用中确认后才会执行（10 分钟内有效，计划编号 {}）。请在“待确认操作”里查看并确认或取消。",
        summary, plan
    ))
}

/// Capture the database-owned listing version at proposal time. The model
/// cannot supply or alter this value: any same-named input is discarded before
/// the authoritative read. Confirmation then compares this snapshot while
/// holding the listing row lock, so a plan cannot silently act on a newer
/// price, description, lifecycle state or restriction revision.
async fn attach_listing_revision_snapshot(
    ctx: &ToolContext,
    user_id: &str,
    campus_id: uuid::Uuid,
    action: &str,
    args: &mut serde_json::Value,
) -> Result<(), ToolError> {
    if !matches!(
        action,
        "update_listing" | "delete_listing" | "purchase_item" | "negotiate_item"
    ) {
        return Ok(());
    }
    let Some(object) = args.as_object_mut() else {
        return Ok(());
    };
    let Some(listing_id) = object
        .get("listing_id")
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
    else {
        object.remove("expected_content_revision");
        return Ok(());
    };
    object.remove("expected_content_revision");

    let revision = if matches!(action, "update_listing" | "delete_listing") {
        sqlx::query_scalar::<_, i64>(
            "SELECT content_revision FROM inventory
             WHERE id = $1 AND campus_id = $2 AND owner_id = $3",
        )
        .bind(&listing_id)
        .bind(campus_id)
        .bind(user_id)
        .fetch_optional(&ctx.db_pool)
        .await
    } else {
        sqlx::query_scalar::<_, i64>(
            "SELECT content_revision FROM inventory
             WHERE id = $1 AND campus_id = $2",
        )
        .bind(&listing_id)
        .bind(campus_id)
        .fetch_optional(&ctx.db_pool)
        .await
    }
    .map_err(|error| ToolError(format!("读取发布版本失败: {}", error)))?;

    if let Some(revision) = revision {
        object.insert(
            "expected_content_revision".to_string(),
            serde_json::json!(revision),
        );
    }
    Ok(())
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

async fn execute_create_listing_in_tx(
    ctx: &ToolContext,
    tx: &mut Transaction<'_, Postgres>,
    owner: &str,
    campus_id: uuid::Uuid,
    args: CreateListingArgs,
) -> Result<CreatedListing, ToolError> {
    let title = args.title.clone();
    let price_cents = args.suggested_price_cny;
    let result = ListingCommandService::new(ctx.db_pool.clone(), ctx.moderation.clone())
        .create_in_tx(
            tx,
            CreateListingDraft {
                campus_id,
                owner_id: owner.to_string(),
                title: args.title,
                category: args.category,
                brand: args.brand,
                direction: Some("offer".to_string()),
                condition_score: args.condition_score as i32,
                suggested_price_cny: price_cents as f64 / 100.0,
                defects: args.defects,
                description: Some(args.original_description),
                image_url: None,
            },
            None,
        )
        .await
        .map_err(|error| ToolError(format!("发布校验失败: {}", error)))?;

    Ok(CreatedListing {
        message: format!(
            "Successfully created listing '{}' (ID: {}, Price: {} CNY, Owner: {})",
            title,
            result.id,
            cents_to_yuan(price_cents),
            owner
        ),
        listing_id: result.id,
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

async fn execute_update_listing_in_tx(
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

async fn execute_delete_listing_in_tx(
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

async fn execute_purchase_item_in_tx(
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

async fn execute_negotiate_item_in_tx(
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

#[derive(Deserialize)]
pub struct GetMyListingsArgs {}

#[derive(Clone)]
pub struct GetMyListingsTool {
    pub ctx: ToolContext,
}

// ---------------------------------------------------------------------------
// 9. GetUserPostsTool
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct GetUserPostsArgs {
    pub user_id: String,
}

#[derive(Clone)]
pub struct GetUserPostsTool {
    pub ctx: ToolContext,
}

#[derive(sqlx::FromRow)]
struct ListingSummaryRow {
    id: String,
    title: String,
    category: String,
    condition_score: i32,
    suggested_price_cny: i64,
}

impl Tool for GetUserPostsTool {
    const NAME: &'static str = "get_user_posts";
    type Error = ToolError;
    type Args = GetUserPostsArgs;
    type Output = String;

    async fn definition(&self, _prompt: String) -> ToolDefinition {
        ToolDefinition {
            name: "get_user_posts".to_string(),
            description: "获取指定用户发布的所有在售帖子列表。".to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "user_id": { "type": "string", "description": "The user ID" }
                },
                "required": ["user_id"]
            }),
        }
    }

    async fn call(&self, args: Self::Args) -> Result<Self::Output, Self::Error> {
        let campus_id = resolve_read_campus(&self.ctx).await?;
        let rows = sqlx::query_as::<_, ListingSummaryRow>(
            "SELECT id, title, category, condition_score, suggested_price_cny
             FROM inventory WHERE owner_id = $1 AND campus_id = $2
               AND status = 'active' AND NOT listing_has_active_restriction(id)
             ORDER BY created_at DESC LIMIT 20",
        )
        .bind(&args.user_id)
        .bind(campus_id)
        .fetch_all(&self.ctx.db_pool)
        .await
        .map_err(|e| ToolError(format!("Query error: {}", e)))?;

        if rows.is_empty() {
            return Ok("该用户当前没有在售帖子。".to_string());
        }
        let mut out = format!("该用户共有 {} 条在售帖子：\n", rows.len());
        for (i, r) in rows.iter().enumerate() {
            out.push_str(&format!(
                "{}. [{}] {} — {} — 成色 {}/10 — {} 元\n",
                i + 1,
                r.id,
                r.title,
                r.category,
                r.condition_score,
                cents_to_yuan(r.suggested_price_cny),
            ));
        }
        Ok(out)
    }
}

// ---------------------------------------------------------------------------
// 10. FindRelatedPostsTool
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct FindRelatedPostsArgs {
    pub listing_id: String,
}

#[derive(Clone)]
pub struct FindRelatedPostsTool {
    pub ctx: ToolContext,
}

impl Tool for FindRelatedPostsTool {
    const NAME: &'static str = "find_related_posts";
    type Error = ToolError;
    type Args = FindRelatedPostsArgs;
    type Output = String;

    async fn definition(&self, _prompt: String) -> ToolDefinition {
        ToolDefinition {
            name: "find_related_posts".to_string(),
            description: "查找与指定帖子相似的其他在售帖子（同品类、相近价格）。".to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "listing_id": { "type": "string", "description": "The reference listing ID" }
                },
                "required": ["listing_id"]
            }),
        }
    }

    async fn call(&self, args: Self::Args) -> Result<Self::Output, Self::Error> {
        let campus_id = resolve_read_campus(&self.ctx).await?;
        let base = sqlx::query_as::<_, (String, i64)>(
            "SELECT category, suggested_price_cny FROM inventory WHERE id = $1",
        )
        .bind(&args.listing_id)
        .fetch_optional(&self.ctx.db_pool)
        .await
        .map_err(|e| ToolError(format!("Query error: {}", e)))?;

        let (category, price) = match base {
            Some(v) => v,
            None => return Ok(format!("未找到 ID 为 {} 的帖子。", args.listing_id)),
        };

        let min_price = (price as f64 * 0.6) as i64;
        let max_price = (price as f64 * 1.4) as i64;
        let rows = sqlx::query_as::<_, ListingSummaryRow>(
            "SELECT id, title, category, condition_score, suggested_price_cny
             FROM inventory
             WHERE id != $1 AND campus_id = $2 AND category = $3
               AND suggested_price_cny BETWEEN $4 AND $5
               AND status = 'active' AND NOT listing_has_active_restriction(id)
             ORDER BY ABS(suggested_price_cny - $6) ASC LIMIT 5",
        )
        .bind(&args.listing_id)
        .bind(campus_id)
        .bind(&category)
        .bind(min_price)
        .bind(max_price)
        .bind(price)
        .fetch_all(&self.ctx.db_pool)
        .await
        .map_err(|e| ToolError(format!("Query error: {}", e)))?;

        if rows.is_empty() {
            return Ok("没有找到相似的帖子。".to_string());
        }
        let mut out = format!("找到 {} 条相关帖子：\n", rows.len());
        for (i, r) in rows.iter().enumerate() {
            out.push_str(&format!(
                "{}. [{}] {} — 成色 {}/10 — {} 元\n",
                i + 1,
                r.id,
                r.title,
                r.condition_score,
                cents_to_yuan(r.suggested_price_cny),
            ));
        }
        Ok(out)
    }
}

// ---------------------------------------------------------------------------
// 11. GetCommentsTool
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct GetCommentsArgs {
    pub conversation_id: String,
}

#[derive(Clone)]
pub struct GetCommentsTool {
    pub ctx: ToolContext,
}

#[derive(sqlx::FromRow)]
struct CommentRow {
    sender: String,
    content: String,
    created_at: chrono::DateTime<chrono::Utc>,
}

impl Tool for GetCommentsTool {
    const NAME: &'static str = "get_comments";
    type Error = ToolError;
    type Args = GetCommentsArgs;
    type Output = String;

    async fn definition(&self, _prompt: String) -> ToolDefinition {
        ToolDefinition {
            name: "get_comments".to_string(),
            description: "获取某个商品对话中的最近留言记录。".to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "conversation_id": { "type": "string", "description": "The conversation thread ID" }
                },
                "required": ["conversation_id"]
            }),
        }
    }

    async fn call(&self, args: Self::Args) -> Result<Self::Output, Self::Error> {
        let current = self.ctx.current_user_id.clone().unwrap_or_default();
        if current.is_empty() {
            return Ok("[hidden] 请先登录后才能读取对话。".to_string());
        }
        let allowed = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS(
                 SELECT 1 FROM chat_messages
                 WHERE conversation_id = $1 AND (sender = $2 OR receiver = $2)
                 LIMIT 1)",
        )
        .bind(&args.conversation_id)
        .bind(&current)
        .fetch_one(&self.ctx.db_pool)
        .await
        .unwrap_or(false);

        if !allowed {
            return Ok("[hidden] 你不是这个对话的参与者。".to_string());
        }

        let rows = sqlx::query_as::<_, CommentRow>(
            "SELECT sender, content, created_at FROM chat_messages
             WHERE conversation_id = $1 AND is_agent = FALSE
             ORDER BY created_at DESC LIMIT 20",
        )
        .bind(&args.conversation_id)
        .fetch_all(&self.ctx.db_pool)
        .await
        .map_err(|e| ToolError(format!("Query error: {}", e)))?;

        if rows.is_empty() {
            return Ok("这个对话还没有留言。".to_string());
        }
        let mut out = format!("最近 {} 条留言：\n", rows.len());
        for r in &rows {
            out.push_str(&format!(
                "[{}] {}: {}\n",
                r.created_at.format("%m-%d %H:%M"),
                r.sender,
                r.content,
            ));
        }
        Ok(out)
    }
}

// ---------------------------------------------------------------------------
// 12. DraftMessageTool — generates a message draft without sending it
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct DraftMessageArgs {
    pub listing_id: String,
    pub receiver_id: String,
    pub draft_text: String,
}

#[derive(Clone)]
#[allow(dead_code)]
pub struct DraftMessageTool {
    pub ctx: ToolContext,
}

impl Tool for DraftMessageTool {
    const NAME: &'static str = "draft_message";
    type Error = ToolError;
    type Args = DraftMessageArgs;
    type Output = String;

    async fn definition(&self, _prompt: String) -> ToolDefinition {
        ToolDefinition {
            name: "draft_message".to_string(),
            description: "生成一条私信草稿给卖家。不会直接发送——用户确认后才发送。用于帮用户组织语言联系卖家。".to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "listing_id": { "type": "string", "description": "The related listing ID" },
                    "receiver_id": { "type": "string", "description": "The seller's user ID" },
                    "draft_text": { "type": "string", "description": "The draft message text to show the user for confirmation" }
                },
                "required": ["listing_id", "receiver_id", "draft_text"]
            }),
        }
    }

    async fn call(&self, args: Self::Args) -> Result<Self::Output, Self::Error> {
        // This tool does NOT send anything. It returns a formatted draft
        // for the frontend to show as a confirmation card.
        let listing_exists = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS(SELECT 1 FROM inventory WHERE id = $1 AND status = 'active')",
        )
        .bind(&args.listing_id)
        .fetch_one(&self.ctx.db_pool)
        .await
        .unwrap_or(false);

        let receiver_exists =
            sqlx::query_scalar::<_, bool>("SELECT EXISTS(SELECT 1 FROM users WHERE id = $1)")
                .bind(&args.receiver_id)
                .fetch_one(&self.ctx.db_pool)
                .await
                .unwrap_or(false);

        if !listing_exists || !receiver_exists {
            return Err(ToolError(
                "无法生成私信草稿：帖子或接收人不存在。".to_string(),
            ));
        }

        Ok(format!(
            "DRAFT_MESSAGE|{}|{}|{}",
            args.listing_id, args.receiver_id, args.draft_text
        ))
    }
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
            proposal_idempotency_key: None,
            moderation: ModerationService::new_for_test(false),
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
            GetUserPostsTool,
            FindRelatedPostsTool,
            GetCommentsTool,
            DraftMessageTool,
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
            proposal_idempotency_key: None,
            moderation: ModerationService::new_for_test(false),
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
    async fn draft_message_tool_rejects_missing_listing_or_receiver() {
        with_test_pool(|pool| async move {
            let seller_id = Uuid::new_v4().to_string();
            let listing_id = Uuid::new_v4().to_string();
            insert_tool_user(&pool, &seller_id, "draft_seller").await;
            insert_tool_listing(&pool, &listing_id, &seller_id, 10_000, "active").await;

            let ctx = tool_context(pool.clone(), Some(seller_id.clone()));
            let tool = DraftMessageTool { ctx };
            let valid = tool
                .call(DraftMessageArgs {
                    listing_id: listing_id.clone(),
                    receiver_id: seller_id.clone(),
                    draft_text: "周末方便面交吗？".to_string(),
                })
                .await
                .expect("valid draft");
            assert!(valid.starts_with("DRAFT_MESSAGE|"));

            let missing_listing = tool
                .call(DraftMessageArgs {
                    listing_id: Uuid::new_v4().to_string(),
                    receiver_id: seller_id.clone(),
                    draft_text: "test".to_string(),
                })
                .await;
            assert!(missing_listing.is_err());

            let missing_receiver = tool
                .call(DraftMessageArgs {
                    listing_id,
                    receiver_id: Uuid::new_v4().to_string(),
                    draft_text: "test".to_string(),
                })
                .await;
            assert!(missing_receiver.is_err());
        })
        .await;
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
                proposal_idempotency_key: None,
                moderation: ModerationService::new_for_test(false),
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
