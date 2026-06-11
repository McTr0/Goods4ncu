use async_trait::async_trait;
use good4ncu::agents::tools::{
    CreateListingArgs, CreateListingTool, DeleteListingArgs, DeleteListingTool, EmbedUpdater,
    ToolContext, ToolError, UpdateListingArgs, UpdateListingTool,
};
use good4ncu::services::notification::NotificationService;
use good4ncu::test_infra::with_test_pool;
use rig::tool::Tool;
use sqlx::Row;
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

#[derive(Clone)]
struct FailingEmbedUpdater;

#[async_trait(?Send)]
impl EmbedUpdater for FailingEmbedUpdater {
    async fn embed_and_update(
        &self,
        _content: String,
        _listing_id: String,
        _conn: &mut sqlx::PgConnection,
    ) -> Result<(), ToolError> {
        Err(ToolError("forced embedding failure".to_string()))
    }
}

fn build_tool_context(db_pool: sqlx::PgPool, current_user_id: Option<&str>) -> ToolContext {
    build_tool_context_with_updater(db_pool, current_user_id, Arc::new(NoopEmbedUpdater))
}

fn build_tool_context_with_updater(
    db_pool: sqlx::PgPool,
    current_user_id: Option<&str>,
    embed_updater: Arc<dyn EmbedUpdater>,
) -> ToolContext {
    ToolContext {
        db_pool: db_pool.clone(),
        embed_updater,
        current_user_id: current_user_id.map(ToString::to_string),
        notification: NotificationService::new(db_pool),
    }
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

        sqlx::query(
            "INSERT INTO inventory (id, title, category, brand, condition_score, suggested_price_cny, defects, owner_id) \
             VALUES ($1, 'Owner Item', 'misc', 'Brand', 8, 10000, '[]', $2)",
        )
        .bind(&listing_id)
        .bind(&owner_id)
        .execute(&pool)
        .await
        .unwrap();

        let tool = UpdateListingTool {
            ctx: build_tool_context(pool.clone(), Some(attacker_id.as_str())),
        };
        let result = tool
            .call(UpdateListingArgs {
                listing_id: listing_id.clone(),
                new_price: Some(9999),
                new_title: None,
                new_description: None,
            })
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

        sqlx::query(
            "INSERT INTO inventory (id, title, category, brand, condition_score, suggested_price_cny, defects, owner_id) \
             VALUES ($1, 'Owner Item', 'misc', 'Brand', 8, 10000, '[]', $2)",
        )
        .bind(&listing_id)
        .bind(&owner_id)
        .execute(&pool)
        .await
        .unwrap();

        let tool = DeleteListingTool {
            ctx: build_tool_context(pool.clone(), Some(attacker_id.as_str())),
        };
        let result = tool
            .call(DeleteListingArgs {
                listing_id: listing_id.clone(),
            })
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
async fn create_listing_tool_rolls_back_inventory_when_embedding_fails() {
    with_test_pool(|pool| async move {
        let suffix = Uuid::new_v4().to_string();
        let owner_id = format!("create-owner-{suffix}");
        let username = format!("create-owner-{suffix}");
        let title = format!("Rollback Listing {suffix}");

        sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
            .bind(&owner_id)
            .bind(&username)
            .execute(&pool)
            .await
            .unwrap();

        let tool = CreateListingTool {
            ctx: build_tool_context_with_updater(
                pool.clone(),
                Some(owner_id.as_str()),
                Arc::new(FailingEmbedUpdater),
            ),
        };

        let err = tool
            .call(CreateListingArgs {
                title: title.clone(),
                category: "misc".to_string(),
                brand: "Brand".to_string(),
                condition_score: 8,
                suggested_price_cny: 10_000,
                defects: vec![],
                original_description: "should rollback".to_string(),
            })
            .await
            .unwrap_err();

        assert!(err.to_string().contains("Embedding error"));

        let listing_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM inventory WHERE owner_id = $1 AND title = $2")
                .bind(&owner_id)
                .bind(&title)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(listing_count, 0);
    })
    .await;
}

#[tokio::test]
async fn delete_listing_tool_removes_listing_document_in_same_operation() {
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

        let tool = DeleteListingTool {
            ctx: build_tool_context(pool.clone(), Some(owner_id.as_str())),
        };
        let result = tool
            .call(DeleteListingArgs {
                listing_id: listing_id.clone(),
            })
            .await
            .unwrap();

        assert!(result.contains("Successfully removed"));

        let row = sqlx::query("SELECT status FROM inventory WHERE id = $1")
            .bind(&listing_id)
            .fetch_one(&pool)
            .await
            .unwrap();
        let status: String = row.get("status");
        assert_eq!(status, "deleted");

        let document_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM documents WHERE id = $1")
            .bind(&listing_id)
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(document_count, 0);
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
