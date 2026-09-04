//! Auth API integration tests migrated from src/api/auth.rs to maintain the zero-SQL invariant in src/api/.

use axum::{extract::State, http::HeaderMap, Json};
use goods4ncu::api::auth::{
    change_password, extract_auth_session_from_token_str, generate_access_token,
    generate_access_token_for_campus, generate_access_token_for_campus_with_auth_time,
    hash_password, hash_token, reauthenticate, rotate_refresh_token, switch_active_campus,
    verify_password, ChangePasswordRequest, ReauthenticateRequest, SwitchCampusRequest,
};
use goods4ncu::api::error::ApiError;
use goods4ncu::api::{ApiAgents, ApiInfrastructure, ApiSecrets, AppState};
use goods4ncu::repositories::{
    AuthRepository, PostgresAuthRepository, PostgresListingRepository, PostgresOrderRepository,
    PostgresUserRepository, UserRepository,
};
use goods4ncu::services::{self, campus::CampusService, notification::NotificationService};
use goods4ncu::test_infra::with_test_pool;
use sqlx::Row;
use std::sync::Arc;
use uuid::Uuid;

fn build_state(pool: sqlx::PgPool) -> AppState {
    let admin_service = services::admin::AdminService::new(pool.clone());

    AppState {
        secrets: ApiSecrets {
            jwt_secret: "test_jwt_secret_at_least_32_characters_long".to_string(),
            gemini_api_key: "test-gemini-key".to_string(),
            oss_endpoint: "https://oss-cn-beijing.aliyuncs.com".to_string(),
            oss_bucket: "test-bucket".to_string(),
            oss_role_arn: None,
            oss_access_key_id: None,
            oss_access_key_secret: None,
        },
        infra: {
            let ws_hub = Arc::new(goods4ncu::api::ws::WsHub::new());
            ApiInfrastructure {
                db: pool.clone(),
                rate_limit: {
                    let factory =
                        goods4ncu::middleware::rate_limit::RateLimiterFactory::new(100, 60);
                    goods4ncu::middleware::rate_limit::RateLimitStateHandle::new(
                        factory.build_local(),
                    )
                },
                notification: NotificationService::new(pool.clone()),
                ws_hub,
                metrics: Arc::new(goods4ncu::api::metrics::MetricsService::new()),
                order_service: services::order::OrderService::new(pool.clone()),
                admin_service,
                moderation: services::moderation::ModerationService::new(
                    &goods4ncu::config::AppConfig::test_defaults(),
                ),
                token_denylist: services::token_denylist::TokenDenylist::new(),
                media_signer: None,
                shutdown: goods4ncu::lifecycle::ShutdownSignal::never(),
                deployment_profile: goods4ncu::config::DeploymentProfile::Local,
                #[cfg(feature = "redis")]
                replicated_runtime: None,
            }
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
            agent_enabled: true,
        },
        listing_repo: PostgresListingRepository::new(pool.clone()),
        user_repo: PostgresUserRepository::new(pool.clone()),
        auth_repo: PostgresAuthRepository::new(pool.clone()),
        order_repo: PostgresOrderRepository::new(pool),
    }
}

#[tokio::test]
async fn test_revoke_refresh_token_is_single_use() {
    with_test_pool(|pool| async move {
        sqlx::query(
            "INSERT INTO users (id, username, password_hash, role) VALUES ($1, $2, 'hash', 'user')",
        )
        .bind("auth-user-single-use")
        .bind("auth_single_use")
        .execute(&pool)
        .await
        .expect("insert user");

        let auth_repo = PostgresAuthRepository::new(pool.clone());
        let token_hash = hash_token("single-use-refresh-token");
        let expires_at = chrono::Utc::now() + chrono::Duration::hours(1);

        sqlx::query(
            "INSERT INTO refresh_tokens (user_id, token_hash, expires_at) VALUES ($1, $2, $3)",
        )
        .bind("auth-user-single-use")
        .bind(&token_hash)
        .bind(expires_at)
        .execute(&pool)
        .await
        .expect("insert refresh token");

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
async fn test_rotate_refresh_replay_revokes_all_user_sessions() {
    with_test_pool(|pool| async move {
        let user_id = "auth-user-replay";
        sqlx::query(
            "INSERT INTO users (id, username, password_hash, role) VALUES ($1, $2, 'hash', 'user')",
        )
        .bind(user_id)
        .bind("auth_replay")
        .execute(&pool)
        .await
        .expect("insert user");

        let revoked_hash = hash_token("revoked-refresh-token");
        let active_hash = hash_token("active-refresh-token");
        let expires_at = chrono::Utc::now() + chrono::Duration::hours(1);

        sqlx::query(
            "INSERT INTO refresh_tokens (user_id, token_hash, expires_at, revoked_at) VALUES ($1, $2, $3, NOW())",
        )
        .bind(user_id)
        .bind(&revoked_hash)
        .bind(expires_at)
        .execute(&pool)
        .await
        .expect("insert revoked token");

        sqlx::query(
            "INSERT INTO refresh_tokens (user_id, token_hash, expires_at) VALUES ($1, $2, $3)",
        )
        .bind(user_id)
        .bind(&active_hash)
        .bind(expires_at)
        .execute(&pool)
        .await
        .expect("insert active token");

        let auth_repo = PostgresAuthRepository::new(pool.clone());
        let user_repo = PostgresUserRepository::new(pool.clone());
        let campus_service = CampusService::new(pool.clone());

        let result = rotate_refresh_token(
            &auth_repo,
            &user_repo,
            "revoked-refresh-token",
            "test_jwt_secret_at_least_32_characters_long",
            &campus_service,
            None,
            None,
        )
        .await;
        assert!(result.is_err());

        let active_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM refresh_tokens WHERE user_id = $1 AND revoked_at IS NULL",
        )
        .bind(user_id)
        .fetch_one(&pool)
        .await
        .expect("count active tokens");

        assert_eq!(active_count, 0);
    })
    .await;
}

#[tokio::test]
async fn test_create_user_persists_standard_record() {
    with_test_pool(|pool| async move {
        let auth_repo = PostgresAuthRepository::new(pool.clone());

        let user_id = auth_repo
            .create_user("shadow_user", Some("shadow@example.com"), "hash")
            .await
            .expect("create user");
        assert!(Uuid::parse_str(&user_id).is_ok());

        let row = sqlx::query("SELECT id, username, email FROM users WHERE id = $1")
            .bind(&user_id)
            .fetch_one(&pool)
            .await
            .expect("select user");

        assert_eq!(row.get::<String, _>("id"), user_id);
        assert_eq!(row.get::<String, _>("username"), "shadow_user");
        assert_eq!(
            row.get::<Option<String>, _>("email").as_deref(),
            Some("shadow@example.com")
        );
    })
    .await;
}

#[tokio::test]
async fn test_change_password_updates_hash_via_repository_path() {
    with_test_pool(|pool| async move {
        let old_hash = hash_password("current-pass-123".to_string())
            .await
            .expect("hash password");

        let user_repo = PostgresUserRepository::new(pool.clone());
        let user_id = user_repo
            .create("change_password_user", None, &old_hash, "user")
            .await
            .expect("create user");

        let state = build_state(pool.clone());
        let (token, _jti, _exp) =
            generate_access_token(&user_id, "user", &state.secrets.jwt_secret, 3600)
                .expect("generate token");

        let mut headers = HeaderMap::new();
        headers.insert(
            "Authorization",
            format!("Bearer {}", token).parse().unwrap(),
        );

        let _ = change_password(
            State(state),
            headers,
            Json(ChangePasswordRequest {
                current_password: "current-pass-123".to_string(),
                new_password: "brand-new-pass-456".to_string(),
            }),
        )
        .await
        .expect("change password");

        let updated_hash: String =
            sqlx::query_scalar("SELECT password_hash FROM users WHERE id = $1")
                .bind(&user_id)
                .fetch_one(&pool)
                .await
                .expect("select updated hash");

        assert!(
            verify_password("brand-new-pass-456".to_string(), updated_hash)
                .await
                .expect("new password verifies")
        );
    })
    .await;
}

#[tokio::test]
async fn test_reauthenticate_rejects_wrong_password_and_issues_recent_token() {
    with_test_pool(|pool| async move {
        let password = "reauth-pass-123";
        let password_hash = hash_password(password.to_string())
            .await
            .expect("hash password");
        let user_repo = PostgresUserRepository::new(pool.clone());
        let user_id = user_repo
            .create(
                &format!("reauth_{}", Uuid::new_v4()),
                None,
                &password_hash,
                "admin",
            )
            .await
            .expect("create admin");
        let state = build_state(pool);
        let (stale_token, _, _) = generate_access_token_for_campus_with_auth_time(
            &user_id,
            "admin",
            None,
            None,
            &state.secrets.jwt_secret,
            3600,
        )
        .expect("stale token");
        let mut headers = HeaderMap::new();
        headers.insert(
            "Authorization",
            format!("Bearer {stale_token}").parse().expect("header"),
        );

        let error = reauthenticate(
            State(state.clone()),
            headers.clone(),
            Json(ReauthenticateRequest {
                password: "wrong-password".to_string(),
                totp_code: None,
            }),
        )
        .await
        .err()
        .expect("wrong password must fail");
        assert!(matches!(error, ApiError::RecentAuthenticationFailed));

        let response = reauthenticate(
            State(state.clone()),
            headers,
            Json(ReauthenticateRequest {
                password: password.to_string(),
                totp_code: None,
            }),
        )
        .await
        .expect("reauthenticate")
        .0;
        let context =
            extract_auth_session_from_token_str(&response.token, &state.secrets.jwt_secret)
                .expect("decode recent token");
        assert_eq!(context.user_id, user_id);
        assert!(context.has_recent_authentication());
        assert!(response.recent_auth_expires_at > chrono::Utc::now());
    })
    .await;
}

#[tokio::test]
async fn test_switch_active_campus_rotates_session_and_revokes_access_token() {
    with_test_pool(|pool| async move {
        let suffix = Uuid::new_v4();
        let user_repo = PostgresUserRepository::new(pool.clone());
        let user_id = user_repo
            .create(&format!("campus_switch_{suffix}"), None, "hash", "user")
            .await
            .expect("create user");
        let ncu_id = Uuid::parse_str("c0000000-0000-0000-0000-000000000001").expect("ncu id");
        let second_campus_id = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO campuses (id, slug, name_zh, name_en, email_domains)
             VALUES ($1, $2, '第二校园', 'Second Campus', ARRAY['second.example.edu'])",
        )
        .bind(second_campus_id)
        .bind(format!("second-{suffix}"))
        .execute(&pool)
        .await
        .expect("insert second campus");
        sqlx::query(
            "UPDATE campus_memberships
             SET status = 'verified', verification_method = 'test', verified_at = NOW()
             WHERE campus_id = $1 AND user_id = $2",
        )
        .bind(ncu_id)
        .bind(&user_id)
        .execute(&pool)
        .await
        .expect("verify ncu membership");
        sqlx::query(
            "INSERT INTO campus_memberships (
                campus_id, user_id, status, role, verification_method, verified_at
             ) VALUES ($1, $2, 'verified', 'member', 'test', NOW())",
        )
        .bind(second_campus_id)
        .bind(&user_id)
        .execute(&pool)
        .await
        .expect("insert second verified membership");

        let state = build_state(pool.clone());
        let current_refresh = format!("refresh-{suffix}");
        state
            .auth_repo
            .store_refresh_token(
                &user_id,
                &hash_token(&current_refresh),
                chrono::Utc::now() + chrono::Duration::hours(1),
                Some(ncu_id),
            )
            .await
            .expect("store current refresh token");
        let (current_access, current_jti, _) = generate_access_token_for_campus(
            &user_id,
            "user",
            Some(ncu_id),
            &state.secrets.jwt_secret,
            3600,
        )
        .expect("current access token");
        let mut headers = HeaderMap::new();
        headers.insert(
            "Authorization",
            format!("Bearer {current_access}").parse().expect("header"),
        );

        let response = switch_active_campus(
            State(state.clone()),
            headers,
            Json(SwitchCampusRequest {
                campus_id: second_campus_id,
                refresh_token: current_refresh,
            }),
        )
        .await
        .expect("switch active campus")
        .0;
        assert_eq!(response.active_campus_id, second_campus_id);
        let new_context =
            extract_auth_session_from_token_str(&response.token, &state.secrets.jwt_secret)
                .expect("decode switched access token");
        assert_eq!(new_context.campus_id, Some(second_campus_id));
        assert!(!new_context.has_recent_authentication());

        let new_record = state
            .auth_repo
            .find_refresh_token(&hash_token(&response.refresh_token))
            .await
            .expect("load switched refresh token")
            .expect("switched refresh token exists");
        assert_eq!(new_record.user_id, user_id);
        assert_eq!(new_record.campus_id, Some(second_campus_id));
        let revoked: bool =
            sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM revoked_access_tokens WHERE jti = $1)")
                .bind(current_jti)
                .fetch_one(&pool)
                .await
                .expect("check access revocation");
        assert!(revoked);
    })
    .await;
}
