use argon2::{
    password_hash::{rand_core::OsRng, PasswordHasher, SaltString},
    Argon2,
};
use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use good4ncu::agents::router::IntentRouter;
use good4ncu::api::auth::generate_access_token;
use good4ncu::api::{create_router, ApiAgents, ApiInfrastructure, ApiSecrets, AppState};
use good4ncu::repositories::{
    PostgresAuthRepository, PostgresChatRepository, PostgresListingRepository,
    PostgresOrderRepository, PostgresUserRepository,
};
use good4ncu::services::{self, notification::NotificationService};
use good4ncu::test_infra::with_test_pool;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use sqlx::Row;
use std::sync::Arc;
use tower::ServiceExt;
use uuid::Uuid;

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

fn hash_password(password: &str) -> String {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .expect("hash password")
        .to_string()
}

async fn response_json(response: axum::response::Response) -> Value {
    let bytes = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("read response body");
    serde_json::from_slice(&bytes).expect("parse response json")
}

async fn insert_user(
    pool: &sqlx::PgPool,
    id: &str,
    username: &str,
    password_hash: &str,
    role: &str,
    status: &str,
) {
    sqlx::query(
        "INSERT INTO users (id, username, password_hash, role, status) VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(id)
    .bind(username)
    .bind(password_hash)
    .bind(role)
    .bind(status)
    .execute(pool)
    .await
    .expect("insert user");
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

struct HitlRequestFixture<'a> {
    id: &'a str,
    listing_id: &'a str,
    buyer_id: &'a str,
    seller_id: &'a str,
    proposed_price: i64,
    status: &'a str,
    counter_price: Option<i64>,
}

async fn insert_hitl_request(pool: &sqlx::PgPool, fixture: HitlRequestFixture<'_>) {
    sqlx::query(
        "INSERT INTO hitl_requests (id, listing_id, buyer_id, seller_id, proposed_price, reason, status, counter_price) \
         VALUES ($1, $2, $3, $4, $5, 'test negotiation', $6, $7)",
    )
    .bind(fixture.id)
    .bind(fixture.listing_id)
    .bind(fixture.buyer_id)
    .bind(fixture.seller_id)
    .bind(fixture.proposed_price)
    .bind(fixture.status)
    .bind(fixture.counter_price)
    .execute(pool)
    .await
    .expect("insert hitl request");
}

async fn insert_connection(
    pool: &sqlx::PgPool,
    connection_id: Uuid,
    requester_id: &str,
    receiver_id: &str,
    status: &str,
) {
    sqlx::query(
        "INSERT INTO chat_connections (id, requester_id, receiver_id, status) VALUES ($1, $2, $3, $4)",
    )
    .bind(connection_id)
    .bind(requester_id)
    .bind(receiver_id)
    .bind(status)
    .execute(pool)
    .await
    .expect("insert connection");
}

async fn insert_refresh_token(pool: &sqlx::PgPool, user_id: &str, token: &str) {
    let expires_at = chrono::Utc::now() + chrono::Duration::hours(1);
    sqlx::query("INSERT INTO refresh_tokens (user_id, token_hash, expires_at) VALUES ($1, $2, $3)")
        .bind(user_id)
        .bind(hash_refresh_token(token))
        .bind(expires_at)
        .execute(pool)
        .await
        .expect("insert refresh token");
}

async fn insert_chat_message(
    pool: &sqlx::PgPool,
    conversation_id: &str,
    listing_id: &str,
    sender: &str,
    receiver: &str,
    content: &str,
) {
    sqlx::query(
        "INSERT INTO chat_messages (conversation_id, listing_id, sender, receiver, is_agent, content) \
         VALUES ($1, $2, $3, $4, false, $5)",
    )
    .bind(conversation_id)
    .bind(listing_id)
    .bind(sender)
    .bind(receiver)
    .bind(content)
    .execute(pool)
    .await
    .expect("insert chat message");
}

#[tokio::test]
async fn logout_revokes_access_token_and_blocks_reuse() {
    with_test_pool(|pool| async move {
        insert_user(
            &pool,
            "logout-user-1",
            "logout_user",
            &hash_password("password123"),
            "user",
            "active",
        )
        .await;

        let state = build_state(pool.clone());
        let app = create_router(state, &[]);

        let (token, jti, _exp) = generate_access_token(
            "logout-user-1",
            "user",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("generate access token");

        let req = Request::builder()
            .method("POST")
            .uri("/api/auth/logout")
            .header("Authorization", bearer(&token))
            .header("Content-Type", "application/json")
            .body(Body::from(json!({ "refresh_token": null }).to_string()))
            .unwrap();

        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        let revoked_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM revoked_access_tokens WHERE jti = $1")
                .bind(&jti)
                .fetch_one(&pool)
                .await
                .expect("count revoked access tokens");
        assert_eq!(revoked_count, 1);

        let req = Request::builder()
            .method("POST")
            .uri("/api/auth/logout")
            .header("Authorization", bearer(&token))
            .header("Content-Type", "application/json")
            .body(Body::from(json!({ "refresh_token": null }).to_string()))
            .unwrap();

        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    })
    .await;
}

#[tokio::test]
async fn banned_user_login_is_rejected() {
    with_test_pool(|pool| async move {
        insert_user(
            &pool,
            "banned-user-1",
            "banned_user",
            &hash_password("password123"),
            "user",
            "banned",
        )
        .await;

        let state = build_state(pool.clone());
        let app = create_router(state, &[]);

        let req = Request::builder()
            .method("POST")
            .uri("/api/auth/login")
            .header("Content-Type", "application/json")
            .body(Body::from(
                json!({
                    "username": "banned_user",
                    "password": "password123"
                })
                .to_string(),
            ))
            .unwrap();

        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

        let body = response_json(resp).await;
        assert_eq!(body["error"], "认证失败: 账号已被封禁");

        let refresh_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM refresh_tokens WHERE user_id = $1")
                .bind("banned-user-1")
                .fetch_one(&pool)
                .await
                .expect("count refresh tokens");
        assert_eq!(refresh_count, 0);
    })
    .await;
}

#[tokio::test]
async fn registration_rejects_malformed_ncu_email_local_part() {
    with_test_pool(|pool| async move {
        let state = build_state(pool.clone());
        let app = create_router(state, &[]);

        for (index, email) in [
            "@email.ncu.edu.cn",
            "student@@email.ncu.edu.cn",
            ".student@email.ncu.edu.cn",
            "student..name@email.ncu.edu.cn",
            "student name@email.ncu.edu.cn",
        ]
        .into_iter()
        .enumerate()
        {
            let username = format!("email_bad_{index}");
            let req = Request::builder()
                .method("POST")
                .uri("/api/auth/register")
                .header("Content-Type", "application/json")
                .body(Body::from(
                    json!({
                        "username": username,
                        "email": email,
                        "password": "password123"
                    })
                    .to_string(),
                ))
                .unwrap();

            let resp = app.clone().oneshot(req).await.unwrap();
            assert_eq!(resp.status(), StatusCode::BAD_REQUEST, "email={email}");
        }

        let created_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM users WHERE username LIKE 'email_bad_%'")
                .fetch_one(&pool)
                .await
                .expect("count malformed email users");
        assert_eq!(created_count, 0);
    })
    .await;
}

#[tokio::test]
async fn admin_ban_immediately_blocks_active_sessions_and_refresh() {
    with_test_pool(|pool| async move {
        insert_user(&pool, "ban-admin-1", "ban_admin", "hash", "admin", "active").await;
        insert_user(
            &pool,
            "ban-target-1",
            "ban_target",
            "hash",
            "user",
            "active",
        )
        .await;
        insert_refresh_token(&pool, "ban-target-1", "target-refresh-token").await;

        let state = build_state(pool.clone());
        let app = create_router(state, &[]);

        let (admin_token, _, _) = generate_access_token(
            "ban-admin-1",
            "admin",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("generate admin token");
        let (target_token, _, _) = generate_access_token(
            "ban-target-1",
            "user",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("generate target token");

        let req = Request::builder()
            .method("POST")
            .uri("/api/admin/users/ban-target-1/ban")
            .header("Authorization", bearer(&admin_token))
            .body(Body::empty())
            .unwrap();

        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        let active_refresh_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM refresh_tokens WHERE user_id = $1 AND revoked_at IS NULL",
        )
        .bind("ban-target-1")
        .fetch_one(&pool)
        .await
        .expect("count active refresh tokens");
        assert_eq!(active_refresh_count, 0);

        let req = Request::builder()
            .method("GET")
            .uri("/api/watchlist")
            .header("Authorization", bearer(&target_token))
            .body(Body::empty())
            .unwrap();

        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
        let body = response_json(resp).await;
        assert_eq!(body["error"], "认证失败: 账号已被封禁");

        let req = Request::builder()
            .method("POST")
            .uri("/api/auth/refresh")
            .header("Content-Type", "application/json")
            .body(Body::from(
                json!({ "refresh_token": "target-refresh-token" }).to_string(),
            ))
            .unwrap();

        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    })
    .await;
}

#[tokio::test]
async fn banned_user_chat_stream_is_rejected_before_llm_work() {
    with_test_pool(|pool| async move {
        insert_user(
            &pool,
            "banned-stream-1",
            "banned_stream",
            "hash",
            "user",
            "banned",
        )
        .await;

        let state = build_state(pool.clone());
        let app = create_router(state, &[]);
        let (token, _jti, _exp) = generate_access_token(
            "banned-stream-1",
            "user",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("generate banned user token");

        let req = Request::builder()
            .method("POST")
            .uri("/api/chat/stream")
            .header("Authorization", bearer(&token))
            .header("Content-Type", "application/json")
            .body(Body::from(json!({ "message": "hello" }).to_string()))
            .unwrap();

        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    })
    .await;
}

#[tokio::test]
async fn watchlist_rejects_own_listing() {
    with_test_pool(|pool| async move {
        insert_user(
            &pool,
            "watch-owner-1",
            "watch_owner",
            "hash",
            "user",
            "active",
        )
        .await;
        insert_listing(&pool, "watch-listing-1", "watch-owner-1", "active").await;

        let state = build_state(pool.clone());
        let app = create_router(state, &[]);
        let (token, _jti, _exp) = generate_access_token(
            "watch-owner-1",
            "user",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("generate access token");

        let req = Request::builder()
            .method("POST")
            .uri("/api/watchlist/watch-listing-1")
            .header("Authorization", bearer(&token))
            .body(Body::empty())
            .unwrap();

        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

        let watch_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM watchlist WHERE user_id = $1 AND listing_id = $2",
        )
        .bind("watch-owner-1")
        .bind("watch-listing-1")
        .fetch_one(&pool)
        .await
        .expect("count watchlist rows");
        assert_eq!(watch_count, 0);
    })
    .await;
}

#[tokio::test]
async fn seller_approval_creates_order_before_reporting_success() {
    with_test_pool(|pool| async move {
        insert_user(
            &pool,
            "nego-seller-1",
            "nego_seller",
            "hash",
            "user",
            "active",
        )
        .await;
        insert_user(
            &pool,
            "nego-buyer-1",
            "nego_buyer",
            "hash",
            "user",
            "active",
        )
        .await;
        insert_listing(&pool, "nego-listing-1", "nego-seller-1", "active").await;
        insert_hitl_request(
            &pool,
            HitlRequestFixture {
                id: "nego-request-1",
                listing_id: "nego-listing-1",
                buyer_id: "nego-buyer-1",
                seller_id: "nego-seller-1",
                proposed_price: 9_000,
                status: "pending",
                counter_price: None,
            },
        )
        .await;

        let state = build_state(pool.clone());
        let app = create_router(state, &[]);
        let (token, _jti, _exp) = generate_access_token(
            "nego-seller-1",
            "user",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("generate seller token");

        let req = Request::builder()
            .method("PATCH")
            .uri("/api/negotiations/nego-request-1/respond")
            .header("Authorization", bearer(&token))
            .header("Content-Type", "application/json")
            .body(Body::from(json!({ "action": "approve" }).to_string()))
            .unwrap();

        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let body = response_json(resp).await;
        assert_eq!(body["status"], "approved");

        let order = sqlx::query(
            "SELECT buyer_id, seller_id, final_price, status FROM orders WHERE listing_id = $1",
        )
        .bind("nego-listing-1")
        .fetch_one(&pool)
        .await
        .expect("select created order");
        assert_eq!(order.get::<String, _>("buyer_id"), "nego-buyer-1");
        assert_eq!(order.get::<String, _>("seller_id"), "nego-seller-1");
        assert_eq!(order.get::<i64, _>("final_price"), 9_000);
        assert_eq!(order.get::<String, _>("status"), "pending");

        let hitl = sqlx::query("SELECT status, resolved_at FROM hitl_requests WHERE id = $1")
            .bind("nego-request-1")
            .fetch_one(&pool)
            .await
            .expect("select hitl request");
        assert_eq!(hitl.get::<String, _>("status"), "approved");
        assert!(hitl
            .get::<Option<chrono::DateTime<chrono::Utc>>, _>("resolved_at")
            .is_some());

        let listing_status: String =
            sqlx::query_scalar("SELECT status FROM inventory WHERE id = $1")
                .bind("nego-listing-1")
                .fetch_one(&pool)
                .await
                .expect("select listing status");
        assert_eq!(listing_status, "sold");

        let system_messages: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM chat_messages WHERE listing_id = $1")
                .bind("nego-listing-1")
                .fetch_one(&pool)
                .await
                .expect("count system messages");
        assert_eq!(system_messages, 1);
    })
    .await;
}

#[tokio::test]
async fn seller_approval_rolls_back_when_order_cannot_be_created() {
    with_test_pool(|pool| async move {
        insert_user(
            &pool,
            "nego-sold-seller-1",
            "nego_sold_seller",
            "hash",
            "user",
            "active",
        )
        .await;
        insert_user(
            &pool,
            "nego-sold-buyer-1",
            "nego_sold_buyer",
            "hash",
            "user",
            "active",
        )
        .await;
        insert_listing(&pool, "nego-sold-listing-1", "nego-sold-seller-1", "sold").await;
        insert_hitl_request(
            &pool,
            HitlRequestFixture {
                id: "nego-sold-request-1",
                listing_id: "nego-sold-listing-1",
                buyer_id: "nego-sold-buyer-1",
                seller_id: "nego-sold-seller-1",
                proposed_price: 9_000,
                status: "pending",
                counter_price: None,
            },
        )
        .await;

        let state = build_state(pool.clone());
        let app = create_router(state, &[]);
        let (token, _jti, _exp) = generate_access_token(
            "nego-sold-seller-1",
            "user",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("generate seller token");

        let req = Request::builder()
            .method("PATCH")
            .uri("/api/negotiations/nego-sold-request-1/respond")
            .header("Authorization", bearer(&token))
            .header("Content-Type", "application/json")
            .body(Body::from(json!({ "action": "approve" }).to_string()))
            .unwrap();

        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::CONFLICT);

        let hitl = sqlx::query("SELECT status, resolved_at FROM hitl_requests WHERE id = $1")
            .bind("nego-sold-request-1")
            .fetch_one(&pool)
            .await
            .expect("select hitl request");
        assert_eq!(hitl.get::<String, _>("status"), "pending");
        assert!(hitl
            .get::<Option<chrono::DateTime<chrono::Utc>>, _>("resolved_at")
            .is_none());

        let order_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM orders WHERE listing_id = $1")
                .bind("nego-sold-listing-1")
                .fetch_one(&pool)
                .await
                .expect("count orders");
        assert_eq!(order_count, 0);

        let system_messages: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM chat_messages WHERE listing_id = $1")
                .bind("nego-sold-listing-1")
                .fetch_one(&pool)
                .await
                .expect("count system messages");
        assert_eq!(system_messages, 0);
    })
    .await;
}

#[tokio::test]
async fn buyer_accept_counter_creates_order_and_finalizes_negotiation() {
    with_test_pool(|pool| async move {
        insert_user(
            &pool,
            "nego-counter-seller-1",
            "nego_counter_seller",
            "hash",
            "user",
            "active",
        )
        .await;
        insert_user(
            &pool,
            "nego-counter-buyer-1",
            "nego_counter_buyer",
            "hash",
            "user",
            "active",
        )
        .await;
        insert_listing(
            &pool,
            "nego-counter-listing-1",
            "nego-counter-seller-1",
            "active",
        )
        .await;
        insert_hitl_request(
            &pool,
            HitlRequestFixture {
                id: "nego-counter-request-1",
                listing_id: "nego-counter-listing-1",
                buyer_id: "nego-counter-buyer-1",
                seller_id: "nego-counter-seller-1",
                proposed_price: 9_000,
                status: "countered",
                counter_price: Some(11_000),
            },
        )
        .await;

        let state = build_state(pool.clone());
        let app = create_router(state, &[]);
        let (token, _jti, _exp) = generate_access_token(
            "nego-counter-buyer-1",
            "user",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("generate buyer token");

        let req = Request::builder()
            .method("PATCH")
            .uri("/api/negotiations/nego-counter-request-1/accept")
            .header("Authorization", bearer(&token))
            .body(Body::empty())
            .unwrap();

        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let body = response_json(resp).await;
        assert_eq!(body["status"], "buyer_accepted");

        let order = sqlx::query(
            "SELECT buyer_id, seller_id, final_price, status FROM orders WHERE listing_id = $1",
        )
        .bind("nego-counter-listing-1")
        .fetch_one(&pool)
        .await
        .expect("select created order");
        assert_eq!(order.get::<String, _>("buyer_id"), "nego-counter-buyer-1");
        assert_eq!(order.get::<String, _>("seller_id"), "nego-counter-seller-1");
        assert_eq!(order.get::<i64, _>("final_price"), 11_000);
        assert_eq!(order.get::<String, _>("status"), "pending");

        let hitl = sqlx::query(
            "SELECT status, buyer_action, resolved_at FROM hitl_requests WHERE id = $1",
        )
        .bind("nego-counter-request-1")
        .fetch_one(&pool)
        .await
        .expect("select hitl request");
        assert_eq!(hitl.get::<String, _>("status"), "approved");
        assert_eq!(
            hitl.get::<Option<String>, _>("buyer_action").as_deref(),
            Some("accepted")
        );
        assert!(hitl
            .get::<Option<chrono::DateTime<chrono::Utc>>, _>("resolved_at")
            .is_some());

        let listing_status: String =
            sqlx::query_scalar("SELECT status FROM inventory WHERE id = $1")
                .bind("nego-counter-listing-1")
                .fetch_one(&pool)
                .await
                .expect("select listing status");
        assert_eq!(listing_status, "sold");
    })
    .await;
}

#[tokio::test]
async fn buyer_reject_counter_finalizes_negotiation_without_order() {
    with_test_pool(|pool| async move {
        insert_user(
            &pool,
            "nego-reject-seller-1",
            "nego_reject_seller",
            "hash",
            "user",
            "active",
        )
        .await;
        insert_user(
            &pool,
            "nego-reject-buyer-1",
            "nego_reject_buyer",
            "hash",
            "user",
            "active",
        )
        .await;
        insert_listing(
            &pool,
            "nego-reject-listing-1",
            "nego-reject-seller-1",
            "active",
        )
        .await;
        insert_hitl_request(
            &pool,
            HitlRequestFixture {
                id: "nego-reject-request-1",
                listing_id: "nego-reject-listing-1",
                buyer_id: "nego-reject-buyer-1",
                seller_id: "nego-reject-seller-1",
                proposed_price: 9_000,
                status: "countered",
                counter_price: Some(11_000),
            },
        )
        .await;

        let state = build_state(pool.clone());
        let app = create_router(state, &[]);
        let (token, _jti, _exp) = generate_access_token(
            "nego-reject-buyer-1",
            "user",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("generate buyer token");

        let req = Request::builder()
            .method("PATCH")
            .uri("/api/negotiations/nego-reject-request-1/reject")
            .header("Authorization", bearer(&token))
            .body(Body::empty())
            .unwrap();

        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let body = response_json(resp).await;
        assert_eq!(body["status"], "buyer_rejected");

        let hitl = sqlx::query(
            "SELECT status, buyer_action, resolved_at FROM hitl_requests WHERE id = $1",
        )
        .bind("nego-reject-request-1")
        .fetch_one(&pool)
        .await
        .expect("select hitl request");
        assert_eq!(hitl.get::<String, _>("status"), "rejected");
        assert_eq!(
            hitl.get::<Option<String>, _>("buyer_action").as_deref(),
            Some("rejected")
        );
        assert!(hitl
            .get::<Option<chrono::DateTime<chrono::Utc>>, _>("resolved_at")
            .is_some());

        let order_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM orders WHERE listing_id = $1")
                .bind("nego-reject-listing-1")
                .fetch_one(&pool)
                .await
                .expect("count orders");
        assert_eq!(order_count, 0);

        let listing_status: String =
            sqlx::query_scalar("SELECT status FROM inventory WHERE id = $1")
                .bind("nego-reject-listing-1")
                .fetch_one(&pool)
                .await
                .expect("select listing status");
        assert_eq!(listing_status, "active");

        let system_messages: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM chat_messages WHERE listing_id = $1")
                .bind("nego-reject-listing-1")
                .fetch_one(&pool)
                .await
                .expect("count system messages");
        assert_eq!(system_messages, 1);
    })
    .await;
}

#[tokio::test]
async fn typing_indicator_requires_connected_conversation() {
    with_test_pool(|pool| async move {
        insert_user(&pool, "typing-user-a", "typing_a", "hash", "user", "active").await;
        insert_user(&pool, "typing-user-b", "typing_b", "hash", "user", "active").await;

        let connection_id = Uuid::new_v4();
        insert_connection(
            &pool,
            connection_id,
            "typing-user-a",
            "typing-user-b",
            "pending",
        )
        .await;

        let state = build_state(pool.clone());
        let app = create_router(state, &[]);
        let (token, _jti, _exp) = generate_access_token(
            "typing-user-a",
            "user",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("generate access token");

        let req = Request::builder()
            .method("POST")
            .uri("/api/chat/typing")
            .header("Authorization", bearer(&token))
            .header("Content-Type", "application/json")
            .body(Body::from(
                json!({ "conversation_id": connection_id.to_string() }).to_string(),
            ))
            .unwrap();

        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    })
    .await;
}

#[tokio::test]
async fn conversation_messages_offset_is_applied_in_sql() {
    with_test_pool(|pool| async move {
        insert_user(&pool, "conv-user-a", "conv_a", "hash", "user", "active").await;
        insert_user(&pool, "conv-user-b", "conv_b", "hash", "user", "active").await;
        insert_listing(&pool, "conv-listing-1", "conv-user-a", "active").await;

        for content in ["msg-1", "msg-2", "msg-3", "msg-4", "msg-5"] {
            insert_chat_message(
                &pool,
                "legacy-conv-1",
                "conv-listing-1",
                "conv-user-a",
                "conv-user-b",
                content,
            )
            .await;
        }

        let state = build_state(pool.clone());
        let app = create_router(state, &[]);
        let (token, _jti, _exp) = generate_access_token(
            "conv-user-a",
            "user",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("generate access token");

        let req = Request::builder()
            .method("GET")
            .uri("/api/conversations/legacy-conv-1/messages?limit=2&offset=2")
            .header("Authorization", bearer(&token))
            .body(Body::empty())
            .unwrap();

        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        let body = response_json(resp).await;
        assert_eq!(body["total"], 5);
        assert_eq!(body["messages"].as_array().map(Vec::len), Some(2));
        assert_eq!(body["messages"][0]["content"], "msg-3");
        assert_eq!(body["messages"][1]["content"], "msg-2");
    })
    .await;
}
