//! Tests for Autonomous ReAct & Self-Healing Engine.

use goods4ncu::agents::react::{ReActEngine, StepActionType};
use goods4ncu::agents::tools::ToolContext;
use goods4ncu::services::notification::NotificationService;
use goods4ncu::test_infra::with_test_pool;
use uuid::Uuid;

fn ncu_campus_id() -> Uuid {
    Uuid::parse_str("c0000000-0000-0000-0000-000000000001").expect("valid NCU campus id")
}

fn test_tool_ctx(pool: sqlx::PgPool, user_id: &str) -> ToolContext {
    ToolContext {
        db_pool: pool.clone(),
        current_user_id: Some(user_id.to_string()),
        current_campus_id: Some(ncu_campus_id()),
        proposal_idempotency_key: None,
        moderation: goods4ncu::services::moderation::ModerationService::new_for_test(false),
        notification: NotificationService::new(pool),
    }
}

async fn seed_verified_user(pool: &sqlx::PgPool, user_id: &str) {
    sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
        .bind(user_id)
        .bind(format!("react_user_{}", Uuid::new_v4()))
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

#[tokio::test]
async fn test_react_engine_search_and_self_healing_reflection() {
    with_test_pool(|pool| async move {
        let user_id = format!("usr_{}", Uuid::new_v4());
        seed_verified_user(&pool, &user_id).await;

        let ctx = test_tool_ctx(pool, &user_id);
        let engine = ReActEngine::new(ctx).with_max_steps(5);

        assert_eq!(engine.max_steps(), 5);

        // 1. Execute search for non-existent item -> Should reflect empty result and advise broadening query
        let (obs, refl) = engine
            .execute_action(
                StepActionType::SearchInventory,
                serde_json::json!({ "keyword": "non_existent_super_rare_book_99999" }),
            )
            .await;

        assert!(obs.contains("No items found") || obs.contains("未找到") || obs.contains("0 件"));
        assert!(refl.is_some());
        assert!(refl.unwrap().contains("放宽关键词"));

        // 2. Execute final answer action
        let (ans, refl_final) = engine
            .execute_action(
                StepActionType::FinalAnswer,
                serde_json::json!({ "answer": "已完成搜索，暂无匹配商品" }),
            )
            .await;
        assert_eq!(ans, "已完成搜索，暂无匹配商品");
        assert!(refl_final.is_none());
    })
    .await;
}

#[tokio::test]
async fn test_react_engine_high_risk_action_proposal() {
    with_test_pool(|pool| async move {
        let user_id = format!("usr_{}", Uuid::new_v4());
        seed_verified_user(&pool, &user_id).await;

        let ctx = test_tool_ctx(pool, &user_id);
        let engine = ReActEngine::new(ctx);

        // Proposing purchase item should generate a pending ActionPlan proposal
        let (obs, _) = engine
            .execute_action(
                StepActionType::PurchaseItem,
                serde_json::json!({
                    "listing_id": "non_existent_listing",
                    "offered_price": 5000
                }),
            )
            .await;

        // Since listing does not exist, safe validation fails gracefully rather than panicking
        assert!(obs.contains("失败") || obs.contains("不存在") || obs.contains("计划"));
    })
    .await;
}
