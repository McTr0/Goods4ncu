use axum::body::Body;
use axum::http::{Request, StatusCode};
use good4ncu::agents::router::IntentRouter;
use good4ncu::api::auth::generate_access_token;
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
                },
            ),
            token_denylist: services::token_denylist::TokenDenylist::new(),
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
            ("GET", "/api/admin/stats"),
            ("GET", "/api/admin/users"),
            ("GET", "/api/admin/listings"),
            ("GET", "/api/admin/orders"),
            ("GET", "/api/admin/audit-logs"),
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
