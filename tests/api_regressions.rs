use argon2::{
    password_hash::{rand_core::OsRng, PasswordHasher, SaltString},
    Argon2,
};
use axum::body::{to_bytes, Body};
use axum::http::{Method, Request, StatusCode};
use goods4ncu::agents::router::IntentRouter;
use goods4ncu::api::auth::{generate_access_token, generate_access_token_for_campus};
use goods4ncu::api::{create_router, ApiAgents, ApiInfrastructure, ApiSecrets, AppState};
use goods4ncu::repositories::{
    CreateListingInput, PostgresAuthRepository, PostgresChatRepository, PostgresListingRepository,
    PostgresOrderRepository, PostgresUserRepository,
};
use goods4ncu::services::intent::slots::{PriceSlot, Slots};
use goods4ncu::services::intent::{kinds, status, IntentService, NewIntent};
use goods4ncu::services::{self, notification::NotificationService};
use goods4ncu::test_infra::{concurrent_test_pool, with_test_pool};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use sqlx::Row;
use std::sync::Arc;
use tower::ServiceExt;
use uuid::Uuid;

fn bearer(value: &str) -> String {
    format!("Bearer {}", value)
}

#[tokio::test]
async fn listing_and_image_job_roll_back_as_one_transaction() {
    with_test_pool(|pool| async move {
        let owner = Uuid::new_v4().to_string();
        insert_user(
            &pool,
            &owner,
            &format!("rollback-owner-{}", Uuid::new_v4()),
            "hash",
            "user",
            "active",
        )
        .await;
        let campus: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
            .fetch_one(&pool)
            .await
            .unwrap();
        let repo = PostgresListingRepository::new(pool.clone());
        let mut tx = pool.begin().await.unwrap();
        let created = repo
            .create_idempotent_in_tx(
                &mut tx,
                CreateListingInput {
                    campus_id: campus,
                    title: "Rollback image".into(),
                    category: "other".into(),
                    brand: Some("Test".into()),
                    direction: "offer".into(),
                    condition_score: 8,
                    suggested_price_cny: 100.0,
                    defects: vec![],
                    description: String::new(),
                    image_url: Some("https://cdn.example.com/rollback.jpg".into()),
                    owner_id: owner,
                },
                None,
                None,
            )
            .await
            .unwrap();
        let moderation = services::moderation::ModerationService::new_for_test(true);
        assert!(moderation
            .submit_image_job_in_tx(
                &mut tx,
                Uuid::new_v4(),
                &created.id,
                "https://cdn.example.com/rollback.jpg",
                "listing_image"
            )
            .await
            .is_err());
        tx.rollback().await.unwrap();
        let listings: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM inventory WHERE id = $1")
            .bind(&created.id)
            .fetch_one(&pool)
            .await
            .unwrap();
        let jobs: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM moderation_jobs WHERE resource_id = $1")
                .bind(&created.id)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!((listings, jobs), (0, 0));
    })
    .await;
}

#[tokio::test]
async fn listing_create_commits_one_quarantined_image_job_and_replays_without_duplicates() {
    with_test_pool(|pool| async move {
        let user_id = Uuid::new_v4().to_string();
        insert_user(
            &pool,
            &user_id,
            &format!("image-owner-{}", Uuid::new_v4()),
            "hash",
            "user",
            "active",
        )
        .await;
        let campus_id: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
            .fetch_one(&pool)
            .await
            .expect("campus");
        let (token, _, _) = generate_access_token_for_campus(
            &user_id,
            "user",
            Some(campus_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("token");
        let app = create_router(build_state_with_image_moderation(pool.clone(), true), &[]);
        let key = Uuid::new_v4().to_string();
        let body = json!({
            "title": "Atomic image listing", "category": "other", "brand": "Test",
            "condition_score": 8, "suggested_price_cny": 100.0, "defects": [],
            "image_url": "https://cdn.example.com/atomic.jpg"
        });
        let mut listing_id = String::new();
        for replayed in [false, true] {
            let request = Request::builder()
                .method("POST")
                .uri("/api/listings")
                .header("Content-Type", "application/json")
                .header("Authorization", bearer(&token))
                .header("Idempotency-Key", &key)
                .body(Body::from(body.to_string()))
                .unwrap();
            let response = app.clone().oneshot(request).await.expect("response");
            assert_eq!(response.status(), StatusCode::OK);
            let json = response_json(response).await;
            assert_eq!(json["replayed"], replayed);
            listing_id = json["id"].as_str().unwrap().to_string();
        }
        let status: String =
            sqlx::query_scalar("SELECT images_moderation_status FROM inventory WHERE id = $1")
                .bind(&listing_id)
                .fetch_one(&pool)
                .await
                .expect("status");
        let jobs: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM moderation_jobs WHERE resource_id = $1")
                .bind(&listing_id)
                .fetch_one(&pool)
                .await
                .expect("jobs");
        assert_eq!((status.as_str(), jobs), ("pending", 1));
    })
    .await;
}

#[tokio::test]
async fn listing_update_rejects_cross_campus_and_non_active_targets() {
    with_test_pool(|pool| async move {
        let owner = Uuid::new_v4().to_string();
        insert_user(&pool, &owner, &format!("update-owner-{}", Uuid::new_v4()), "hash", "user", "active").await;
        let ncu: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'").fetch_one(&pool).await.unwrap();
        let other = Uuid::new_v4();
        sqlx::query("INSERT INTO campuses (id, slug, name_zh, name_en, email_domains) VALUES ($1, $2, '其他', 'Other', ARRAY[]::TEXT[])")
            .bind(other).bind(format!("update-scope-{}", other.simple())).execute(&pool).await.unwrap();
        let cross = Uuid::new_v4().to_string();
        let inactive = Uuid::new_v4().to_string();
        for (id, campus, status) in [(&cross, other, "active"), (&inactive, ncu, "deleted")] {
            sqlx::query("INSERT INTO inventory (id, campus_id, title, category, brand, condition_score, suggested_price_cny, defects, owner_id, status) VALUES ($1,$2,'Original','other','Test',8,10000,'[]',$3,$4)")
                .bind(id).bind(campus).bind(&owner).bind(status).execute(&pool).await.unwrap();
        }
        let (token, _, _) = generate_access_token_for_campus(&owner, "user", Some(ncu), "test_jwt_secret_at_least_32_characters_long", 3600).unwrap();
        let app = create_router(build_state(pool.clone()), &[]);
        for (id, expected) in [(&cross, StatusCode::NOT_FOUND), (&inactive, StatusCode::CONFLICT)] {
            let (status, _) = authenticated_json(&app, Method::PUT, &format!("/api/listings/{id}"), &token, Some(json!({"title":"Changed"}))).await;
            assert_eq!(status, expected);
        }
        let changed: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM inventory WHERE owner_id = $1 AND title = 'Changed'")
            .bind(&owner).fetch_one(&pool).await.unwrap();
        assert_eq!(changed, 0);
    }).await;
}

fn hash_refresh_token(token: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(token.as_bytes());
    hex::encode(hasher.finalize())
}

fn build_state(pool: sqlx::PgPool) -> AppState {
    build_state_with_image_moderation(pool, false)
}

fn build_state_with_image_moderation(pool: sqlx::PgPool, image_enabled: bool) -> AppState {
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
                let factory = goods4ncu::middleware::rate_limit::RateLimiterFactory::new(100, 60);
                goods4ncu::middleware::rate_limit::RateLimitStateHandle::new(factory.build_local())
            },
            notification: NotificationService::new(pool.clone()),
            ws_connections: goods4ncu::api::ws::new_ws_state(),
            metrics: Arc::new(goods4ncu::api::metrics::MetricsService::new()),
            order_service: services::order::OrderService::new(pool.clone()),
            admin_service,
            moderation: services::moderation::ModerationService::new(
                &goods4ncu::config::AppConfig {
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
                    moderation_image_enabled: image_enabled,
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
            shutdown: goods4ncu::lifecycle::ShutdownSignal::never(),
        },
        agents: ApiAgents {
            llm_provider: Arc::new(
                goods4ncu::llm::gemini::GeminiProvider::new("test-key", 768)
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

async fn authenticated_json(
    app: &axum::Router,
    method: Method,
    uri: &str,
    token: &str,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let mut request = Request::builder()
        .method(method)
        .uri(uri)
        .header("Authorization", bearer(token));
    if body.is_some() {
        request = request.header("Content-Type", "application/json");
    }
    let response = app
        .clone()
        .oneshot(
            request
                .body(body.map_or_else(Body::empty, |value| Body::from(value.to_string())))
                .expect("request"),
        )
        .await
        .expect("response");
    let status = response.status();
    (status, response_json(response).await)
}

fn active_intent<'a>(
    campus_id: Uuid,
    author_id: &'a str,
    kind: &'a str,
    raw_input: &'a str,
    slots: Slots,
) -> NewIntent<'a> {
    NewIntent {
        campus_id,
        author_id,
        kind,
        raw_input,
        slots,
        confidence: 1.0,
        status: status::ACTIVE,
        visibility: "campus",
        valid_until: None,
    }
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

    sqlx::query(
        "INSERT INTO campus_memberships (
            campus_id, user_id, status, verification_method, verified_at
         )
         SELECT id, $1, 'verified', 'test_fixture', NOW()
         FROM campuses WHERE slug = 'ncu'
         ON CONFLICT (campus_id, user_id) DO NOTHING",
    )
    .bind(id)
    .execute(pool)
    .await
    .expect("insert test campus membership");
    sqlx::query(
        "INSERT INTO chat_connection_preferences (user_id, allow_strangers)
         VALUES ($1, TRUE)
         ON CONFLICT (user_id) DO UPDATE SET allow_strangers = TRUE",
    )
    .bind(id)
    .execute(pool)
    .await
    .expect("insert chat connection preferences");
}

#[tokio::test]
async fn active_campus_scopes_recommendations_and_public_user_pages() {
    with_test_pool(|pool| async move {
        let password_hash = hash_password("Test1234");
        let viewer_id = Uuid::new_v4().to_string();
        let ncu_owner_id = Uuid::new_v4().to_string();
        let other_owner_id = Uuid::new_v4().to_string();
        insert_user(
            &pool,
            &viewer_id,
            &format!("campus_viewer_{}", Uuid::new_v4()),
            &password_hash,
            "user",
            "active",
        )
        .await;
        insert_user(
            &pool,
            &ncu_owner_id,
            &format!("ncu_owner_{}", Uuid::new_v4()),
            &password_hash,
            "user",
            "active",
        )
        .await;
        insert_user(
            &pool,
            &other_owner_id,
            &format!("other_owner_{}", Uuid::new_v4()),
            &password_hash,
            "user",
            "active",
        )
        .await;

        let ncu_id: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
            .fetch_one(&pool)
            .await
            .expect("ncu campus");
        let other_campus_id = Uuid::new_v4();
        let other_slug = format!("api-campus-{}", &other_campus_id.to_string()[..8]);
        sqlx::query(
            "INSERT INTO campuses (id, slug, name_zh, name_en, email_domains)
             VALUES ($1, $2, '路由测试大学', 'Route Test University', ARRAY['route.test'])",
        )
        .bind(other_campus_id)
        .bind(&other_slug)
        .execute(&pool)
        .await
        .expect("insert second campus");

        for user_id in [&viewer_id, &other_owner_id] {
            sqlx::query(
                "INSERT INTO campus_memberships (
                    campus_id, user_id, status, verification_method, verified_at
                 ) VALUES ($1, $2, 'verified', 'test_fixture', NOW())",
            )
            .bind(other_campus_id)
            .bind(user_id)
            .execute(&pool)
            .await
            .expect("insert second campus membership");
        }

        let ncu_listing_id = Uuid::new_v4().to_string();
        let other_listing_id = Uuid::new_v4().to_string();
        for (id, campus_id, owner_id, title) in [
            (&ncu_listing_id, ncu_id, &ncu_owner_id, "NCU-only listing"),
            (
                &other_listing_id,
                other_campus_id,
                &other_owner_id,
                "Other-campus listing",
            ),
        ] {
            sqlx::query(
                "INSERT INTO inventory (
                    id, campus_id, title, category, brand, condition_score,
                    suggested_price_cny, defects, owner_id, status, direction
                 ) VALUES ($1, $2, $3, 'other', 'Test', 8, 10000, '[]', $4, 'active', 'offer')",
            )
            .bind(id)
            .bind(campus_id)
            .bind(title)
            .bind(owner_id)
            .execute(&pool)
            .await
            .expect("insert scoped listing");
        }

        let (token, _, _) = generate_access_token_for_campus(
            &viewer_id,
            "user",
            Some(other_campus_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("campus token");
        let app = create_router(build_state(pool.clone()), &[]);

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/recommendations/feed?direction=all")
                    .header("Authorization", bearer(&token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let feed = response_json(response).await;
        let feed_ids: Vec<&str> = feed["items"]
            .as_array()
            .expect("feed items")
            .iter()
            .filter_map(|item| item["id"].as_str())
            .collect();
        assert!(feed_ids.contains(&other_listing_id.as_str()));
        assert!(!feed_ids.contains(&ncu_listing_id.as_str()));

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri(format!("/api/users/{other_owner_id}"))
                    .header("Authorization", bearer(&token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let profile = response_json(response).await;
        assert_eq!(profile["listing_count"], 1);

        let response = app
            .oneshot(
                Request::builder()
                    .uri(format!("/api/users/{ncu_owner_id}"))
                    .header("Authorization", bearer(&token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    })
    .await;
}

#[tokio::test]
async fn moderation_cases_are_private_and_allow_one_safe_appeal() {
    with_test_pool(|pool| async move {
        let password_hash = hash_password("Test1234");
        let subject_id = Uuid::new_v4().to_string();
        let other_user_id = Uuid::new_v4().to_string();
        insert_user(
            &pool,
            &subject_id,
            &format!("case_subject_{}", Uuid::new_v4()),
            &password_hash,
            "user",
            "active",
        )
        .await;
        insert_user(
            &pool,
            &other_user_id,
            &format!("case_other_{}", Uuid::new_v4()),
            &password_hash,
            "user",
            "active",
        )
        .await;
        let campus_id: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
            .fetch_one(&pool)
            .await
            .expect("ncu campus");
        let case_id = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO moderation_cases (
                id, campus_id, subject_user_id, resource_type, resource_id,
                source_type, source_ref_id, status, reason_category,
                public_reason, internal_details, resolution, opened_by,
                decided_by, decided_at
             ) VALUES (
                $1, $2, $3, 'listing_image', $4, 'manual', $5,
                'actioned', 'image_policy', '图片未通过内容安全审核',
                '{\"matched_keyword\":\"internal-secret\"}'::jsonb,
                'content_restricted', $6, $6, NOW()
             )",
        )
        .bind(case_id)
        .bind(campus_id)
        .bind(&subject_id)
        .bind(format!("resource-{case_id}"))
        .bind(format!("manual-{case_id}"))
        .bind(&other_user_id)
        .execute(&pool)
        .await
        .expect("insert moderation case");

        let (subject_token, _, _) = generate_access_token_for_campus(
            &subject_id,
            "user",
            Some(campus_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("subject token");
        let (other_token, _, _) = generate_access_token_for_campus(
            &other_user_id,
            "user",
            Some(campus_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("other token");
        let app = create_router(build_state(pool.clone()), &[]);

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri(format!("/api/moderation/cases/{case_id}"))
                    .header("Authorization", bearer(&subject_token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body = response_json(response).await;
        assert_eq!(body["id"], case_id.to_string());
        assert_eq!(body["can_appeal"], true);
        assert!(body.get("internal_details").is_none());
        assert!(body.get("opened_by").is_none());
        assert!(body.get("decided_by").is_none());

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri(format!("/api/moderation/cases/{case_id}"))
                    .header("Authorization", bearer(&other_token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);

        let appeal_body = json!({
            "reason": "该图片是普通商品实拍，请重新进行人工审核。"
        });
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/moderation/cases/{case_id}/appeals"))
                    .header("Authorization", bearer(&subject_token))
                    .header("Content-Type", "application/json")
                    .body(Body::from(appeal_body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let appeal = response_json(response).await;
        assert_eq!(appeal["status"], "pending");
        assert!(appeal.get("reviewed_by").is_none());

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/moderation/cases/{case_id}/appeals"))
                    .header("Authorization", bearer(&subject_token))
                    .header("Content-Type", "application/json")
                    .body(Body::from(appeal_body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::CONFLICT);

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/api/moderation/cases")
                    .header("Authorization", bearer(&subject_token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let list = response_json(response).await;
        assert_eq!(list["items"][0]["status"], "appealed");
        assert_eq!(list["items"][0]["pending_appeal"], true);
        assert_eq!(list["items"][0]["can_appeal"], false);
    })
    .await;
}

#[tokio::test]
async fn listing_creation_requires_verified_campus_membership() {
    with_test_pool(|pool| async move {
        let user_id = Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO users (id, username, email, password_hash)
             VALUES ($1, $2, $3, 'hash')",
        )
        .bind(&user_id)
        .bind(format!("pending_listing_{}", Uuid::new_v4()))
        .bind("202600000010@email.ncu.edu.cn")
        .execute(&pool)
        .await
        .expect("pending user");
        let membership_id = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO campus_memberships (id, campus_id, user_id, status)
             SELECT $1, id, $2, 'pending' FROM campuses WHERE slug = 'ncu'",
        )
        .bind(membership_id)
        .bind(&user_id)
        .execute(&pool)
        .await
        .expect("pending membership");

        let (token, _, _) = generate_access_token(
            &user_id,
            "user",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("token");
        let app = create_router(build_state(pool.clone()), &[]);
        let body = json!({
            "title": "Campus gated listing",
            "category": "other",
            "brand": "Test",
            "condition_score": 8,
            "suggested_price_cny": 100.0,
            "defects": []
        });
        let request = Request::builder()
            .method("POST")
            .uri("/api/listings")
            .header("Content-Type", "application/json")
            .header("Authorization", bearer(&token))
            .header("Idempotency-Key", Uuid::new_v4().to_string())
            .body(Body::from(body.to_string()))
            .unwrap();
        let response = app.clone().oneshot(request).await.unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
        let error = response_json(response).await;
        assert_eq!(error["code"], "campus_verification_required");

        sqlx::query(
            "UPDATE campus_memberships
             SET status = 'verified', verification_method = 'test', verified_at = NOW()
             WHERE id = $1",
        )
        .bind(membership_id)
        .execute(&pool)
        .await
        .expect("verify membership");
        let request = Request::builder()
            .method("POST")
            .uri("/api/listings")
            .header("Content-Type", "application/json")
            .header("Authorization", bearer(&token))
            .header("Idempotency-Key", Uuid::new_v4().to_string())
            .body(Body::from(body.to_string()))
            .unwrap();
        let response = app.oneshot(request).await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
    })
    .await;
}

/// Object-storage credentials are a write capability and must be gated like
/// every other write path. A `pending` account cannot publish or contact
/// anyone; it must not be able to obtain bucket credentials either, or it can
/// use platform storage to host arbitrary content.
#[tokio::test]
async fn upload_token_requires_verified_campus_membership() {
    with_test_pool(|pool| async move {
        let user_id = Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO users (id, username, email, password_hash)
             VALUES ($1, $2, $3, 'hash')",
        )
        .bind(&user_id)
        .bind(format!("pending_upload_{}", Uuid::new_v4()))
        .bind("202600000011@email.ncu.edu.cn")
        .execute(&pool)
        .await
        .expect("pending user");
        let membership_id = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO campus_memberships (id, campus_id, user_id, status)
             SELECT $1, id, $2, 'pending' FROM campuses WHERE slug = 'ncu'",
        )
        .bind(membership_id)
        .bind(&user_id)
        .execute(&pool)
        .await
        .expect("pending membership");

        let app = create_router(build_state(pool.clone()), &[]);

        let anonymous = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/upload/token")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            anonymous.status(),
            StatusCode::UNAUTHORIZED,
            "guests must not receive storage credentials"
        );

        let (token, _, _) = generate_access_token(
            &user_id,
            "user",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("token");
        let pending = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/upload/token")
                    .header("Authorization", bearer(&token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            pending.status(),
            StatusCode::FORBIDDEN,
            "an unverified membership must not receive storage credentials"
        );
        let error = response_json(pending).await;
        assert_eq!(error["code"], "campus_verification_required");

        sqlx::query(
            "UPDATE campus_memberships
             SET status = 'verified', verification_method = 'test', verified_at = NOW()
             WHERE id = $1",
        )
        .bind(membership_id)
        .execute(&pool)
        .await
        .expect("verify membership");

        let verified = app
            .oneshot(
                Request::builder()
                    .uri("/api/upload/token")
                    .header("Authorization", bearer(&token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        // OSS is intentionally unconfigured in tests, so the request fails
        // later on missing config rather than on authorization. What matters is
        // that a verified member is no longer rejected by the campus gate.
        assert_ne!(verified.status(), StatusCode::UNAUTHORIZED);
        assert_ne!(
            verified.status(),
            StatusCode::FORBIDDEN,
            "a verified member must pass the campus gate"
        );
    })
    .await;
}

/// Secret Chat is deprecated: new sessions are refused unless a deployment
/// explicitly opts in, while message history on existing sessions stays
/// readable so nothing a user already wrote becomes inaccessible.
#[tokio::test]
async fn secret_chat_creation_is_disabled_by_default_but_history_stays_readable() {
    with_test_pool(|pool| async move {
        let password_hash = hash_password("Test1234");
        let alice_id = Uuid::new_v4().to_string();
        let bob_id = Uuid::new_v4().to_string();
        insert_user(
            &pool,
            &alice_id,
            &format!("secret_alice_{}", Uuid::new_v4()),
            &password_hash,
            "user",
            "active",
        )
        .await;
        insert_user(
            &pool,
            &bob_id,
            &format!("secret_bob_{}", Uuid::new_v4()),
            &password_hash,
            "user",
            "active",
        )
        .await;

        // A pre-existing session, as left behind by a deployment that had the
        // feature enabled.
        let session_id: Uuid = sqlx::query_scalar(
            "INSERT INTO chat_secret_sessions (
                campus_id, initiator_id, recipient_id,
                initiator_key_fingerprint, recipient_key_fingerprint
             )
             SELECT id, $1, $2, 'fp-alice', 'fp-bob' FROM campuses WHERE slug = 'ncu'
             RETURNING id",
        )
        .bind(&alice_id)
        .bind(&bob_id)
        .fetch_one(&pool)
        .await
        .expect("seed legacy secret session");

        let (token, _, _) = generate_access_token(
            &alice_id,
            "user",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("token");
        let create_body = json!({
            "recipient_id": bob_id,
            "initiator_key_fingerprint": "fp-alice-2",
            "recipient_key_fingerprint": "fp-bob-2",
        });

        // Default configuration: creation is refused even for a verified member.
        let app = create_router(build_state(pool.clone()), &[]);
        let denied = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/chat/secret-sessions")
                    .header("Content-Type", "application/json")
                    .header("Authorization", bearer(&token))
                    .body(Body::from(create_body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            denied.status(),
            StatusCode::FORBIDDEN,
            "deprecated secret chat must not accept new sessions by default"
        );

        // History on the legacy session must remain readable.
        let history = app
            .oneshot(
                Request::builder()
                    .uri(format!("/api/chat/secret-sessions/{}/messages", session_id))
                    .header("Authorization", bearer(&token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            history.status(),
            StatusCode::OK,
            "existing sessions must stay readable after deprecation"
        );

        // Explicit opt-in (migration window) restores creation.
        let mut opted_in_state = build_state(pool.clone());
        opted_in_state.infra.secret_chat_new_sessions_enabled = true;
        let opted_in = create_router(opted_in_state, &[]);
        let created = opted_in
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/chat/secret-sessions")
                    .header("Content-Type", "application/json")
                    .header("Authorization", bearer(&token))
                    .body(Body::from(create_body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(created.status(), StatusCode::OK);
    })
    .await;
}

#[tokio::test]
async fn public_marketplace_hides_other_campus_listings() {
    with_test_pool(|pool| async move {
        let campus_id = Uuid::new_v4();
        let owner_id = Uuid::new_v4().to_string();
        let listing_id = Uuid::new_v4().to_string();
        let title = format!("Cross Campus {}", Uuid::new_v4());
        sqlx::query(
            "INSERT INTO campuses (id, slug, name_zh, name_en, email_domains)
             VALUES ($1, $2, '测试大学', 'Test University', ARRAY['test.edu.cn'])",
        )
        .bind(campus_id)
        .bind(format!("test-{}", &campus_id.to_string()[..8]))
        .execute(&pool)
        .await
        .expect("insert campus");
        sqlx::query(
            "INSERT INTO users (id, username, password_hash)
             VALUES ($1, $2, 'hash')",
        )
        .bind(&owner_id)
        .bind(format!("other_campus_{}", Uuid::new_v4()))
        .execute(&pool)
        .await
        .expect("insert owner");
        sqlx::query(
            "INSERT INTO inventory (
                id, campus_id, title, category, brand, condition_score,
                suggested_price_cny, defects, owner_id, status
             ) VALUES ($1, $2, $3, 'misc', 'Brand', 8, 10000, '[]', $4, 'active')",
        )
        .bind(&listing_id)
        .bind(campus_id)
        .bind(&title)
        .bind(&owner_id)
        .execute(&pool)
        .await
        .expect("insert listing");

        let app = create_router(build_state(pool.clone()), &[]);
        let list_response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri(format!(
                        "/api/listings?direction=all&search={}",
                        title.replace(' ', "%20")
                    ))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(list_response.status(), StatusCode::OK);
        let list_body = response_json(list_response).await;
        assert_eq!(list_body["total"], 0);

        let detail_response = app
            .oneshot(
                Request::builder()
                    .uri(format!("/api/listings/{listing_id}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(detail_response.status(), StatusCode::NOT_FOUND);
    })
    .await;
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

async fn restrict_listing_for_test(pool: &sqlx::PgPool, listing_id: &str, actor_id: &str) -> Uuid {
    let campus_id: Uuid = sqlx::query_scalar("SELECT campus_id FROM inventory WHERE id = $1")
        .bind(listing_id)
        .fetch_one(pool)
        .await
        .expect("listing campus");
    goods4ncu::services::moderation_case::ModerationCaseService::new(pool.clone())
        .impose_manual_listing_takedown(listing_id, campus_id, actor_id, "测试发布受平台限制", None)
        .await
        .expect("restrict listing")
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
async fn watchlist_add_rejects_restricted_and_cross_campus_listings_without_side_facts() {
    with_test_pool(|pool| async move {
        let password_hash = hash_password("Test1234");
        let viewer_id = Uuid::new_v4().to_string();
        let owner_id = Uuid::new_v4().to_string();
        let admin_id = Uuid::new_v4().to_string();
        for (id, username, role) in [
            (
                &viewer_id,
                format!("watch_viewer_{}", Uuid::new_v4()),
                "user",
            ),
            (&owner_id, format!("watch_owner_{}", Uuid::new_v4()), "user"),
            (
                &admin_id,
                format!("watch_admin_{}", Uuid::new_v4()),
                "admin",
            ),
        ] {
            insert_user(&pool, id, &username, &password_hash, role, "active").await;
        }
        let ncu_id: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
            .fetch_one(&pool)
            .await
            .expect("ncu campus");
        let restricted_id = Uuid::new_v4().to_string();
        insert_listing(&pool, &restricted_id, &owner_id, "active").await;
        restrict_listing_for_test(&pool, &restricted_id, &admin_id).await;

        let other_campus = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO campuses (id, slug, name_zh, name_en, email_domains)
             VALUES ($1, $2, '收藏隔离测试校区', 'Watch Scope Campus', ARRAY[]::TEXT[])",
        )
        .bind(other_campus)
        .bind(format!("watch-scope-{}", other_campus.simple()))
        .execute(&pool)
        .await
        .expect("other campus");
        let cross_campus_id = Uuid::new_v4().to_string();
        insert_listing(&pool, &cross_campus_id, &owner_id, "active").await;
        sqlx::query("UPDATE inventory SET campus_id = $1 WHERE id = $2")
            .bind(other_campus)
            .bind(&cross_campus_id)
            .execute(&pool)
            .await
            .expect("move listing to other campus");

        let (token, _, _) = generate_access_token_for_campus(
            &viewer_id,
            "user",
            Some(ncu_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("viewer token");
        let app = create_router(build_state(pool.clone()), &[]);
        for listing_id in [&restricted_id, &cross_campus_id] {
            let response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri(format!("/api/watchlist/{listing_id}"))
                        .header("Authorization", bearer(&token))
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .expect("watchlist response");
            assert_eq!(
                response.status(),
                StatusCode::NOT_FOUND,
                "restricted and cross-campus listings share a fail-closed response"
            );
        }
        let side_facts: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM watchlist WHERE user_id = $1")
                .bind(&viewer_id)
                .fetch_one(&pool)
                .await
                .expect("watchlist side facts");
        assert_eq!(side_facts, 0);
    })
    .await;
}

#[tokio::test]
async fn assistant_chat_rejects_restricted_listing_context_before_persisting_a_turn() {
    with_test_pool(|pool| async move {
        let password_hash = hash_password("Test1234");
        let viewer_id = Uuid::new_v4().to_string();
        let owner_id = Uuid::new_v4().to_string();
        let admin_id = Uuid::new_v4().to_string();
        for (id, username, role) in [
            (
                &viewer_id,
                format!("assistant_viewer_{}", Uuid::new_v4()),
                "user",
            ),
            (
                &owner_id,
                format!("assistant_owner_{}", Uuid::new_v4()),
                "user",
            ),
            (
                &admin_id,
                format!("assistant_admin_{}", Uuid::new_v4()),
                "admin",
            ),
        ] {
            insert_user(&pool, id, &username, &password_hash, role, "active").await;
        }
        let campus_id: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
            .fetch_one(&pool)
            .await
            .expect("ncu campus");
        let listing_id = Uuid::new_v4().to_string();
        insert_listing(&pool, &listing_id, &owner_id, "active").await;
        restrict_listing_for_test(&pool, &listing_id, &admin_id).await;
        let (token, _, _) = generate_access_token_for_campus(
            &viewer_id,
            "user",
            Some(campus_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("viewer token");
        let app = create_router(build_state(pool.clone()), &[]);
        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/chat")
                    .header("Authorization", bearer(&token))
                    .header("Content-Type", "application/json")
                    .body(Body::from(
                        json!({
                            "message": "你好",
                            "conversation_id": "__agent__",
                            "listing_id": listing_id
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .expect("assistant response");
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
        let persisted: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM chat_messages
             WHERE sender = $1 OR receiver = $1 OR listing_id = $2",
        )
        .bind(&viewer_id)
        .bind(&listing_id)
        .fetch_one(&pool)
        .await
        .expect("assistant side facts");
        assert_eq!(
            persisted, 0,
            "rejected context must not log either chat turn"
        );
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
        assert_eq!(order.get::<String, _>("status"), "confirmed");

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
async fn restricted_pending_negotiation_only_allows_seller_rejection() {
    with_test_pool(|pool| async move {
        let seller = format!("nego-restricted-seller-{}", Uuid::new_v4().simple());
        let buyer = format!("nego-restricted-buyer-{}", Uuid::new_v4().simple());
        let admin = format!("nego-restricted-admin-{}", Uuid::new_v4().simple());
        insert_user(
            &pool,
            &seller,
            "nego_restricted_seller",
            "hash",
            "user",
            "active",
        )
        .await;
        insert_user(
            &pool,
            &buyer,
            "nego_restricted_buyer",
            "hash",
            "user",
            "active",
        )
        .await;
        insert_user(
            &pool,
            &admin,
            "nego_restricted_admin",
            "hash",
            "admin",
            "active",
        )
        .await;
        let listing_id = format!("nego-restricted-listing-{}", Uuid::new_v4().simple());
        insert_listing(&pool, &listing_id, &seller, "active").await;

        let approve_id = format!("nego-restricted-approve-{}", Uuid::new_v4().simple());
        let counter_id = format!("nego-restricted-counter-{}", Uuid::new_v4().simple());
        let reject_id = format!("nego-restricted-reject-{}", Uuid::new_v4().simple());
        for id in [&approve_id, &counter_id, &reject_id] {
            insert_hitl_request(
                &pool,
                HitlRequestFixture {
                    id,
                    listing_id: &listing_id,
                    buyer_id: &buyer,
                    seller_id: &seller,
                    proposed_price: 9_000,
                    status: "pending",
                    counter_price: None,
                },
            )
            .await;
        }
        restrict_listing_for_test(&pool, &listing_id, &admin).await;

        let (token, _, _) = generate_access_token(
            &seller,
            "user",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("seller token");
        let app = create_router(build_state(pool.clone()), &[]);

        for (id, body) in [
            (&approve_id, json!({ "action": "approve" })),
            (
                &counter_id,
                json!({ "action": "counter", "counter_price": 10_000 }),
            ),
        ] {
            let response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .method("PATCH")
                        .uri(format!("/api/negotiations/{id}/respond"))
                        .header("Authorization", bearer(&token))
                        .header("Content-Type", "application/json")
                        .body(Body::from(body.to_string()))
                        .unwrap(),
                )
                .await
                .expect("restricted negotiation response");
            assert_eq!(response.status(), StatusCode::CONFLICT);
        }

        let rejected = app
            .oneshot(
                Request::builder()
                    .method("PATCH")
                    .uri(format!("/api/negotiations/{reject_id}/respond"))
                    .header("Authorization", bearer(&token))
                    .header("Content-Type", "application/json")
                    .body(Body::from(json!({ "action": "reject" }).to_string()))
                    .unwrap(),
            )
            .await
            .expect("seller rejection");
        assert_eq!(rejected.status(), StatusCode::OK);

        let statuses: Vec<(String, String)> =
            sqlx::query_as("SELECT id, status FROM hitl_requests WHERE id = ANY($1) ORDER BY id")
                .bind(vec![
                    approve_id.clone(),
                    counter_id.clone(),
                    reject_id.clone(),
                ])
                .fetch_all(&pool)
                .await
                .expect("negotiation statuses");
        assert_eq!(
            statuses
                .iter()
                .find(|(id, _)| id == &approve_id)
                .map(|(_, status)| status.as_str()),
            Some("pending")
        );
        assert_eq!(
            statuses
                .iter()
                .find(|(id, _)| id == &counter_id)
                .map(|(_, status)| status.as_str()),
            Some("pending")
        );
        assert_eq!(
            statuses
                .iter()
                .find(|(id, _)| id == &reject_id)
                .map(|(_, status)| status.as_str()),
            Some("rejected")
        );
        let order_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM orders WHERE listing_id = $1")
                .bind(&listing_id)
                .fetch_one(&pool)
                .await
                .expect("order side facts");
        assert_eq!(order_count, 0);
        let message_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM chat_messages WHERE listing_id = $1")
                .bind(&listing_id)
                .fetch_one(&pool)
                .await
                .expect("message side facts");
        assert_eq!(
            message_count, 1,
            "only the explicitly allowed rejection may create a closing message"
        );
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
        assert_eq!(order.get::<String, _>("status"), "confirmed");

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
async fn typing_indicator_endpoint_is_removed_after_attention_migration() {
    with_test_pool(|pool| async move {
        let conversation_id = Uuid::new_v4();
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
            .uri(format!("/api/chat/conversations/{conversation_id}/typing"))
            .header("Authorization", bearer(&token))
            .header("Content-Type", "application/json")
            .body(Body::empty())
            .unwrap();

        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
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

/// Phase 2 wanted lifecycle: fulfill removes the wanted from matching surfaces
/// while preserving history, and relist reopens it.
#[tokio::test]
async fn wanted_fulfill_and_reopen_lifecycle() {
    with_test_pool(|pool| async move {
        let password_hash = hash_password("Test1234");
        let requester_id = Uuid::new_v4().to_string();
        let responder_id = Uuid::new_v4().to_string();
        insert_user(
            &pool,
            &requester_id,
            &format!("wl_requester_{}", Uuid::new_v4().simple()),
            &password_hash,
            "user",
            "active",
        )
        .await;
        insert_user(
            &pool,
            &responder_id,
            &format!("wl_responder_{}", Uuid::new_v4().simple()),
            &password_hash,
            "user",
            "active",
        )
        .await;

        let wanted_id = Uuid::new_v4().to_string();
        let offer_id = Uuid::new_v4().to_string();
        for (id, owner, direction, title) in [
            (&wanted_id, &requester_id, "wanted", "Lifecycle Wanted"),
            (&offer_id, &responder_id, "offer", "Lifecycle Offer"),
        ] {
            sqlx::query(
                "INSERT INTO inventory (id, campus_id, title, category, brand, condition_score,
                                        suggested_price_cny, defects, owner_id, status, direction)
                 SELECT $1, id, $2, 'misc', 'Brand', 8, 10000, '[]', $3, 'active', $4
                 FROM campuses WHERE slug = 'ncu'",
            )
            .bind(id)
            .bind(title)
            .bind(owner)
            .bind(direction)
            .execute(&pool)
            .await
            .expect("insert listing");
        }
        // A pending response exists before fulfillment.
        let first_response_id = sqlx::query_scalar::<_, Uuid>(
            "INSERT INTO wanted_responses (campus_id, wanted_listing_id, offer_listing_id,
                                           responder_id, requester_id)
             SELECT id, $1, $2, $3, $4 FROM campuses WHERE slug = 'ncu'
             RETURNING id",
        )
        .bind(&wanted_id)
        .bind(&offer_id)
        .bind(&responder_id)
        .bind(&requester_id)
        .fetch_one(&pool)
        .await
        .expect("insert response");

        let (owner_token, _, _) = generate_access_token(
            &requester_id,
            "user",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("token");
        let (outsider_token, _, _) = generate_access_token(
            &responder_id,
            "user",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("token");
        let app = create_router(build_state(pool.clone()), &[]);
        let post_empty = |uri: String, token: &str| {
            Request::builder()
                .method("POST")
                .uri(uri)
                .header("Authorization", bearer(token))
                .body(Body::empty())
                .unwrap()
        };

        // Only the owner can fulfill.
        let response = app
            .clone()
            .oneshot(post_empty(
                format!("/api/listings/{wanted_id}/fulfill"),
                &outsider_token,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);

        // An offer cannot be fulfilled.
        let response = app
            .clone()
            .oneshot(post_empty(
                format!("/api/listings/{offer_id}/fulfill"),
                &outsider_token,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);

        // Owner fulfills the wanted.
        let response = app
            .clone()
            .oneshot(post_empty(
                format!("/api/listings/{wanted_id}/fulfill"),
                &owner_token,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let status: String = sqlx::query_scalar("SELECT status FROM inventory WHERE id = $1")
            .bind(&wanted_id)
            .fetch_one(&pool)
            .await
            .expect("status");
        assert_eq!(status, "fulfilled");

        // Fulfilled again → conflict (no lost-update surprises).
        let response = app
            .clone()
            .oneshot(post_empty(
                format!("/api/listings/{wanted_id}/fulfill"),
                &owner_token,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::CONFLICT);

        // Fulfilled wanted leaves the public feed…
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/recommendations/feed?direction=wanted")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let feed = response_json(response).await;
        assert!(
            !feed["items"]
                .as_array()
                .expect("items")
                .iter()
                .any(|item| item["id"] == wanted_id),
            "fulfilled wanted must not appear in the feed"
        );

        // …and cannot receive new responses.
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/listings/{wanted_id}/responses"))
                    .header("Content-Type", "application/json")
                    .header("Authorization", bearer(&outsider_token))
                    .body(Body::from(
                        json!({ "offer_listing_id": offer_id }).to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);

        // The pending response history is preserved, and its responder was
        // notified of fulfillment.
        let response_status: String =
            sqlx::query_scalar("SELECT status FROM wanted_responses WHERE wanted_listing_id = $1")
                .bind(&wanted_id)
                .fetch_one(&pool)
                .await
                .expect("response status");
        assert_eq!(response_status, "pending");
        let notified: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM notifications
             WHERE user_id = $1 AND event_type = 'wanted_fulfilled'",
        )
        .bind(&responder_id)
        .fetch_one(&pool)
        .await
        .expect("notified");
        assert_eq!(notified, 1);

        // Closing a round immediately makes its still-pending history
        // read-only for both parties.
        let (status, listed) = authenticated_json(
            &app,
            Method::GET,
            &format!("/api/wanted-responses?role=requester&wanted_listing_id={wanted_id}"),
            &owner_token,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(listed["items"][0]["status"], "pending");
        assert_eq!(listed["items"][0]["round_state"], "closed");
        assert_eq!(listed["items"][0]["lifecycle_epoch"], 1);
        assert_eq!(listed["items"][0]["current_lifecycle_epoch"], 1);
        assert_eq!(listed["items"][0]["available_actions"], json!([]));

        let (status, error) = authenticated_json(
            &app,
            Method::POST,
            &format!("/api/wanted-responses/{first_response_id}/withdraw"),
            &outsider_token,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::CONFLICT);
        assert_eq!(error["code"], "wanted_response_round_closed");

        // Relist reopens the wanted.
        let response = app
            .clone()
            .oneshot(post_empty(
                format!("/api/listings/{wanted_id}/relist"),
                &owner_token,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let (status, lifecycle_epoch): (String, i64) =
            sqlx::query_as("SELECT status, lifecycle_epoch FROM inventory WHERE id = $1")
                .bind(&wanted_id)
                .fetch_one(&pool)
                .await
                .expect("status after reopen");
        assert_eq!(status, "active");
        assert_eq!(lifecycle_epoch, 2);

        // The old pending row remains truthful history after reopen and every
        // old-round action returns a stable refresh signal.
        for (action, token) in [
            ("accept", &owner_token),
            ("dismiss", &owner_token),
            ("withdraw", &outsider_token),
        ] {
            let (status, error) = authenticated_json(
                &app,
                Method::POST,
                &format!("/api/wanted-responses/{first_response_id}/{action}"),
                token,
                None,
            )
            .await;
            assert_eq!(status, StatusCode::CONFLICT);
            assert_eq!(error["code"], "wanted_response_round_closed");
        }

        let (status, listed) = authenticated_json(
            &app,
            Method::GET,
            &format!("/api/wanted-responses?role=requester&wanted_listing_id={wanted_id}"),
            &owner_token,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(listed["items"][0]["round_state"], "closed");
        assert_eq!(listed["items"][0]["current_lifecycle_epoch"], 2);
        assert_eq!(listed["items"][0]["available_actions"], json!([]));

        // The same offer may be recommended exactly once in the new round.
        let request_body = json!({ "offer_listing_id": offer_id }).to_string();
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/listings/{wanted_id}/responses"))
                    .header("Content-Type", "application/json")
                    .header("Authorization", bearer(&outsider_token))
                    .header("Idempotency-Key", "wanted-reopen-attempt-1")
                    .body(Body::from(request_body.clone()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let created = response_json(response).await;
        assert_eq!(created["replayed"], false);
        let second_response_id = created["id"].as_str().expect("response id").to_string();

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/listings/{wanted_id}/responses"))
                    .header("Content-Type", "application/json")
                    .header("Authorization", bearer(&outsider_token))
                    .header("Idempotency-Key", "wanted-reopen-attempt-1")
                    .body(Body::from(request_body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let replayed = response_json(response).await;
        assert_eq!(replayed["id"], second_response_id);
        assert_eq!(replayed["replayed"], true);
        let creation_notices: i64 = sqlx::query_scalar(
            "SELECT COUNT(*)
             FROM notifications
             WHERE user_id = $1
               AND related_listing_id = $2
               AND event_type = 'wanted_response'",
        )
        .bind(&requester_id)
        .bind(&wanted_id)
        .fetch_one(&pool)
        .await
        .expect("idempotent response notification count");
        assert_eq!(creation_notices, 1);

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/listings/{wanted_id}/responses"))
                    .header("Content-Type", "application/json")
                    .header("Authorization", bearer(&outsider_token))
                    .header("Idempotency-Key", "wanted-reopen-attempt-1")
                    .body(Body::from(
                        json!({
                            "offer_listing_id": offer_id,
                            "message": "同一个 key 不能改内容"
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::CONFLICT);

        let rows: Vec<(Uuid, i64)> = sqlx::query_as(
            "SELECT id, lifecycle_epoch
             FROM wanted_responses
             WHERE wanted_listing_id = $1
             ORDER BY lifecycle_epoch",
        )
        .bind(&wanted_id)
        .fetch_all(&pool)
        .await
        .expect("response rounds");
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0], (first_response_id, 1));
        assert_eq!(rows[1].0.to_string(), second_response_id);
        assert_eq!(rows[1].1, 2);

        let (status, listed) = authenticated_json(
            &app,
            Method::GET,
            &format!("/api/wanted-responses?role=requester&wanted_listing_id={wanted_id}"),
            &owner_token,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(listed["total"], 2);
        assert_eq!(listed["items"][0]["round_state"], "current");
        assert_eq!(
            listed["items"][0]["available_actions"],
            json!(["accept", "dismiss"])
        );
        assert_eq!(listed["items"][1]["round_state"], "closed");

        // Full-round uniqueness survives a terminal transition: withdrawing
        // does not allow the same offer to be submitted again until another
        // reopen advances the epoch.
        let (status, _) = authenticated_json(
            &app,
            Method::POST,
            &format!("/api/wanted-responses/{second_response_id}/withdraw"),
            &outsider_token,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/listings/{wanted_id}/responses"))
                    .header("Content-Type", "application/json")
                    .header("Authorization", bearer(&outsider_token))
                    .header("Idempotency-Key", "wanted-reopen-attempt-2")
                    .body(Body::from(
                        json!({ "offer_listing_id": offer_id }).to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);

        // Owner deletion is another lifecycle close path. It freezes a
        // different current-round pending response, and reopening from deleted
        // advances exactly one more epoch.
        let delete_offer_id = Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO inventory (
                id, campus_id, title, category, brand, condition_score,
                suggested_price_cny, defects, owner_id, status, direction
             ) SELECT $1, id, 'Delete-round offer', 'misc', 'Brand', 8,
                      10000, '[]', $2, 'active', 'offer'
               FROM campuses WHERE slug = 'ncu'",
        )
        .bind(&delete_offer_id)
        .bind(&responder_id)
        .execute(&pool)
        .await
        .expect("insert delete-round offer");
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/listings/{wanted_id}/responses"))
                    .header("Content-Type", "application/json")
                    .header("Authorization", bearer(&outsider_token))
                    .header("Idempotency-Key", "wanted-delete-round")
                    .body(Body::from(
                        json!({ "offer_listing_id": delete_offer_id }).to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let delete_round_response = response_json(response).await;
        let delete_round_response_id = delete_round_response["id"]
            .as_str()
            .expect("delete-round response id")
            .to_string();

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("DELETE")
                    .uri(format!("/api/listings/{wanted_id}"))
                    .header("Authorization", bearer(&owner_token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let (deleted_status, deleted_epoch): (String, i64) =
            sqlx::query_as("SELECT status, lifecycle_epoch FROM inventory WHERE id = $1")
                .bind(&wanted_id)
                .fetch_one(&pool)
                .await
                .expect("deleted wanted state");
        assert_eq!(deleted_status, "deleted");
        assert_eq!(deleted_epoch, 2);

        let (status, error) = authenticated_json(
            &app,
            Method::POST,
            &format!("/api/wanted-responses/{delete_round_response_id}/withdraw"),
            &outsider_token,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::CONFLICT);
        assert_eq!(error["code"], "wanted_response_round_closed");

        let response = app
            .clone()
            .oneshot(post_empty(
                format!("/api/listings/{wanted_id}/relist"),
                &owner_token,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let reopened_epoch: i64 =
            sqlx::query_scalar("SELECT lifecycle_epoch FROM inventory WHERE id = $1")
                .bind(&wanted_id)
                .fetch_one(&pool)
                .await
                .expect("epoch after deleted reopen");
        assert_eq!(reopened_epoch, 3);
    })
    .await;
}

#[tokio::test]
async fn wanted_response_creation_serializes_with_close_and_same_round_duplicates() {
    with_test_pool(|pool| async move {
        let password_hash = hash_password("Test1234");
        let requester_id = Uuid::new_v4().to_string();
        let responder_id = Uuid::new_v4().to_string();
        insert_user(
            &pool,
            &requester_id,
            &format!("race_requester_{}", Uuid::new_v4().simple()),
            &password_hash,
            "user",
            "active",
        )
        .await;
        insert_user(
            &pool,
            &responder_id,
            &format!("race_responder_{}", Uuid::new_v4().simple()),
            &password_hash,
            "user",
            "active",
        )
        .await;

        let campus_id: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
            .fetch_one(&pool)
            .await
            .expect("ncu campus");
        let wanted_id = Uuid::new_v4().to_string();
        let offer_id = Uuid::new_v4().to_string();
        for (id, owner, direction) in [
            (&wanted_id, &requester_id, "wanted"),
            (&offer_id, &responder_id, "offer"),
        ] {
            sqlx::query(
                "INSERT INTO inventory (
                    id, campus_id, title, category, brand, condition_score,
                    suggested_price_cny, defects, owner_id, status, direction
                 ) VALUES ($1, $2, 'Lifecycle race item', 'misc', 'Test',
                           8, 10000, '[]', $3, 'active', $4)",
            )
            .bind(id)
            .bind(campus_id)
            .bind(owner)
            .bind(direction)
            .execute(&pool)
            .await
            .expect("insert race listing");
        }

        let (requester_token, _, _) = generate_access_token(
            &requester_id,
            "user",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("requester token");
        let (responder_token, _, _) = generate_access_token(
            &responder_id,
            "user",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("responder token");

        let concurrent_pool = concurrent_test_pool(6).await;
        let app = create_router(build_state(concurrent_pool.clone()), &[]);
        let mut closing = concurrent_pool.begin().await.expect("closing tx");
        sqlx::query("SELECT 1 FROM inventory WHERE id = $1 FOR UPDATE")
            .bind(&wanted_id)
            .fetch_one(&mut *closing)
            .await
            .expect("lock wanted");
        sqlx::query("UPDATE inventory SET status = 'fulfilled' WHERE id = $1")
            .bind(&wanted_id)
            .execute(&mut *closing)
            .await
            .expect("stage fulfillment");

        let mut response_task = tokio::spawn({
            let app = app.clone();
            let wanted_id = wanted_id.clone();
            let offer_id = offer_id.clone();
            let responder_token = responder_token.clone();
            async move {
                app.oneshot(
                    Request::builder()
                        .method("POST")
                        .uri(format!("/api/listings/{wanted_id}/responses"))
                        .header("Content-Type", "application/json")
                        .header("Authorization", bearer(&responder_token))
                        .header("Idempotency-Key", "wanted-close-race")
                        .body(Body::from(
                            json!({ "offer_listing_id": offer_id }).to_string(),
                        ))
                        .unwrap(),
                )
                .await
                .unwrap()
            }
        });

        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(150), &mut response_task)
                .await
                .is_err(),
            "response creation must wait on the wanted lifecycle row"
        );
        closing.commit().await.expect("commit fulfillment");
        let response = response_task.await.expect("response task");
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM wanted_responses WHERE wanted_listing_id = $1",
        )
        .bind(&wanted_id)
        .fetch_one(&pool)
        .await
        .expect("response count after close race");
        assert_eq!(count, 0);

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/listings/{wanted_id}/relist"))
                    .header("Authorization", bearer(&requester_token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        let request = |key: &'static str| {
            Request::builder()
                .method("POST")
                .uri(format!("/api/listings/{wanted_id}/responses"))
                .header("Content-Type", "application/json")
                .header("Authorization", bearer(&responder_token))
                .header("Idempotency-Key", key)
                .body(Body::from(
                    json!({ "offer_listing_id": offer_id }).to_string(),
                ))
                .unwrap()
        };
        let (first, second) = tokio::join!(
            app.clone().oneshot(request("wanted-duplicate-race-a")),
            app.clone().oneshot(request("wanted-duplicate-race-b")),
        );
        let statuses = [
            first.expect("first response").status(),
            second.expect("second response").status(),
        ];
        assert_eq!(
            statuses
                .iter()
                .filter(|status| **status == StatusCode::OK)
                .count(),
            1
        );
        assert_eq!(
            statuses
                .iter()
                .filter(|status| **status == StatusCode::BAD_REQUEST)
                .count(),
            1
        );

        let rows: Vec<(Uuid, i64)> = sqlx::query_as(
            "SELECT id, lifecycle_epoch
             FROM wanted_responses
             WHERE wanted_listing_id = $1",
        )
        .bind(&wanted_id)
        .fetch_all(&pool)
        .await
        .expect("serialized response rows");
        assert_eq!(rows.len(), 1);
        let (response_id, response_epoch) = rows[0];
        assert_eq!(response_epoch, 2);

        // Ambiguous rows from a rolling upgrade remain visible but fail
        // closed; NULL must never be interpreted as the current epoch.
        sqlx::query("UPDATE wanted_responses SET lifecycle_epoch = NULL WHERE id = $1")
            .bind(response_id)
            .execute(&pool)
            .await
            .expect("simulate ambiguous legacy history");
        let (status, listed) = authenticated_json(
            &app,
            Method::GET,
            &format!("/api/wanted-responses?role=responder&wanted_listing_id={wanted_id}"),
            &responder_token,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert!(listed["items"][0]["lifecycle_epoch"].is_null());
        assert_eq!(listed["items"][0]["round_state"], "closed");
        assert_eq!(listed["items"][0]["available_actions"], json!([]));
        let (status, error) = authenticated_json(
            &app,
            Method::POST,
            &format!("/api/wanted-responses/{response_id}/withdraw"),
            &responder_token,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::CONFLICT);
        assert_eq!(error["code"], "wanted_response_round_closed");
    })
    .await;
}

/// Phase 2 response actions: accept/dismiss (requester) and withdraw
/// (responder), single-winner transitions, counterpart notifications.
#[tokio::test]
async fn wanted_response_actions_transition_once_and_notify() {
    with_test_pool(|pool| async move {
        let password_hash = hash_password("Test1234");
        let requester_id = Uuid::new_v4().to_string();
        let responder_id = Uuid::new_v4().to_string();
        insert_user(
            &pool,
            &requester_id,
            &format!("ra_requester_{}", Uuid::new_v4().simple()),
            &password_hash,
            "user",
            "active",
        )
        .await;
        insert_user(
            &pool,
            &responder_id,
            &format!("ra_responder_{}", Uuid::new_v4().simple()),
            &password_hash,
            "user",
            "active",
        )
        .await;

        let wanted_id = Uuid::new_v4().to_string();
        let offer_id = Uuid::new_v4().to_string();
        for (id, owner, direction) in [
            (&wanted_id, &requester_id, "wanted"),
            (&offer_id, &responder_id, "offer"),
        ] {
            sqlx::query(
                "INSERT INTO inventory (id, campus_id, title, category, brand, condition_score,
                                        suggested_price_cny, defects, owner_id, status, direction)
                 SELECT $1, id, 'Action Item', 'misc', 'Brand', 8, 10000, '[]', $2, 'active', $3
                 FROM campuses WHERE slug = 'ncu'",
            )
            .bind(id)
            .bind(owner)
            .bind(direction)
            .execute(&pool)
            .await
            .expect("insert listing");
        }
        let seed_response = |pool: sqlx::PgPool,
                             wanted: String,
                             offer: String,
                             responder: String,
                             requester: String| async move {
            sqlx::query_scalar::<_, Uuid>(
                "INSERT INTO wanted_responses (campus_id, wanted_listing_id, offer_listing_id,
                                               responder_id, requester_id)
                 SELECT id, $1, $2, $3, $4 FROM campuses WHERE slug = 'ncu' RETURNING id",
            )
            .bind(wanted)
            .bind(offer)
            .bind(responder)
            .bind(requester)
            .fetch_one(&pool)
            .await
            .expect("insert response")
        };

        let (requester_token, _, _) = generate_access_token(
            &requester_id,
            "user",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("token");
        let (responder_token, _, _) = generate_access_token(
            &responder_id,
            "user",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("token");
        let app = create_router(build_state(pool.clone()), &[]);
        let post_empty = |uri: String, token: &str| {
            Request::builder()
                .method("POST")
                .uri(uri)
                .header("Authorization", bearer(token))
                .body(Body::empty())
                .unwrap()
        };

        // Accept: responder cannot act as requester (404, no existence leak).
        let response_id = seed_response(
            pool.clone(),
            wanted_id.clone(),
            offer_id.clone(),
            responder_id.clone(),
            requester_id.clone(),
        )
        .await;
        let response = app
            .clone()
            .oneshot(post_empty(
                format!("/api/wanted-responses/{response_id}/accept"),
                &responder_token,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);

        // Requester accepts; responder is notified.
        let response = app
            .clone()
            .oneshot(post_empty(
                format!("/api/wanted-responses/{response_id}/accept"),
                &requester_token,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let status: String =
            sqlx::query_scalar("SELECT status FROM wanted_responses WHERE id = $1")
                .bind(response_id)
                .fetch_one(&pool)
                .await
                .expect("status");
        assert_eq!(status, "accepted");
        let notified: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM notifications
             WHERE user_id = $1 AND event_type = 'wanted_response_accepted'",
        )
        .bind(&responder_id)
        .fetch_one(&pool)
        .await
        .expect("notify count");
        assert_eq!(notified, 1);

        // A second action on the same response conflicts.
        let response = app
            .clone()
            .oneshot(post_empty(
                format!("/api/wanted-responses/{response_id}/dismiss"),
                &requester_token,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::CONFLICT);

        // Withdraw: responder retracts their own pending recommendation.
        sqlx::query("DELETE FROM wanted_responses WHERE id = $1")
            .bind(response_id)
            .execute(&pool)
            .await
            .expect("cleanup");
        let response_id = seed_response(
            pool.clone(),
            wanted_id.clone(),
            offer_id.clone(),
            responder_id.clone(),
            requester_id.clone(),
        )
        .await;
        let response = app
            .clone()
            .oneshot(post_empty(
                format!("/api/wanted-responses/{response_id}/withdraw"),
                &responder_token,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let status: String =
            sqlx::query_scalar("SELECT status FROM wanted_responses WHERE id = $1")
                .bind(response_id)
                .fetch_one(&pool)
                .await
                .expect("status");
        assert_eq!(status, "withdrawn");

        // Role-scoped listing works for both sides.
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/wanted-responses?role=responder")
                    .header("Authorization", bearer(&responder_token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let listed = response_json(response).await;
        assert!(!listed["items"].as_array().expect("items").is_empty());
    })
    .await;
}

#[tokio::test]
async fn wanted_response_http_journey_lists_statuses_and_gates_actions() {
    with_test_pool(|pool| async move {
        let password_hash = hash_password("Test1234");
        let requester_id = Uuid::new_v4().to_string();
        let responder_id = Uuid::new_v4().to_string();
        insert_user(
            &pool,
            &requester_id,
            &format!("response_requester_{}", Uuid::new_v4().simple()),
            &password_hash,
            "user",
            "active",
        )
        .await;
        insert_user(
            &pool,
            &responder_id,
            &format!("response_responder_{}", Uuid::new_v4().simple()),
            &password_hash,
            "user",
            "active",
        )
        .await;

        let campus_id: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
            .fetch_one(&pool)
            .await
            .expect("ncu campus");
        let wanted_id = Uuid::new_v4().to_string();
        let accepted_offer_id = Uuid::new_v4().to_string();
        let dismissed_offer_id = Uuid::new_v4().to_string();
        let withdrawn_offer_id = Uuid::new_v4().to_string();
        for (id, owner, direction, title) in [
            (
                &wanted_id,
                &requester_id,
                "wanted",
                "Wanted response journey",
            ),
            (
                &accepted_offer_id,
                &responder_id,
                "offer",
                "Accepted offer",
            ),
            (
                &dismissed_offer_id,
                &responder_id,
                "offer",
                "Dismissed offer",
            ),
            (
                &withdrawn_offer_id,
                &responder_id,
                "offer",
                "Withdrawn offer",
            ),
        ] {
            sqlx::query(
                "INSERT INTO inventory (
                    id, campus_id, title, category, brand, condition_score,
                    suggested_price_cny, defects, owner_id, status, direction
                 ) VALUES ($1, $2, $3, 'electronics', 'Test', 8, 10000, '[]',
                           $4, 'active', $5)",
            )
            .bind(id)
            .bind(campus_id)
            .bind(title)
            .bind(owner)
            .bind(direction)
            .execute(&pool)
            .await
            .expect("insert wanted journey listing");
        }

        let (requester_token, _, _) = generate_access_token_for_campus(
            &requester_id,
            "user",
            Some(campus_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("requester token");
        let (responder_token, _, _) = generate_access_token_for_campus(
            &responder_id,
            "user",
            Some(campus_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("responder token");
        let app = create_router(build_state(pool.clone()), &[]);
        let responses_uri = format!("/api/listings/{wanted_id}/responses");

        // Exercise the real creation endpoint rather than seeding the response
        // row, including the directed inbox notification.
        let (status, accepted_created) = authenticated_json(
            &app,
            Method::POST,
            &responses_uri,
            &responder_token,
            Some(json!({
                "offer_listing_id": accepted_offer_id,
                "message": "符合你的预算，可以看看"
            })),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let accepted_response_id = accepted_created["id"]
            .as_str()
            .expect("accepted response id");
        Uuid::parse_str(accepted_response_id).expect("response id is a UUID");
        let creation_notice_target: Option<String> = sqlx::query_scalar(
            "SELECT related_listing_id FROM notifications
             WHERE user_id = $1 AND event_type = 'wanted_response'
             ORDER BY created_at DESC LIMIT 1",
        )
        .bind(&requester_id)
        .fetch_one(&pool)
        .await
        .expect("wanted response notification");
        assert_eq!(creation_notice_target.as_deref(), Some(wanted_id.as_str()));

        // The list contract is tenant/role/filter scoped and remains pageable
        // even when the requested page is empty.
        let list_uri = format!(
            "/api/wanted-responses?role=requester&status=pending&wanted_listing_id={wanted_id}&limit=1&offset=0"
        );
        let (status, listed) =
            authenticated_json(&app, Method::GET, &list_uri, &requester_token, None).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(listed["total"], 1);
        assert_eq!(listed["limit"], 1);
        assert_eq!(listed["offset"], 0);
        assert_eq!(listed["items"].as_array().map(Vec::len), Some(1));
        assert_eq!(listed["items"][0]["id"], accepted_response_id);
        assert_eq!(listed["items"][0]["wanted_status"], "active");
        assert_eq!(listed["items"][0]["offer_status"], "active");
        let empty_page_uri = format!(
            "/api/wanted-responses?role=requester&wanted_listing_id={wanted_id}&limit=1&offset=1"
        );
        let (status, empty_page) =
            authenticated_json(&app, Method::GET, &empty_page_uri, &requester_token, None).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(empty_page["total"], 1);
        assert_eq!(empty_page["offset"], 1);
        assert!(empty_page["items"]
            .as_array()
            .expect("empty page items")
            .is_empty());

        let (status, accepted) = authenticated_json(
            &app,
            Method::POST,
            &format!("/api/wanted-responses/{accepted_response_id}/accept"),
            &requester_token,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(accepted["status"], "accepted");
        let accepted_notice_target: Option<String> = sqlx::query_scalar(
            "SELECT related_listing_id FROM notifications
             WHERE user_id = $1 AND event_type = 'wanted_response_accepted'
             ORDER BY created_at DESC LIMIT 1",
        )
        .bind(&responder_id)
        .fetch_one(&pool)
        .await
        .expect("accepted notification");
        assert_eq!(accepted_notice_target.as_deref(), Some(wanted_id.as_str()));

        // A sold offer cannot be accepted, but the requester may still dismiss
        // its pending response while the wanted listing remains active.
        let (status, dismissed_created) = authenticated_json(
            &app,
            Method::POST,
            &responses_uri,
            &responder_token,
            Some(json!({ "offer_listing_id": dismissed_offer_id })),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let dismissed_response_id = dismissed_created["id"]
            .as_str()
            .expect("dismissed response id");
        sqlx::query("UPDATE inventory SET status = 'sold' WHERE id = $1")
            .bind(&dismissed_offer_id)
            .execute(&pool)
            .await
            .expect("sell offered listing");
        let (status, error) = authenticated_json(
            &app,
            Method::POST,
            &format!("/api/wanted-responses/{dismissed_response_id}/accept"),
            &requester_token,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::CONFLICT);
        assert_eq!(error["code"], "conflict");
        let (status, dismissed) = authenticated_json(
            &app,
            Method::POST,
            &format!("/api/wanted-responses/{dismissed_response_id}/dismiss"),
            &requester_token,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(dismissed["status"], "dismissed");
        let dismissed_notice_target: Option<String> = sqlx::query_scalar(
            "SELECT related_listing_id FROM notifications
             WHERE user_id = $1 AND event_type = 'wanted_response_dismissed'
             ORDER BY created_at DESC LIMIT 1",
        )
        .bind(&responder_id)
        .fetch_one(&pool)
        .await
        .expect("dismissed notification");
        assert_eq!(
            dismissed_notice_target.as_deref(),
            Some(wanted_id.as_str())
        );

        // Once the wanted listing is no longer active, the round is frozen for
        // both parties and remains pending, read-only history.
        let (status, withdrawn_created) = authenticated_json(
            &app,
            Method::POST,
            &responses_uri,
            &responder_token,
            Some(json!({ "offer_listing_id": withdrawn_offer_id })),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let withdrawn_response_id = withdrawn_created["id"]
            .as_str()
            .expect("withdrawn response id");
        sqlx::query("UPDATE inventory SET status = 'fulfilled' WHERE id = $1")
            .bind(&wanted_id)
            .execute(&pool)
            .await
            .expect("fulfill wanted");
        for (action, token) in [
            ("accept", &requester_token),
            ("dismiss", &requester_token),
            ("withdraw", &responder_token),
        ] {
            let (status, error) = authenticated_json(
                &app,
                Method::POST,
                &format!("/api/wanted-responses/{withdrawn_response_id}/{action}"),
                token,
                None,
            )
            .await;
            assert_eq!(status, StatusCode::CONFLICT, "{action}");
            assert_eq!(error["code"], "wanted_response_round_closed");
        }
        let frozen_status: String =
            sqlx::query_scalar("SELECT status FROM wanted_responses WHERE id = $1")
                .bind(Uuid::parse_str(withdrawn_response_id).expect("response UUID"))
                .fetch_one(&pool)
                .await
                .expect("frozen response status");
        assert_eq!(frozen_status, "pending");
        let withdrawn_notices: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM notifications
             WHERE user_id = $1 AND event_type = 'wanted_response_withdrawn'",
        )
        .bind(&requester_id)
        .fetch_one(&pool)
        .await
        .expect("withdrawn notification count");
        assert_eq!(withdrawn_notices, 0);
    })
    .await;
}

#[tokio::test]
async fn wanted_response_list_and_actions_require_the_verified_active_campus() {
    with_test_pool(|pool| async move {
        let password_hash = hash_password("Test1234");
        let requester_id = Uuid::new_v4().to_string();
        let responder_id = Uuid::new_v4().to_string();
        insert_user(
            &pool,
            &requester_id,
            &format!("tenant_requester_{}", Uuid::new_v4().simple()),
            &password_hash,
            "user",
            "active",
        )
        .await;
        insert_user(
            &pool,
            &responder_id,
            &format!("tenant_responder_{}", Uuid::new_v4().simple()),
            &password_hash,
            "user",
            "active",
        )
        .await;

        let ncu_id: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
            .fetch_one(&pool)
            .await
            .expect("ncu campus");
        let other_campus_id = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO campuses (id, slug, name_zh, name_en, email_domains)
             VALUES ($1, $2, '响应租户测试大学', 'Response tenant test',
                     ARRAY['response-tenant.test'])",
        )
        .bind(other_campus_id)
        .bind(format!(
            "response-tenant-{}",
            &other_campus_id.to_string()[..8]
        ))
        .execute(&pool)
        .await
        .expect("insert other campus");
        for user_id in [&requester_id, &responder_id] {
            sqlx::query(
                "INSERT INTO campus_memberships (
                    campus_id, user_id, status, verification_method, verified_at
                 ) VALUES ($1, $2, 'verified', 'test_fixture', NOW())",
            )
            .bind(other_campus_id)
            .bind(user_id)
            .execute(&pool)
            .await
            .expect("insert other campus membership");
        }

        let ncu_wanted_id = Uuid::new_v4().to_string();
        let ncu_offer_id = Uuid::new_v4().to_string();
        let other_wanted_id = Uuid::new_v4().to_string();
        let other_offer_id = Uuid::new_v4().to_string();
        for (id, campus, owner, direction, title) in [
            (
                &ncu_wanted_id,
                ncu_id,
                &requester_id,
                "wanted",
                "NCU wanted",
            ),
            (&ncu_offer_id, ncu_id, &responder_id, "offer", "NCU offer"),
            (
                &other_wanted_id,
                other_campus_id,
                &requester_id,
                "wanted",
                "Other wanted",
            ),
            (
                &other_offer_id,
                other_campus_id,
                &responder_id,
                "offer",
                "Other offer",
            ),
        ] {
            sqlx::query(
                "INSERT INTO inventory (
                    id, campus_id, title, category, brand, condition_score,
                    suggested_price_cny, defects, owner_id, status, direction
                 ) VALUES ($1, $2, $3, 'misc', 'Test', 8, 10000, '[]',
                           $4, 'active', $5)",
            )
            .bind(id)
            .bind(campus)
            .bind(title)
            .bind(owner)
            .bind(direction)
            .execute(&pool)
            .await
            .expect("insert tenant listing");
        }
        let ncu_response_id = sqlx::query_scalar::<_, Uuid>(
            "INSERT INTO wanted_responses (
                campus_id, wanted_listing_id, offer_listing_id, responder_id, requester_id
             ) VALUES ($1, $2, $3, $4, $5)
             RETURNING id",
        )
        .bind(ncu_id)
        .bind(&ncu_wanted_id)
        .bind(&ncu_offer_id)
        .bind(&responder_id)
        .bind(&requester_id)
        .fetch_one(&pool)
        .await
        .expect("insert ncu response");
        let other_response_id = sqlx::query_scalar::<_, Uuid>(
            "INSERT INTO wanted_responses (
                campus_id, wanted_listing_id, offer_listing_id, responder_id, requester_id
             ) VALUES ($1, $2, $3, $4, $5)
             RETURNING id",
        )
        .bind(other_campus_id)
        .bind(&other_wanted_id)
        .bind(&other_offer_id)
        .bind(&responder_id)
        .bind(&requester_id)
        .fetch_one(&pool)
        .await
        .expect("insert other response");

        let (requester_ncu_token, _, _) = generate_access_token_for_campus(
            &requester_id,
            "user",
            Some(ncu_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("ncu requester token");
        let (requester_other_token, _, _) = generate_access_token_for_campus(
            &requester_id,
            "user",
            Some(other_campus_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("other requester token");
        let (responder_ncu_token, _, _) = generate_access_token_for_campus(
            &responder_id,
            "user",
            Some(ncu_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("ncu responder token");
        let app = create_router(build_state(pool.clone()), &[]);

        let (status, ncu_list) = authenticated_json(
            &app,
            Method::GET,
            "/api/wanted-responses?role=requester",
            &requester_ncu_token,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(ncu_list["total"], 1);
        assert_eq!(ncu_list["items"][0]["wanted_listing_id"], ncu_wanted_id);

        let (status, filtered_cross_campus) = authenticated_json(
            &app,
            Method::GET,
            &format!("/api/wanted-responses?role=requester&wanted_listing_id={other_wanted_id}"),
            &requester_ncu_token,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(filtered_cross_campus["total"], 0);

        // The caller is a party to this response, but it belongs to a different
        // active campus. Treat it exactly like a missing response.
        let (status, error) = authenticated_json(
            &app,
            Method::POST,
            &format!("/api/wanted-responses/{other_response_id}/accept"),
            &requester_ncu_token,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        assert_eq!(error["code"], "not_found");

        let (status, other_list) = authenticated_json(
            &app,
            Method::GET,
            "/api/wanted-responses?role=requester",
            &requester_other_token,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(other_list["total"], 1);
        assert_eq!(other_list["items"][0]["wanted_listing_id"], other_wanted_id);

        sqlx::query(
            "UPDATE campus_memberships SET status = 'suspended'
             WHERE campus_id = $1 AND user_id = $2",
        )
        .bind(ncu_id)
        .bind(&requester_id)
        .execute(&pool)
        .await
        .expect("suspend requester membership");
        for (method, uri) in [
            (Method::GET, "/api/wanted-responses".to_string()),
            (
                Method::POST,
                format!("/api/wanted-responses/{ncu_response_id}/accept"),
            ),
        ] {
            let (status, error) =
                authenticated_json(&app, method, &uri, &requester_ncu_token, None).await;
            assert_eq!(status, StatusCode::FORBIDDEN);
            assert_eq!(error["code"], "campus_scope_mismatch");
        }

        sqlx::query(
            "UPDATE campus_memberships SET status = 'revoked'
             WHERE campus_id = $1 AND user_id = $2",
        )
        .bind(ncu_id)
        .bind(&responder_id)
        .execute(&pool)
        .await
        .expect("revoke responder membership");
        let (status, error) = authenticated_json(
            &app,
            Method::POST,
            &format!("/api/wanted-responses/{ncu_response_id}/withdraw"),
            &responder_ncu_token,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN);
        assert_eq!(error["code"], "campus_scope_mismatch");

        let response_status: String =
            sqlx::query_scalar("SELECT status FROM wanted_responses WHERE id = $1")
                .bind(ncu_response_id)
                .fetch_one(&pool)
                .await
                .expect("ncu response status");
        assert_eq!(response_status, "pending");
    })
    .await;
}

/// Phase 2 explainability: every feed item carries a user-readable
/// rank_reason and a machine-readable source; responses carry the ranking
/// version.
#[tokio::test]
async fn recommendation_feed_explains_ranking() {
    with_test_pool(|pool| async move {
        let password_hash = hash_password("Test1234");
        let viewer_id = Uuid::new_v4().to_string();
        let seller_id = Uuid::new_v4().to_string();
        insert_user(
            &pool,
            &viewer_id,
            &format!("rr_viewer_{}", Uuid::new_v4().simple()),
            &password_hash,
            "user",
            "active",
        )
        .await;
        insert_user(
            &pool,
            &seller_id,
            &format!("rr_seller_{}", Uuid::new_v4().simple()),
            &password_hash,
            "user",
            "active",
        )
        .await;

        // The viewer watches an electronics item, so a fresh electronics
        // listing by someone else should rank with a category-affinity reason.
        let watched_id = Uuid::new_v4().to_string();
        let candidate_id = Uuid::new_v4().to_string();
        let unrelated_id = Uuid::new_v4().to_string();
        for (id, category) in [
            (&watched_id, "electronics"),
            (&candidate_id, "electronics"),
            (&unrelated_id, "misc"),
        ] {
            sqlx::query(
                "INSERT INTO inventory (id, campus_id, title, category, brand, condition_score,
                                        suggested_price_cny, defects, owner_id, status, direction)
                 SELECT $1, id, 'Reason Item', $2, 'Brand', 8, 10000, '[]', $3, 'active', 'offer'
                 FROM campuses WHERE slug = 'ncu'",
            )
            .bind(id)
            .bind(category)
            .bind(&seller_id)
            .execute(&pool)
            .await
            .expect("insert listing");
        }
        sqlx::query("INSERT INTO watchlist (user_id, listing_id) VALUES ($1, $2)")
            .bind(&viewer_id)
            .bind(&watched_id)
            .execute(&pool)
            .await
            .expect("watch");

        let app = create_router(build_state(pool.clone()), &[]);

        // Anonymous: recency source with a readable reason.
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/recommendations/feed?direction=offer")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let feed = response_json(response).await;
        assert_eq!(feed["ranking_version"], "2026.07-feedback-v2");
        for item in feed["items"].as_array().expect("items") {
            assert_eq!(item["source"], "recency");
            assert!(!item["rank_reason"].as_str().expect("reason").is_empty());
        }

        // Authenticated: the affinity match explains itself with the category.
        let (token, _, _) = generate_access_token(
            &viewer_id,
            "user",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("token");
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/recommendations/feed?direction=offer")
                    .header("Authorization", bearer(&token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let feed = response_json(response).await;
        let candidate = feed["items"]
            .as_array()
            .expect("items")
            .iter()
            .find(|item| item["id"] == candidate_id)
            .expect("affinity candidate present");
        assert_eq!(candidate["source"], "category_affinity");
        assert!(
            candidate["rank_reason"]
                .as_str()
                .expect("reason")
                .contains("electronics"),
            "reason must name the category: {}",
            candidate["rank_reason"]
        );
    })
    .await;
}

/// Phase 1 media quarantine at the API layer: unreviewed or rejected media
/// URLs never leave the server through public read paths, while owners keep
/// seeing their own uploads.
#[tokio::test]
async fn unapproved_media_is_not_served_publicly() {
    with_test_pool(|pool| async move {
        let password_hash = hash_password("Test1234");
        let owner_id = Uuid::new_v4().to_string();
        let viewer_id = Uuid::new_v4().to_string();
        insert_user(
            &pool,
            &owner_id,
            &format!("mq_owner_{}", Uuid::new_v4().simple()),
            &password_hash,
            "user",
            "active",
        )
        .await;
        insert_user(
            &pool,
            &viewer_id,
            &format!("mq_viewer_{}", Uuid::new_v4().simple()),
            &password_hash,
            "user",
            "active",
        )
        .await;

        let listing_id = Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO inventory (id, campus_id, title, category, brand, condition_score,
                                    suggested_price_cny, defects, owner_id, status, direction,
                                    image_url, images_moderation_status)
             SELECT $1, id, 'Quarantined Item', 'misc', 'Brand', 8, 10000, '[]', $2, 'active',
                    'offer', 'https://cdn.example.com/pending.jpg', 'pending'
             FROM campuses WHERE slug = 'ncu'",
        )
        .bind(&listing_id)
        .bind(&owner_id)
        .execute(&pool)
        .await
        .expect("insert pending-media listing");

        let wanted_id = Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO inventory (id, campus_id, title, category, brand, condition_score,
                                    suggested_price_cny, defects, owner_id, status, direction)
             SELECT $1, id, 'Wanted quarantined item', 'misc', '不限', 5, 20000, '[]',
                    $2, 'active', 'wanted'
             FROM campuses WHERE slug = 'ncu'",
        )
        .bind(&wanted_id)
        .bind(&viewer_id)
        .execute(&pool)
        .await
        .expect("insert wanted listing");

        // Owner avatar pending moderation.
        sqlx::query(
            "UPDATE users SET avatar_url = 'https://cdn.example.com/avatar.jpg',
                              avatar_moderation_status = 'pending'
             WHERE id = $1",
        )
        .bind(&owner_id)
        .execute(&pool)
        .await
        .expect("set pending avatar");

        let app = create_router(build_state(pool.clone()), &[]);
        let (owner_token, _, _) = generate_access_token(
            &owner_id,
            "user",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("token");

        // Public listing list and detail hide the URL.
        for uri in [
            "/api/listings?limit=50".to_string(),
            format!("/api/listings/{listing_id}"),
            format!("/api/listings/{wanted_id}/matches"),
            "/api/recommendations/feed?direction=offer".to_string(),
        ] {
            let response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .uri(uri.clone())
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK, "{uri}");
            let body = response_json(response).await;
            let text = body.to_string();
            assert!(
                !text.contains("pending.jpg"),
                "unreviewed media leaked via {uri}: {text}"
            );
        }

        // Public user profile hides the pending avatar; public user listings
        // hide the pending listing image.
        for uri in [
            format!("/api/users/{owner_id}"),
            format!("/api/users/{owner_id}/listings"),
        ] {
            let response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .uri(uri.clone())
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK, "{uri}");
            let text = response_json(response).await.to_string();
            assert!(
                !text.contains("avatar.jpg") && !text.contains("pending.jpg"),
                "unreviewed media leaked via {uri}: {text}"
            );
        }

        // The owner still sees their own upload in “my listings”.
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/user/listings")
                    .header("Authorization", bearer(&owner_token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let text = response_json(response).await.to_string();
        assert!(
            text.contains("pending.jpg"),
            "owner must keep seeing their own pending media"
        );

        // Approval makes the media public; rejection hides it again.
        sqlx::query("UPDATE inventory SET images_moderation_status = 'approved' WHERE id = $1")
            .bind(&listing_id)
            .execute(&pool)
            .await
            .expect("approve");
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri(format!("/api/listings/{listing_id}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let text = response_json(response).await.to_string();
        assert!(text.contains("pending.jpg"), "approved media must serve");

        sqlx::query("UPDATE inventory SET images_moderation_status = 'rejected' WHERE id = $1")
            .bind(&listing_id)
            .execute(&pool)
            .await
            .expect("reject");
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri(format!("/api/listings/{listing_id}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let text = response_json(response).await.to_string();
        assert!(
            !text.contains("pending.jpg"),
            "rejected media must never serve"
        );
    })
    .await;
}

/// Submission quarantines atomically: with moderation enabled the resource
/// flips to 'pending' in the same transaction as the job insert; with it
/// disabled the resource is explicitly marked review-exempt.
#[tokio::test]
async fn image_submission_quarantines_resource_with_job() {
    with_test_pool(|pool| async move {
        let owner_id = Uuid::new_v4().to_string();
        insert_user(
            &pool,
            &owner_id,
            &format!("mq_submit_{}", Uuid::new_v4().simple()),
            &hash_password("Test1234"),
            "user",
            "active",
        )
        .await;
        let campus_id: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
            .fetch_one(&pool)
            .await
            .expect("campus");
        let listing_id = Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO inventory (id, campus_id, title, category, brand, condition_score,
                                    suggested_price_cny, defects, owner_id, status,
                                    image_url)
             VALUES ($1, $2, 'Submit Item', 'misc', 'Brand', 8, 10000, '[]', $3, 'active',
                     'https://cdn.example.com/new.jpg')",
        )
        .bind(&listing_id)
        .bind(campus_id)
        .bind(&owner_id)
        .execute(&pool)
        .await
        .expect("insert listing");

        // Enabled moderation: job + pending status committed together.
        let enabled = services::moderation::ModerationService::new_for_test(true);
        enabled
            .submit_image_job(
                &pool,
                campus_id,
                &listing_id,
                "https://cdn.example.com/new.jpg",
                "listing_image",
            )
            .await
            .expect("submit enabled");
        let (status, jobs): (String, i64) = (
            sqlx::query_scalar("SELECT images_moderation_status FROM inventory WHERE id = $1")
                .bind(&listing_id)
                .fetch_one(&pool)
                .await
                .expect("status"),
            sqlx::query_scalar(
                "SELECT COUNT(*) FROM moderation_jobs WHERE resource_id = $1 AND status = 'pending'",
            )
            .bind(&listing_id)
            .fetch_one(&pool)
            .await
            .expect("jobs"),
        );
        assert_eq!((status.as_str(), jobs), ("pending", 1));

        // Disabled moderation: resource marked review-exempt, no job.
        let disabled = services::moderation::ModerationService::new_for_test(false);
        disabled
            .submit_image_job(
                &pool,
                campus_id,
                &listing_id,
                "https://cdn.example.com/new.jpg",
                "listing_image",
            )
            .await
            .expect("submit disabled");
        let status: String =
            sqlx::query_scalar("SELECT images_moderation_status FROM inventory WHERE id = $1")
                .bind(&listing_id)
                .fetch_one(&pool)
                .await
                .expect("status");
        assert_eq!(status, "approved");
    })
    .await;
}

/// The embedding upsert uses `ON CONFLICT (id)`, which requires a unique
/// constraint on `documents.id`. There was only a plain index, so every real
/// (non-noop) embed write failed and rolled back its transaction — invisible to
/// tests that inject a NoopEmbedUpdater. This asserts the schema supports the
/// upsert and that re-embedding the same listing replaces rather than duplicates.
#[tokio::test]
async fn documents_upsert_by_id_is_supported_by_the_schema() {
    with_test_pool(|pool| async move {
        let has_unique: bool = sqlx::query_scalar(
            "SELECT EXISTS (
                SELECT 1 FROM pg_constraint
                WHERE conrelid = 'documents'::regclass
                  AND contype IN ('u', 'p')
                  AND conkey = ARRAY[(
                      SELECT attnum FROM pg_attribute
                      WHERE attrelid = 'documents'::regclass AND attname = 'id'
                  )]::smallint[]
             )",
        )
        .fetch_one(&pool)
        .await
        .expect("constraint lookup");
        assert!(
            has_unique,
            "documents.id needs a UNIQUE/PRIMARY KEY constraint or ON CONFLICT (id) fails"
        );

        // Exercise the exact statement the EmbedUpdater issues, twice.
        let listing_id = format!("embed-upsert-{}", Uuid::new_v4().simple());
        let embedding: Vec<f64> = vec![0.0; 768];
        for text in ["first version", "second version"] {
            sqlx::query(
                "INSERT INTO documents (id, document, embedded_text, embedding) \
                 VALUES ($1, $2::jsonb, $3, $4) \
                 ON CONFLICT (id) DO UPDATE SET \
                   document = EXCLUDED.document, \
                   embedded_text = EXCLUDED.embedded_text, \
                   embedding = EXCLUDED.embedding",
            )
            .bind(&listing_id)
            .bind(serde_json::json!({ "id": listing_id, "content": text }))
            .bind(text)
            .bind(&embedding)
            .execute(&pool)
            .await
            .unwrap_or_else(|e| panic!("embed upsert must succeed ({text}): {e}"));
        }

        let (rows, stored): (i64, String) =
            sqlx::query_as("SELECT count(*), max(embedded_text) FROM documents WHERE id = $1")
                .bind(&listing_id)
                .fetch_one(&pool)
                .await
                .expect("stored document");
        assert_eq!(rows, 1, "re-embedding must replace, not duplicate");
        assert_eq!(
            stored, "second version",
            "upsert must apply the new content"
        );
    })
    .await;
}

/// `migrations/0005_seed_data.sql` is labelled "run manually" but lives in
/// `migrations/`, so sqlx applies it everywhere — shipping an `admin` account
/// whose password (`Test1234`) is published in the repo. Production must refuse
/// to start while those rows exist; non-production keeps them for convenience.
#[tokio::test]
async fn production_refuses_to_start_with_demo_seed_accounts() {
    with_test_pool(|pool| async move {
        // Re-create one seed row exactly as 0005 does (tests truncate users).
        sqlx::query(
            "INSERT INTO users (id, username, password_hash, role, status)
             VALUES ('a0000000-0000-0000-0000-000000000001', 'admin', 'hash', 'admin', 'active')
             ON CONFLICT (id) DO NOTHING",
        )
        .execute(&pool)
        .await
        .expect("seed admin");

        // Non-production: allowed.
        goods4ncu::db::assert_no_demo_seed_in_production(&pool, false)
            .await
            .expect("non-production must tolerate seed accounts");

        // Production: refused, and the message names the account and the fix.
        let error = goods4ncu::db::assert_no_demo_seed_in_production(&pool, true)
            .await
            .expect_err("production must refuse a database with seed accounts");
        let message = error.to_string();
        assert!(
            message.contains("admin"),
            "must name the account: {message}"
        );
        assert!(
            message.contains("remove_demo_seed.sql"),
            "must give the cleanup command: {message}"
        );

        // After removal, production is allowed.
        sqlx::query("DELETE FROM users WHERE id = 'a0000000-0000-0000-0000-000000000001'")
            .execute(&pool)
            .await
            .expect("remove seed");
        goods4ncu::db::assert_no_demo_seed_in_production(&pool, true)
            .await
            .expect("a cleaned database must start in production");
    })
    .await;
}

#[tokio::test]
async fn content_report_routes_require_verified_tenant_and_return_only_report_id() {
    with_test_pool(|pool| async move {
        let password_hash = hash_password("Test1234");
        let reporter_id = Uuid::new_v4().to_string();
        let owner_id = Uuid::new_v4().to_string();
        insert_user(
            &pool,
            &reporter_id,
            &format!("route_reporter_{}", Uuid::new_v4()),
            &password_hash,
            "user",
            "active",
        )
        .await;
        insert_user(
            &pool,
            &owner_id,
            &format!("route_owner_{}", Uuid::new_v4()),
            &password_hash,
            "user",
            "active",
        )
        .await;
        let campus_id: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
            .fetch_one(&pool)
            .await
            .expect("NCU campus");
        let listing_id = Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO inventory (
                 id, campus_id, title, category, brand, condition_score,
                 suggested_price_cny, defects, owner_id, status, direction
             ) VALUES ($1, $2, 'API report target', 'other', 'Test', 8,
                       10000, '[]', $3, 'active', 'offer')",
        )
        .bind(&listing_id)
        .bind(campus_id)
        .bind(&owner_id)
        .execute(&pool)
        .await
        .expect("insert listing");

        let (token, _, _) = generate_access_token_for_campus(
            &reporter_id,
            "user",
            Some(campus_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("reporter token");
        let app = create_router(build_state(pool.clone()), &[]);
        let body = json!({"reason": "疑似诈骗", "details": "请人工核对"});

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/listings/{listing_id}/report"))
                    .header("Content-Type", "application/json")
                    .body(Body::from(body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/listings/{listing_id}/report"))
                    .header("Authorization", bearer(&token))
                    .header("Content-Type", "application/json")
                    .body(Body::from(body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let listing_report = response_json(response).await;
        let listing_fields = listing_report.as_object().expect("report response object");
        assert_eq!(listing_fields.len(), 1);
        let listing_report_id = listing_report["report_id"]
            .as_str()
            .expect("listing report id");
        Uuid::parse_str(listing_report_id).expect("UUID report id");

        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/users/{owner_id}/report"))
                    .header("Authorization", bearer(&token))
                    .header("Content-Type", "application/json")
                    .body(Body::from(json!({"reason": "疑似骚扰"}).to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let user_report = response_json(response).await;
        let user_fields = user_report.as_object().expect("report response object");
        assert_eq!(user_fields.len(), 1);
        Uuid::parse_str(user_report["report_id"].as_str().expect("user report id"))
            .expect("UUID report id");

        let report_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM content_reports WHERE reporter_id = $1")
                .bind(&reporter_id)
                .fetch_one(&pool)
                .await
                .expect("report count");
        assert_eq!(report_count, 2);
    })
    .await;
}

#[tokio::test]
async fn feed_feedback_api_is_tenant_scoped_idempotent_and_server_derived() {
    with_test_pool(|pool| async move {
        let password_hash = hash_password("Test1234");
        let viewer_id = Uuid::new_v4().to_string();
        let owner_id = Uuid::new_v4().to_string();
        for (id, label) in [(&viewer_id, "viewer"), (&owner_id, "owner")] {
            insert_user(
                &pool,
                id,
                &format!("feed_{label}_{}", Uuid::new_v4().simple()),
                &password_hash,
                "user",
                "active",
            )
            .await;
        }
        let campus_id: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
            .fetch_one(&pool)
            .await
            .expect("ncu campus");

        let listing_id = Uuid::new_v4().to_string();
        let self_listing_id = Uuid::new_v4().to_string();
        for (id, owner, title) in [
            (&listing_id, &owner_id, "Target listing"),
            (&self_listing_id, &viewer_id, "Self listing"),
        ] {
            sqlx::query(
                "INSERT INTO inventory (
                    id, campus_id, title, category, brand, condition_score,
                    suggested_price_cny, defects, owner_id, status, direction
                 ) VALUES ($1, $2, $3, 'Electronics', 'Test', 8, 10000,
                           '[]', $4, 'active', 'offer')",
            )
            .bind(id)
            .bind(campus_id)
            .bind(title)
            .bind(owner)
            .execute(&pool)
            .await
            .expect("insert listing");
        }

        let other_campus = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO campuses (id, slug, name_zh, name_en, email_domains)
             VALUES ($1, $2, '反馈测试大学', 'Feedback Test University', ARRAY['feedback.test'])",
        )
        .bind(other_campus)
        .bind(format!("feedback-{}", &other_campus.to_string()[..8]))
        .execute(&pool)
        .await
        .expect("insert other campus");
        let other_listing_id = Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO inventory (
                id, campus_id, title, category, brand, condition_score,
                suggested_price_cny, defects, owner_id, status, direction
             ) VALUES ($1, $2, 'Other campus', 'Electronics', 'Test', 8,
                       10000, '[]', $3, 'active', 'offer')",
        )
        .bind(&other_listing_id)
        .bind(other_campus)
        .bind(&owner_id)
        .execute(&pool)
        .await
        .expect("insert other-campus listing");

        let (token, _, _) = generate_access_token_for_campus(
            &viewer_id,
            "user",
            Some(campus_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("viewer token");
        let app = create_router(build_state(pool.clone()), &[]);

        let feedback_body = |resource_id: &str, action: &str| {
            json!({
                "resource_type": "listing",
                "resource_id": resource_id,
                "action": action,
            })
            .to_string()
        };

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/feed/feedback")
                    .header("Content-Type", "application/json")
                    .body(Body::from(feedback_body(&listing_id, "less_like_this")))
                    .unwrap(),
            )
            .await
            .expect("anonymous response");
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);

        let submit = |resource_id: &str, action: &str| {
            Request::builder()
                .method("POST")
                .uri("/api/feed/feedback")
                .header("Authorization", bearer(&token))
                .header("Content-Type", "application/json")
                .body(Body::from(feedback_body(resource_id, action)))
                .expect("feedback request")
        };
        let response = app
            .clone()
            .oneshot(submit(&listing_id, "less_like_this"))
            .await
            .expect("feedback response");
        assert_eq!(response.status(), StatusCode::OK);
        let first = response_json(response).await;
        assert_eq!(first["resource_id"], listing_id);
        assert_eq!(first["action"], "less_like_this");
        assert!(first.get("signal_key").is_none());
        assert!(first.get("campus_id").is_none());

        let response = app
            .clone()
            .oneshot(submit(&listing_id, "hide"))
            .await
            .expect("idempotent update");
        assert_eq!(response.status(), StatusCode::OK);
        let second = response_json(response).await;
        assert_eq!(second["feedback_id"], first["feedback_id"]);
        let row: (String, String) = sqlx::query_as(
            "SELECT action, signal_key FROM feed_feedback
             WHERE user_id = $1 AND resource_id = $2",
        )
        .bind(&viewer_id)
        .bind(&listing_id)
        .fetch_one(&pool)
        .await
        .expect("stored feedback");
        assert_eq!(row.0, "hide");
        assert_eq!(row.1, "listing:category:electronics");
        let count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM feed_feedback WHERE user_id = $1 AND resource_id = $2",
        )
        .bind(&viewer_id)
        .bind(&listing_id)
        .fetch_one(&pool)
        .await
        .expect("feedback count");
        assert_eq!(count, 1);

        for hidden_target in [&self_listing_id, &other_listing_id] {
            let response = app
                .clone()
                .oneshot(submit(hidden_target, "not_relevant"))
                .await
                .expect("non-enumerable target response");
            assert_eq!(response.status(), StatusCode::NOT_FOUND);
        }

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/feed/preferences")
                    .header("Authorization", bearer(&token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .expect("default preferences");
        assert_eq!(response.status(), StatusCode::OK);
        let preferences = response_json(response).await;
        assert_eq!(preferences["personalization_enabled"], true);
        assert!(preferences["signals_reset_at"].is_null());

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("PUT")
                    .uri("/api/feed/preferences")
                    .header("Authorization", bearer(&token))
                    .header("Content-Type", "application/json")
                    .body(Body::from(
                        json!({"personalization_enabled": false}).to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .expect("update preferences");
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response_json(response).await["personalization_enabled"],
            false
        );

        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/feed/personalization/clear")
                    .header("Authorization", bearer(&token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .expect("clear personalization");
        assert_eq!(response.status(), StatusCode::OK);
        let cleared = response_json(response).await;
        assert_eq!(cleared["personalization_enabled"], false);
        assert!(cleared["signals_reset_at"].is_string());
    })
    .await;
}

#[tokio::test]
async fn listing_feedback_controls_ranking_without_leaking_across_users() {
    with_test_pool(|pool| async move {
        let password_hash = hash_password("Test1234");
        let viewer_id = Uuid::new_v4().to_string();
        let other_viewer_id = Uuid::new_v4().to_string();
        let seller_id = Uuid::new_v4().to_string();
        for (id, label) in [
            (&viewer_id, "viewer"),
            (&other_viewer_id, "other"),
            (&seller_id, "seller"),
        ] {
            insert_user(
                &pool,
                id,
                &format!("listing_rank_{label}_{}", Uuid::new_v4().simple()),
                &password_hash,
                "user",
                "active",
            )
            .await;
        }
        let campus_id: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
            .fetch_one(&pool)
            .await
            .expect("ncu campus");

        let watched_id = Uuid::new_v4().to_string();
        let feedback_target_id = Uuid::new_v4().to_string();
        let same_category_id = Uuid::new_v4().to_string();
        let unrelated_id = Uuid::new_v4().to_string();
        let ordered_signal_id = Uuid::new_v4().to_string();
        let order_category_id = Uuid::new_v4().to_string();
        for (id, category, age_hours) in [
            (&watched_id, "electronics", 4_i32),
            (&feedback_target_id, "electronics", 1_i32),
            (&same_category_id, "electronics", 3_i32),
            (&unrelated_id, "misc", 2_i32),
            (&ordered_signal_id, "books", 6_i32),
            (&order_category_id, "books", 5_i32),
        ] {
            sqlx::query(
                "INSERT INTO inventory (
                    id, campus_id, title, category, brand, condition_score,
                    suggested_price_cny, defects, owner_id, status, direction, created_at
                 ) VALUES ($1, $2, $3, $4, 'Test', 8, 10000, '[]', $5,
                           'active', 'offer', NOW() - make_interval(hours => $6))",
            )
            .bind(id)
            .bind(campus_id)
            .bind(format!("Ranking {id}"))
            .bind(category)
            .bind(&seller_id)
            .bind(age_hours)
            .execute(&pool)
            .await
            .expect("insert listing");
        }
        sqlx::query(
            "INSERT INTO watchlist (user_id, listing_id, created_at)
             VALUES ($1, $2, NOW() - INTERVAL '1 day')",
        )
        .bind(&viewer_id)
        .bind(&watched_id)
        .execute(&pool)
        .await
        .expect("watch listing");
        sqlx::query(
            "INSERT INTO orders (
                id, campus_id, listing_id, buyer_id, seller_id, final_price, status, created_at
             ) VALUES ($1, $2, $3, $4, $5, 10000, 'confirmed', NOW() - INTERVAL '1 day')",
        )
        .bind(Uuid::new_v4().to_string())
        .bind(campus_id)
        .bind(&ordered_signal_id)
        .bind(&viewer_id)
        .bind(&seller_id)
        .execute(&pool)
        .await
        .expect("insert order signal");

        let (viewer_token, _, _) = generate_access_token_for_campus(
            &viewer_id,
            "user",
            Some(campus_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("viewer token");
        let (other_token, _, _) = generate_access_token_for_campus(
            &other_viewer_id,
            "user",
            Some(campus_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("other viewer token");
        let app = create_router(build_state(pool.clone()), &[]);

        let (_, initial) = authenticated_json(
            &app,
            Method::GET,
            "/api/recommendations/feed?direction=offer",
            &viewer_token,
            None,
        )
        .await;
        let initial_items = initial["items"].as_array().expect("initial items");
        let same_category = initial_items
            .iter()
            .find(|item| item["id"] == same_category_id)
            .expect("same-category candidate");
        assert_eq!(same_category["source"], "category_affinity");
        assert_eq!(
            initial_items
                .iter()
                .find(|item| item["id"] == order_category_id)
                .expect("order-category candidate")["source"],
            "category_affinity",
            "order history contributes an affinity signal before reset"
        );
        assert!(
            initial_items
                .iter()
                .position(|item| item["id"] == same_category_id)
                .expect("same-category position")
                < initial_items
                    .iter()
                    .position(|item| item["id"] == unrelated_id)
                    .expect("unrelated position"),
            "watch affinity should outrank newer unrelated inventory"
        );
        assert!(
            !initial_items.iter().any(|item| item["id"] == watched_id),
            "an active watchlist signal is not replayed as a recommendation"
        );

        let (status, disabled) = authenticated_json(
            &app,
            Method::PUT,
            "/api/feed/preferences",
            &viewer_token,
            Some(json!({"personalization_enabled": false})),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(disabled["personalization_enabled"], false);
        let (_, disabled_feed) = authenticated_json(
            &app,
            Method::GET,
            "/api/recommendations/feed?direction=offer",
            &viewer_token,
            None,
        )
        .await;
        let disabled_items = disabled_feed["items"].as_array().expect("disabled items");
        assert_eq!(
            disabled_items
                .iter()
                .find(|item| item["id"] == same_category_id)
                .expect("same-category while disabled")["source"],
            "recency"
        );
        assert!(disabled_items.iter().any(|item| item["id"] == watched_id));

        let (status, _) = authenticated_json(
            &app,
            Method::PUT,
            "/api/feed/preferences",
            &viewer_token,
            Some(json!({"personalization_enabled": true})),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let (status, receipt) = authenticated_json(
            &app,
            Method::POST,
            "/api/feed/feedback",
            &viewer_token,
            Some(json!({
                "resource_type": "listing",
                "resource_id": feedback_target_id,
                "action": "less_like_this"
            })),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(receipt["action"], "less_like_this");

        let (_, downranked) = authenticated_json(
            &app,
            Method::GET,
            "/api/recommendations/feed?direction=offer",
            &viewer_token,
            None,
        )
        .await;
        let downranked_items = downranked["items"].as_array().expect("downranked items");
        assert!(
            !downranked_items
                .iter()
                .any(|item| item["id"] == feedback_target_id),
            "the feedback target is an exact exclusion"
        );
        let same_category = downranked_items
            .iter()
            .find(|item| item["id"] == same_category_id)
            .expect("same-category remains eligible");
        assert_eq!(
            same_category["source"], "recency",
            "an offset affinity must not still claim category_affinity"
        );
        assert!(
            downranked_items
                .iter()
                .position(|item| item["id"] == unrelated_id)
                .expect("unrelated position")
                < downranked_items
                    .iter()
                    .position(|item| item["id"] == same_category_id)
                    .expect("same-category position"),
            "less_like_this downranks the category without banning it"
        );

        let (_, other_feed) = authenticated_json(
            &app,
            Method::GET,
            "/api/recommendations/feed?direction=offer",
            &other_token,
            None,
        )
        .await;
        assert!(
            other_feed["items"]
                .as_array()
                .expect("other viewer items")
                .iter()
                .any(|item| item["id"] == feedback_target_id),
            "one user's exact exclusion must not leak to another user"
        );

        sqlx::query(
            "UPDATE feed_feedback SET updated_at = NOW() - INTERVAL '1 hour'
             WHERE user_id = $1 AND resource_id = $2",
        )
        .bind(&viewer_id)
        .bind(&feedback_target_id)
        .execute(&pool)
        .await
        .expect("age generalized signal");
        let (status, cleared) = authenticated_json(
            &app,
            Method::POST,
            "/api/feed/personalization/clear",
            &viewer_token,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert!(cleared["signals_reset_at"].is_string());
        let (_, cleared_feed) = authenticated_json(
            &app,
            Method::GET,
            "/api/recommendations/feed?direction=offer",
            &viewer_token,
            None,
        )
        .await;
        let cleared_items = cleared_feed["items"].as_array().expect("cleared items");
        assert!(cleared_items.iter().any(|item| item["id"] == watched_id));
        assert!(
            !cleared_items
                .iter()
                .any(|item| item["id"] == feedback_target_id),
            "clear forgets generalized signals but preserves exact exclusions"
        );
        assert_eq!(
            cleared_items
                .iter()
                .find(|item| item["id"] == same_category_id)
                .expect("candidate after clear")["source"],
            "recency"
        );
        assert_eq!(
            cleared_items
                .iter()
                .find(|item| item["id"] == order_category_id)
                .expect("order-category candidate after clear")["source"],
            "recency",
            "clear ignores order-history affinity older than signals_reset_at"
        );
    })
    .await;
}

#[tokio::test]
async fn similar_recommendations_apply_feedback_to_vector_and_recency_paths() {
    with_test_pool(|pool| async move {
        let password_hash = hash_password("Test1234");
        let viewer_id = Uuid::new_v4().to_string();
        let other_viewer_id = Uuid::new_v4().to_string();
        let seller_id = Uuid::new_v4().to_string();
        for (id, label) in [
            (&viewer_id, "viewer"),
            (&other_viewer_id, "other"),
            (&seller_id, "seller"),
        ] {
            insert_user(
                &pool,
                id,
                &format!("similar_{label}_{}", Uuid::new_v4().simple()),
                &password_hash,
                "user",
                "active",
            )
            .await;
        }
        let campus_id: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
            .fetch_one(&pool)
            .await
            .expect("ncu campus");

        let source_id = Uuid::new_v4().to_string();
        let fallback_source_id = Uuid::new_v4().to_string();
        let feedback_target_id = Uuid::new_v4().to_string();
        let same_category_id = Uuid::new_v4().to_string();
        let other_category_id = Uuid::new_v4().to_string();
        let self_candidate_id = Uuid::new_v4().to_string();
        let inactive_id = Uuid::new_v4().to_string();
        for (id, title, category, owner, status, age_hours) in [
            (
                &source_id,
                "Vector source",
                "electronics",
                &seller_id,
                "active",
                10_i32,
            ),
            (
                &fallback_source_id,
                "Fallback source",
                "other",
                &seller_id,
                "active",
                9,
            ),
            (
                &feedback_target_id,
                "Closest electronics",
                "electronics",
                &seller_id,
                "active",
                0,
            ),
            (
                &same_category_id,
                "Second electronics",
                "electronics",
                &seller_id,
                "active",
                1,
            ),
            (
                &other_category_id,
                "Further book",
                "books",
                &seller_id,
                "active",
                2,
            ),
            (
                &self_candidate_id,
                "Viewer owned candidate",
                "electronics",
                &viewer_id,
                "active",
                0,
            ),
            (
                &inactive_id,
                "Inactive candidate",
                "books",
                &seller_id,
                "sold",
                0,
            ),
        ] {
            sqlx::query(
                "INSERT INTO inventory (
                    id, campus_id, title, category, brand, condition_score,
                    suggested_price_cny, defects, owner_id, status, direction, created_at
                 ) VALUES ($1, $2, $3, $4, 'Test', 8, 10000, '[]', $5, $6,
                           'offer', NOW() - make_interval(hours => $7))",
            )
            .bind(id)
            .bind(campus_id)
            .bind(title)
            .bind(category)
            .bind(owner)
            .bind(status)
            .bind(age_hours)
            .execute(&pool)
            .await
            .expect("insert similar listing");
        }

        let embedding = |x: f64, y: f64| {
            let mut value = vec![0.0_f64; 768];
            value[0] = x;
            value[1] = y;
            value
        };
        for (id, vector) in [
            (&source_id, embedding(1.0, 0.0)),
            (&feedback_target_id, embedding(1.0, 0.0)),
            (&same_category_id, embedding(0.999, 0.001)),
            (&other_category_id, embedding(0.8, 0.2)),
            (&self_candidate_id, embedding(1.0, 0.0)),
            (&inactive_id, embedding(1.0, 0.0)),
        ] {
            sqlx::query(
                "INSERT INTO documents (id, document, embedded_text, embedding)
                 VALUES ($1, $2::jsonb, $3, $4)",
            )
            .bind(id)
            .bind(json!({"id": id}))
            .bind(id)
            .bind(vector)
            .execute(&pool)
            .await
            .expect("insert embedding");
        }

        let (viewer_token, _, _) = generate_access_token_for_campus(
            &viewer_id,
            "user",
            Some(campus_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("viewer token");
        let (other_token, _, _) = generate_access_token_for_campus(
            &other_viewer_id,
            "user",
            Some(campus_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("other viewer token");
        let app = create_router(build_state(pool.clone()), &[]);
        let similar_uri = format!("/api/recommendations/similar?listing_id={source_id}&limit=10");

        for uri in [
            similar_uri.as_str(),
            "/api/recommendations/feed?direction=offer",
        ] {
            let (status, _) = authenticated_json(&app, Method::GET, uri, "not-a-jwt", None).await;
            assert_eq!(
                status,
                StatusCode::UNAUTHORIZED,
                "a malformed Bearer token must not silently lose viewer filtering"
            );
        }

        let (_, initial) =
            authenticated_json(&app, Method::GET, &similar_uri, &viewer_token, None).await;
        assert_eq!(initial["ranking_version"], "2026.07-similar-feedback-v1");
        let initial_items = initial["items"].as_array().expect("initial similar items");
        for expected in [&feedback_target_id, &same_category_id, &other_category_id] {
            assert!(
                initial_items.iter().any(|item| item["id"] == *expected),
                "eligible vector candidate {expected} should be present"
            );
        }
        assert!(
            !initial_items
                .iter()
                .any(|item| item["id"] == self_candidate_id || item["id"] == inactive_id),
            "self-owned and inactive candidates must be filtered before ranking"
        );
        for item in initial_items {
            assert_eq!(item["rank_reason"], "vector_similarity");
            assert_eq!(item["source"], "vector_similarity");
            let object = item.as_object().expect("recommendation object");
            assert!(!object.contains_key("owner_id"));
            assert!(!object.contains_key("signal_key"));
        }

        let (status, _) = authenticated_json(
            &app,
            Method::POST,
            "/api/feed/feedback",
            &viewer_token,
            Some(json!({
                "resource_type": "listing",
                "resource_id": feedback_target_id,
                "action": "less_like_this"
            })),
        )
        .await;
        assert_eq!(status, StatusCode::OK);

        let (_, downranked) =
            authenticated_json(&app, Method::GET, &similar_uri, &viewer_token, None).await;
        let downranked_items = downranked["items"].as_array().expect("downranked items");
        assert!(
            !downranked_items
                .iter()
                .any(|item| item["id"] == feedback_target_id),
            "feedback target must be an exact exclusion"
        );
        let position = |items: &[Value], id: &str| {
            items
                .iter()
                .position(|item| item["id"] == id)
                .unwrap_or_else(|| panic!("missing candidate {id}"))
        };
        assert!(
            position(downranked_items, &other_category_id)
                < position(downranked_items, &same_category_id),
            "less_like_this should demote same-category vector candidates"
        );

        let fallback_uri =
            format!("/api/recommendations/similar?listing_id={fallback_source_id}&limit=2");
        let (_, fallback) =
            authenticated_json(&app, Method::GET, &fallback_uri, &viewer_token, None).await;
        let fallback_items = fallback["items"].as_array().expect("fallback items");
        assert_eq!(fallback_items.len(), 2);
        assert!(
            !fallback_items
                .iter()
                .any(|item| item["id"] == feedback_target_id),
            "recency fallback must exact-filter before applying its limit"
        );
        assert_eq!(fallback_items[0]["id"], other_category_id);
        assert_eq!(fallback_items[0]["rank_reason"], "recency");
        assert_eq!(fallback_items[0]["source"], "recency");

        let (status, _) = authenticated_json(
            &app,
            Method::GET,
            &format!("/api/recommendations/similar?listing_id={inactive_id}"),
            &viewer_token,
            None,
        )
        .await;
        assert_eq!(
            status,
            StatusCode::NOT_FOUND,
            "an inactive listing cannot be used as a recommendation source"
        );

        let (_, other_view) =
            authenticated_json(&app, Method::GET, &similar_uri, &other_token, None).await;
        assert!(
            other_view["items"]
                .as_array()
                .expect("other viewer items")
                .iter()
                .any(|item| item["id"] == feedback_target_id),
            "one viewer's exact feedback must not affect another viewer"
        );

        let (status, _) = authenticated_json(
            &app,
            Method::PUT,
            "/api/feed/preferences",
            &viewer_token,
            Some(json!({"personalization_enabled": false})),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let (_, disabled) =
            authenticated_json(&app, Method::GET, &similar_uri, &viewer_token, None).await;
        let disabled_items = disabled["items"].as_array().expect("disabled items");
        assert!(
            !disabled_items
                .iter()
                .any(|item| item["id"] == feedback_target_id),
            "turning personalization off must preserve exact exclusions"
        );
        assert!(
            position(disabled_items, &same_category_id)
                < position(disabled_items, &other_category_id),
            "turning personalization off restores vector order"
        );

        let (status, _) = authenticated_json(
            &app,
            Method::PUT,
            "/api/feed/preferences",
            &viewer_token,
            Some(json!({"personalization_enabled": true})),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        sqlx::query(
            "UPDATE feed_feedback SET updated_at = NOW() - INTERVAL '1 hour'
             WHERE user_id = $1 AND resource_id = $2",
        )
        .bind(&viewer_id)
        .bind(&feedback_target_id)
        .execute(&pool)
        .await
        .expect("age similar feedback");
        let (status, _) = authenticated_json(
            &app,
            Method::POST,
            "/api/feed/personalization/clear",
            &viewer_token,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let (_, cleared) =
            authenticated_json(&app, Method::GET, &similar_uri, &viewer_token, None).await;
        let cleared_items = cleared["items"].as_array().expect("cleared items");
        assert!(
            !cleared_items
                .iter()
                .any(|item| item["id"] == feedback_target_id),
            "reset must not restore an explicitly rejected candidate"
        );
        assert!(
            position(cleared_items, &same_category_id)
                < position(cleared_items, &other_category_id),
            "reset ignores generalized feedback older than signals_reset_at"
        );

        for (resource_id, action) in [
            (&same_category_id, "hide"),
            (&other_category_id, "not_relevant"),
        ] {
            let (status, _) = authenticated_json(
                &app,
                Method::POST,
                "/api/feed/feedback",
                &viewer_token,
                Some(json!({
                    "resource_type": "listing",
                    "resource_id": resource_id,
                    "action": action
                })),
            )
            .await;
            assert_eq!(status, StatusCode::OK);
        }
        for uri in [&similar_uri, &fallback_uri] {
            let (_, response) =
                authenticated_json(&app, Method::GET, uri, &viewer_token, None).await;
            let items = response["items"]
                .as_array()
                .expect("filtered similar items");
            assert!(
                !items.iter().any(|item| {
                    item["id"] == same_category_id || item["id"] == other_category_id
                }),
                "hide and not_relevant must exact-filter both recommendation paths"
            );
        }
    })
    .await;
}

#[tokio::test]
async fn wanted_matches_are_versioned_private_and_feedback_aware() {
    with_test_pool(|pool| async move {
        let password_hash = hash_password("Test1234");
        let requester_id = Uuid::new_v4().to_string();
        let other_viewer_id = Uuid::new_v4().to_string();
        let seller_id = Uuid::new_v4().to_string();
        for (id, label) in [
            (&requester_id, "requester"),
            (&other_viewer_id, "other"),
            (&seller_id, "seller"),
        ] {
            insert_user(
                &pool,
                id,
                &format!("wanted_match_{label}_{}", Uuid::new_v4().simple()),
                &password_hash,
                "user",
                "active",
            )
            .await;
        }
        let campus_id: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
            .fetch_one(&pool)
            .await
            .expect("ncu campus");

        let wanted_id = Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO inventory (
                id, campus_id, title, category, brand, condition_score,
                suggested_price_cny, defects, owner_id, status, direction
             ) VALUES ($1, $2, '想收一台显示器', 'electronics', '不限', 5, 50000,
                       '[]', $3, 'active', 'wanted')",
        )
        .bind(&wanted_id)
        .bind(campus_id)
        .bind(&requester_id)
        .execute(&pool)
        .await
        .expect("insert wanted");

        let feedback_target_id = Uuid::new_v4().to_string();
        let same_brand_id = Uuid::new_v4().to_string();
        let alternate_brand_id = Uuid::new_v4().to_string();
        let hidden_id = Uuid::new_v4().to_string();
        let irrelevant_id = Uuid::new_v4().to_string();
        let over_budget_id = Uuid::new_v4().to_string();
        let low_condition_id = Uuid::new_v4().to_string();
        let wrong_category_id = Uuid::new_v4().to_string();
        let inactive_id = Uuid::new_v4().to_string();
        let self_owned_id = Uuid::new_v4().to_string();
        for (id, brand, category, price, condition, owner, status, age_hours) in [
            (
                &feedback_target_id,
                "Acme",
                "electronics",
                30000_i64,
                8_i32,
                &seller_id,
                "active",
                0_i32,
            ),
            (
                &same_brand_id,
                "Acme",
                "electronics",
                32000,
                8,
                &seller_id,
                "active",
                1,
            ),
            (
                &alternate_brand_id,
                "Beta",
                "electronics",
                33000,
                8,
                &seller_id,
                "active",
                2,
            ),
            (
                &hidden_id,
                "Gamma",
                "electronics",
                34000,
                8,
                &seller_id,
                "active",
                3,
            ),
            (
                &irrelevant_id,
                "Delta",
                "electronics",
                35000,
                8,
                &seller_id,
                "active",
                4,
            ),
            (
                &over_budget_id,
                "Budget",
                "electronics",
                60000,
                8,
                &seller_id,
                "active",
                0,
            ),
            (
                &low_condition_id,
                "Condition",
                "electronics",
                30000,
                4,
                &seller_id,
                "active",
                0,
            ),
            (
                &wrong_category_id,
                "Category",
                "books",
                30000,
                8,
                &seller_id,
                "active",
                0,
            ),
            (
                &inactive_id,
                "Inactive",
                "electronics",
                30000,
                8,
                &seller_id,
                "sold",
                0,
            ),
            (
                &self_owned_id,
                "Self",
                "electronics",
                30000,
                8,
                &requester_id,
                "active",
                0,
            ),
        ] {
            sqlx::query(
                "INSERT INTO inventory (
                    id, campus_id, title, category, brand, condition_score,
                    suggested_price_cny, defects, owner_id, status, direction, created_at
                 ) VALUES ($1, $2, $3, $4, $5, $6, $7, '[]', $8, $9, 'offer',
                           NOW() - make_interval(hours => $10))",
            )
            .bind(id)
            .bind(campus_id)
            .bind(format!("匹配候选 {brand}"))
            .bind(category)
            .bind(brand)
            .bind(condition)
            .bind(price)
            .bind(owner)
            .bind(status)
            .bind(age_hours)
            .execute(&pool)
            .await
            .expect("insert wanted match candidate");
        }

        let (requester_token, _, _) = generate_access_token_for_campus(
            &requester_id,
            "user",
            Some(campus_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("requester token");
        let (other_token, _, _) = generate_access_token_for_campus(
            &other_viewer_id,
            "user",
            Some(campus_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("other token");
        let app = create_router(build_state(pool.clone()), &[]);
        let matches_uri = format!("/api/listings/{wanted_id}/matches");

        let (status, initial) =
            authenticated_json(&app, Method::GET, &matches_uri, &requester_token, None).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(initial["ranking_version"], "2026.07-wanted-feedback-v1");
        let initial_items = initial["items"].as_array().expect("initial matches");
        for expected in [
            &feedback_target_id,
            &same_brand_id,
            &alternate_brand_id,
            &hidden_id,
            &irrelevant_id,
        ] {
            assert!(
                initial_items.iter().any(|item| item["id"] == *expected),
                "eligible candidate {expected} should be present"
            );
        }
        for rejected in [
            &over_budget_id,
            &low_condition_id,
            &wrong_category_id,
            &inactive_id,
            &self_owned_id,
        ] {
            assert!(
                !initial_items.iter().any(|item| item["id"] == *rejected),
                "hard-ineligible candidate {rejected} must not be returned"
            );
        }
        for item in initial_items {
            assert_eq!(item["rank_reason"], "known_slots_compatible");
            assert_eq!(item["source"], "wanted_match");
            assert_eq!(item["ranking_version"], "2026.07-wanted-feedback-v1");
            let summary = item["match_summary"].as_array().expect("match summary");
            for reason in [
                "category_match",
                "price_within_constraint",
                "condition_at_least_requested",
            ] {
                assert!(
                    summary.iter().any(|value| value == reason),
                    "missing truthful match reason {reason}"
                );
            }
            let object = item.as_object().expect("match object");
            for private in [
                "owner_id",
                "campus_id",
                "signal_key",
                "feedback_weight",
                "distance",
            ] {
                assert!(
                    !object.contains_key(private),
                    "private ranking field {private} leaked"
                );
            }
        }

        for (resource_id, action) in [
            (&feedback_target_id, "less_like_this"),
            (&hidden_id, "hide"),
            (&irrelevant_id, "not_relevant"),
        ] {
            let (status, _) = authenticated_json(
                &app,
                Method::POST,
                "/api/feed/feedback",
                &requester_token,
                Some(json!({
                    "resource_type": "listing",
                    "resource_id": resource_id,
                    "action": action
                })),
            )
            .await;
            assert_eq!(status, StatusCode::OK);
        }

        let (_, downranked) =
            authenticated_json(&app, Method::GET, &matches_uri, &requester_token, None).await;
        let downranked_items = downranked["items"].as_array().expect("downranked matches");
        for excluded in [&feedback_target_id, &hidden_id, &irrelevant_id] {
            assert!(
                !downranked_items.iter().any(|item| item["id"] == *excluded),
                "every explicit feedback action must exact-filter its target"
            );
        }
        let position = |items: &[Value], id: &str| {
            items
                .iter()
                .position(|item| item["id"] == id)
                .unwrap_or_else(|| panic!("missing wanted candidate {id}"))
        };
        assert!(
            position(downranked_items, &alternate_brand_id)
                < position(downranked_items, &same_brand_id),
            "less_like_this should demote same-brand siblings within the hard category"
        );

        let (_, other_view) =
            authenticated_json(&app, Method::GET, &matches_uri, &other_token, None).await;
        let other_items = other_view["items"]
            .as_array()
            .expect("other viewer matches");
        for expected in [&feedback_target_id, &hidden_id, &irrelevant_id] {
            assert!(
                other_items.iter().any(|item| item["id"] == *expected),
                "one user's feedback must not affect another user's matches"
            );
        }

        let (status, _) = authenticated_json(
            &app,
            Method::PUT,
            "/api/feed/preferences",
            &requester_token,
            Some(json!({"personalization_enabled": false})),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let (_, disabled) =
            authenticated_json(&app, Method::GET, &matches_uri, &requester_token, None).await;
        let disabled_items = disabled["items"].as_array().expect("disabled matches");
        assert!(
            position(disabled_items, &same_brand_id)
                < position(disabled_items, &alternate_brand_id),
            "turning personalization off restores the base match order"
        );
        for excluded in [&feedback_target_id, &hidden_id, &irrelevant_id] {
            assert!(
                !disabled_items.iter().any(|item| item["id"] == *excluded),
                "personalization off must preserve exact exclusions"
            );
        }

        let (status, _) = authenticated_json(
            &app,
            Method::PUT,
            "/api/feed/preferences",
            &requester_token,
            Some(json!({"personalization_enabled": true})),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        sqlx::query(
            "UPDATE feed_feedback SET updated_at = NOW() - INTERVAL '1 hour'
             WHERE user_id = $1",
        )
        .bind(&requester_id)
        .execute(&pool)
        .await
        .expect("age wanted feedback");
        let (status, _) = authenticated_json(
            &app,
            Method::POST,
            "/api/feed/personalization/clear",
            &requester_token,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let (_, cleared) =
            authenticated_json(&app, Method::GET, &matches_uri, &requester_token, None).await;
        let cleared_items = cleared["items"].as_array().expect("cleared matches");
        assert!(
            position(cleared_items, &same_brand_id) < position(cleared_items, &alternate_brand_id),
            "reset ignores old same-brand feedback"
        );
        for excluded in [&feedback_target_id, &hidden_id, &irrelevant_id] {
            assert!(
                !cleared_items.iter().any(|item| item["id"] == *excluded),
                "reset must preserve exact exclusions"
            );
        }

        sqlx::query("UPDATE inventory SET status = 'fulfilled' WHERE id = $1")
            .bind(&wanted_id)
            .execute(&pool)
            .await
            .expect("fulfill wanted");
        let (_, fulfilled) =
            authenticated_json(&app, Method::GET, &matches_uri, &requester_token, None).await;
        assert_eq!(fulfilled["ranking_version"], "2026.07-wanted-feedback-v1");
        assert!(fulfilled["items"]
            .as_array()
            .expect("fulfilled items")
            .is_empty());

        sqlx::query("UPDATE inventory SET status = 'active' WHERE id = $1")
            .bind(&wanted_id)
            .execute(&pool)
            .await
            .expect("reopen wanted");
        let (_, reopened) =
            authenticated_json(&app, Method::GET, &matches_uri, &requester_token, None).await;
        for excluded in [&feedback_target_id, &hidden_id, &irrelevant_id] {
            assert!(
                !reopened["items"]
                    .as_array()
                    .expect("reopened matches")
                    .iter()
                    .any(|item| item["id"] == *excluded),
                "reopening a wanted must not restore exact-hidden candidates"
            );
        }

        let other_campus_id = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO campuses (id, slug, name_zh, name_en, email_domains)
             VALUES ($1, $2, '跨校匹配测试', 'Cross-campus match test', ARRAY['match.test'])",
        )
        .bind(other_campus_id)
        .bind(format!(
            "wanted-match-{}",
            &other_campus_id.to_string()[..8]
        ))
        .execute(&pool)
        .await
        .expect("insert other campus");
        let other_wanted_id = Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO inventory (
                id, campus_id, title, category, brand, condition_score,
                suggested_price_cny, defects, owner_id, status, direction
             ) VALUES ($1, $2, 'Other campus wanted', 'electronics', '不限', 5,
                       50000, '[]', $3, 'active', 'wanted')",
        )
        .bind(&other_wanted_id)
        .bind(other_campus_id)
        .bind(&seller_id)
        .execute(&pool)
        .await
        .expect("insert other-campus wanted");
        let response = app
            .oneshot(
                Request::builder()
                    .uri(format!("/api/listings/{other_wanted_id}/matches"))
                    .header("Authorization", bearer(&requester_token))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .expect("cross-campus source response");
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    })
    .await;
}

#[tokio::test]
async fn intent_feedback_filters_and_explains_feed_and_matches() {
    with_test_pool(|pool| async move {
        let password_hash = hash_password("Test1234");
        let viewer_id = Uuid::new_v4().to_string();
        let other_viewer_id = Uuid::new_v4().to_string();
        let author_id = Uuid::new_v4().to_string();
        for (id, label) in [
            (&viewer_id, "viewer"),
            (&other_viewer_id, "other"),
            (&author_id, "author"),
        ] {
            insert_user(
                &pool,
                id,
                &format!("intent_rank_{label}_{}", Uuid::new_v4().simple()),
                &password_hash,
                "user",
                "active",
            )
            .await;
        }
        let campus_id: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
            .fetch_one(&pool)
            .await
            .expect("ncu campus");
        let service = IntentService::new(pool.clone());

        let companion_target = service
            .create(active_intent(
                campus_id,
                &author_id,
                kinds::COMPANION,
                "找最新的羽毛球搭子",
                Slots::default(),
            ))
            .await
            .expect("create companion target");
        let companion_candidate = service
            .create(active_intent(
                campus_id,
                &author_id,
                kinds::COMPANION,
                "找另一个羽毛球搭子",
                Slots::default(),
            ))
            .await
            .expect("create companion candidate");
        let help_candidate = service
            .create(active_intent(
                campus_id,
                &author_id,
                kinds::HELP,
                "请帮忙搬一个纸箱",
                Slots::default(),
            ))
            .await
            .expect("create help candidate");
        let seeking_slots = Slots {
            category: Some("electronics".to_string()),
            price: Some(PriceSlot::Range {
                min_cents: None,
                max_cents: Some(30_000),
            }),
            condition_score: Some(7),
            ..Default::default()
        };
        let mine = service
            .create(active_intent(
                campus_id,
                &viewer_id,
                kinds::GOODS_SEEK,
                "收一台三百元以内的显示器",
                seeking_slots,
            ))
            .await
            .expect("create seeking intent");
        let matching_slots = Slots {
            category: Some("electronics".to_string()),
            price: Some(PriceSlot::Exact { cents: 20_000 }),
            condition_score: Some(8),
            ..Default::default()
        };
        let matching_target = service
            .create(active_intent(
                campus_id,
                &author_id,
                kinds::GOODS_OFFER,
                "出一台两百元显示器",
                matching_slots.clone(),
            ))
            .await
            .expect("create matching target");
        let matching_visible = service
            .create(active_intent(
                campus_id,
                &author_id,
                kinds::GOODS_OFFER,
                "再出一台两百元显示器",
                matching_slots,
            ))
            .await
            .expect("create visible match");
        let incompatible = service
            .create(active_intent(
                campus_id,
                &author_id,
                kinds::GOODS_OFFER,
                "出一台五百元显示器",
                Slots {
                    category: Some("electronics".to_string()),
                    price: Some(PriceSlot::Exact { cents: 50_000 }),
                    condition_score: Some(8),
                    ..Default::default()
                },
            ))
            .await
            .expect("create incompatible offer");

        for (id, age_hours) in [
            (companion_target, 1_i32),
            (companion_candidate, 2_i32),
            (help_candidate, 3_i32),
            (mine, 4_i32),
            (matching_target, 5_i32),
            (matching_visible, 6_i32),
            (incompatible, 7_i32),
        ] {
            sqlx::query(
                "UPDATE intents SET created_at = NOW() - make_interval(hours => $2)
                 WHERE id = $1",
            )
            .bind(id)
            .bind(age_hours)
            .execute(&pool)
            .await
            .expect("set intent age");
        }
        let companion_target = companion_target.to_string();
        let companion_candidate = companion_candidate.to_string();
        let help_candidate = help_candidate.to_string();
        let mine = mine.to_string();
        let matching_target = matching_target.to_string();
        let matching_visible = matching_visible.to_string();
        let incompatible = incompatible.to_string();

        let (viewer_token, _, _) = generate_access_token_for_campus(
            &viewer_id,
            "user",
            Some(campus_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("viewer token");
        let (other_token, _, _) = generate_access_token_for_campus(
            &other_viewer_id,
            "user",
            Some(campus_id),
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("other viewer token");
        let app = create_router(build_state(pool.clone()), &[]);

        for (resource_id, action) in [
            (&companion_target, "less_like_this"),
            (&matching_target, "hide"),
        ] {
            let (status, _) = authenticated_json(
                &app,
                Method::POST,
                "/api/feed/feedback",
                &viewer_token,
                Some(json!({
                    "resource_type": "intent",
                    "resource_id": resource_id,
                    "action": action,
                })),
            )
            .await;
            assert_eq!(status, StatusCode::OK);
        }

        let (_, downranked_feed) =
            authenticated_json(&app, Method::GET, "/api/intents/feed", &viewer_token, None).await;
        assert_eq!(downranked_feed["ranking_version"], "2026.07-intent-hard-v1");
        let downranked_items = downranked_feed["items"]
            .as_array()
            .expect("downranked intent feed");
        assert!(
            !downranked_items
                .iter()
                .any(|item| item["id"] == companion_target),
            "feedback exact-hides the intent"
        );
        assert!(
            downranked_items
                .iter()
                .position(|item| item["id"] == help_candidate)
                .expect("help position")
                < downranked_items
                    .iter()
                    .position(|item| item["id"] == companion_candidate)
                    .expect("companion position"),
            "less_like_this downranks the same intent kind without banning it"
        );
        for item in downranked_items {
            assert_eq!(item["rank_reason"], "recent_campus_intent");
            assert_eq!(
                item["match_summary"],
                json!(["same_campus", "active_intent"])
            );
            assert_eq!(item["source"], "campus_recency");
            assert_eq!(item["ranking_version"], "2026.07-intent-hard-v1");
            assert!(item.get("author_id").is_none());
        }

        let (_, other_feed) =
            authenticated_json(&app, Method::GET, "/api/intents/feed", &other_token, None).await;
        let other_items = other_feed["items"].as_array().expect("other viewer feed");
        assert!(other_items
            .iter()
            .any(|item| item["id"] == companion_target));
        assert!(other_items.iter().any(|item| item["id"] == matching_target));

        let (_, _) = authenticated_json(
            &app,
            Method::PUT,
            "/api/feed/preferences",
            &viewer_token,
            Some(json!({"personalization_enabled": false})),
        )
        .await;
        let (_, disabled_feed) =
            authenticated_json(&app, Method::GET, "/api/intents/feed", &viewer_token, None).await;
        let disabled_items = disabled_feed["items"].as_array().expect("disabled feed");
        assert!(
            disabled_items
                .iter()
                .position(|item| item["id"] == companion_candidate)
                .expect("companion position")
                < disabled_items
                    .iter()
                    .position(|item| item["id"] == help_candidate)
                    .expect("help position"),
            "personalization off ignores generalized intent signals"
        );
        assert!(!disabled_items
            .iter()
            .any(|item| item["id"] == companion_target));

        let (_, _) = authenticated_json(
            &app,
            Method::PUT,
            "/api/feed/preferences",
            &viewer_token,
            Some(json!({"personalization_enabled": true})),
        )
        .await;
        let (_, reenabled_feed) =
            authenticated_json(&app, Method::GET, "/api/intents/feed", &viewer_token, None).await;
        let reenabled_items = reenabled_feed["items"].as_array().expect("re-enabled feed");
        assert!(
            reenabled_items
                .iter()
                .position(|item| item["id"] == help_candidate)
                .expect("help position")
                < reenabled_items
                    .iter()
                    .position(|item| item["id"] == companion_candidate)
                    .expect("companion position")
        );

        sqlx::query(
            "UPDATE feed_feedback SET updated_at = NOW() - INTERVAL '1 hour'
             WHERE user_id = $1 AND resource_type = 'intent'",
        )
        .bind(&viewer_id)
        .execute(&pool)
        .await
        .expect("age intent signals");
        let (status, _) = authenticated_json(
            &app,
            Method::POST,
            "/api/feed/personalization/clear",
            &viewer_token,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let (_, cleared_feed) =
            authenticated_json(&app, Method::GET, "/api/intents/feed", &viewer_token, None).await;
        let cleared_items = cleared_feed["items"].as_array().expect("cleared feed");
        assert!(
            cleared_items
                .iter()
                .position(|item| item["id"] == companion_candidate)
                .expect("companion position")
                < cleared_items
                    .iter()
                    .position(|item| item["id"] == help_candidate)
                    .expect("help position"),
            "clear restores recency once generalized downrank is ignored"
        );
        assert!(!cleared_items
            .iter()
            .any(|item| item["id"] == companion_target));

        let (status, matches) = authenticated_json(
            &app,
            Method::GET,
            &format!("/api/intents/{mine}/matches"),
            &viewer_token,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(matches["ranking_version"], "2026.07-intent-hard-v1");
        let match_items = matches["items"].as_array().expect("matches");
        assert!(
            !match_items.iter().any(|item| item["id"] == matching_target),
            "clear preserves exact exclusions in matches"
        );
        assert!(!match_items.iter().any(|item| item["id"] == incompatible));
        let visible_match = match_items
            .iter()
            .find(|item| item["id"] == matching_visible)
            .expect("compatible match remains");
        assert_eq!(visible_match["rank_reason"], "known_slots_compatible");
        assert_eq!(visible_match["source"], "hard_constraints");
        assert_eq!(
            visible_match["match_summary"],
            json!([
                "kind_compatible",
                "category_match",
                "price_within_constraint",
                "condition_at_least_requested"
            ])
        );
        assert_eq!(visible_match["ranking_version"], "2026.07-intent-hard-v1");
        assert!(visible_match.get("author_id").is_none());
    })
    .await;
}
