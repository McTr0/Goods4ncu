//! Agent ActionPlan protocol: the model proposes, only the user's
//! authenticated confirmation executes, and the token never reaches the model.

use async_trait::async_trait;
use goods4ncu::agents::tools::{
    CreateListingArgs, CreateListingTool, EmbedUpdater, NegotiateItemArgs, NegotiateItemTool,
    ToolContext, ToolError,
};
use goods4ncu::services::agent_plan::{AgentPlanService, ConfirmOutcome};
use goods4ncu::services::moderation_case::ModerationCaseService;
use goods4ncu::services::notification::NotificationService;
use goods4ncu::test_infra::with_test_pool;
use rig::tool::Tool;
use std::sync::Arc;
use uuid::Uuid;

#[derive(Clone)]
struct NoopEmbedUpdater;

#[async_trait(?Send)]
impl EmbedUpdater for NoopEmbedUpdater {
    async fn embed_and_update(
        &self,
        _content: String,
        _listing_id: String,
        _conn: &mut sqlx::PgConnection,
    ) -> Result<(), ToolError> {
        Ok(())
    }
}

fn tool_ctx(pool: sqlx::PgPool, user_id: &str) -> ToolContext {
    ToolContext {
        db_pool: pool.clone(),
        embed_updater: Arc::new(NoopEmbedUpdater),
        current_user_id: Some(user_id.to_string()),
        current_campus_id: None,
        notification: NotificationService::new(pool),
    }
}

async fn seed_verified_user(pool: &sqlx::PgPool, user_id: &str) {
    sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
        .bind(user_id)
        .bind(format!("plan_user_{}", Uuid::new_v4()))
        .execute(pool)
        .await
        .expect("insert user");
    sqlx::query(
        "INSERT INTO campus_memberships (campus_id, user_id, status, verification_method, verified_at)
         SELECT id, $1, 'verified', 'test_fixture', NOW() FROM campuses WHERE slug = 'ncu'",
    )
    .bind(user_id)
    .execute(pool)
    .await
    .expect("insert membership");
}

fn create_args(title: &str) -> CreateListingArgs {
    CreateListingArgs {
        title: title.to_string(),
        category: "misc".to_string(),
        brand: "Brand".to_string(),
        condition_score: 8,
        suggested_price_cny: 10_000,
        defects: vec![],
        original_description: "plan flow".to_string(),
    }
}

async fn seed_listing(pool: &sqlx::PgPool, seller_id: &str) -> String {
    let listing_id = format!("plan-listing-{}", Uuid::new_v4().simple());
    sqlx::query(
        "INSERT INTO inventory (id, title, category, brand, condition_score,
                                suggested_price_cny, defects, owner_id, status)
         VALUES ($1, 'Plan Target', 'misc', 'Brand', 8, 10000, '[]', $2, 'active')",
    )
    .bind(&listing_id)
    .bind(seller_id)
    .execute(pool)
    .await
    .expect("insert listing");
    listing_id
}

fn purchase_args(listing_id: &str) -> goods4ncu::agents::tools::PurchaseItemIntentArgs {
    goods4ncu::agents::tools::PurchaseItemIntentArgs {
        listing_id: listing_id.to_string(),
        offered_price: 10_000,
    }
}

#[tokio::test]
async fn l2_write_executes_immediately_and_creates_no_plan() {
    // Publishing is recoverable, so it no longer waits behind a confirmation
    // dialog — it happens and stays undoable (see tests/undo_integration.rs).
    // This locks that in: an L2 write must not leave a pending plan behind.
    with_test_pool(|pool| async move {
        let user_id = format!("plan-l2-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &user_id).await;
        let title = format!("L2 Immediate {}", Uuid::new_v4().simple());

        let tool = CreateListingTool {
            ctx: tool_ctx(pool.clone(), &user_id),
        };
        let reply = tool.call(create_args(&title)).await.expect("tool call");

        let listings: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM inventory WHERE title = $1")
            .bind(&title)
            .fetch_one(&pool)
            .await
            .expect("count listings");
        assert_eq!(listings, 1, "an L2 write must execute at once");

        let plans: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM agent_action_plans WHERE user_id = $1")
                .bind(&user_id)
                .fetch_one(&pool)
                .await
                .expect("count plans");
        assert_eq!(plans, 0, "an L2 write must not queue a confirmation");

        // The user is told the action is recoverable.
        assert!(reply.contains("撤销"), "reply: {reply}");
    })
    .await;
}

#[tokio::test]
async fn l3_tool_call_proposes_a_plan_instead_of_executing() {
    // Money and identity keep the up-front confirmation, and the token that
    // unlocks it never reaches model-visible text — so a prompt-injected model
    // cannot confirm the proposal it just made.
    with_test_pool(|pool| async move {
        let buyer_id = format!("plan-proposer-{}", Uuid::new_v4().simple());
        let seller_id = format!("plan-proposer-seller-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &buyer_id).await;
        seed_verified_user(&pool, &seller_id).await;
        let listing_id = seed_listing(&pool, &seller_id).await;

        let tool = goods4ncu::agents::tools::PurchaseItemIntentTool {
            ctx: tool_ctx(pool.clone(), &buyer_id),
        };
        let reply = tool
            .call(purchase_args(&listing_id))
            .await
            .expect("tool call");

        assert!(reply.contains("待确认操作"), "reply: {reply}");
        let token: String = sqlx::query_scalar(
            "SELECT confirmation_token FROM agent_action_plans WHERE user_id = $1",
        )
        .bind(&buyer_id)
        .fetch_one(&pool)
        .await
        .expect("plan row exists");
        assert!(
            !reply.contains(&token),
            "confirmation token must not appear in model-visible text"
        );

        // Nothing was executed.
        let orders: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM orders WHERE listing_id = $1")
            .bind(&listing_id)
            .fetch_one(&pool)
            .await
            .expect("count orders");
        assert_eq!(orders, 0, "the tool must not execute without confirmation");
    })
    .await;
}

#[tokio::test]
async fn confirm_rejects_wrong_token_and_other_users() {
    with_test_pool(|pool| async move {
        let buyer_id = format!("plan-confirmer-{}", Uuid::new_v4().simple());
        let seller_id = format!("plan-confirmer-seller-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &buyer_id).await;
        seed_verified_user(&pool, &seller_id).await;
        let listing_id = seed_listing(&pool, &seller_id).await;
        let ctx = tool_ctx(pool.clone(), &buyer_id);

        let tool = goods4ncu::agents::tools::PurchaseItemIntentTool { ctx: ctx.clone() };
        tool.call(purchase_args(&listing_id))
            .await
            .expect("propose");

        let service = AgentPlanService::new(pool.clone());
        let plans = service.list_pending(&buyer_id).await.expect("list");
        assert_eq!(plans.len(), 1);
        let plan = &plans[0];
        assert_eq!(plan.action, "purchase_item");
        assert_eq!(plan.risk_level, "L3");

        // Wrong token: indistinguishable from a missing plan.
        let outcome = service
            .confirm(&ctx, &buyer_id, plan.id, "wrong-token")
            .await
            .expect("confirm wrong token");
        assert!(matches!(outcome, ConfirmOutcome::NotFound));

        // Another user cannot confirm someone else's plan even with the token.
        let other_id = format!("plan-outsider-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &other_id).await;
        let outcome = service
            .confirm(&ctx, &other_id, plan.id, &plan.confirmation_token)
            .await
            .expect("cross-user confirm");
        assert!(matches!(outcome, ConfirmOutcome::NotFound));

        // Neither rejected attempt executed anything.
        let orders: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM orders WHERE listing_id = $1")
            .bind(&listing_id)
            .fetch_one(&pool)
            .await
            .expect("count orders");
        assert_eq!(orders, 0);
    })
    .await;
}

#[tokio::test]
async fn expired_and_cancelled_plans_cannot_execute() {
    with_test_pool(|pool| async move {
        let buyer_id = format!("plan-expiry-{}", Uuid::new_v4().simple());
        let seller_id = format!("plan-expiry-seller-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &buyer_id).await;
        seed_verified_user(&pool, &seller_id).await;
        let ctx = tool_ctx(pool.clone(), &buyer_id);
        let service = AgentPlanService::new(pool.clone());
        let tool = goods4ncu::agents::tools::PurchaseItemIntentTool { ctx: ctx.clone() };

        // Expired plan.
        let listing_a = seed_listing(&pool, &seller_id).await;
        tool.call(purchase_args(&listing_a))
            .await
            .expect("propose a");
        let plan = &service.list_pending(&buyer_id).await.expect("list")[0];
        let (plan_a, token_a) = (plan.id, plan.confirmation_token.clone());
        sqlx::query(
            "UPDATE agent_action_plans SET expires_at = NOW() - interval '1 second' WHERE id = $1",
        )
        .bind(plan_a)
        .execute(&pool)
        .await
        .expect("expire");
        let outcome = service
            .confirm(&ctx, &buyer_id, plan_a, &token_a)
            .await
            .expect("confirm expired");
        assert!(matches!(outcome, ConfirmOutcome::Expired));

        // Cancelled plan.
        let listing_b = seed_listing(&pool, &seller_id).await;
        tool.call(purchase_args(&listing_b))
            .await
            .expect("propose b");
        let plan = &service.list_pending(&buyer_id).await.expect("list b")[0];
        let (plan_b, token_b) = (plan.id, plan.confirmation_token.clone());
        assert!(service.cancel(&buyer_id, plan_b).await.expect("cancel"));
        let outcome = service
            .confirm(&ctx, &buyer_id, plan_b, &token_b)
            .await
            .expect("confirm cancelled");
        assert!(matches!(outcome, ConfirmOutcome::NotConfirmable(_)));

        // Neither executed anything.
        for listing_id in [&listing_a, &listing_b] {
            let count: i64 =
                sqlx::query_scalar("SELECT COUNT(*) FROM orders WHERE listing_id = $1")
                    .bind(listing_id)
                    .fetch_one(&pool)
                    .await
                    .expect("count");
            assert_eq!(count, 0);
        }
    })
    .await;
}

#[tokio::test]
async fn confirmed_plan_still_fails_when_state_changed_since_proposal() {
    with_test_pool(|pool| async move {
        // A plan whose target became invalid between proposal and confirmation
        // must fail at execution — confirmation is not a bypass of validation.
        let buyer_id = format!("plan-buyer-{}", Uuid::new_v4().simple());
        let seller_id = format!("plan-seller-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &buyer_id).await;
        seed_verified_user(&pool, &seller_id).await;
        let listing_id = format!("plan-listing-{}", Uuid::new_v4().simple());
        sqlx::query(
            "INSERT INTO inventory (id, title, category, brand, condition_score,
                                    suggested_price_cny, defects, owner_id, status)
             VALUES ($1, 'Plan Target', 'misc', 'Brand', 8, 10000, '[]', $2, 'active')",
        )
        .bind(&listing_id)
        .bind(&seller_id)
        .execute(&pool)
        .await
        .expect("insert listing");

        let ctx = tool_ctx(pool.clone(), &buyer_id);
        let tool = goods4ncu::agents::tools::PurchaseItemIntentTool { ctx: ctx.clone() };
        tool.call(goods4ncu::agents::tools::PurchaseItemIntentArgs {
            listing_id: listing_id.clone(),
            offered_price: 10_000,
        })
        .await
        .expect("propose purchase");

        // Listing sells through another channel before the user confirms.
        sqlx::query("UPDATE inventory SET status = 'sold' WHERE id = $1")
            .bind(&listing_id)
            .execute(&pool)
            .await
            .expect("sell listing");

        let service = AgentPlanService::new(pool.clone());
        let plan = &service.list_pending(&buyer_id).await.expect("list")[0];
        assert_eq!(plan.risk_level, "L3");
        // L3: the first confirmation only arms the plan.
        let outcome = service
            .confirm(&ctx, &buyer_id, plan.id, &plan.confirmation_token)
            .await
            .expect("first confirm");
        assert!(matches!(outcome, ConfirmOutcome::NeedsSecondConfirmation));
        let outcome = service
            .confirm(&ctx, &buyer_id, plan.id, &plan.confirmation_token)
            .await
            .expect("second confirm");
        // Execution runs but reports the listing unavailable; no order exists.
        match outcome {
            ConfirmOutcome::Executed(result) => {
                assert!(result.contains("no longer available"), "result: {result}")
            }
            other => panic!("unexpected outcome: {other:?}"),
        }
        let orders: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM orders WHERE listing_id = $1")
            .bind(&listing_id)
            .fetch_one(&pool)
            .await
            .expect("orders count");
        assert_eq!(orders, 0, "no deal intent may exist for a sold listing");
    })
    .await;
}

#[tokio::test]
async fn confirmed_negotiation_plan_cannot_create_side_facts_after_restriction() {
    with_test_pool(|pool| async move {
        let buyer_id = format!("plan-restricted-buyer-{}", Uuid::new_v4().simple());
        let seller_id = format!("plan-restricted-seller-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &buyer_id).await;
        seed_verified_user(&pool, &seller_id).await;
        let listing_id = seed_listing(&pool, &seller_id).await;
        let ctx = tool_ctx(pool.clone(), &buyer_id);
        NegotiateItemTool { ctx: ctx.clone() }
            .call(NegotiateItemArgs {
                listing_id: listing_id.clone(),
                offered_price: 9_000,
                reason: "confirmed before restriction".to_string(),
            })
            .await
            .expect("propose negotiation plan");

        let campus_id: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
            .fetch_one(&pool)
            .await
            .expect("ncu campus");
        ModerationCaseService::new(pool.clone())
            .impose_manual_listing_takedown(
                &listing_id,
                campus_id,
                &seller_id,
                "测试发布受平台限制",
                None,
            )
            .await
            .expect("restrict listing");

        let service = AgentPlanService::new(pool.clone());
        let plan = &service.list_pending(&buyer_id).await.expect("list plan")[0];
        let (plan_id, token) = (plan.id, plan.confirmation_token.clone());
        assert!(matches!(
            service
                .confirm(&ctx, &buyer_id, plan_id, &token)
                .await
                .expect("arm plan"),
            ConfirmOutcome::NeedsSecondConfirmation
        ));
        let outcome = service
            .confirm(&ctx, &buyer_id, plan_id, &token)
            .await
            .expect("execute restricted plan");
        match outcome {
            ConfirmOutcome::Failed(_) => {}
            other => panic!("unexpected restricted-plan outcome: {other:?}"),
        }

        let hitl_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM hitl_requests WHERE listing_id = $1")
                .bind(&listing_id)
                .fetch_one(&pool)
                .await
                .expect("hitl side facts");
        let notification_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM notifications WHERE related_listing_id = $1")
                .bind(&listing_id)
                .fetch_one(&pool)
                .await
                .expect("notification side facts");
        assert_eq!((hitl_count, notification_count), (0, 0));
    })
    .await;
}

#[tokio::test]
async fn l3_plan_requires_two_confirmations_before_any_write() {
    with_test_pool(|pool| async move {
        let buyer_id = format!("plan-l3-buyer-{}", Uuid::new_v4().simple());
        let seller_id = format!("plan-l3-seller-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &buyer_id).await;
        seed_verified_user(&pool, &seller_id).await;
        let listing_id = format!("plan-l3-listing-{}", Uuid::new_v4().simple());
        sqlx::query(
            "INSERT INTO inventory (id, title, category, brand, condition_score,
                                    suggested_price_cny, defects, owner_id, status)
             VALUES ($1, 'L3 Target', 'misc', 'Brand', 8, 10000, '[]', $2, 'active')",
        )
        .bind(&listing_id)
        .bind(&seller_id)
        .execute(&pool)
        .await
        .expect("insert listing");

        let ctx = tool_ctx(pool.clone(), &buyer_id);
        let tool = goods4ncu::agents::tools::PurchaseItemIntentTool { ctx: ctx.clone() };
        tool.call(goods4ncu::agents::tools::PurchaseItemIntentArgs {
            listing_id: listing_id.clone(),
            offered_price: 10_000,
        })
        .await
        .expect("propose purchase");

        let service = AgentPlanService::new(pool.clone());
        let plan = &service.list_pending(&buyer_id).await.expect("list")[0];
        let (plan_id, token) = (plan.id, plan.confirmation_token.clone());

        // One confirmation arms the plan but must not create the deal intent.
        let outcome = service
            .confirm(&ctx, &buyer_id, plan_id, &token)
            .await
            .expect("first confirm");
        assert!(matches!(outcome, ConfirmOutcome::NeedsSecondConfirmation));
        let orders: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM orders WHERE listing_id = $1")
            .bind(&listing_id)
            .fetch_one(&pool)
            .await
            .expect("orders after first confirm");
        assert_eq!(orders, 0, "a single L3 confirmation must not execute");

        // An armed plan still appears in the pending list for the second step,
        // and can still be cancelled instead.
        let plans = service.list_pending(&buyer_id).await.expect("list armed");
        assert_eq!(plans.len(), 1);
        assert_eq!(plans[0].status, "confirmed_once");

        // The second confirmation executes exactly once.
        let outcome = service
            .confirm(&ctx, &buyer_id, plan_id, &token)
            .await
            .expect("second confirm");
        assert!(matches!(outcome, ConfirmOutcome::Executed(_)));
        let orders: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM orders WHERE listing_id = $1")
            .bind(&listing_id)
            .fetch_one(&pool)
            .await
            .expect("orders after second confirm");
        assert_eq!(orders, 1);

        // Further confirms are idempotent.
        let outcome = service
            .confirm(&ctx, &buyer_id, plan_id, &token)
            .await
            .expect("third confirm");
        assert!(matches!(outcome, ConfirmOutcome::AlreadyExecuted(_)));
    })
    .await;
}
