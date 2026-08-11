//! Agent ActionPlan protocol: the model proposes, only the user's
//! authenticated confirmation executes, and the token never reaches the model.

use goods4ncu::agents::tools::{
    CreateListingArgs, CreateListingTool, NegotiateItemArgs, NegotiateItemTool, ToolContext,
};
use goods4ncu::services::agent_plan::{AgentPlanService, ConfirmOutcome};
use goods4ncu::services::moderation_case::ModerationCaseService;
use goods4ncu::services::notification::NotificationService;
use goods4ncu::test_infra::{concurrent_test_pool, with_test_pool};
use rig::tool::Tool;
use std::sync::Arc;
use tokio::sync::Barrier;
use uuid::Uuid;

fn ncu_campus_id() -> Uuid {
    Uuid::parse_str("c0000000-0000-0000-0000-000000000001").expect("valid NCU campus id")
}

fn tool_ctx(pool: sqlx::PgPool, user_id: &str) -> ToolContext {
    tool_ctx_in_campus(pool, user_id, ncu_campus_id())
}

fn tool_ctx_in_campus(pool: sqlx::PgPool, user_id: &str, campus_id: Uuid) -> ToolContext {
    ToolContext {
        db_pool: pool.clone(),
        current_user_id: Some(user_id.to_string()),
        current_campus_id: Some(campus_id),
        moderation: goods4ncu::services::moderation::ModerationService::new_for_test(false),
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

fn expect_second_token(outcome: ConfirmOutcome) -> String {
    match outcome {
        ConfirmOutcome::NeedsSecondConfirmation { confirmation_token } => confirmation_token,
        other => panic!("expected a second-confirmation token, got {other:?}"),
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
        let plans = service
            .list_pending(&buyer_id, ncu_campus_id())
            .await
            .expect("list");
        assert_eq!(plans.len(), 1);
        let plan = &plans[0];
        assert_eq!(plan.action, "purchase_item");
        assert_eq!(plan.risk_level, "L3");

        // Wrong token: indistinguishable from a missing plan.
        let outcome = service
            .confirm(&ctx, &buyer_id, ncu_campus_id(), plan.id, "wrong-token")
            .await
            .expect("confirm wrong token");
        assert!(matches!(outcome, ConfirmOutcome::NotFound));

        // Another user cannot confirm someone else's plan even with the token.
        let other_id = format!("plan-outsider-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &other_id).await;
        let outcome = service
            .confirm(
                &ctx,
                &other_id,
                ncu_campus_id(),
                plan.id,
                &plan.confirmation_token,
            )
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
        let plan = &service
            .list_pending(&buyer_id, ncu_campus_id())
            .await
            .expect("list")[0];
        let (plan_a, token_a) = (plan.id, plan.confirmation_token.clone());
        sqlx::query(
            "UPDATE agent_action_plans SET expires_at = NOW() - interval '1 second' WHERE id = $1",
        )
        .bind(plan_a)
        .execute(&pool)
        .await
        .expect("expire");
        let outcome = service
            .confirm(&ctx, &buyer_id, ncu_campus_id(), plan_a, &token_a)
            .await
            .expect("confirm expired");
        assert!(matches!(outcome, ConfirmOutcome::Expired));

        // Cancelled plan.
        let listing_b = seed_listing(&pool, &seller_id).await;
        tool.call(purchase_args(&listing_b))
            .await
            .expect("propose b");
        let plan = &service
            .list_pending(&buyer_id, ncu_campus_id())
            .await
            .expect("list b")[0];
        let (plan_b, token_b) = (plan.id, plan.confirmation_token.clone());
        assert!(service
            .cancel(&buyer_id, ncu_campus_id(), plan_b)
            .await
            .expect("cancel"));
        let outcome = service
            .confirm(&ctx, &buyer_id, ncu_campus_id(), plan_b, &token_b)
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
        let plan = &service
            .list_pending(&buyer_id, ncu_campus_id())
            .await
            .expect("list")[0];
        assert_eq!(plan.risk_level, "L3");
        // L3: the first confirmation only arms the plan.
        let outcome = service
            .confirm(
                &ctx,
                &buyer_id,
                ncu_campus_id(),
                plan.id,
                &plan.confirmation_token,
            )
            .await
            .expect("first confirm");
        let second_token = expect_second_token(outcome);
        let outcome = service
            .confirm(&ctx, &buyer_id, ncu_campus_id(), plan.id, &second_token)
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
        let plan = &service
            .list_pending(&buyer_id, ncu_campus_id())
            .await
            .expect("list plan")[0];
        let (plan_id, token) = (plan.id, plan.confirmation_token.clone());
        let second_token = expect_second_token(
            service
                .confirm(&ctx, &buyer_id, ncu_campus_id(), plan_id, &token)
                .await
                .expect("arm plan"),
        );
        let outcome = service
            .confirm(&ctx, &buyer_id, ncu_campus_id(), plan_id, &second_token)
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
        let plan = &service
            .list_pending(&buyer_id, ncu_campus_id())
            .await
            .expect("list")[0];
        let (plan_id, token) = (plan.id, plan.confirmation_token.clone());

        // One confirmation arms the plan but must not create the deal intent.
        let outcome = service
            .confirm(&ctx, &buyer_id, ncu_campus_id(), plan_id, &token)
            .await
            .expect("first confirm");
        let second_token = expect_second_token(outcome);
        let orders: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM orders WHERE listing_id = $1")
            .bind(&listing_id)
            .fetch_one(&pool)
            .await
            .expect("orders after first confirm");
        assert_eq!(orders, 0, "a single L3 confirmation must not execute");

        // An armed plan still appears in the pending list for the second step,
        // and can still be cancelled instead.
        let plans = service
            .list_pending(&buyer_id, ncu_campus_id())
            .await
            .expect("list armed");
        assert_eq!(plans.len(), 1);
        assert_eq!(plans[0].status, "confirmed_once");
        assert_eq!(plans[0].confirmation_token, second_token);

        // The second confirmation executes exactly once.
        let outcome = service
            .confirm(&ctx, &buyer_id, ncu_campus_id(), plan_id, &second_token)
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
            .confirm(&ctx, &buyer_id, ncu_campus_id(), plan_id, &second_token)
            .await
            .expect("third confirm");
        assert!(matches!(outcome, ConfirmOutcome::AlreadyExecuted(_)));
    })
    .await;
}

#[tokio::test]
async fn retrying_the_primary_l3_token_never_executes_and_replays_the_same_second_token() {
    with_test_pool(|pool| async move {
        let buyer_id = format!("plan-primary-retry-{}", Uuid::new_v4().simple());
        let seller_id = format!("plan-primary-retry-seller-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &buyer_id).await;
        seed_verified_user(&pool, &seller_id).await;
        let listing_id = seed_listing(&pool, &seller_id).await;
        let ctx = tool_ctx(pool.clone(), &buyer_id);

        goods4ncu::agents::tools::PurchaseItemIntentTool { ctx: ctx.clone() }
            .call(purchase_args(&listing_id))
            .await
            .expect("propose purchase");

        let service = AgentPlanService::new(pool.clone());
        let plan = &service
            .list_pending(&buyer_id, ncu_campus_id())
            .await
            .expect("list plan")[0];
        let (plan_id, primary_token) = (plan.id, plan.confirmation_token.clone());

        let first_second_token = expect_second_token(
            service
                .confirm(&ctx, &buyer_id, ncu_campus_id(), plan_id, &primary_token)
                .await
                .expect("first primary confirmation"),
        );
        let replayed_second_token = expect_second_token(
            service
                .confirm(&ctx, &buyer_id, ncu_campus_id(), plan_id, &primary_token)
                .await
                .expect("retry primary confirmation"),
        );

        assert_eq!(first_second_token, replayed_second_token);
        let listed = service
            .list_pending(&buyer_id, ncu_campus_id())
            .await
            .expect("list armed plan");
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].status, "confirmed_once");
        assert_eq!(listed[0].confirmation_token, first_second_token);

        let orders: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM orders WHERE listing_id = $1")
            .bind(&listing_id)
            .fetch_one(&pool)
            .await
            .expect("count orders");
        assert_eq!(orders, 0, "a primary-token retry must never execute L3");
    })
    .await;
}

#[tokio::test]
async fn concurrent_second_token_confirms_share_one_stable_terminal_result() {
    with_test_pool(|pool| async move {
        let buyer_id = format!("plan-concurrent-buyer-{}", Uuid::new_v4().simple());
        let seller_id = format!("plan-concurrent-seller-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &buyer_id).await;
        seed_verified_user(&pool, &seller_id).await;
        let listing_id = seed_listing(&pool, &seller_id).await;
        let ctx = tool_ctx(pool.clone(), &buyer_id);

        goods4ncu::agents::tools::PurchaseItemIntentTool { ctx: ctx.clone() }
            .call(purchase_args(&listing_id))
            .await
            .expect("propose purchase");
        let service = AgentPlanService::new(pool.clone());
        let plan = &service
            .list_pending(&buyer_id, ncu_campus_id())
            .await
            .expect("list plan")[0];
        let plan_id = plan.id;
        let second_token = expect_second_token(
            service
                .confirm(
                    &ctx,
                    &buyer_id,
                    ncu_campus_id(),
                    plan_id,
                    &plan.confirmation_token,
                )
                .await
                .expect("arm plan"),
        );

        // A one-connection test pool would serialise before PostgreSQL ever
        // sees contention, so use a dedicated multi-connection pool here.
        let concurrent_pool = concurrent_test_pool(4).await;
        let barrier = Arc::new(Barrier::new(2));
        let mut tasks = Vec::new();
        for _ in 0..2 {
            let task_pool = concurrent_pool.clone();
            let task_barrier = Arc::clone(&barrier);
            let task_buyer = buyer_id.clone();
            let task_token = second_token.clone();
            tasks.push(tokio::spawn(async move {
                let task_ctx = tool_ctx(task_pool.clone(), &task_buyer);
                task_barrier.wait().await;
                AgentPlanService::new(task_pool)
                    .confirm(
                        &task_ctx,
                        &task_buyer,
                        ncu_campus_id(),
                        plan_id,
                        &task_token,
                    )
                    .await
            }));
        }

        let mut outcomes = Vec::new();
        for task in tasks {
            outcomes.push(
                task.await
                    .expect("confirmation task joined")
                    .expect("confirm"),
            );
        }
        let executed = outcomes
            .iter()
            .filter(|outcome| matches!(outcome, ConfirmOutcome::Executed(_)))
            .count();
        let replayed = outcomes
            .iter()
            .filter(|outcome| matches!(outcome, ConfirmOutcome::AlreadyExecuted(_)))
            .count();
        assert_eq!((executed, replayed), (1, 1), "outcomes: {outcomes:?}");

        let orders: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM orders WHERE listing_id = $1")
            .bind(&listing_id)
            .fetch_one(&pool)
            .await
            .expect("count orders");
        assert_eq!(orders, 1, "concurrent confirms must create one domain fact");
    })
    .await;
}

#[tokio::test]
async fn plans_are_not_visible_or_confirmable_from_another_campus() {
    with_test_pool(|pool| async move {
        let buyer_id = format!("plan-campus-buyer-{}", Uuid::new_v4().simple());
        let seller_id = format!("plan-campus-seller-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &buyer_id).await;
        seed_verified_user(&pool, &seller_id).await;
        let listing_id = seed_listing(&pool, &seller_id).await;
        let ncu_ctx = tool_ctx(pool.clone(), &buyer_id);

        goods4ncu::agents::tools::PurchaseItemIntentTool {
            ctx: ncu_ctx.clone(),
        }
        .call(purchase_args(&listing_id))
        .await
        .expect("propose purchase");

        let service = AgentPlanService::new(pool.clone());
        let ncu_plan = &service
            .list_pending(&buyer_id, ncu_campus_id())
            .await
            .expect("list NCU plan")[0];
        let (plan_id, primary_token) = (ncu_plan.id, ncu_plan.confirmation_token.clone());

        let other_campus = Uuid::new_v4();
        let other_slug = format!("plan-other-{}", Uuid::new_v4().simple());
        sqlx::query(
            "INSERT INTO campuses (id, slug, name_zh, name_en, email_domains)
             VALUES ($1, $2, '其他校园', 'Other Campus', ARRAY[]::TEXT[])",
        )
        .bind(other_campus)
        .bind(other_slug)
        .execute(&pool)
        .await
        .expect("insert other campus");
        sqlx::query(
            "INSERT INTO campus_memberships (
                campus_id, user_id, status, verification_method, verified_at
             ) VALUES ($1, $2, 'verified', 'test_fixture', NOW())",
        )
        .bind(other_campus)
        .bind(&buyer_id)
        .execute(&pool)
        .await
        .expect("verify buyer in other campus");

        let other_campus_plans = service
            .list_pending(&buyer_id, other_campus)
            .await
            .expect("list other campus")
            .len();
        let other_ctx = tool_ctx_in_campus(pool.clone(), &buyer_id, other_campus);
        let outcome = service
            .confirm(&other_ctx, &buyer_id, other_campus, plan_id, &primary_token)
            .await
            .expect("cross-campus confirm");

        let orders: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM orders WHERE listing_id = $1")
            .bind(&listing_id)
            .fetch_one(&pool)
            .await
            .expect("count orders");

        sqlx::query("DELETE FROM campus_memberships WHERE campus_id = $1")
            .bind(other_campus)
            .execute(&pool)
            .await
            .expect("delete temporary membership");
        sqlx::query("DELETE FROM campuses WHERE id = $1")
            .bind(other_campus)
            .execute(&pool)
            .await
            .expect("delete temporary campus");

        assert_eq!(other_campus_plans, 0);
        assert!(matches!(outcome, ConfirmOutcome::NotFound));
        assert_eq!(orders, 0);
    })
    .await;
}

#[tokio::test]
async fn terminal_plan_update_failure_rolls_back_the_domain_fact_and_is_safely_retryable() {
    with_test_pool(|pool| async move {
        let buyer_id = format!("plan-finalize-buyer-{}", Uuid::new_v4().simple());
        let seller_id = format!("plan-finalize-seller-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &buyer_id).await;
        seed_verified_user(&pool, &seller_id).await;
        let listing_id = seed_listing(&pool, &seller_id).await;
        let ctx = tool_ctx(pool.clone(), &buyer_id);

        goods4ncu::agents::tools::PurchaseItemIntentTool { ctx: ctx.clone() }
            .call(purchase_args(&listing_id))
            .await
            .expect("propose purchase");
        let service = AgentPlanService::new(pool.clone());
        let plan = &service
            .list_pending(&buyer_id, ncu_campus_id())
            .await
            .expect("list plan")[0];
        let plan_id = plan.id;
        let second_token = expect_second_token(
            service
                .confirm(
                    &ctx,
                    &buyer_id,
                    ncu_campus_id(),
                    plan_id,
                    &plan.confirmation_token,
                )
                .await
                .expect("arm plan"),
        );

        sqlx::query(
            "DROP TRIGGER IF EXISTS fail_agent_plan_finalize_for_test ON agent_action_plans",
        )
        .execute(&pool)
        .await
        .expect("drop stale test trigger");
        let function_sql = format!(
            "CREATE OR REPLACE FUNCTION fail_agent_plan_finalize_for_test()
             RETURNS trigger LANGUAGE plpgsql AS $function$
             BEGIN
                 IF NEW.id = '{}'::uuid AND NEW.status = 'executed' THEN
                     RAISE EXCEPTION 'forced terminal plan update failure';
                 END IF;
                 RETURN NEW;
             END
             $function$",
            plan_id
        );
        sqlx::query(&function_sql)
            .execute(&pool)
            .await
            .expect("create failure function");
        sqlx::query(
            "CREATE TRIGGER fail_agent_plan_finalize_for_test
             BEFORE UPDATE ON agent_action_plans
             FOR EACH ROW EXECUTE FUNCTION fail_agent_plan_finalize_for_test()",
        )
        .execute(&pool)
        .await
        .expect("create failure trigger");

        let failed_confirmation = service
            .confirm(&ctx, &buyer_id, ncu_campus_id(), plan_id, &second_token)
            .await;
        let status: String = sqlx::query_scalar(
            "SELECT status FROM agent_action_plans WHERE id = $1 AND campus_id = $2",
        )
        .bind(plan_id)
        .bind(ncu_campus_id())
        .fetch_one(&pool)
        .await
        .expect("read rolled-back plan");
        let orders_after_failure: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM orders WHERE listing_id = $1")
                .bind(&listing_id)
                .fetch_one(&pool)
                .await
                .expect("count rolled-back orders");

        sqlx::query("DROP TRIGGER fail_agent_plan_finalize_for_test ON agent_action_plans")
            .execute(&pool)
            .await
            .expect("drop test trigger");
        sqlx::query("DROP FUNCTION fail_agent_plan_finalize_for_test()")
            .execute(&pool)
            .await
            .expect("drop test function");

        assert!(failed_confirmation.is_err());
        assert_eq!(status, "confirmed_once");
        assert_eq!(orders_after_failure, 0);

        let retry = service
            .confirm(&ctx, &buyer_id, ncu_campus_id(), plan_id, &second_token)
            .await
            .expect("retry after terminal failure");
        assert!(matches!(retry, ConfirmOutcome::Executed(_)));
        let orders_after_retry: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM orders WHERE listing_id = $1")
                .bind(&listing_id)
                .fetch_one(&pool)
                .await
                .expect("count retried orders");
        assert_eq!(orders_after_retry, 1);
    })
    .await;
}
