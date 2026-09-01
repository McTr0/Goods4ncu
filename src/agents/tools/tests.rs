use super::*;
use crate::services::moderation::ModerationService;
use crate::test_infra::with_test_pool;
use rig::tool::Tool;
use sqlx::PgPool;
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
        DraftCommentTool,
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

async fn insert_tool_post(
    pool: &sqlx::PgPool,
    post_id: &str,
    author_id: &str,
    campus_id: uuid::Uuid,
) {
    sqlx::query(
        "INSERT INTO posts (id, campus_id, author_id, category, title, body, status)
         VALUES ($1::uuid, $2::uuid, $3::text, 'discussion', '测试帖', '正文', 'active')",
    )
    .bind(post_id)
    .bind(campus_id)
    .bind(author_id)
    .execute(pool)
    .await
    .expect("insert post");
}

#[tokio::test]
async fn draft_comment_tool_rejects_missing_or_closed_post() {
    with_test_pool(|pool| async move {
        let user_id = Uuid::new_v4().to_string();
        insert_tool_user(&pool, &user_id, "draft_comment_user").await;
        let campus_id =
            sqlx::query_scalar::<_, uuid::Uuid>("SELECT id FROM campuses WHERE slug = 'ncu'")
                .fetch_one(&pool)
                .await
                .expect("ncu campus");
        let post_id = Uuid::new_v4().to_string();
        insert_tool_post(&pool, &post_id, &user_id, campus_id).await;

        let ctx = tool_context(pool.clone(), Some(user_id.clone()));
        let tool = DraftCommentTool { ctx };

        let valid = tool
            .call(DraftCommentArgs {
                post_id: post_id.clone(),
                draft_text: "请问周末可以自提吗？".to_string(),
            })
            .await
            .expect("valid draft");
        assert_eq!(
            valid,
            format!("DRAFT_COMMENT|{}|{}", post_id, "请问周末可以自提吗？")
        );

        let missing = tool
            .call(DraftCommentArgs {
                post_id: Uuid::new_v4().to_string(),
                draft_text: "test".to_string(),
            })
            .await;
        assert!(missing.is_err());
    })
    .await;
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
