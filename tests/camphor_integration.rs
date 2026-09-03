//! Camphor leaf currency: daily grant idempotency and fertilize rules.

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use goods4ncu::api::auth::generate_access_token_for_campus;
use goods4ncu::api::{create_router, ApiAgents, ApiInfrastructure, ApiSecrets, AppState};
use goods4ncu::services::notification::NotificationService;
use goods4ncu::test_infra::with_test_pool;
use serde_json::{json, Value};
use std::sync::Arc;
use tower::ServiceExt;
use uuid::Uuid;

fn bearer(value: &str) -> String {
    format!("Bearer {}", value)
}

async fn response_json(response: axum::response::Response) -> Value {
    let bytes = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    serde_json::from_slice(&bytes).unwrap_or(Value::Null)
}

async fn seed_user(pool: &sqlx::PgPool, username: &str) -> (String, String) {
    let user_id = Uuid::new_v4().to_string();
    sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
        .bind(&user_id)
        .bind(format!("{username}-{}", Uuid::new_v4()))
        .execute(pool)
        .await
        .expect("insert user");
    sqlx::query(
        "INSERT INTO campus_memberships (campus_id, user_id, status, verification_method, verified_at)
         SELECT id, $1, 'verified', 'test_fixture', NOW()
         FROM campuses WHERE slug = 'ncu'
         ON CONFLICT (campus_id, user_id) DO NOTHING",
    )
    .bind(&user_id)
    .execute(pool)
    .await
    .expect("membership");
    let campus_id: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
        .fetch_one(pool)
        .await
        .expect("campus");
    let token = generate_access_token_for_campus(
        &user_id,
        "user",
        Some(campus_id),
        "test_jwt_secret_at_least_32_characters_long",
        3600,
    )
    .expect("token");
    (user_id, token.0)
}

fn build_state(pool: sqlx::PgPool) -> AppState {
    let admin_service = goods4ncu::services::admin::AdminService::new(pool.clone());
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
            rate_limit: {
                let factory =
                    goods4ncu::middleware::rate_limit::RateLimiterFactory::new(10_000, 60);
                goods4ncu::middleware::rate_limit::RateLimitStateHandle::new(factory.build_local())
            },
            notification: NotificationService::new(pool.clone()),
            ws_connections: goods4ncu::api::ws::new_ws_state(),
            metrics: Arc::new(goods4ncu::api::metrics::MetricsService::new()),
            order_service: goods4ncu::services::order::OrderService::new(pool.clone()),
            admin_service,
            moderation: goods4ncu::services::moderation::ModerationService::new_for_test(false),
            token_denylist: goods4ncu::services::token_denylist::TokenDenylist::new(),
            media_signer: None,
            shutdown: goods4ncu::lifecycle::ShutdownSignal::never(),
        },
        agents: ApiAgents {
            llm_provider: Arc::new(
                goods4ncu::llm::gemini::GeminiProvider::new("test-key", 768)
                    .expect("gemini provider init"),
            ),
            tri_tier_router: goods4ncu::agents::router::TriTierIntentRouter::new(
                goods4ncu::agents::router::IntentRouter::new(vec![]),
                None,
                None,
            ),
            router: goods4ncu::agents::router::IntentRouter::new(vec![]),
            agent_enabled: true,
        },
        listing_repo: goods4ncu::repositories::PostgresListingRepository::new(pool.clone()),
        user_repo: goods4ncu::repositories::PostgresUserRepository::new(pool.clone()),
        auth_repo: goods4ncu::repositories::PostgresAuthRepository::new(pool.clone()),
        order_repo: goods4ncu::repositories::PostgresOrderRepository::new(pool),
    }
}

async fn create_discussion_post(app: &axum::Router, token: &str, title: &str) -> String {
    let request = Request::builder()
        .method("POST")
        .uri("/api/posts")
        .header("Content-Type", "application/json")
        .header("Authorization", bearer(token))
        .body(Body::from(
            json!({"title": title, "body": "正文", "category": "discussion"}).to_string(),
        ))
        .unwrap();
    let response = app.clone().oneshot(request).await.expect("response");
    assert_eq!(response.status(), StatusCode::OK);
    let body = response_json(response).await;
    body["id"].as_str().unwrap().to_string()
}

#[tokio::test]
async fn daily_grant_settles_once_and_reports_balance() {
    with_test_pool(|pool| async move {
        let pool = pool.clone();
        let _ = &pool;
        let (_uid, token) = seed_user(&pool, "leaf-farmer").await;
        let app = create_router(build_state(pool.clone()), &[]);

        for expected in [1i64, 1, 1] {
            let request = Request::builder()
                .method("GET")
                .uri("/api/camphor")
                .header("Authorization", bearer(&token))
                .body(Body::empty())
                .unwrap();
            let response = app.clone().oneshot(request).await.expect("response");
            assert_eq!(response.status(), StatusCode::OK);
            let body = response_json(response).await;
            assert_eq!(body["balance"].as_i64().unwrap(), expected);
            assert_eq!(body["granted_today"], json!(true));
        }

        // Exactly one ledger row despite three calls.
        let grants: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM camphor_ledger WHERE reason = 'daily_grant'")
                .fetch_one(&pool)
                .await
                .expect("count");
        assert_eq!(grants, 1);
    })
    .await;
}

#[tokio::test]
async fn fertilize_follows_coin_rules() {
    with_test_pool(|pool| async move {
        let pool = pool.clone();
        let _ = &pool;
        let (_author_id, author_token) = seed_user(&pool, "post-author").await;
        let (_fan_id, fan_token) = seed_user(&pool, "leaf-fan").await;
        let app = create_router(build_state(pool.clone()), &[]);

        let post_id = create_discussion_post(&app, &author_token, "求推荐自习室").await;

        // Author cannot fertilize their own post.
        let request = Request::builder()
            .method("POST")
            .uri(format!("/api/posts/{post_id}/fertilize"))
            .header("Authorization", bearer(&author_token))
            .body(Body::empty())
            .unwrap();
        let response = app.clone().oneshot(request).await.expect("response");
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);

        // Fan settles the daily grant (+1) then fertilizes (-1).
        let request = Request::builder()
            .method("GET")
            .uri("/api/camphor")
            .header("Authorization", bearer(&fan_token))
            .body(Body::empty())
            .unwrap();
        let response = app.clone().oneshot(request).await.expect("response");
        assert_eq!(response.status(), StatusCode::OK);

        let request = Request::builder()
            .method("POST")
            .uri(format!("/api/posts/{post_id}/fertilize"))
            .header("Authorization", bearer(&fan_token))
            .body(Body::empty())
            .unwrap();
        let response = app.clone().oneshot(request).await.expect("response");
        assert_eq!(response.status(), StatusCode::OK);
        let body = response_json(response).await;
        assert_eq!(body["balance"].as_i64().unwrap(), 0);
        assert_eq!(body["fertilizer_count"].as_i64().unwrap(), 1);

        // Second fertilize attempt fails; counter unchanged.
        let request = Request::builder()
            .method("POST")
            .uri(format!("/api/posts/{post_id}/fertilize"))
            .header("Authorization", bearer(&fan_token))
            .body(Body::empty())
            .unwrap();
        let response = app.clone().oneshot(request).await.expect("response");
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);

        let count: i32 =
            sqlx::query_scalar("SELECT fertilizer_count FROM posts WHERE id = $1::uuid")
                .bind(&post_id)
                .fetch_one(&pool)
                .await
                .expect("count");
        assert_eq!(count, 1);

        // A second fan without leaves gets the insufficient-balance error.
        let (_broke_id, broke_token) = seed_user(&pool, "no-leaves").await;
        let request = Request::builder()
            .method("POST")
            .uri(format!("/api/posts/{post_id}/fertilize"))
            .header("Authorization", bearer(&broke_token))
            .body(Body::empty())
            .unwrap();
        let response = app.clone().oneshot(request).await.expect("response");
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let body = response_json(response).await;
        assert!(body["message"].as_str().unwrap().contains("香樟叶不足"));
    })
    .await;
}
