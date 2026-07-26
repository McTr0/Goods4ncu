use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use good4ncu::agents::router::IntentRouter;
use good4ncu::api::auth::{
    generate_access_token, generate_access_token_for_campus,
    generate_access_token_for_campus_with_auth_time,
};
use good4ncu::api::error::ApiError;
use good4ncu::api::{create_router, ApiAgents, ApiInfrastructure, ApiSecrets, AppState};
use good4ncu::repositories::{
    AuthRepository, PostgresAuthRepository, PostgresChatRepository, PostgresListingRepository,
    PostgresOrderRepository, PostgresUserRepository,
};
use good4ncu::services::{self, notification::NotificationService};
use good4ncu::test_infra::with_test_pool;
use sha2::{Digest, Sha256};
use std::sync::Arc;
use tower::ServiceExt;

fn bearer(value: &str) -> String {
    format!("Bearer {}", value)
}

fn hash_refresh_token(token: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(token.as_bytes());
    hex::encode(hasher.finalize())
}

fn build_state(pool: sqlx::PgPool) -> AppState {
    let (service_manager, _rx) = services::ServiceManager::new(pool.clone());
    let admin_service = service_manager.admin.clone();
    let event_tx = service_manager.event_tx.clone();

    AppState {
        secrets: ApiSecrets {
            jwt_secret: "test_jwt_secret_at_least_32_characters_long".to_string(),
            jwt_secret_old: None,
            gemini_api_key: "test-gemini-key".to_string(),
            oss_endpoint: "https://oss-cn-beijing.aliyuncs.com".to_string(),
            oss_bucket: "test-bucket".to_string(),
            oss_role_arn: None,
            oss_access_key_id: None,
            oss_access_key_secret: None,
        },
        infra: ApiInfrastructure {
            db: pool.clone(),
            event_tx,
            rate_limit: {
                let factory = good4ncu::middleware::rate_limit::RateLimiterFactory::new(100, 60);
                good4ncu::middleware::rate_limit::RateLimitStateHandle::new(factory.build_local())
            },
            notification: NotificationService::new(pool.clone()),
            ws_connections: good4ncu::api::ws::new_ws_state(),
            metrics: Arc::new(good4ncu::api::metrics::MetricsService::new()),
            order_service: services::order::OrderService::new(pool.clone()),
            admin_service,
            moderation: services::moderation::ModerationService::new(
                &good4ncu::config::AppConfig {
                    gemini_api_key: "test-gemini-key".to_string(),
                    minimax_api_key: None,
                    minimax_api_base_url: None,
                    llm_api_key: None,
                    jwt_secret: "test_jwt_secret_at_least_32_characters_long".to_string(),
                    jwt_secret_old: None,
                    database_url: "postgres://test/test".to_string(),
                    oss_access_key_id: None,
                    oss_access_key_secret: None,
                    llm_provider: "gemini".to_string(),
                    llm_model: "gemini-3-flash-preview".to_string(),
                    llm_base_url: None,
                    vector_dim: 768,
                    cors_origins: vec![],
                    oss_endpoint: "https://oss-cn-beijing.aliyuncs.com".to_string(),
                    oss_bucket: "test-bucket".to_string(),
                    oss_role_arn: None,
                    redis_url: None,
                    rate_limit_max_requests: 100,
                    rate_limit_window_secs: 60,
                    server_host: "127.0.0.1".to_string(),
                    server_port: 3000,
                    shutdown_drain_secs: 5,
                    shutdown_timeout_secs: 25,
                    event_bus_capacity: 2048,
                    hitl_expire_scan_interval_secs: 600,
                    hitl_expire_timeout_hours: 48,
                    moka_cache_max_capacity: 100_000,
                    access_token_ttl_secs: 86_400,
                    refresh_token_ttl_secs: 604_800,
                    conversation_history_limit: 10,
                    max_keyword_len: 200,
                    price_tolerance: 0.5,
                    categories: vec!["other".to_string()],
                    blocked_keywords: vec![],
                    moderation_image_enabled: false,
                    moderation_image_api_url: None,
                    moderation_image_api_key: None,
                    secret_chat_new_sessions_enabled: false,
                    media_private_bucket: false,
                    media_url_ttl_secs: 600,
                    media_path_style: true,
                    media_region: "us-east-1".to_string(),
                },
            ),
            token_denylist: services::token_denylist::TokenDenylist::new(),
            secret_chat_new_sessions_enabled: false,
            media_signer: None,
            shutdown: good4ncu::lifecycle::ShutdownSignal::never(),
        },
        agents: ApiAgents {
            llm_provider: Arc::new(
                good4ncu::llm::gemini::GeminiProvider::new("test-key", 768)
                    .expect("gemini provider init"),
            ),
            router: IntentRouter::new(vec![]),
        },
        listing_repo: PostgresListingRepository::new(pool.clone()),
        user_repo: PostgresUserRepository::new(pool.clone()),
        chat_repo: PostgresChatRepository::new(pool.clone()),
        auth_repo: PostgresAuthRepository::new(pool.clone()),
        order_repo: PostgresOrderRepository::new(pool),
    }
}

async fn insert_user(pool: &sqlx::PgPool, id: &str, username: &str, role: &str) {
    sqlx::query(
        "INSERT INTO users (id, username, password_hash, role) VALUES ($1, $2, 'hash', $3)",
    )
    .bind(id)
    .bind(username)
    .bind(role)
    .execute(pool)
    .await
    .expect("insert user");

    sqlx::query(
        "INSERT INTO campus_memberships (
            campus_id, user_id, status, role, verification_method, verified_at
         ) VALUES (
            'c0000000-0000-0000-0000-000000000001', $1,
            'verified', 'member', 'test_fixture', NOW()
         ) ON CONFLICT (campus_id, user_id) DO NOTHING",
    )
    .bind(id)
    .execute(pool)
    .await
    .expect("insert default campus membership");
}

async fn insert_campus(pool: &sqlx::PgPool, campus_id: uuid::Uuid, slug: &str) {
    sqlx::query(
        "INSERT INTO campuses (id, slug, name_zh, name_en, email_domains)
         VALUES ($1, $2, $2, $2, ARRAY[]::TEXT[])",
    )
    .bind(campus_id)
    .bind(slug)
    .execute(pool)
    .await
    .expect("insert campus");
}

async fn move_user_to_campus(
    pool: &sqlx::PgPool,
    user_id: &str,
    campus_id: uuid::Uuid,
    membership_role: &str,
) {
    sqlx::query("DELETE FROM campus_memberships WHERE user_id = $1")
        .bind(user_id)
        .execute(pool)
        .await
        .expect("remove old membership");
    sqlx::query(
        "INSERT INTO campus_memberships (
            campus_id, user_id, status, role, verification_method, verified_at
         ) VALUES ($1, $2, 'verified', $3, 'test_fixture', NOW())",
    )
    .bind(campus_id)
    .bind(user_id)
    .bind(membership_role)
    .execute(pool)
    .await
    .expect("insert campus membership");
}

async fn insert_refresh_token(pool: &sqlx::PgPool, user_id: &str, token_hash: &str, revoked: bool) {
    let expires_at = chrono::Utc::now() + chrono::Duration::hours(1);
    if revoked {
        sqlx::query(
            "INSERT INTO refresh_tokens (user_id, token_hash, expires_at, revoked_at) VALUES ($1, $2, $3, NOW())",
        )
        .bind(user_id)
        .bind(token_hash)
        .bind(expires_at)
        .execute(pool)
        .await
        .expect("insert revoked refresh token");
    } else {
        sqlx::query(
            "INSERT INTO refresh_tokens (user_id, token_hash, expires_at) VALUES ($1, $2, $3)",
        )
        .bind(user_id)
        .bind(token_hash)
        .bind(expires_at)
        .execute(pool)
        .await
        .expect("insert refresh token");
    }
}

async fn insert_listing(pool: &sqlx::PgPool, listing_id: &str, owner_id: &str, status: &str) {
    sqlx::query(
        "INSERT INTO inventory (id, title, category, brand, condition_score, suggested_price_cny, defects, owner_id, status) \
         VALUES ($1, 'Test Listing', 'misc', 'Brand', 8, 10000, '[]', $2, $3)",
    )
    .bind(listing_id)
    .bind(owner_id)
    .bind(status)
    .execute(pool)
    .await
    .expect("insert listing");
}

async fn insert_order(
    pool: &sqlx::PgPool,
    order_id: &str,
    listing_id: &str,
    buyer_id: &str,
    seller_id: &str,
    status: &str,
) {
    sqlx::query(
        "INSERT INTO orders (id, listing_id, buyer_id, seller_id, final_price, status) VALUES ($1, $2, $3, $4, 10000, $5)",
    )
    .bind(order_id)
    .bind(listing_id)
    .bind(buyer_id)
    .bind(seller_id)
    .bind(status)
    .execute(pool)
    .await
    .expect("insert order");
}

#[tokio::test]
async fn admin_routes_require_auth_and_admin_role() {
    with_test_pool(|pool| async move {
        insert_user(&pool, "admin-1", "admin_u", "admin").await;
        insert_user(&pool, "user-1", "user_u", "user").await;
        insert_user(&pool, "target-user-1", "target_u", "user").await;

        let state = build_state(pool.clone());
        let app = create_router(state, &[]);

        let admin_routes = [
            ("GET", "/api/admin/capabilities"),
            ("GET", "/api/admin/stats"),
            ("GET", "/api/admin/users"),
            ("GET", "/api/admin/listings"),
            ("GET", "/api/admin/orders"),
            ("GET", "/api/admin/audit-logs"),
            ("GET", "/api/admin/moderation/jobs"),
            ("GET", "/api/admin/moderation/cases"),
            ("POST", "/api/admin/users/target-user-1/ban"),
            ("POST", "/api/admin/users/target-user-1/unban"),
            ("POST", "/api/admin/users/target-user-1/impersonate"),
            ("POST", "/api/admin/listings/listing-1/takedown"),
            ("POST", "/api/admin/tokens/test-jti/revoke"),
        ];

        let (user_token, _, _) = generate_access_token(
            "user-1",
            "user",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("user token");
        let (admin_token, _, _) = generate_access_token(
            "admin-1",
            "admin",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("admin token");

        for (method, uri) in admin_routes {
            let req = Request::builder()
                .method(method)
                .uri(uri)
                .body(Body::empty())
                .unwrap();
            let resp = app.clone().oneshot(req).await.unwrap();
            assert_eq!(
                resp.status(),
                StatusCode::UNAUTHORIZED,
                "{} {} should reject missing auth",
                method,
                uri
            );

            let req = Request::builder()
                .method(method)
                .uri(uri)
                .header("Authorization", bearer(&user_token))
                .body(Body::empty())
                .unwrap();
            let resp = app.clone().oneshot(req).await.unwrap();
            assert_eq!(
                resp.status(),
                StatusCode::FORBIDDEN,
                "{} {} should reject non-admin",
                method,
                uri
            );

            let req = Request::builder()
                .method(method)
                .uri(uri)
                .header("Authorization", bearer(&admin_token))
                .body(Body::empty())
                .unwrap();
            let resp = app.clone().oneshot(req).await.unwrap();
            assert_ne!(
                resp.status(),
                StatusCode::UNAUTHORIZED,
                "{} {} admin auth should pass middleware",
                method,
                uri
            );
            assert_ne!(
                resp.status(),
                StatusCode::FORBIDDEN,
                "{} {} admin auth should pass middleware",
                method,
                uri
            );
        }

        let req = Request::builder()
            .method("POST")
            .uri("/api/admin/users/user-1/role")
            .header("Authorization", bearer(&admin_token))
            .header("Content-Type", "application/json")
            .body(Body::from(r#"{"role":"seller"}"#))
            .unwrap();
        let resp = app.clone().oneshot(req).await.unwrap();
        assert_ne!(resp.status(), StatusCode::UNAUTHORIZED);
        assert_ne!(resp.status(), StatusCode::FORBIDDEN);

        let req = Request::builder()
            .method("POST")
            .uri("/api/admin/orders/order-1/status")
            .header("Authorization", bearer(&admin_token))
            .header("Content-Type", "application/json")
            .body(Body::from(r#"{"status":"cancelled"}"#))
            .unwrap();
        let resp = app.clone().oneshot(req).await.unwrap();
        assert_ne!(resp.status(), StatusCode::UNAUTHORIZED);
        assert_ne!(resp.status(), StatusCode::FORBIDDEN);
    })
    .await;
}

#[tokio::test]
async fn admin_user_search_filters_results_and_total_within_campus() {
    with_test_pool(|pool| async move {
        let suffix = uuid::Uuid::new_v4().simple().to_string();
        let admin_id = format!("admin-search-{suffix}");
        let matching_id = format!("seller-search-{suffix}");
        let other_id = format!("buyer-search-{suffix}");
        let matching_username = format!("seller_{suffix}");
        let other_username = format!("buyer_{suffix}");

        insert_user(&pool, &admin_id, &format!("admin_{suffix}"), "admin").await;
        insert_user(&pool, &matching_id, &matching_username, "user").await;
        insert_user(&pool, &other_id, &other_username, "user").await;

        let state = build_state(pool.clone());
        let app = create_router(state, &[]);
        let (admin_token, _, _) = generate_access_token(
            &admin_id,
            "admin",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("admin token");

        let response = app
            .oneshot(
                Request::builder()
                    .uri(format!("/api/admin/users?q={matching_username}"))
                    .header("Authorization", bearer(&admin_token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body: serde_json::Value = serde_json::from_slice(
            &to_bytes(response.into_body(), usize::MAX)
                .await
                .expect("users body"),
        )
        .expect("users json");

        assert_eq!(body["total"], 1);
        let users = body["users"].as_array().expect("users array");
        assert_eq!(users.len(), 1);
        assert_eq!(users[0]["id"], matching_id);
        assert_eq!(users[0]["username"], matching_username);
    })
    .await;
}

#[tokio::test]
async fn admin_self_target_mutations_are_forbidden() {
    with_test_pool(|pool| async move {
        insert_user(&pool, "admin-self", "admin_self", "admin").await;
        insert_user(&pool, "admin-peer", "admin_peer", "admin").await;
        insert_user(&pool, "banned-user", "banned_user", "user").await;
        sqlx::query("UPDATE users SET status = 'banned' WHERE id = $1")
            .bind("banned-user")
            .execute(&pool)
            .await
            .expect("ban test user");

        let state = build_state(pool.clone());
        let app = create_router(state, &[]);

        let (admin_token, _, _) = generate_access_token(
            "admin-self",
            "admin",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("admin token");

        let req = Request::builder()
            .method("POST")
            .uri("/api/admin/users/admin-self/ban")
            .header("Authorization", bearer(&admin_token))
            .body(Body::empty())
            .unwrap();
        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::FORBIDDEN);

        let req = Request::builder()
            .method("POST")
            .uri("/api/admin/users/admin-peer/ban")
            .header("Authorization", bearer(&admin_token))
            .body(Body::empty())
            .unwrap();
        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::FORBIDDEN);

        let peer_status: String = sqlx::query_scalar("SELECT status FROM users WHERE id = $1")
            .bind("admin-peer")
            .fetch_one(&pool)
            .await
            .expect("select peer admin status");
        assert_eq!(peer_status, "active");

        let req = Request::builder()
            .method("POST")
            .uri("/api/admin/users/banned-user/impersonate")
            .header("Authorization", bearer(&admin_token))
            .body(Body::empty())
            .unwrap();
        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::FORBIDDEN);

        let req = Request::builder()
            .method("POST")
            .uri("/api/admin/users/admin-self/unban")
            .header("Authorization", bearer(&admin_token))
            .body(Body::empty())
            .unwrap();
        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::FORBIDDEN);

        let req = Request::builder()
            .method("POST")
            .uri("/api/admin/users/admin-self/role")
            .header("Authorization", bearer(&admin_token))
            .header("Content-Type", "application/json")
            .body(Body::from(r#"{"role":"seller"}"#))
            .unwrap();
        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::FORBIDDEN);
    })
    .await;
}

#[tokio::test]
async fn revoke_refresh_token_is_single_use() {
    with_test_pool(|pool| async move {
        insert_user(&pool, "user-revoke-1", "revoke_user", "user").await;
        let auth_repo = PostgresAuthRepository::new(pool.clone());

        let token_hash = hash_refresh_token("refresh-single-use-token");
        insert_refresh_token(&pool, "user-revoke-1", &token_hash, false).await;

        auth_repo
            .revoke_refresh_token(&token_hash)
            .await
            .expect("first revoke should succeed");

        let second = auth_repo.revoke_refresh_token(&token_hash).await;
        assert!(matches!(second, Err(ApiError::Unauthorized)));
    })
    .await;
}

#[tokio::test]
async fn refresh_replay_revoked_token_revokes_all_sessions() {
    with_test_pool(|pool| async move {
        let user_id = "refresh-user-1";
        insert_user(&pool, user_id, "refresh_user", "user").await;

        let revoked_token = "revoked-refresh-token";
        let active_token = "active-refresh-token";

        insert_refresh_token(&pool, user_id, &hash_refresh_token(revoked_token), true).await;
        insert_refresh_token(&pool, user_id, &hash_refresh_token(active_token), false).await;

        let state = build_state(pool.clone());
        let app = create_router(state, &[]);

        let req = Request::builder()
            .method("POST")
            .uri("/api/auth/refresh")
            .header("content-type", "application/json")
            .body(Body::from(
                serde_json::json!({ "refresh_token": revoked_token }).to_string(),
            ))
            .unwrap();

        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

        let remaining_active: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM refresh_tokens WHERE user_id = $1 AND revoked_at IS NULL",
        )
        .bind(user_id)
        .fetch_one(&pool)
        .await
        .expect("count active sessions");

        assert_eq!(remaining_active, 0);
    })
    .await;
}

#[tokio::test]
async fn admin_update_order_status_rejects_invalid_status_and_unknown_order() {
    with_test_pool(|pool| async move {
        insert_user(&pool, "admin-o-1", "admin_o1", "admin").await;
        insert_user(&pool, "seller-o-1", "seller_o1", "seller").await;
        insert_user(&pool, "buyer-o-1", "buyer_o1", "buyer").await;
        insert_listing(&pool, "listing-o-1", "seller-o-1", "sold").await;
        insert_order(
            &pool,
            "order-o-1",
            "listing-o-1",
            "buyer-o-1",
            "seller-o-1",
            "pending",
        )
        .await;

        let state = build_state(pool.clone());
        let app = create_router(state, &[]);

        let (admin_token, _, _) = generate_access_token(
            "admin-o-1",
            "admin",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("admin token");

        let invalid_req = Request::builder()
            .method("POST")
            .uri("/api/admin/orders/order-o-1/status")
            .header("Authorization", bearer(&admin_token))
            .header("Content-Type", "application/json")
            .body(Body::from(r#"{"status":"invalid_status"}"#))
            .unwrap();
        let invalid_resp = app.clone().oneshot(invalid_req).await.unwrap();
        assert_eq!(invalid_resp.status(), StatusCode::BAD_REQUEST);

        let missing_req = Request::builder()
            .method("POST")
            .uri("/api/admin/orders/non-existent-order/status")
            .header("Authorization", bearer(&admin_token))
            .header("Content-Type", "application/json")
            .body(Body::from(r#"{"status":"cancelled"}"#))
            .unwrap();
        let missing_resp = app.clone().oneshot(missing_req).await.unwrap();
        assert_eq!(missing_resp.status(), StatusCode::NOT_FOUND);
    })
    .await;
}

#[tokio::test]
async fn admin_forced_cancel_does_not_relist_with_other_active_order() {
    with_test_pool(|pool| async move {
        insert_user(&pool, "admin-o-2", "admin_o2", "admin").await;
        insert_user(&pool, "seller-o-2", "seller_o2", "seller").await;
        insert_user(&pool, "buyer-o-2a", "buyer_o2a", "buyer").await;
        insert_user(&pool, "buyer-o-2b", "buyer_o2b", "buyer").await;

        insert_listing(&pool, "listing-o-2", "seller-o-2", "sold").await;

        // Target order to cancel.
        insert_order(
            &pool,
            "order-o-2-cancel",
            "listing-o-2",
            "buyer-o-2a",
            "seller-o-2",
            "pending",
        )
        .await;

        // Another active order keeps listing sold.
        insert_order(
            &pool,
            "order-o-2-active",
            "listing-o-2",
            "buyer-o-2b",
            "seller-o-2",
            "paid",
        )
        .await;

        let state = build_state(pool.clone());
        let app = create_router(state, &[]);

        let (admin_token, _, _) = generate_access_token(
            "admin-o-2",
            "admin",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("admin token");

        let req = Request::builder()
            .method("POST")
            .uri("/api/admin/orders/order-o-2-cancel/status")
            .header("Authorization", bearer(&admin_token))
            .header("Content-Type", "application/json")
            .body(Body::from(r#"{"status":"cancelled"}"#))
            .unwrap();

        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        let inventory_row = sqlx::query("SELECT status FROM inventory WHERE id = $1")
            .bind("listing-o-2")
            .fetch_one(&pool)
            .await
            .expect("query inventory status");
        let inventory_status: String = sqlx::Row::get(&inventory_row, "status");
        assert_eq!(inventory_status, "sold");

        let cancelled_row = sqlx::query("SELECT status FROM orders WHERE id = $1")
            .bind("order-o-2-cancel")
            .fetch_one(&pool)
            .await
            .expect("query cancelled order status");
        let cancelled_status: String = sqlx::Row::get(&cancelled_row, "status");
        assert_eq!(cancelled_status, "cancelled");
    })
    .await;
}

#[tokio::test]
async fn campus_operator_reads_only_own_campus_and_cannot_mutate() {
    with_test_pool(|pool| async move {
        let ncu_id = uuid::Uuid::parse_str("c0000000-0000-0000-0000-000000000001")
            .expect("ncu id");
        let other_campus_id = uuid::Uuid::new_v4();
        let other_campus_slug = format!("other-{}", &other_campus_id.to_string()[..8]);
        insert_campus(&pool, other_campus_id, &other_campus_slug).await;
        insert_user(&pool, "operator-ncu", "operator_ncu", "user").await;
        insert_user(&pool, "seller-ncu", "seller_ncu", "user").await;
        insert_user(&pool, "seller-other", "seller_other", "user").await;
        sqlx::query(
            "UPDATE campus_memberships SET role = 'operator'
             WHERE user_id = $1 AND campus_id = $2",
        )
        .bind("operator-ncu")
        .bind(ncu_id)
        .execute(&pool)
        .await
        .expect("promote campus operator");
        move_user_to_campus(&pool, "seller-other", other_campus_id, "member").await;

        insert_listing(&pool, "listing-ncu-scope", "seller-ncu", "active").await;
        insert_listing(&pool, "listing-other-scope", "seller-other", "active").await;
        sqlx::query("UPDATE inventory SET campus_id = $1 WHERE id = $2")
            .bind(other_campus_id)
            .bind("listing-other-scope")
            .execute(&pool)
            .await
            .expect("move listing to other campus");

        let ncu_job_id = format!("moderation-ncu-{}", uuid::Uuid::new_v4());
        let other_job_id = format!("moderation-other-{}", uuid::Uuid::new_v4());
        sqlx::query(
            "INSERT INTO moderation_jobs (
                id, campus_id, resource_type, resource_id, image_url, status
             ) VALUES
                ($1, $2, 'listing_image', 'listing-ncu-scope', 'https://example.test/ncu.jpg', 'pending'),
                ($3, $4, 'listing_image', 'listing-other-scope', 'https://example.test/other.jpg', 'pending')",
        )
        .bind(&ncu_job_id)
        .bind(ncu_id)
        .bind(&other_job_id)
        .bind(other_campus_id)
        .execute(&pool)
        .await
        .expect("insert moderation fixtures");

        let state = build_state(pool.clone());
        let app = create_router(state, &[]);
        let (operator_token, _, _) = generate_access_token_for_campus(
            "operator-ncu",
            "user",
            Some(ncu_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("operator token");

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/admin/listings")
                    .header("Authorization", bearer(&operator_token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body: serde_json::Value = serde_json::from_slice(
            &to_bytes(response.into_body(), usize::MAX)
                .await
                .expect("listings body"),
        )
        .expect("listings json");
        assert_eq!(body["campus_id"], ncu_id.to_string());
        assert!(body["listings"]
            .as_array()
            .expect("listings array")
            .iter()
            .any(|listing| listing["id"] == "listing-ncu-scope"));
        assert!(!body["listings"]
            .as_array()
            .expect("listings array")
            .iter()
            .any(|listing| listing["id"] == "listing-other-scope"));

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/admin/moderation/jobs")
                    .header("Authorization", bearer(&operator_token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body: serde_json::Value = serde_json::from_slice(
            &to_bytes(response.into_body(), usize::MAX)
                .await
                .expect("moderation body"),
        )
        .expect("moderation json");
        assert!(body["jobs"]
            .as_array()
            .expect("moderation jobs")
            .iter()
            .any(|job| job["id"] == ncu_job_id));
        assert!(!body["jobs"]
            .as_array()
            .expect("moderation jobs")
            .iter()
            .any(|job| job["id"] == other_job_id));

        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/admin/users/seller-ncu/ban")
                    .header("Authorization", bearer(&operator_token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
    })
    .await;
}

#[tokio::test]
async fn platform_admin_cross_campus_access_requires_reason_and_is_audited() {
    with_test_pool(|pool| async move {
        let ncu_id = uuid::Uuid::parse_str("c0000000-0000-0000-0000-000000000001")
            .expect("ncu id");
        let other_campus_id = uuid::Uuid::new_v4();
        let other_campus_slug = format!("audit-{}", &other_campus_id.to_string()[..8]);
        insert_campus(&pool, other_campus_id, &other_campus_slug).await;
        insert_user(&pool, "platform-admin", "platform_admin", "admin").await;
        insert_user(&pool, "cross-campus-user", "cross_campus_user", "user").await;
        move_user_to_campus(
            &pool,
            "cross-campus-user",
            other_campus_id,
            "member",
        )
        .await;
        insert_listing(
            &pool,
            "cross-campus-listing",
            "cross-campus-user",
            "active",
        )
        .await;
        sqlx::query("UPDATE inventory SET campus_id = $1 WHERE id = $2")
            .bind(other_campus_id)
            .bind("cross-campus-listing")
            .execute(&pool)
            .await
            .expect("move cross-campus listing");

        let state = build_state(pool.clone());
        let app = create_router(state, &[]);
        let (admin_token, _, _) = generate_access_token_for_campus(
            "platform-admin",
            "admin",
            Some(ncu_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("platform admin token");

        let missing_reason_uri = format!("/api/admin/listings?campus_id={other_campus_id}");
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri(missing_reason_uri)
                    .header("Authorization", bearer(&admin_token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);

        let scoped_uri = format!(
            "/api/admin/listings?campus_id={other_campus_id}&reason=incident-review"
        );
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri(scoped_uri)
                    .header("Authorization", bearer(&admin_token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body: serde_json::Value = serde_json::from_slice(
            &to_bytes(response.into_body(), usize::MAX)
                .await
                .expect("cross-campus body"),
        )
        .expect("cross-campus json");
        assert_eq!(body["campus_id"], other_campus_id.to_string());
        assert_eq!(body["total"], 1);
        assert_eq!(body["listings"][0]["id"], "cross-campus-listing");

        let mutation_uri = format!(
            "/api/admin/users/cross-campus-user/ban?campus_id={other_campus_id}&reason=incident-review"
        );
        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(mutation_uri)
                    .header("Authorization", bearer(&admin_token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        let audit = sqlx::query(
            "SELECT campus_id, scope_reason FROM admin_audit_logs
             WHERE action = 'ban_user' AND target_id = $1",
        )
        .bind("cross-campus-user")
        .fetch_one(&pool)
        .await
        .expect("cross-campus audit");
        assert_eq!(
            sqlx::Row::get::<uuid::Uuid, _>(&audit, "campus_id"),
            other_campus_id
        );
        assert_eq!(
            sqlx::Row::get::<Option<String>, _>(&audit, "scope_reason").as_deref(),
            Some("incident-review")
        );
    })
    .await;
}

#[tokio::test]
async fn campus_operator_reads_moderation_cases_but_platform_admin_reviews() {
    with_test_pool(|pool| async move {
        let suffix = uuid::Uuid::new_v4().simple().to_string();
        let platform_admin_id = format!("case-admin-{suffix}");
        let operator_id = format!("case-operator-{suffix}");
        let subject_id = format!("case-subject-{suffix}");
        insert_user(
            &pool,
            &platform_admin_id,
            &format!("case_admin_{suffix}"),
            "admin",
        )
        .await;
        insert_user(
            &pool,
            &operator_id,
            &format!("case_operator_{suffix}"),
            "user",
        )
        .await;
        insert_user(
            &pool,
            &subject_id,
            &format!("case_subject_{suffix}"),
            "user",
        )
        .await;
        let campus_id =
            uuid::Uuid::parse_str("c0000000-0000-0000-0000-000000000001").expect("ncu id");
        sqlx::query(
            "UPDATE campus_memberships SET role = 'operator'
             WHERE campus_id = $1 AND user_id = $2",
        )
        .bind(campus_id)
        .bind(&operator_id)
        .execute(&pool)
        .await
        .expect("promote operator");
        let case_id = uuid::Uuid::new_v4();
        sqlx::query(
            "INSERT INTO moderation_cases (
                id, campus_id, subject_user_id, resource_type, resource_id,
                source_type, source_ref_id, status, reason_category,
                public_reason, internal_details
             ) VALUES (
                $1, $2, $3, 'chat_message', '1001', 'manual', $4,
                'open', 'message_report', '一条聊天消息正在审核',
                '{\"evidence\":\"operator-visible\"}'::jsonb
             )",
        )
        .bind(case_id)
        .bind(campus_id)
        .bind(&subject_id)
        .bind(format!("manual-{case_id}"))
        .execute(&pool)
        .await
        .expect("insert case");

        let app = create_router(build_state(pool.clone()), &[]);
        let (operator_token, _, _) = generate_access_token_for_campus(
            &operator_id,
            "user",
            Some(campus_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("operator token");
        let (admin_token, _, _) = generate_access_token_for_campus(
            &platform_admin_id,
            "admin",
            Some(campus_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("admin token");

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/admin/capabilities")
                    .header("Authorization", bearer(&operator_token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body: serde_json::Value = serde_json::from_slice(
            &to_bytes(response.into_body(), usize::MAX)
                .await
                .expect("capabilities body"),
        )
        .expect("capabilities json");
        assert_eq!(body["can_read"], true);
        assert_eq!(body["can_review"], false);
        assert_eq!(body["is_platform_admin"], false);

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/admin/moderation/cases?status=open")
                    .header("Authorization", bearer(&operator_token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body: serde_json::Value = serde_json::from_slice(
            &to_bytes(response.into_body(), usize::MAX)
                .await
                .expect("case list body"),
        )
        .expect("case list json");
        assert!(body["cases"]
            .as_array()
            .expect("cases")
            .iter()
            .any(|item| item["id"] == case_id.to_string()));

        let review_body = serde_json::json!({
            "action": "start_review",
            "note": "开始人工复核"
        });
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/admin/moderation/cases/{case_id}/review"))
                    .header("Authorization", bearer(&operator_token))
                    .header("Content-Type", "application/json")
                    .body(Body::from(review_body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/admin/moderation/cases/{case_id}/review"))
                    .header("Authorization", bearer(&admin_token))
                    .header("Content-Type", "application/json")
                    .body(Body::from(review_body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body: serde_json::Value = serde_json::from_slice(
            &to_bytes(response.into_body(), usize::MAX)
                .await
                .expect("review body"),
        )
        .expect("review json");
        assert_eq!(body["status"], "reviewing");
        assert_eq!(body["assigned_to"], platform_admin_id);

        let audit_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM admin_audit_logs
             WHERE campus_id = $1 AND admin_id = $2
               AND action = 'moderation_case_start_review' AND target_id = $3",
        )
        .bind(campus_id)
        .bind(&platform_admin_id)
        .bind(case_id.to_string())
        .fetch_one(&pool)
        .await
        .expect("audit count");
        assert_eq!(audit_count, 1);
    })
    .await;
}

#[tokio::test]
async fn sensitive_admin_writes_require_recent_password_authentication() {
    with_test_pool(|pool| async move {
        let suffix = uuid::Uuid::new_v4().simple().to_string();
        let admin_id = format!("step-up-admin-{suffix}");
        let target_id = format!("step-up-target-{suffix}");
        insert_user(
            &pool,
            &admin_id,
            &format!("step_up_admin_{suffix}"),
            "admin",
        )
        .await;
        insert_user(
            &pool,
            &target_id,
            &format!("step_up_target_{suffix}"),
            "user",
        )
        .await;
        let campus_id =
            uuid::Uuid::parse_str("c0000000-0000-0000-0000-000000000001").expect("ncu id");
        let (stale_token, _, _) = generate_access_token_for_campus_with_auth_time(
            &admin_id,
            "admin",
            Some(campus_id),
            None,
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("stale admin token");
        let app = create_router(build_state(pool.clone()), &[]);

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/admin/capabilities")
                    .header("Authorization", bearer(&stale_token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body: serde_json::Value = serde_json::from_slice(
            &to_bytes(response.into_body(), usize::MAX)
                .await
                .expect("capabilities body"),
        )
        .expect("capabilities json");
        assert_eq!(body["can_review"], true);
        assert_eq!(body["recent_authentication_required"], true);
        assert_eq!(body["recent_authentication_valid"], false);

        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/admin/users/{target_id}/ban"))
                    .header("Authorization", bearer(&stale_token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
        let body: serde_json::Value = serde_json::from_slice(
            &to_bytes(response.into_body(), usize::MAX)
                .await
                .expect("step-up body"),
        )
        .expect("step-up json");
        assert_eq!(body["code"], "recent_authentication_required");
        let target_status: String = sqlx::query_scalar("SELECT status FROM users WHERE id = $1")
            .bind(&target_id)
            .fetch_one(&pool)
            .await
            .expect("target status");
        assert_eq!(target_status, "active");
    })
    .await;
}

#[tokio::test]
async fn appeal_requires_an_independent_reviewer_and_restores_resource() {
    with_test_pool(|pool| async move {
        let suffix = uuid::Uuid::new_v4().simple().to_string();
        let original_reviewer = format!("appeal-admin-a-{suffix}");
        let independent_reviewer = format!("appeal-admin-b-{suffix}");
        let subject_id = format!("appeal-subject-{suffix}");
        insert_user(
            &pool,
            &original_reviewer,
            &format!("appeal_admin_a_{suffix}"),
            "admin",
        )
        .await;
        insert_user(
            &pool,
            &independent_reviewer,
            &format!("appeal_admin_b_{suffix}"),
            "admin",
        )
        .await;
        insert_user(
            &pool,
            &subject_id,
            &format!("appeal_subject_{suffix}"),
            "user",
        )
        .await;
        let campus_id =
            uuid::Uuid::parse_str("c0000000-0000-0000-0000-000000000001").expect("ncu id");
        sqlx::query("UPDATE users SET avatar_moderation_status = 'rejected' WHERE id = $1")
            .bind(&subject_id)
            .execute(&pool)
            .await
            .expect("reject avatar");
        let case_id = uuid::Uuid::new_v4();
        sqlx::query(
            "INSERT INTO moderation_cases (
                id, campus_id, subject_user_id, resource_type, resource_id,
                source_type, source_ref_id, status, reason_category,
                public_reason, resolution, decided_by, decided_at
             ) VALUES (
                $1, $2, $3, 'avatar', $3, 'manual', $4, 'actioned',
                'image_policy', '头像未通过内容安全审核',
                'content_restricted', $5, NOW()
             )",
        )
        .bind(case_id)
        .bind(campus_id)
        .bind(&subject_id)
        .bind(format!("manual-appeal-{case_id}"))
        .bind(&original_reviewer)
        .execute(&pool)
        .await
        .expect("insert actioned case");

        let service = good4ncu::services::moderation_case::ModerationCaseService::new(pool.clone());
        let appeal = service
            .submit_appeal(
                case_id,
                &subject_id,
                campus_id,
                "这是一张正常的本人头像，请由另一位审核人员重新检查。",
            )
            .await
            .expect("submit appeal");
        let same_reviewer = service
            .review_appeal(
                appeal.id,
                campus_id,
                &original_reviewer,
                good4ncu::services::moderation_case::AppealDecision::Overturn,
                "重新检查后恢复",
            )
            .await;
        assert!(matches!(same_reviewer, Err(ApiError::Forbidden)));

        let reviewed = service
            .review_appeal(
                appeal.id,
                campus_id,
                &independent_reviewer,
                good4ncu::services::moderation_case::AppealDecision::Overturn,
                "独立复核确认内容合规，恢复展示",
            )
            .await
            .expect("independent review");
        assert_eq!(reviewed.status, "overturned");
        let case_row = sqlx::query(
            "SELECT status, resolution, decided_by FROM moderation_cases WHERE id = $1",
        )
        .bind(case_id)
        .fetch_one(&pool)
        .await
        .expect("case after appeal");
        assert_eq!(sqlx::Row::get::<String, _>(&case_row, "status"), "resolved");
        assert_eq!(
            sqlx::Row::get::<Option<String>, _>(&case_row, "resolution").as_deref(),
            Some("restored")
        );
        assert_eq!(
            sqlx::Row::get::<Option<String>, _>(&case_row, "decided_by").as_deref(),
            Some(independent_reviewer.as_str())
        );
        let avatar_status: String =
            sqlx::query_scalar("SELECT avatar_moderation_status FROM users WHERE id = $1")
                .bind(&subject_id)
                .fetch_one(&pool)
                .await
                .expect("avatar status");
        assert_eq!(avatar_status, "approved");
    })
    .await;
}

/// Full TOTP MFA lifecycle for a platform admin: enroll, confirm, and from
/// then on the password step-up must demand a fresh single-use code.
#[tokio::test]
async fn admin_totp_mfa_gates_the_recent_authentication_step_up() {
    use argon2::password_hash::{rand_core::OsRng, PasswordHasher, SaltString};
    use argon2::Argon2;

    with_test_pool(|pool| async move {
        let suffix = uuid::Uuid::new_v4().simple().to_string();
        let admin_id = format!("mfa-admin-{suffix}");
        let password = "Str0ng-step-up-password";
        let password_hash = Argon2::default()
            .hash_password(password.as_bytes(), &SaltString::generate(&mut OsRng))
            .expect("hash password")
            .to_string();
        insert_user(&pool, &admin_id, &format!("mfa_admin_{suffix}"), "admin").await;
        sqlx::query("UPDATE users SET password_hash = $2 WHERE id = $1")
            .bind(&admin_id)
            .bind(&password_hash)
            .execute(&pool)
            .await
            .expect("set real password hash");

        let campus_id =
            uuid::Uuid::parse_str("c0000000-0000-0000-0000-000000000001").expect("ncu id");
        let now = chrono::Utc::now().timestamp();
        let (recent_token, _, _) = generate_access_token_for_campus_with_auth_time(
            &admin_id,
            "admin",
            Some(campus_id),
            Some(now),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("recent-auth admin token");
        let app = create_router(build_state(pool.clone()), &[]);

        let post_json = |uri: &str, token: &str, body: serde_json::Value| {
            Request::builder()
                .method("POST")
                .uri(uri.to_string())
                .header("Content-Type", "application/json")
                .header("Authorization", bearer(token))
                .body(Body::from(body.to_string()))
                .unwrap()
        };

        // Enroll: obtain the secret.
        let response = app
            .clone()
            .oneshot(post_json(
                "/api/auth/mfa/totp/setup",
                &recent_token,
                serde_json::json!({}),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK, "setup should succeed");
        let setup: serde_json::Value = serde_json::from_slice(
            &to_bytes(response.into_body(), usize::MAX)
                .await
                .expect("setup body"),
        )
        .expect("setup json");
        let secret = setup["secret_base32"].as_str().expect("secret").to_string();
        assert!(setup["otpauth_uri"]
            .as_str()
            .expect("uri")
            .starts_with("otpauth://totp/"));

        // Before confirmation the password step-up must NOT demand a code —
        // a half-finished enrollment must never lock the admin out.
        let response = app
            .clone()
            .oneshot(post_json(
                "/api/auth/reauth",
                &recent_token,
                serde_json::json!({ "password": password }),
            ))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::OK,
            "unconfirmed enrollment must not be enforced"
        );

        // Confirm possession with a valid code.
        let now = chrono::Utc::now().timestamp();
        let code = good4ncu::services::totp::code_at(&secret, now).expect("code");
        let response = app
            .clone()
            .oneshot(post_json(
                "/api/auth/mfa/totp/confirm",
                &recent_token,
                serde_json::json!({ "code": code }),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK, "confirm should succeed");

        // Enrollment is now locked: a session cannot swap in a new secret.
        let response = app
            .clone()
            .oneshot(post_json(
                "/api/auth/mfa/totp/setup",
                &recent_token,
                serde_json::json!({}),
            ))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::CONFLICT,
            "confirmed factor must not be self-service replaceable"
        );

        // Password alone no longer opens the sensitive-write window.
        let response = app
            .clone()
            .oneshot(post_json(
                "/api/auth/reauth",
                &recent_token,
                serde_json::json!({ "password": password }),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        let body: serde_json::Value = serde_json::from_slice(
            &to_bytes(response.into_body(), usize::MAX)
                .await
                .expect("mfa body"),
        )
        .expect("mfa json");
        assert_eq!(body["code"], "mfa_required");

        // A wrong code fails without opening the window.
        let response = app
            .clone()
            .oneshot(post_json(
                "/api/auth/reauth",
                &recent_token,
                serde_json::json!({ "password": password, "totp_code": "000000" }),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);

        // A fresh, unconsumed code completes the step-up. Which time step the
        // confirm call consumed depends on where the wall clock fell relative
        // to the 30s TOTP grid, so try successive future steps — failed
        // attempts consume nothing, and exactly one candidate must succeed.
        let mut accepted_code = None;
        for offset in [30i64, 60, 90] {
            let now = chrono::Utc::now().timestamp();
            let candidate =
                good4ncu::services::totp::code_at(&secret, now + offset).expect("candidate code");
            let response = app
                .clone()
                .oneshot(post_json(
                    "/api/auth/reauth",
                    &recent_token,
                    serde_json::json!({ "password": password, "totp_code": candidate }),
                ))
                .await
                .unwrap();
            if response.status() == StatusCode::OK {
                accepted_code = Some(candidate);
                break;
            }
            assert_eq!(
                response.status(),
                StatusCode::UNAUTHORIZED,
                "a non-matching candidate must fail closed"
            );
        }
        let accepted_code = accepted_code.expect("one future-step code must complete the step-up");

        // The same code cannot be replayed.
        let response = app
            .clone()
            .oneshot(post_json(
                "/api/auth/reauth",
                &recent_token,
                serde_json::json!({ "password": password, "totp_code": accepted_code }),
            ))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::UNAUTHORIZED,
            "a consumed TOTP code must be rejected on replay"
        );
    })
    .await;
}

/// Ordinary users cannot touch admin MFA enrollment, and stale admin sessions
/// must re-authenticate before changing an authentication factor.
#[tokio::test]
async fn totp_enrollment_requires_recent_admin_authentication() {
    with_test_pool(|pool| async move {
        let suffix = uuid::Uuid::new_v4().simple().to_string();
        let user_id = format!("mfa-user-{suffix}");
        let admin_id = format!("mfa-stale-admin-{suffix}");
        insert_user(&pool, &user_id, &format!("mfa_user_{suffix}"), "user").await;
        insert_user(&pool, &admin_id, &format!("mfa_stale_{suffix}"), "admin").await;
        let campus_id =
            uuid::Uuid::parse_str("c0000000-0000-0000-0000-000000000001").expect("ncu id");
        let now = chrono::Utc::now().timestamp();
        let (user_token, _, _) = generate_access_token_for_campus_with_auth_time(
            &user_id,
            "user",
            Some(campus_id),
            Some(now),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("user token");
        let (stale_admin_token, _, _) = generate_access_token_for_campus_with_auth_time(
            &admin_id,
            "admin",
            Some(campus_id),
            None, // no recent authentication
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("stale admin token");
        let app = create_router(build_state(pool.clone()), &[]);

        for (token, expected, label) in [
            (&user_token, StatusCode::FORBIDDEN, "ordinary user"),
            (
                &stale_admin_token,
                StatusCode::FORBIDDEN,
                "admin without recent auth",
            ),
        ] {
            let response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/api/auth/mfa/totp/setup")
                        .header("Content-Type", "application/json")
                        .header("Authorization", bearer(token))
                        .body(Body::from("{}"))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), expected, "{label}");
        }
    })
    .await;
}

/// Second-campus onboarding journey (Phase 4): platform admin creates a dark
/// campus, activates it, a student registers with that campus's email, lands
/// as its pending member, verifies via OTP, publishes there — and the NCU
/// public surface never sees any of it. Deactivation shuts the door again.
#[tokio::test]
async fn second_campus_onboarding_journey_end_to_end() {
    with_test_pool(|pool| async move {
        let suffix = uuid::Uuid::new_v4().simple().to_string();
        let admin_id = format!("onboard-admin-{suffix}");
        insert_user(&pool, &admin_id, &format!("onboard_admin_{suffix}"), "admin").await;
        let ncu_id =
            uuid::Uuid::parse_str("c0000000-0000-0000-0000-000000000001").expect("ncu id");
        let now = chrono::Utc::now().timestamp();
        let (admin_token, _, _) = generate_access_token_for_campus_with_auth_time(
            &admin_id,
            "admin",
            Some(ncu_id),
            Some(now),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("admin token");
        let app = create_router(build_state(pool.clone()), &[]);

        let json_req = |method: &str, uri: String, token: &str, body: serde_json::Value| {
            Request::builder()
                .method(method)
                .uri(uri)
                .header("Content-Type", "application/json")
                .header("Authorization", bearer(token))
                .body(Body::from(body.to_string()))
                .unwrap()
        };
        let body_json = |response: axum::response::Response| async move {
            let bytes = to_bytes(response.into_body(), usize::MAX).await.expect("body");
            serde_json::from_slice::<serde_json::Value>(&bytes).expect("json")
        };

        // 1. Create the campus — it starts dark (inactive).
        let slug = format!("buni-{}", &suffix[..8]);
        let domain = format!("stu.{}.edu.cn", &suffix[..8]);
        let response = app
            .clone()
            .oneshot(json_req(
                "POST",
                "/api/admin/campuses".to_string(),
                &admin_token,
                serde_json::json!({
                    "slug": slug,
                    "name_zh": "B 大学",
                    "name_en": "B University",
                    "email_domains": [domain],
                }),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let created = body_json(response).await;
        assert_eq!(created["status"], "inactive");
        let campus_id = created["id"].as_str().expect("campus id").to_string();

        // 2. Dark campus: not publicly listed, registration with its domain refused.
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/campuses")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let listed = body_json(response).await;
        assert!(
            !listed.to_string().contains(&slug),
            "inactive campus must not be publicly listed"
        );
        let student_email = format!("20260001@{domain}");
        let response = app
            .clone()
            .oneshot(json_req(
                "POST",
                "/api/auth/register".to_string(),
                "",
                serde_json::json!({
                    "username": format!("b_student_{suffix}"),
                    "email": student_email,
                    "password": "B-campus-pass1",
                }),
            ))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::BAD_REQUEST,
            "registration against an inactive campus must be refused"
        );

        // 3. Activate (audited) — campus becomes publicly listed.
        let response = app
            .clone()
            .oneshot(json_req(
                "POST",
                format!("/api/admin/campuses/{campus_id}/activate"),
                &admin_token,
                serde_json::json!({}),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let audit: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM admin_audit_logs WHERE action = 'set_campus_status' AND target_id = $1",
        )
        .bind(&campus_id)
        .fetch_one(&pool)
        .await
        .expect("audit");
        assert_eq!(audit, 1, "status flips must be audited");

        // 4. Student registers with the campus email and lands pending in B.
        let response = app
            .clone()
            .oneshot(json_req(
                "POST",
                "/api/auth/register".to_string(),
                "",
                serde_json::json!({
                    "username": format!("b_student_{suffix}"),
                    "email": student_email,
                    "password": "B-campus-pass1",
                }),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let registered = body_json(response).await;
        let student_token = registered["token"].as_str().expect("token").to_string();
        let student_id = registered["user_id"].as_str().expect("user id").to_string();
        let (membership_id, membership_campus, membership_status): (uuid::Uuid, uuid::Uuid, String) =
            sqlx::query_as(
                "SELECT id, campus_id, status FROM campus_memberships WHERE user_id = $1",
            )
            .bind(&student_id)
            .fetch_one(&pool)
            .await
            .map_err(|e| panic!("membership: {e}"))
            .unwrap();
        assert_eq!(membership_campus.to_string(), campus_id, "membership must route to campus B");
        assert_eq!(membership_status, "pending");

        // 5. Pending member cannot publish yet.
        let listing_body = serde_json::json!({
            "title": "B Campus Bike",
            "category": "other",
            "brand": "Brand",
            "condition_score": 8,
            "suggested_price_cny": 100.0,
            "defects": [],
        });
        let response = app
            .clone()
            .oneshot(json_req(
                "POST",
                "/api/listings".to_string(),
                &student_token,
                listing_body.clone(),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);

        // 6. OTP verification (challenge seeded exactly as the delivery flow
        //    stores it), then the verified member publishes in campus B.
        let challenge_id = uuid::Uuid::new_v4();
        let code = "654321";
        let code_hash = good4ncu::services::campus::verification_code_hash(
            "test_jwt_secret_at_least_32_characters_long",
            challenge_id,
            code,
        )
        .expect("hash");
        sqlx::query(
            "INSERT INTO campus_verification_challenges (
                id, membership_id, email, code_hash, delivery_status, expires_at
             ) VALUES ($1, $2, $3, $4, 'sent', NOW() + INTERVAL '5 minutes')",
        )
        .bind(challenge_id)
        .bind(membership_id)
        .bind(&student_email)
        .bind(code_hash)
        .execute(&pool)
        .await
        .expect("challenge");
        let response = app
            .clone()
            .oneshot(json_req(
                "POST",
                format!("/api/user/campus-memberships/{membership_id}/verification/confirm"),
                &student_token,
                serde_json::json!({ "code": code }),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK, "OTP confirm must verify membership");

        let response = app
            .clone()
            .oneshot(json_req(
                "POST",
                "/api/listings".to_string(),
                &student_token,
                listing_body,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK, "verified member publishes in B");
        let listing_campus: uuid::Uuid = sqlx::query_scalar(
            "SELECT campus_id FROM inventory WHERE title = 'B Campus Bike'",
        )
        .fetch_one(&pool)
        .await
        .expect("listing campus");
        assert_eq!(listing_campus.to_string(), campus_id);

        // 7. The NCU public surface never sees campus B's listing.
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/listings?limit=100")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let public = body_json(response).await;
        assert!(
            !public.to_string().contains("B Campus Bike"),
            "cross-campus leak into the NCU public surface"
        );

        // 8. Deactivation closes the door: protected writes stop immediately.
        let response = app
            .clone()
            .oneshot(json_req(
                "POST",
                format!("/api/admin/campuses/{campus_id}/deactivate"),
                &admin_token,
                serde_json::json!({}),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let response = app
            .clone()
            .oneshot(json_req(
                "POST",
                "/api/listings".to_string(),
                &student_token,
                serde_json::json!({
                    "title": "After deactivation",
                    "category": "other",
                    "brand": "Brand",
                    "condition_score": 8,
                    "suggested_price_cny": 100.0,
                    "defects": [],
                }),
            ))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::FORBIDDEN,
            "a deactivated campus must stop accepting writes"
        );
    })
    .await;
}
