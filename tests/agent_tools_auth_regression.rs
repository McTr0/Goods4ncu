use goods4ncu::agents::tools::{
    execute_create_listing, execute_delete_listing, execute_update_listing, CreateListingArgs,
    CreateListingTool, DeleteListingArgs, DeleteListingTool, ToolContext, UpdateListingArgs,
    UpdateListingTool,
};
use goods4ncu::services::notification::NotificationService;
use goods4ncu::test_infra::with_test_pool;
use rig::tool::Tool;
use sqlx::Row;
use uuid::Uuid;

fn build_tool_context(db_pool: sqlx::PgPool, current_user_id: Option<&str>) -> ToolContext {
    ToolContext {
        db_pool: db_pool.clone(),
        current_user_id: current_user_id.map(ToString::to_string),
        current_campus_id: None,
        proposal_idempotency_key: None,
        moderation: goods4ncu::services::moderation::ModerationService::new_for_test(false),
        notification: NotificationService::new(db_pool),
    }
}

async fn verify_ncu_membership(pool: &sqlx::PgPool, user_id: &str) {
    sqlx::query(
        "INSERT INTO campus_memberships (
             campus_id, user_id, status, verification_method, verified_at
         ) SELECT id, $1, 'verified', 'test_fixture', NOW()
           FROM campuses WHERE slug = 'ncu'",
    )
    .bind(user_id)
    .execute(pool)
    .await
    .expect("verify NCU membership");
}

#[tokio::test]
async fn test_update_listing_tool_denies_cross_owner_mutation() {
    with_test_pool(|pool| async move {
        let suffix = Uuid::new_v4().to_string();
        let owner_id = format!("owner-user-{suffix}");
        let attacker_id = format!("attacker-user-{suffix}");
        let listing_id = format!("listing-auth-{suffix}");
        let owner_username = format!("owner-{suffix}");
        let attacker_username = format!("attacker-{suffix}");

        sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
            .bind(&owner_id)
            .bind(&owner_username)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
            .bind(&attacker_id)
            .bind(&attacker_username)
            .execute(&pool)
            .await
            .unwrap();
        verify_ncu_membership(&pool, &attacker_id).await;

        sqlx::query(
            "INSERT INTO inventory (id, title, category, brand, condition_score, suggested_price_cny, defects, owner_id) \
             VALUES ($1, 'Owner Item', 'misc', 'Brand', 8, 10000, '[]', $2)",
        )
        .bind(&listing_id)
        .bind(&owner_id)
        .execute(&pool)
        .await
        .unwrap();

        let ctx = build_tool_context(pool.clone(), Some(attacker_id.as_str()));
        let result = execute_update_listing(
            &ctx,
            UpdateListingArgs {
                listing_id: listing_id.clone(),
                new_price: Some(9999),
                new_title: None,
                new_description: None,
            },
        )
        .await
        .unwrap();

        assert!(result.contains("or you don't own it"));

        let row = sqlx::query("SELECT suggested_price_cny FROM inventory WHERE id = $1")
            .bind(&listing_id)
            .fetch_one(&pool)
            .await
            .unwrap();
        let price: i64 = row.get("suggested_price_cny");
        assert_eq!(price, 10000);
    })
    .await;
}

#[tokio::test]
async fn test_delete_listing_tool_denies_cross_owner_mutation() {
    with_test_pool(|pool| async move {
        let suffix = Uuid::new_v4().to_string();
        let owner_id = format!("owner-user-{suffix}");
        let attacker_id = format!("attacker-user-{suffix}");
        let listing_id = format!("listing-auth-{suffix}");
        let owner_username = format!("owner-{suffix}");
        let attacker_username = format!("attacker-{suffix}");

        sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
            .bind(&owner_id)
            .bind(&owner_username)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
            .bind(&attacker_id)
            .bind(&attacker_username)
            .execute(&pool)
            .await
            .unwrap();
        verify_ncu_membership(&pool, &attacker_id).await;

        sqlx::query(
            "INSERT INTO inventory (id, title, category, brand, condition_score, suggested_price_cny, defects, owner_id) \
             VALUES ($1, 'Owner Item', 'misc', 'Brand', 8, 10000, '[]', $2)",
        )
        .bind(&listing_id)
        .bind(&owner_id)
        .execute(&pool)
        .await
        .unwrap();

        let ctx = build_tool_context(pool.clone(), Some(attacker_id.as_str()));
        let result = execute_delete_listing(
            &ctx,
            DeleteListingArgs {
                listing_id: listing_id.clone(),
            },
        )
        .await
        .unwrap();

        assert!(result.contains("or you don't own it"));

        let row = sqlx::query("SELECT status FROM inventory WHERE id = $1")
            .bind(&listing_id)
            .fetch_one(&pool)
            .await
            .unwrap();
        let status: String = row.get("status");
        assert_eq!(status, "active");
    })
    .await;
}

#[tokio::test]
async fn agent_listing_mutations_are_scoped_to_the_verified_active_campus() {
    with_test_pool(|pool| async move {
        let suffix = Uuid::new_v4().to_string();
        let owner_id = format!("campus-owner-{suffix}");
        sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
            .bind(&owner_id)
            .bind(format!("campus-owner-{suffix}"))
            .execute(&pool)
            .await
            .unwrap();
        verify_ncu_membership(&pool, &owner_id).await;

        let other_campus = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO campuses (id, slug, name_zh, name_en, email_domains)
             VALUES ($1, $2, '其他', 'Other', ARRAY[]::TEXT[])",
        )
        .bind(other_campus)
        .bind(format!("agent-scope-{}", other_campus.simple()))
        .execute(&pool)
        .await
        .unwrap();
        let listing_id = Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO inventory (
                 id, campus_id, title, category, brand, condition_score,
                 suggested_price_cny, defects, owner_id, status
             ) VALUES ($1, $2, 'Other Campus Item', 'misc', 'Brand', 8,
                       10000, '[]', $3, 'active')",
        )
        .bind(&listing_id)
        .bind(other_campus)
        .bind(&owner_id)
        .execute(&pool)
        .await
        .unwrap();

        let ctx = build_tool_context(pool.clone(), Some(&owner_id));
        let update = execute_update_listing(
            &ctx,
            UpdateListingArgs {
                listing_id: listing_id.clone(),
                new_price: None,
                new_title: Some("Cross-campus mutation".to_string()),
                new_description: None,
            },
        )
        .await
        .unwrap();
        let delete = execute_delete_listing(
            &ctx,
            DeleteListingArgs {
                listing_id: listing_id.clone(),
            },
        )
        .await
        .unwrap();
        assert!(update.contains("No active listing"));
        assert!(delete.contains("No active listing"));

        let (title, status): (String, String) =
            sqlx::query_as("SELECT title, status FROM inventory WHERE id = $1")
                .bind(&listing_id)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(
            (title.as_str(), status.as_str()),
            ("Other Campus Item", "active")
        );
    })
    .await;
}

#[tokio::test]
async fn create_listing_tool_does_not_depend_on_embedding_provider() {
    with_test_pool(|pool| async move {
        let suffix = Uuid::new_v4().to_string();
        let owner_id = format!("create-owner-{suffix}");
        let username = format!("create-owner-{suffix}");
        let title = format!("Provider Independent Listing {suffix}");

        sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
            .bind(&owner_id)
            .bind(&username)
            .execute(&pool)
            .await
            .unwrap();
        verify_ncu_membership(&pool, &owner_id).await;

        // ToolContext intentionally has no provider dependency. Publication
        // commits inventory state while projection runs asynchronously.
        let ctx = build_tool_context(pool.clone(), Some(owner_id.as_str()));

        let result = execute_create_listing(
            &ctx,
            CreateListingArgs {
                title: title.clone(),
                category: "misc".to_string(),
                brand: "Brand".to_string(),
                condition_score: 8,
                suggested_price_cny: 10_000,
                defects: vec![],
                original_description: "provider runs asynchronously".to_string(),
            },
        )
        .await
        .expect("publication must not call generator");
        assert_eq!(result.listing_id.len(), 36);

        let listing_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM inventory WHERE owner_id = $1 AND title = $2")
                .bind(&owner_id)
                .bind(&title)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(listing_count, 1);
    })
    .await;
}

#[tokio::test]
async fn delete_listing_tool_enqueues_a_revision_matched_projection_tombstone() {
    with_test_pool(|pool| async move {
        let suffix = Uuid::new_v4().to_string();
        let owner_id = format!("delete-owner-{suffix}");
        let listing_id = format!("delete-listing-{suffix}");
        let username = format!("delete-owner-{suffix}");

        sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
            .bind(&owner_id)
            .bind(&username)
            .execute(&pool)
            .await
            .unwrap();
        verify_ncu_membership(&pool, &owner_id).await;

        sqlx::query(
            "INSERT INTO inventory (id, title, category, brand, condition_score, suggested_price_cny, defects, owner_id) \
             VALUES ($1, 'Owner Item', 'misc', 'Brand', 8, 10000, '[]', $2)",
        )
        .bind(&listing_id)
        .bind(&owner_id)
        .execute(&pool)
        .await
        .unwrap();

        sqlx::query(
            "INSERT INTO documents (id, document, embedded_text) VALUES ($1, $2::jsonb, $3)",
        )
        .bind(&listing_id)
        .bind(serde_json::json!({ "id": listing_id, "content": "stale" }))
        .bind("stale")
        .execute(&pool)
        .await
        .unwrap();

        let ctx = build_tool_context(pool.clone(), Some(owner_id.as_str()));
        let result = execute_delete_listing(
            &ctx,
            DeleteListingArgs {
                listing_id: listing_id.clone(),
            },
        )
        .await
        .unwrap();

        assert!(result.contains("Successfully removed"));

        let row = sqlx::query("SELECT status, content_revision FROM inventory WHERE id = $1")
            .bind(&listing_id)
            .fetch_one(&pool)
            .await
            .unwrap();
        let status: String = row.get("status");
        let content_revision: i64 = row.get("content_revision");
        assert_eq!(status, "deleted");

        // Projection cleanup is durable and asynchronous: migration 0057
        // coalesces the delete revision into the listing's embedding job. The
        // worker will remove the stale document after this business transaction
        // commits, without coupling deletion success to provider availability.
        let job = sqlx::query(
            "SELECT desired_revision, status FROM embedding_jobs WHERE listing_id = $1",
        )
            .bind(&listing_id)
            .fetch_one(&pool)
            .await
            .unwrap();
        let desired_revision: i64 = job.get("desired_revision");
        let job_status: String = job.get("status");
        assert_eq!(desired_revision, content_revision);
        assert_eq!(job_status, "pending");
    })
    .await;
}

#[tokio::test]
async fn create_listing_tool_requires_verified_campus_membership() {
    with_test_pool(|pool| async move {
        let suffix = Uuid::new_v4().to_string();
        let user_id = format!("pending-campus-user-{suffix}");
        let username = format!("pending-campus-user-{suffix}");
        let title = format!("Blocked Listing {suffix}");

        sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
            .bind(&user_id)
            .bind(&username)
            .execute(&pool)
            .await
            .unwrap();

        let tool = CreateListingTool {
            ctx: build_tool_context(pool.clone(), Some(user_id.as_str())),
        };
        let error = tool
            .call(CreateListingArgs {
                title: title.clone(),
                category: "misc".to_string(),
                brand: "Brand".to_string(),
                condition_score: 8,
                suggested_price_cny: 10_000,
                defects: vec![],
                original_description: "must not be persisted".to_string(),
            })
            .await
            .unwrap_err();

        assert!(error.to_string().contains("校园身份验证"));
        let listing_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM inventory WHERE owner_id = $1 AND title = $2")
                .bind(&user_id)
                .bind(&title)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(listing_count, 0);
    })
    .await;
}

#[tokio::test]
async fn test_mutation_tools_require_authenticated_user() {
    with_test_pool(|pool| async move {
        let update_tool = UpdateListingTool {
            ctx: build_tool_context(pool.clone(), None),
        };
        let update_err = update_tool
            .call(UpdateListingArgs {
                listing_id: "any-listing".to_string(),
                new_price: Some(5000),
                new_title: None,
                new_description: None,
            })
            .await
            .unwrap_err();

        let delete_tool = DeleteListingTool {
            ctx: build_tool_context(pool, None),
        };
        let delete_err = delete_tool
            .call(DeleteListingArgs {
                listing_id: "any-listing".to_string(),
            })
            .await
            .unwrap_err();

        assert!(update_err.to_string().contains("请先登录再进行操作"));
        assert!(delete_err.to_string().contains("请先登录再进行操作"));
    })
    .await;
}
