//! Integration tests for AgentMemoryService & user personalization.

use goods4ncu::services::agent_memory::{
    AgentMemoryService, CreateMemoryInput, UpdateProfileInput,
};
use goods4ncu::test_infra::with_test_pool;
use uuid::Uuid;

fn ncu_campus_id() -> Uuid {
    Uuid::parse_str("c0000000-0000-0000-0000-000000000001").expect("valid NCU campus id")
}

async fn seed_test_user(pool: &sqlx::PgPool, user_id: &str) {
    sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
        .bind(user_id)
        .bind(format!("mem_user_{}", Uuid::new_v4()))
        .execute(pool)
        .await
        .expect("insert user");
}

#[tokio::test]
async fn test_agent_profile_lifecycle() {
    with_test_pool(|pool| async move {
        let user_id = format!("usr_{}", Uuid::new_v4());
        seed_test_user(&pool, &user_id).await;
        let campus_id = ncu_campus_id();

        let svc = AgentMemoryService::new(pool.clone());

        // 1. Get or create initial profile
        let profile = svc
            .get_or_create_profile(&user_id, campus_id)
            .await
            .expect("get initial profile");
        assert_eq!(profile.user_id, user_id);
        assert_eq!(profile.privacy_level, "standard");
        assert!(profile.is_memory_enabled);
        assert!(profile.preferred_locations.is_empty());

        // 2. Update profile preferences
        let updated = svc
            .update_profile(
                &user_id,
                campus_id,
                UpdateProfileInput {
                    preferred_locations: Some(vec!["前湖北院".to_string(), "先骕园".to_string()]),
                    interested_categories: Some(vec!["数码".to_string(), "图书".to_string()]),
                    budget_preferences: Some(serde_json::json!({ "max_budget": 500 })),
                    custom_instructions: Some("回答尽量简洁明了".to_string()),
                    privacy_level: Some("standard".to_string()),
                    is_memory_enabled: Some(true),
                    is_proactive_enabled: Some(true),
                },
            )
            .await
            .expect("update profile");

        assert_eq!(updated.preferred_locations, vec!["前湖北院", "先骕园"]);
        assert_eq!(updated.interested_categories, vec!["数码", "图书"]);
        assert_eq!(
            updated.custom_instructions.as_deref(),
            Some("回答尽量简洁明了")
        );
    })
    .await;
}

#[tokio::test]
async fn test_agent_episodic_memories_and_privacy() {
    with_test_pool(|pool| async move {
        let user_id = format!("usr_{}", Uuid::new_v4());
        seed_test_user(&pool, &user_id).await;
        let campus_id = ncu_campus_id();

        let svc = AgentMemoryService::new(pool.clone());
        let _ = svc
            .get_or_create_profile(&user_id, campus_id)
            .await
            .expect("init profile");

        // 1. Add episodic memories
        let mem1 = svc
            .add_memory(
                CreateMemoryInput {
                    user_id: &user_id,
                    campus_id,
                    memory_type: "preference",
                    content: "用户想收一本考研数学二资料",
                    source_ref: Some("chat_turn"),
                    confidence: 0.95,
                },
                None,
            )
            .await
            .expect("add memory 1");

        let _mem2 = svc
            .add_memory(
                CreateMemoryInput {
                    user_id: &user_id,
                    campus_id,
                    memory_type: "habit",
                    content: "用户常在润溪湖夜跑",
                    source_ref: Some("chat_turn"),
                    confidence: 0.90,
                },
                None,
            )
            .await
            .expect("add memory 2");

        // 2. List memories
        let (list, total) = svc
            .list_memories(&user_id, None, 10, 0)
            .await
            .expect("list");
        assert_eq!(total, 2);
        assert_eq!(list.len(), 2);

        // 3. Format context for prompt (standard privacy)
        let context = svc
            .format_memory_context(&user_id, campus_id, "考研", None, None)
            .await
            .expect("format context");
        assert!(context.contains("用户想收一本考研数学二资料"));

        // 4. Update privacy level to minimal -> context should be empty
        svc.update_profile(
            &user_id,
            campus_id,
            UpdateProfileInput {
                preferred_locations: None,
                interested_categories: None,
                budget_preferences: None,
                custom_instructions: None,
                privacy_level: Some("minimal".to_string()),
                is_memory_enabled: None,
                is_proactive_enabled: None,
            },
        )
        .await
        .expect("update to minimal");

        let context_minimal = svc
            .format_memory_context(&user_id, campus_id, "考研", None, None)
            .await
            .expect("format context minimal");
        assert!(context_minimal.is_empty());

        // 5. Delete specific memory
        let deleted = svc
            .delete_memory(&user_id, mem1.id)
            .await
            .expect("delete mem1");
        assert!(deleted);

        let (_, total_after_del) = svc
            .list_memories(&user_id, None, 10, 0)
            .await
            .expect("list after del");
        assert_eq!(total_after_del, 1);

        // 6. Clear all memories
        let cleared_count = svc.clear_all_memories(&user_id).await.expect("clear all");
        assert_eq!(cleared_count, 1);

        let (_, total_after_clear) = svc
            .list_memories(&user_id, None, 10, 0)
            .await
            .expect("list after clear");
        assert_eq!(total_after_clear, 0);
    })
    .await;
}
