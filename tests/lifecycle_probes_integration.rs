//! Health probe behaviour across the process lifecycle.
//!
//! These assertions are what makes a rolling deploy safe: readiness has to fail
//! the moment draining starts so the load balancer stops routing here, while
//! liveness has to keep succeeding so the orchestrator does not treat an
//! orderly drain as a crash and kill the instance before it finishes.

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use goods4ncu::agents::router::IntentRouter;
use goods4ncu::api::{create_router, ApiAgents, ApiInfrastructure, ApiSecrets, AppState};
use goods4ncu::lifecycle::{ShutdownController, ShutdownSignal};
use goods4ncu::repositories::{
    PostgresAuthRepository, PostgresChatRepository, PostgresListingRepository,
    PostgresOrderRepository, PostgresUserRepository,
};
use goods4ncu::services::{self, notification::NotificationService};
use goods4ncu::test_infra::with_test_pool;
use serde_json::Value;
use std::sync::Arc;
use tower::ServiceExt;

fn build_state(pool: sqlx::PgPool, shutdown: ShutdownSignal) -> AppState {
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
            shutdown,
        },
        agents: ApiAgents {
            llm_provider: Arc::new(
                goods4ncu::llm::gemini::GeminiProvider::new("test-key", 768)
                    .expect("gemini provider init"),
            ),
            tri_tier_router: goods4ncu::agents::router::TriTierIntentRouter::new(
                IntentRouter::new(vec![]),
                None,
                None,
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

async fn get(app: axum::Router, uri: &str) -> (StatusCode, String) {
    let response = app
        .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
        .await
        .expect("probe request");
    let status = response.status();
    let bytes = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("probe body");
    (
        status,
        String::from_utf8(bytes.to_vec()).expect("utf8 body"),
    )
}

#[tokio::test]
async fn probes_report_serving_while_the_process_is_running() {
    with_test_pool(|pool| async move {
        let app = create_router(build_state(pool, ShutdownSignal::never()), &[]);

        let (status, body) = get(app.clone(), "/api/livez").await;
        assert_eq!(status, StatusCode::OK);
        let parsed: Value = serde_json::from_str(&body).expect("livez json");
        assert_eq!(parsed["status"], "alive");

        let (status, body) = get(app.clone(), "/api/readyz").await;
        assert_eq!(status, StatusCode::OK);
        let parsed: Value = serde_json::from_str(&body).expect("readyz json");
        assert_eq!(parsed["status"], "ready");

        // The legacy path stays behaviour-compatible for existing probes.
        let (status, body) = get(app, "/api/health").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body, "OK");
    })
    .await;
}

#[tokio::test]
async fn readiness_fails_once_draining_so_the_balancer_stops_routing_here() {
    with_test_pool(|pool| async move {
        let controller = ShutdownController::new();
        let app = create_router(build_state(pool, controller.signal()), &[]);

        let (status, _) = get(app.clone(), "/api/readyz").await;
        assert_eq!(status, StatusCode::OK, "ready before the signal");

        controller.trigger();

        let (status, body) = get(app.clone(), "/api/readyz").await;
        assert_eq!(
            status,
            StatusCode::SERVICE_UNAVAILABLE,
            "readiness must fail immediately when draining"
        );
        let parsed: Value = serde_json::from_str(&body).expect("readyz error json");
        assert_eq!(parsed["code"], "service_unavailable");
        // 503 tells a client to retry elsewhere; 500 would surface as a hard
        // failure and be counted against the error budget.
        assert!(parsed["trace_id"].is_string());

        let (status, _) = get(app, "/api/health").await;
        assert_eq!(
            status,
            StatusCode::SERVICE_UNAVAILABLE,
            "the legacy alias must drain too, or Compose keeps routing to it"
        );
    })
    .await;
}

#[tokio::test]
async fn liveness_keeps_passing_while_draining() {
    with_test_pool(|pool| async move {
        let controller = ShutdownController::new();
        let app = create_router(build_state(pool, controller.signal()), &[]);

        controller.trigger();

        // If liveness failed here the orchestrator would kill the process
        // mid-drain, which is exactly the truncation graceful shutdown exists
        // to prevent.
        let (status, body) = get(app, "/api/livez").await;
        assert_eq!(status, StatusCode::OK);
        let parsed: Value = serde_json::from_str(&body).expect("livez json");
        assert_eq!(parsed["status"], "alive");
    })
    .await;
}

#[tokio::test]
async fn probes_are_exempt_from_rate_limiting() {
    with_test_pool(|pool| async move {
        // Orchestrators poll far more often than a human client. Rate limiting
        // the probes would report a healthy instance as failing.
        let app = create_router(build_state(pool, ShutdownSignal::never()), &[]);

        for _ in 0..150 {
            let (status, _) = get(app.clone(), "/api/livez").await;
            assert_eq!(status, StatusCode::OK);
        }
        for _ in 0..150 {
            let (status, _) = get(app.clone(), "/api/readyz").await;
            assert_eq!(status, StatusCode::OK);
        }
    })
    .await;
}
