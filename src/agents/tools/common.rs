use super::listing::{
    execute_create_listing_in_tx, execute_delete_listing_in_tx, execute_update_listing_in_tx,
};
use super::trade::{execute_negotiate_item_in_tx, execute_purchase_item_in_tx};
use crate::services::campus::CampusService;
use crate::services::moderation::ModerationService;
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
pub(crate) async fn lock_verified_membership_in_tx(
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

pub(crate) async fn require_planned_actor_in_tx(
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
pub(crate) fn parse_planned_args<T: serde::de::DeserializeOwned>(
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

pub(crate) async fn require_verified_campus(
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
pub(crate) async fn propose_action_plan<A: serde::Serialize>(
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
pub(crate) async fn attach_listing_revision_snapshot(
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
pub(crate) mod yuan {
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

pub(crate) async fn resolve_read_campus(ctx: &ToolContext) -> Result<uuid::Uuid, ToolError> {
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
