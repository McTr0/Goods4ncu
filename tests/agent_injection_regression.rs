//! Agent abuse-resistance test set (roadmap Phase 3): cross-user, cross-campus,
//! parameter pollution and confirmation-boundary attacks at the tool layer.
//!
//! These tests exercise the layer a compromised or prompt-injected model would
//! attack: tool arguments are fully attacker-controlled here, and the
//! assertions prove the validated execute bodies refuse to act outside the
//! calling user's authority regardless of what the model asks for.

use goods4ncu::agents::tools::{
    execute_create_listing, execute_negotiate_item, execute_purchase_item, CreateListingArgs,
    NegotiateItemArgs, PurchaseItemIntentArgs, ToolContext,
};
use goods4ncu::services::notification::NotificationService;
use goods4ncu::test_infra::with_test_pool;
use uuid::Uuid;

fn tool_ctx(pool: sqlx::PgPool, user_id: &str) -> ToolContext {
    ToolContext {
        db_pool: pool.clone(),
        current_user_id: Some(user_id.to_string()),
        current_campus_id: None,
        proposal_idempotency_key: None,
        moderation: goods4ncu::services::moderation::ModerationService::new_for_test(false),
        notification: NotificationService::new(pool),
    }
}

async fn seed_verified_user(pool: &sqlx::PgPool, user_id: &str, campus_slug: &str) {
    sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
        .bind(user_id)
        .bind(format!("inj_user_{}", Uuid::new_v4().simple()))
        .execute(pool)
        .await
        .expect("insert user");
    sqlx::query(
        "INSERT INTO campus_memberships (campus_id, user_id, status, verification_method, verified_at)
         SELECT id, $1, 'verified', 'test_fixture', NOW() FROM campuses WHERE slug = $2",
    )
    .bind(user_id)
    .bind(campus_slug)
    .execute(pool)
    .await
    .expect("insert membership");
}

async fn seed_other_campus(pool: &sqlx::PgPool) -> (Uuid, String) {
    let campus_id = Uuid::new_v4();
    let slug = format!("inj-{}", &campus_id.to_string()[..8]);
    sqlx::query(
        "INSERT INTO campuses (id, slug, name_zh, name_en, email_domains)
         VALUES ($1, $2, '注入测试大学', 'Injection Test University', ARRAY['inj.test'])",
    )
    .bind(campus_id)
    .bind(&slug)
    .execute(pool)
    .await
    .expect("insert campus");
    (campus_id, slug)
}

/// A model instructed (via injected content) to buy or negotiate on another
/// campus's listing must be refused at execution, no matter what listing_id it
/// passes.
#[tokio::test]
async fn cross_campus_purchase_and_negotiation_are_refused() {
    with_test_pool(|pool| async move {
        let (other_campus, other_slug) = seed_other_campus(&pool).await;
        let buyer_id = format!("inj-buyer-{}", Uuid::new_v4().simple());
        let seller_id = format!("inj-seller-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &buyer_id, "ncu").await;
        seed_verified_user(&pool, &seller_id, &other_slug).await;

        let listing_id = format!("inj-listing-{}", Uuid::new_v4().simple());
        sqlx::query(
            "INSERT INTO inventory (id, campus_id, title, category, brand, condition_score,
                                    suggested_price_cny, defects, owner_id, status)
             VALUES ($1, $2, 'Other Campus Item', 'misc', 'Brand', 8, 10000, '[]', $3, 'active')",
        )
        .bind(&listing_id)
        .bind(other_campus)
        .bind(&seller_id)
        .execute(&pool)
        .await
        .expect("insert cross-campus listing");

        let ctx = tool_ctx(pool.clone(), &buyer_id);

        let err = execute_purchase_item(
            &ctx,
            PurchaseItemIntentArgs {
                listing_id: listing_id.clone(),
                offered_price: 10_000,
            },
        )
        .await
        .expect_err("cross-campus purchase must fail");
        assert!(err.to_string().contains("校园"), "err: {err}");

        let err = execute_negotiate_item(
            &ctx,
            NegotiateItemArgs {
                listing_id: listing_id.clone(),
                offered_price: 9_000,
                reason: "injected".to_string(),
            },
        )
        .await
        .expect_err("cross-campus negotiation must fail");
        assert!(err.to_string().contains("校园"), "err: {err}");

        let orders: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM orders WHERE listing_id = $1")
            .bind(&listing_id)
            .fetch_one(&pool)
            .await
            .expect("orders");
        let hitl: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM hitl_requests WHERE listing_id = $1")
                .bind(&listing_id)
                .fetch_one(&pool)
                .await
                .expect("hitl");
        assert_eq!((orders, hitl), (0, 0));
    })
    .await;
}

/// Polluted numeric and string arguments must be rejected by the execute
/// bodies with the same rules the HTTP API enforces — the tool path must not
/// be a validation bypass.
#[tokio::test]
async fn polluted_create_listing_arguments_are_rejected() {
    with_test_pool(|pool| async move {
        let owner_id = format!("inj-owner-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &owner_id, "ncu").await;
        let ctx = tool_ctx(pool.clone(), &owner_id);

        let base = || CreateListingArgs {
            title: "Legit".to_string(),
            category: "misc".to_string(),
            brand: "Brand".to_string(),
            condition_score: 8,
            suggested_price_cny: 10_000,
            defects: vec![],
            original_description: "ok".to_string(),
        };

        // Empty and oversized titles.
        let mut args = base();
        args.title = "   ".to_string();
        assert!(execute_create_listing(&ctx, args).await.is_err());
        let mut args = base();
        args.title = "x".repeat(201);
        assert!(execute_create_listing(&ctx, args).await.is_err());

        // Out-of-range condition score.
        let mut args = base();
        args.condition_score = 0;
        assert!(execute_create_listing(&ctx, args).await.is_err());
        let mut args = base();
        args.condition_score = 99;
        assert!(execute_create_listing(&ctx, args).await.is_err());

        // Non-positive and absurd prices.
        let mut args = base();
        args.suggested_price_cny = 0;
        assert!(execute_create_listing(&ctx, args).await.is_err());
        let mut args = base();
        args.suggested_price_cny = -5_000;
        assert!(execute_create_listing(&ctx, args).await.is_err());
        let mut args = base();
        args.suggested_price_cny = 2_000_000_000;
        assert!(execute_create_listing(&ctx, args).await.is_err());

        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM inventory WHERE owner_id = $1")
            .bind(&owner_id)
            .fetch_one(&pool)
            .await
            .expect("count");
        assert_eq!(count, 0, "no polluted listing may be persisted");
    })
    .await;
}

/// Negative or out-of-band offers must be rejected by the price-tolerance
/// bounds even when the model is told to "offer -100" or "offer 1 CNY".
#[tokio::test]
async fn out_of_band_offers_are_rejected() {
    with_test_pool(|pool| async move {
        let buyer_id = format!("inj-offer-buyer-{}", Uuid::new_v4().simple());
        let seller_id = format!("inj-offer-seller-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &buyer_id, "ncu").await;
        seed_verified_user(&pool, &seller_id, "ncu").await;
        let listing_id = format!("inj-offer-listing-{}", Uuid::new_v4().simple());
        sqlx::query(
            "INSERT INTO inventory (id, title, category, brand, condition_score,
                                    suggested_price_cny, defects, owner_id, status)
             VALUES ($1, 'Offer Target', 'misc', 'Brand', 8, 10000, '[]', $2, 'active')",
        )
        .bind(&listing_id)
        .bind(&seller_id)
        .execute(&pool)
        .await
        .expect("insert listing");

        let ctx = tool_ctx(pool.clone(), &buyer_id);
        for bad_offer in [-10_000i64, 0, 1, 100_000] {
            let result = execute_purchase_item(
                &ctx,
                PurchaseItemIntentArgs {
                    listing_id: listing_id.clone(),
                    offered_price: bad_offer,
                },
            )
            .await;
            assert!(result.is_err(), "offer {bad_offer} must be rejected");
        }

        let orders: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM orders WHERE listing_id = $1")
            .bind(&listing_id)
            .fetch_one(&pool)
            .await
            .expect("orders");
        assert_eq!(orders, 0);
    })
    .await;
}

/// Self-dealing: a model told to "buy the user's own listing" (inflating
/// activity) must be refused.
#[tokio::test]
async fn self_dealing_is_refused() {
    with_test_pool(|pool| async move {
        let owner_id = format!("inj-self-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &owner_id, "ncu").await;
        let listing_id = format!("inj-self-listing-{}", Uuid::new_v4().simple());
        sqlx::query(
            "INSERT INTO inventory (id, title, category, brand, condition_score,
                                    suggested_price_cny, defects, owner_id, status)
             VALUES ($1, 'Own Item', 'misc', 'Brand', 8, 10000, '[]', $2, 'active')",
        )
        .bind(&listing_id)
        .bind(&owner_id)
        .execute(&pool)
        .await
        .expect("insert listing");

        let ctx = tool_ctx(pool.clone(), &owner_id);
        let err = execute_purchase_item(
            &ctx,
            PurchaseItemIntentArgs {
                listing_id: listing_id.clone(),
                offered_price: 10_000,
            },
        )
        .await
        .expect_err("self purchase must fail");
        assert!(err.to_string().contains("自己"), "err: {err}");

        let err = execute_negotiate_item(
            &ctx,
            NegotiateItemArgs {
                listing_id,
                offered_price: 9_000,
                reason: "self deal".to_string(),
            },
        )
        .await
        .expect_err("self negotiation must fail");
        assert!(err.to_string().contains("自己"), "err: {err}");
    })
    .await;
}

/// An unverified (pending-membership) user's model session cannot even
/// propose plans, let alone execute: the campus gate fires at proposal time.
#[tokio::test]
async fn unverified_user_cannot_propose_or_execute() {
    with_test_pool(|pool| async move {
        let user_id = format!("inj-pending-{}", Uuid::new_v4().simple());
        sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
            .bind(&user_id)
            .bind(format!("inj_pending_{}", Uuid::new_v4().simple()))
            .execute(&pool)
            .await
            .expect("insert user");
        sqlx::query(
            "INSERT INTO campus_memberships (campus_id, user_id, status)
             SELECT id, $1, 'pending' FROM campuses WHERE slug = 'ncu'",
        )
        .bind(&user_id)
        .execute(&pool)
        .await
        .expect("pending membership");

        let ctx = tool_ctx(pool.clone(), &user_id);
        let err = execute_create_listing(
            &ctx,
            CreateListingArgs {
                title: "Pending user item".to_string(),
                category: "misc".to_string(),
                brand: "Brand".to_string(),
                condition_score: 8,
                suggested_price_cny: 10_000,
                defects: vec![],
                original_description: "should fail".to_string(),
            },
        )
        .await
        .expect_err("unverified execution must fail");
        assert!(err.to_string().contains("校园身份验证"), "err: {err}");

        let plans: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM agent_action_plans WHERE user_id = $1")
                .bind(&user_id)
                .fetch_one(&pool)
                .await
                .expect("plans");
        assert_eq!(plans, 0);
    })
    .await;
}
