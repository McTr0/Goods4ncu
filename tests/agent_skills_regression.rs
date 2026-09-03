//! Regression tests for user agent skills: PATCH validation parity with
//! POST, per-user count/prompt budgets, and cascade cleanup on user delete.

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

async fn seed_verified_user(pool: &sqlx::PgPool) -> (String, String) {
    let user_id = Uuid::new_v4().to_string();
    sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
        .bind(&user_id)
        .bind(format!("skill_user_{}", Uuid::new_v4()))
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

async fn post_skill(app: &axum::Router, token: &str, body: Value) -> (StatusCode, Value) {
    let request = Request::builder()
        .method("POST")
        .uri("/api/agent/skills")
        .header("Content-Type", "application/json")
        .header("Authorization", bearer(token))
        .body(Body::from(body.to_string()))
        .unwrap();
    let response = app.clone().oneshot(request).await.expect("response");
    let status = response.status();
    (status, response_json(response).await)
}

async fn patch_skill(
    app: &axum::Router,
    token: &str,
    id: &str,
    body: Value,
) -> (StatusCode, Value) {
    let request = Request::builder()
        .method("PATCH")
        .uri(format!("/api/agent/skills/{id}"))
        .header("Content-Type", "application/json")
        .header("Authorization", bearer(token))
        .body(Body::from(body.to_string()))
        .unwrap();
    let response = app.clone().oneshot(request).await.expect("response");
    let status = response.status();
    (status, response_json(response).await)
}

#[tokio::test]
async fn patch_validates_instructions_like_post() {
    with_test_pool(|pool| async move {
        let (_user_id, token) = seed_verified_user(&pool).await;
        let app = create_router(build_state(pool), &[]);

        let (_, created) = post_skill(
            &app,
            &token,
            json!({"name": "砍价", "instructions": "友善砍价"}),
        )
        .await;
        let id = created["skill"]["id"].as_str().unwrap().to_string();

        // Overlong instructions must be a client error, not Internal.
        let overlong = "长".repeat(4001);
        let (status, _) = patch_skill(&app, &token, &id, json!({"instructions": overlong})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);

        // Empty-after-trim instructions are rejected as well.
        let (status, _) = patch_skill(&app, &token, &id, json!({"instructions": "   "})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);

        // Boundary value passes and is trimmed.
        let boundary = "好".repeat(4000);
        let (status, body) = patch_skill(
            &app,
            &token,
            &id,
            json!({"instructions": format!("{boundary}  ")}),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(
            body["skill"]["instructions"]
                .as_str()
                .unwrap()
                .chars()
                .count(),
            4000
        );

        // chip_label whitespace-only collapses to null instead of persisting.
        let (status, body) = patch_skill(&app, &token, &id, json!({"chip_label": "   "})).await;
        assert_eq!(status, StatusCode::OK);
        assert!(body["skill"]["chip_label"].is_null());
    })
    .await;
}

#[tokio::test]
async fn skill_count_budget_is_enforced_on_create() {
    with_test_pool(|pool| async move {
        let (_user_id, token) = seed_verified_user(&pool).await;
        let app = create_router(build_state(pool), &[]);

        for i in 0..20 {
            let (status, _) = post_skill(
                &app,
                &token,
                json!({"name": format!("技能{i:02}"), "instructions": "短指令"}),
            )
            .await;
            assert_eq!(status, StatusCode::OK, "skill {i} should be accepted");
        }

        let (status, body) = post_skill(
            &app,
            &token,
            json!({"name": "超出上限", "instructions": "短指令"}),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert!(body["message"].as_str().unwrap().contains("上限"));

        // Replacing an existing name still succeeds at the cap.
        let (status, _) = post_skill(
            &app,
            &token,
            json!({"name": "技能00", "instructions": "替换后的指令"}),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
    })
    .await;
}

#[tokio::test]
async fn enabled_prompt_budget_counts_only_enabled_skills() {
    with_test_pool(|pool| async move {
        let (_user_id, token) = seed_verified_user(&pool).await;
        let app = create_router(build_state(pool), &[]);

        // A+B+C land on 9_999 enabled chars, one short of the cap.
        for (name, instructions) in [
            ("A", "字".repeat(4000)),
            ("B", "字".repeat(4000)),
            ("C", "字".repeat(1999)),
        ] {
            let (status, _) = post_skill(
                &app,
                &token,
                json!({"name": name, "instructions": instructions}),
            )
            .await;
            assert_eq!(status, StatusCode::OK);
        }

        // Two more chars would tip the total past the cap.
        let (status, _) =
            post_skill(&app, &token, json!({"name": "D", "instructions": "yy"})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);

        // Growing C onto exactly 10_000 still passes the boundary.
        let skills: Vec<Value> = {
            let request = Request::builder()
                .method("GET")
                .uri("/api/agent/skills")
                .header("Authorization", bearer(&token))
                .body(Body::empty())
                .unwrap();
            let response = app.clone().oneshot(request).await.unwrap();
            let body = response_json(response).await;
            body["skills"].as_array().cloned().unwrap_or_default()
        };
        let c_id = skills.iter().find(|s| s["name"] == "C").unwrap()["id"]
            .as_str()
            .unwrap()
            .to_string();
        let b_id = skills.iter().find(|s| s["name"] == "B").unwrap()["id"]
            .as_str()
            .unwrap()
            .to_string();
        let (status, _) = patch_skill(
            &app,
            &token,
            &c_id,
            json!({"instructions": "x".repeat(2000)}),
        )
        .await;
        assert_eq!(status, StatusCode::OK);

        // Now any additional enabled content must be rejected...
        let (status, _) = post_skill(&app, &token, json!({"name": "E", "instructions": "y"})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);

        // ...until disabling B frees its share.
        let (status, _) = patch_skill(&app, &token, &b_id, json!({"enabled": false})).await;
        assert_eq!(status, StatusCode::OK);

        let (status, _) = post_skill(
            &app,
            &token,
            json!({"name": "E", "instructions": "y".repeat(3999)}),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
    })
    .await;
}

#[tokio::test]
async fn deleting_a_user_cascades_their_skills() {
    with_test_pool(|pool| async move {
        let (user_id, _token) = seed_verified_user(&pool).await;

        let result = sqlx::query(
            "INSERT INTO user_agent_skills (user_id, name, instructions)
             VALUES ($1, '遗留技能', '内容')",
        )
        .bind(&user_id)
        .execute(&pool)
        .await
        .expect("insert orphan candidate");

        assert_eq!(result.rows_affected(), 1);
        sqlx::query("DELETE FROM users WHERE id = $1")
            .bind(&user_id)
            .execute(&pool)
            .await
            .expect("delete user");

        let remaining: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM user_agent_skills WHERE user_id = $1")
                .bind(&user_id)
                .fetch_one(&pool)
                .await
                .expect("count");
        assert_eq!(remaining, 0, "user deletion must cascade to skills");
    })
    .await;
}
