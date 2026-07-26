use crate::agents::router::IntentRouter;
use crate::api::metrics::MetricsService;
use crate::llm::LlmProvider;
use crate::repositories;
use crate::services::moderation::ModerationService;
use crate::services::notification::NotificationService;
use crate::services::order;
use crate::services::BusinessEvent;
use axum::{
    extract::State,
    middleware,
    response::Response,
    routing::{get, patch, post},
    Router,
};
pub mod admin;
pub mod agent_plans;
pub mod auth;
pub mod campuses;
pub mod chat;
pub mod conversations;
pub mod error;
pub mod interruptions;
pub mod listings;
pub mod metrics;
pub mod mfa;
pub mod moderation_cases;
pub mod negotiate;
pub mod notifications;
pub mod orders;
pub mod recommendations;
pub mod request_context;
pub mod session;
pub mod stats;
pub mod undo;
pub mod upload;
pub mod user;
pub mod user_chat;
pub mod wanted_responses;
pub mod watchlist;
pub mod ws;
use error::ApiError;
use sqlx::PgPool;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::LazyLock;
use tokio::sync::mpsc;
use tower_http::cors::{Any, CorsLayer};
use tower_http::limit::RequestBodyLimitLayer;
use tower_http::services::ServeDir;
use tower_http::timeout::TimeoutLayer;

use crate::middleware::rate_limit::{is_whitelisted, RateLimitStateHandle};
use regex::Regex;

static UUID_PATH_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
        .expect("valid uuid regex")
});
static MONGO_ID_PATH_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[0-9a-fA-F]{24}").expect("valid object id regex"));
static NUMERIC_PATH_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\d+").expect("valid numeric regex"));

fn fallback_peer_addr() -> SocketAddr {
    SocketAddr::from(([0, 0, 0, 0], 0))
}

fn peer_addr_from_extensions(extensions: &axum::http::Extensions) -> Option<SocketAddr> {
    extensions
        .get::<axum::extract::connect_info::ConnectInfo<SocketAddr>>()
        .map(|ci| ci.0)
        .or_else(|| extensions.get::<SocketAddr>().copied())
}

fn missing_peer_rate_limit_key(headers: &axum::http::HeaderMap) -> String {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};

    const FINGERPRINT_HEADERS: &[&str] = &[
        "user-agent",
        "accept-language",
        "accept-encoding",
        "host",
        "origin",
    ];

    let mut hasher = DefaultHasher::new();
    let mut found_component = false;

    for header_name in FINGERPRINT_HEADERS {
        if let Some(value) = headers.get(*header_name).and_then(|v| v.to_str().ok()) {
            header_name.hash(&mut hasher);
            value.hash(&mut hasher);
            found_component = true;
        }
    }

    if !found_component {
        return "anon:missing-peer".to_string();
    }

    format!("anon:{:016x}", hasher.finish())
}

fn rate_limit_key_for_request(
    headers: &axum::http::HeaderMap,
    peer_addr: Option<SocketAddr>,
    secrets: &ApiSecrets,
) -> String {
    auth::extract_user_id_from_token_with_fallback(
        headers,
        &secrets.jwt_secret,
        secrets.jwt_secret_old.as_deref(),
    )
    .map(|user_id| format!("uid:{user_id}"))
    .unwrap_or_else(|_| match peer_addr {
        Some(peer_addr) => format!("ip:{}", peer_addr.ip()),
        None => missing_peer_rate_limit_key(headers),
    })
}

/// Security headers applied to all responses.
async fn security_headers_middleware(
    request: axum::extract::Request,
    next: middleware::Next,
) -> Response {
    let mut response = next.run(request).await;
    let headers = response.headers_mut();
    headers.insert(
        "X-Content-Type-Options",
        axum::http::HeaderValue::from_static("nosniff"),
    );
    headers.insert(
        "X-Frame-Options",
        axum::http::HeaderValue::from_static("DENY"),
    );
    headers.insert(
        "X-XSS-Protection",
        axum::http::HeaderValue::from_static("1; mode=block"),
    );
    headers.insert(
        "Strict-Transport-Security",
        axum::http::HeaderValue::from_static("max-age=31536000; includeSubDomains"),
    );
    response
}

/// Rate-limit middleware that checks rate limits before passing requests to handlers.
pub async fn rate_limit_middleware(
    State(state): State<AppState>,
    request: axum::extract::Request,
    next: middleware::Next,
) -> Response {
    use axum::response::IntoResponse;

    let path = request.uri().path().to_string();

    if is_whitelisted(&path) {
        return next.run(request).await;
    }

    let peer_addr = peer_addr_from_extensions(request.extensions());
    if peer_addr.is_none() {
        tracing::warn!(path = %path, "Rate limit middleware missing peer address extension");
    }

    let rate_limit_key = rate_limit_key_for_request(request.headers(), peer_addr, &state.secrets);

    if !state
        .infra
        .rate_limit
        .check_rate_limit(&rate_limit_key)
        .await
    {
        state.infra.metrics.record_rate_limit_rejected();
        return ApiError::RateLimitExceeded.into_response();
    }

    next.run(request).await
}

/// Denylist middleware that rejects revoked JWT access tokens by JTI.
pub async fn token_denylist_middleware(
    State(state): State<AppState>,
    request: axum::extract::Request,
    next: middleware::Next,
) -> Response {
    use axum::response::IntoResponse;

    let path = request.uri().path();
    if path == "/api/auth/login" || path == "/api/auth/register" || path == "/api/auth/refresh" {
        return next.run(request).await;
    }

    if let Some(auth_header) = request
        .headers()
        .get("Authorization")
        .and_then(|v| v.to_str().ok())
    {
        if let Some(token) = auth_header.strip_prefix("Bearer ") {
            if auth::ensure_token_not_revoked(&state, token).await.is_err() {
                return ApiError::Unauthorized.into_response();
            }
            let user_id = match auth::extract_user_id_from_token_str_with_fallback(
                token,
                &state.secrets.jwt_secret,
                state.secrets.jwt_secret_old.as_deref(),
            ) {
                Ok(user_id) => user_id,
                Err(_) => return ApiError::Unauthorized.into_response(),
            };
            if let Err(err) = auth::ensure_user_not_banned(&state, &user_id).await {
                return err.into_response();
            }
        }
    }

    next.run(request).await
}

/// Normalize dynamic path segments to prevent Prometheus label cardinality explosion.
/// Replaces UUIDs, MongoDB ObjectIds, and numeric IDs with `{id}`.
fn normalize_path(path: &str) -> String {
    let step1 = UUID_PATH_RE.replace_all(path, "{id}");
    let step2 = MONGO_ID_PATH_RE.replace_all(&step1, "{id}");
    let step3 = NUMERIC_PATH_RE.replace_all(&step2, "{id}");
    step3.to_string()
}

/// HTTP metrics middleware that records request count and latency per endpoint.
pub async fn http_metrics_middleware(
    State(state): State<AppState>,
    request: axum::extract::Request,
    next: middleware::Next,
) -> Response {
    let start = std::time::Instant::now();
    let method = request.method().as_str().to_string();
    let path = request.uri().path().to_string();

    let response = next.run(request).await;
    let duration = start.elapsed();
    let status = response.status().as_u16();
    let normalized_path = normalize_path(&path);
    let request_id = request_context::current_or_new_request_id();

    state
        .infra
        .metrics
        .record_http(&method, &normalized_path, status, duration);

    tracing::info!(
        request_id = %request_id,
        method = %method,
        path = %normalized_path,
        status,
        duration_ms = duration.as_secs_f64() * 1000.0,
        "HTTP request completed"
    );

    response
}

/// Extractor that provides the direct TCP peer address of the connected client.
/// The server is started with `into_make_service_with_connect_info`, so this value comes from the
/// TCP connection rather than a spoofable request header.
#[derive(Clone, Debug)]
pub struct PeerAddr(pub SocketAddr);

impl<S> axum::extract::FromRequestParts<S> for PeerAddr
where
    S: Send + Sync,
{
    type Rejection = std::convert::Infallible;

    async fn from_request_parts(
        parts: &mut axum::http::request::Parts,
        _state: &S,
    ) -> Result<Self, Self::Rejection> {
        // Prefer Axum's ConnectInfo; the raw SocketAddr branch keeps tests and custom services safe.
        let addr = peer_addr_from_extensions(&parts.extensions).unwrap_or_else(fallback_peer_addr);
        Ok(PeerAddr(addr))
    }
}

// ---------------------------------------------------------------------------
// Grouped AppState sub-structs — reduce God Object feel while keeping zero
// breaking changes (handlers still receive State<AppState>).
// ---------------------------------------------------------------------------

/// Static config loaded at startup (secrets, keys, endpoints).
#[derive(Clone)]
pub struct ApiSecrets {
    pub jwt_secret: String,
    pub jwt_secret_old: Option<String>,
    pub gemini_api_key: String,
    /// Alibaba Cloud OSS configuration for STS direct-upload.
    pub oss_endpoint: String,
    pub oss_bucket: String,
    pub oss_role_arn: Option<String>,
    pub oss_access_key_id: Option<String>,
    pub oss_access_key_secret: Option<String>,
}

/// Runtime infrastructure (DB pool, async channels, WS connections).
#[derive(Clone)]
pub struct ApiInfrastructure {
    pub db: PgPool,
    pub event_tx: mpsc::Sender<BusinessEvent>,
    pub rate_limit: RateLimitStateHandle,
    pub notification: NotificationService,
    #[allow(dead_code)]
    pub ws_connections: Arc<ws::WsConnections>,
    pub metrics: Arc<MetricsService>,
    pub order_service: order::OrderService,
    pub admin_service: crate::services::admin::AdminService,
    pub moderation: ModerationService,
    pub token_denylist: crate::services::token_denylist::TokenDenylist,
    /// Secret Chat is deprecated; new sessions are refused unless explicitly
    /// enabled for a migration window. Existing sessions stay readable.
    pub secret_chat_new_sessions_enabled: bool,
    /// When set, the media bucket is private and approved media is served as
    /// short-lived presigned URLs instead of raw bucket links. `None` keeps the
    /// legacy public-bucket behaviour.
    pub media_signer: Option<Arc<MediaSigner>>,
    /// Observes process draining so readiness probes can shed traffic before
    /// the listener closes. Defaults to a signal that never fires, which is the
    /// correct behaviour for tests and any embedding without a supervisor.
    pub shutdown: crate::lifecycle::ShutdownSignal,
}

/// Serves approved media from a private bucket via presigned URLs.
pub struct MediaSigner {
    pub bucket: crate::services::storage::PrivateBucket,
    pub ttl_secs: u32,
}

impl MediaSigner {
    /// Rewrite a stored media URL into a short-lived presigned URL. Returns
    /// `None` for values that do not belong to our bucket — signing a foreign
    /// URL would produce a broken link and imply we vouch for it.
    pub fn sign(&self, stored: &str) -> Option<String> {
        let key =
            crate::services::storage::object_key_from_stored_url(stored, &self.bucket.bucket)?;
        Some(self.bucket.presigned_get(&key, self.ttl_secs))
    }
}

/// LLM provider + intent routing.
#[derive(Clone)]
pub struct ApiAgents {
    pub llm_provider: Arc<dyn LlmProvider>,
    pub router: IntentRouter,
}

#[derive(Clone)]
pub struct AppState {
    pub secrets: ApiSecrets,
    pub infra: ApiInfrastructure,
    pub agents: ApiAgents,
    // Repository layer (concrete types for now)
    #[allow(dead_code)]
    pub listing_repo: repositories::PostgresListingRepository,
    #[allow(dead_code)]
    pub user_repo: repositories::PostgresUserRepository,
    #[allow(dead_code)]
    pub chat_repo: repositories::PostgresChatRepository,
    #[allow(dead_code)]
    pub auth_repo: repositories::PostgresAuthRepository,
    #[allow(dead_code)]
    pub order_repo: repositories::PostgresOrderRepository,
}

impl AppState {
    /// Public media URL for an already moderation-approved value. With a
    /// private bucket this returns a presigned URL; otherwise the stored value
    /// passes through unchanged. Callers must have applied the moderation gate
    /// first — this function does not check approval.
    pub fn public_media_url(&self, stored: Option<String>) -> Option<String> {
        let stored = stored?;
        match self.infra.media_signer.as_ref() {
            Some(signer) => signer.sign(&stored).or(Some(stored)),
            None => Some(stored),
        }
    }
}

pub fn create_router(state: AppState, cors_origins: &[String]) -> Router {
    let cors = if cors_origins.is_empty() {
        // Default permissive CORS for development — no CORS_ORIGINS env var set
        // In production, always set CORS_ORIGINS to specific origins
        tracing::warn!("CORS_ORIGINS not set, defaulting to allow all origins");
        CorsLayer::new()
            .allow_origin(Any)
            .allow_methods(Any)
            .allow_headers(Any)
            .expose_headers([request_context::REQUEST_ID_HEADER])
    } else if cors_origins.iter().any(|s| s == "*") {
        // Wildcard: allow all origins
        CorsLayer::new()
            .allow_origin(Any)
            .allow_methods(Any)
            .allow_headers(Any)
            .expose_headers([request_context::REQUEST_ID_HEADER])
    } else {
        let origins: Vec<axum::http::HeaderValue> = cors_origins
            .iter()
            .filter_map(|s| s.parse::<axum::http::HeaderValue>().ok())
            .collect();
        CorsLayer::new()
            .allow_origin(origins)
            .allow_methods(Any)
            .allow_headers(Any)
            .expose_headers([request_context::REQUEST_ID_HEADER])
    };

    Router::new()
        .nest_service("/uploads", ServeDir::new("uploads"))
        .route("/api/health", get(health_check))
        .route("/api/livez", get(livez))
        .route("/api/readyz", get(readyz))
        .route("/api/metrics", get(get_metrics))
        .route("/api/stats", get(stats::get_stats))
        .route("/api/admin/stats", get(admin::get_admin_stats))
        .route(
            "/api/admin/community-health",
            get(admin::get_community_health),
        )
        .route(
            "/api/admin/capabilities",
            get(admin::get_admin_capabilities),
        )
        .route("/api/admin/users", get(admin::get_admin_users))
        .route("/api/admin/listings", get(admin::get_admin_listings))
        .route("/api/admin/orders", get(admin::get_admin_orders))
        .route("/api/admin/audit-logs", get(admin::get_admin_audit_logs))
        .route("/api/admin/campuses", post(admin::create_campus))
        .route(
            "/api/admin/campuses/{id}/{action}",
            post(admin::set_campus_status),
        )
        .route(
            "/api/admin/moderation/jobs",
            get(admin::get_moderation_jobs),
        )
        .route(
            "/api/admin/moderation/cases",
            get(admin::get_moderation_cases),
        )
        .route(
            "/api/admin/moderation/cases/{id}/review",
            post(admin::review_moderation_case),
        )
        .route(
            "/api/admin/moderation/appeals/{id}/review",
            post(admin::review_moderation_appeal),
        )
        .route("/api/admin/users/{id}/ban", post(admin::ban_user))
        .route("/api/admin/users/{id}/unban", post(admin::unban_user))
        .route(
            "/api/admin/users/{id}/impersonate",
            post(admin::impersonate_user),
        )
        .route("/api/admin/tokens/{jti}/revoke", post(admin::revoke_token))
        .route("/api/admin/users/{id}/role", post(admin::update_user_role))
        .route(
            "/api/admin/orders/{id}/status",
            post(admin::update_order_status),
        )
        .route(
            "/api/admin/listings/{id}/takedown",
            post(admin::takedown_listing),
        )
        .route(
            "/api/recommendations/feed",
            get(recommendations::get_recommendation_feed),
        )
        .route(
            "/api/recommendations/similar",
            get(recommendations::get_similar_listings),
        )
        .route("/api/categories", get(listings::get_categories))
        .route("/api/campuses", get(campuses::list_campuses))
        .route("/api/chat", post(chat::handle_chat))
        .route(
            "/api/chat/stream",
            get(chat::handle_chat_stream_get).post(chat::handle_chat_stream_post),
        )
        .route("/api/chat/assistant", get(chat::get_assistant_history))
        .route("/api/auth/register", post(auth::register))
        .route("/api/auth/login", post(auth::login))
        .route("/api/auth/reauth", post(auth::reauthenticate))
        .route("/api/auth/mfa/totp", get(mfa::totp_status))
        .route("/api/auth/mfa/totp/setup", post(mfa::totp_setup))
        .route("/api/auth/mfa/totp/confirm", post(mfa::totp_confirm))
        .route("/api/agent/plans", get(agent_plans::list_plans))
        .route(
            "/api/agent/plans/{id}/confirm",
            post(agent_plans::confirm_plan),
        )
        .route(
            "/api/agent/plans/{id}/cancel",
            post(agent_plans::cancel_plan),
        )
        .route("/api/actions/undoable", get(undo::list_undoable))
        .route("/api/actions/{id}/undo", post(undo::undo_action))
        .route(
            "/api/interruptions/preferences",
            get(interruptions::get_preferences).put(interruptions::update_preferences),
        )
        .route("/api/interruptions/history", get(interruptions::history))
        .route(
            "/api/interruptions/{id}/accept",
            post(interruptions::accept),
        )
        .route(
            "/api/interruptions/{id}/dismiss",
            post(interruptions::dismiss),
        )
        .route("/api/auth/change-password", post(auth::change_password))
        .route("/api/auth/refresh", post(auth::refresh_token))
        .route("/api/auth/logout", post(auth::logout))
        .route("/api/user/active-campus", post(auth::switch_active_campus))
        .route(
            "/api/listings",
            get(listings::get_listings).post(listings::create_listing),
        )
        .route("/api/listings/recognize", post(listings::recognize_item))
        .route(
            "/api/listings/{id}",
            get(listings::get_listing)
                .put(listings::update_listing)
                .delete(listings::delete_listing),
        )
        .route(
            "/api/listings/{id}/matches",
            get(listings::get_wanted_matches),
        )
        .route(
            "/api/listings/{id}/responses",
            post(listings::respond_to_wanted),
        )
        .route("/api/listings/{id}/relist", post(listings::relist_listing))
        .route("/api/listings/{id}/fulfill", post(listings::fulfill_wanted))
        .route(
            "/api/wanted-responses",
            get(wanted_responses::list_wanted_responses),
        )
        .route(
            "/api/wanted-responses/{id}/accept",
            post(wanted_responses::accept_wanted_response),
        )
        .route(
            "/api/wanted-responses/{id}/dismiss",
            post(wanted_responses::dismiss_wanted_response),
        )
        .route(
            "/api/wanted-responses/{id}/withdraw",
            post(wanted_responses::withdraw_wanted_response),
        )
        .route(
            "/api/user/profile",
            get(user::get_profile).patch(user::update_profile),
        )
        .route(
            "/api/user/campus-memberships",
            get(user::get_campus_memberships),
        )
        .route(
            "/api/user/campus-memberships/{id}/verification/request",
            post(user::request_campus_verification),
        )
        .route(
            "/api/user/campus-memberships/{id}/verification/confirm",
            post(user::confirm_campus_verification),
        )
        .route("/api/user/listings", get(user::get_user_listings))
        .route("/api/users/search", get(user::search_users))
        .route("/api/users/lookup", get(user::lookup_users))
        .route(
            "/api/users/{id}/listings",
            get(user::get_public_user_listings),
        )
        .route("/api/users/{id}", get(user::get_user_profile))
        .route(
            "/api/orders",
            get(orders::get_orders).post(orders::create_order),
        )
        .route("/api/orders/{id}", get(orders::get_order))
        .route("/api/orders/{id}/cancel", post(orders::cancel_order))
        .route("/api/orders/{id}/confirm", post(orders::confirm_order))
        .route("/api/orders/{id}/pay", post(orders::pay_order))
        .route("/api/orders/{id}/ship", post(orders::ship_order))
        .route("/api/conversations", get(conversations::list_conversations))
        .route(
            "/api/conversations/{id}/messages",
            get(conversations::get_conversation_messages),
        )
        .route("/api/watchlist", get(watchlist::get_watchlist))
        .route(
            "/api/watchlist/{listing_id}",
            get(watchlist::check_watchlist)
                .post(watchlist::add_to_watchlist)
                .delete(watchlist::remove_from_watchlist),
        )
        .route("/api/notifications", get(notifications::get_notifications))
        .route(
            "/api/notifications/{id}/read",
            post(notifications::mark_notification_read),
        )
        .route(
            "/api/notifications/read-all",
            post(notifications::mark_all_notifications_read),
        )
        .route(
            "/api/moderation/cases",
            get(moderation_cases::list_my_cases),
        )
        .route(
            "/api/moderation/cases/{id}",
            get(moderation_cases::get_my_case),
        )
        .route(
            "/api/moderation/cases/{id}/appeals",
            post(moderation_cases::submit_appeal),
        )
        .route(
            "/api/moderation/appeals/{id}",
            get(moderation_cases::get_my_appeal),
        )
        .route("/api/negotiations", get(negotiate::list_negotiations))
        .route(
            "/api/negotiations/{id}/respond",
            patch(negotiate::respond_negotiation),
        )
        .route(
            "/api/negotiations/{id}/accept",
            patch(negotiate::accept_counter_negotiation),
        )
        .route(
            "/api/negotiations/{id}/reject",
            patch(negotiate::reject_counter_negotiation),
        )
        .route(
            "/api/chat/conversations",
            get(user_chat::list_conversations).post(user_chat::create_conversation),
        )
        .route("/api/chat/threads", get(user_chat::list_threads))
        .route(
            "/api/chat/threads/{peer_user_id}",
            get(user_chat::get_thread),
        )
        .route(
            "/api/chat/conversations/{id}",
            get(user_chat::get_conversation),
        )
        .route(
            "/api/chat/conversations/{id}/respond",
            post(user_chat::respond_conversation),
        )
        .route(
            "/api/chat/conversations/{id}/ack",
            post(user_chat::acknowledge_conversation),
        )
        .route(
            "/api/chat/conversations/{id}/close",
            post(user_chat::close_conversation),
        )
        .route(
            "/api/chat/conversations/{id}/archive",
            post(user_chat::archive_conversation),
        )
        .route(
            "/api/chat/conversations/{id}/messages",
            get(user_chat::get_conversation_messages).post(user_chat::send_conversation_message),
        )
        .route(
            "/api/chat/conversations/{id}/read",
            post(user_chat::mark_conversation_read),
        )
        .route(
            "/api/chat/conversations/{id}/read-preference",
            post(user_chat::set_read_preference),
        )
        .route("/api/chat/messages/{id}", patch(user_chat::edit_message))
        .route(
            "/api/chat/messages/{id}/reaction",
            post(user_chat::set_message_reaction).delete(user_chat::delete_message_reaction),
        )
        .route(
            "/api/chat/messages/{id}/hide",
            post(user_chat::hide_message),
        )
        .route(
            "/api/chat/messages/{id}/report",
            post(user_chat::report_message),
        )
        .route(
            "/api/chat/conversations/{id}/typing",
            post(user_chat::typing_indicator),
        )
        .route(
            "/api/chat/conversations/{id}/reply-suggestions",
            post(user_chat::reply_suggestions),
        )
        .route(
            "/api/chat/blocks",
            get(user_chat::list_blocks).post(user_chat::block_user),
        )
        .route(
            "/api/chat/blocks/{id}",
            axum::routing::delete(user_chat::unblock_user),
        )
        .route(
            "/api/chat/spaces",
            get(user_chat::list_spaces).post(user_chat::create_space),
        )
        .route("/api/chat/spaces/{id}", get(user_chat::get_space))
        .route(
            "/api/chat/spaces/{id}/members",
            post(user_chat::add_space_member),
        )
        .route(
            "/api/chat/spaces/{id}/members/{user_id}",
            axum::routing::delete(user_chat::remove_space_member),
        )
        .route(
            "/api/chat/spaces/{id}/messages",
            get(user_chat::list_space_messages).post(user_chat::send_space_message),
        )
        .route("/api/chat/calls", post(user_chat::create_call))
        .route("/api/chat/calls/{id}/answer", post(user_chat::answer_call))
        .route("/api/chat/calls/{id}/end", post(user_chat::end_call))
        .route(
            "/api/chat/secret-sessions",
            post(user_chat::create_secret_session),
        )
        .route(
            "/api/chat/secret-sessions/{id}/messages",
            get(user_chat::list_secret_messages).post(user_chat::send_secret_message),
        )
        .route("/api/upload/token", get(upload::get_upload_token))
        .route("/api/ws", get(ws::ws_handler))
        // Bound time-to-response so a hung handler (stuck DB query, wedged
        // provider call) cannot hold connections open indefinitely; without
        // this, hangs accumulate until the connection budget is gone. 60s
        // leaves headroom for the slowest legitimate path — a full
        // non-streaming agent run with tools. This does NOT cap response
        // bodies: SSE streams and WebSocket sessions produce their response
        // upfront and stream afterwards, outside this layer's window.
        // 504 (not the default 408): the timeout is the server's fault, and
        // 408 invites clients to blindly retry a request that may have already
        // committed its write.
        .layer(TimeoutLayer::with_status_code(
            axum::http::StatusCode::GATEWAY_TIMEOUT,
            std::time::Duration::from_secs(60),
        ))
        .layer(RequestBodyLimitLayer::new(10 * 1024 * 1024))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            token_denylist_middleware,
        ))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            rate_limit_middleware,
        ))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            http_metrics_middleware,
        ))
        // Security and CORS must wrap auth middleware so rejected browser
        // requests still expose their status and headers to the web client.
        .layer(middleware::from_fn(security_headers_middleware))
        .layer(cors)
        .layer(middleware::from_fn(request_context::request_id_middleware))
        .with_state(state)
}

/// GET /api/metrics — Prometheus text format metrics (no auth required)
async fn get_metrics(State(state): State<AppState>) -> String {
    state.infra.metrics.render()
}

/// GET /api/livez — liveness probe: is this process running at all?
///
/// Deliberately checks nothing external. A liveness probe that pings the
/// database turns a database outage into a rolling restart of every replica,
/// which removes the capacity needed to recover and makes the outage worse.
/// Dependency health belongs in readiness, which sheds traffic without killing
/// the process.
async fn livez() -> axum::Json<serde_json::Value> {
    axum::Json(serde_json::json!({ "status": "alive" }))
}

/// GET /api/readyz — readiness probe: should this instance receive traffic?
///
/// Fails while draining so the load balancer stops sending new requests before
/// the listener closes, and fails when the database is unreachable because
/// nearly every endpoint needs it.
async fn readyz(State(state): State<AppState>) -> Result<axum::Json<serde_json::Value>, ApiError> {
    check_ready(&state).await?;
    Ok(axum::Json(serde_json::json!({ "status": "ready" })))
}

/// Shared readiness logic for `/api/readyz` and the legacy `/api/health`.
async fn check_ready(state: &AppState) -> Result<(), ApiError> {
    if state.infra.shutdown.is_draining() {
        // Not an error condition: the instance is being retired on purpose.
        return Err(ApiError::ServiceUnavailable("draining"));
    }

    sqlx::query("SELECT 1")
        .fetch_one(&state.infra.db)
        .await
        .map_err(|e| {
            tracing::error!(%e, "Readiness check failed: database unreachable");
            ApiError::ServiceUnavailable("database_unreachable")
        })?;

    Ok(())
}

/// GET /api/health — legacy readiness alias kept for existing clients, probes
/// and Compose health checks. Prefer `/api/readyz` and `/api/livez`.
async fn health_check(State(state): State<AppState>) -> Result<&'static str, ApiError> {
    check_ready(&state).await?;
    Ok("OK")
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::{HeaderMap, HeaderValue};

    #[test]
    fn test_peer_addr_clone() {
        use std::net::SocketAddr;
        let addr: SocketAddr = "127.0.0.1:8080".parse().unwrap();
        let peer = PeerAddr(addr);
        let _cloned = peer.clone();
    }

    #[test]
    fn test_peer_addr_debug() {
        use std::net::SocketAddr;
        let addr: SocketAddr = "192.168.1.1:3000".parse().unwrap();
        let peer = PeerAddr(addr);
        let debug_str = format!("{:?}", peer);
        assert!(debug_str.contains("PeerAddr"));
        assert!(debug_str.contains("192.168.1.1"));
    }

    #[test]
    fn rate_limit_key_prefers_authenticated_user_id() {
        let (token, _, _) = auth::generate_access_token(
            "user-123",
            "user",
            "test_jwt_secret_at_least_32_characters_long",
            3600,
        )
        .expect("token");
        let mut headers = HeaderMap::new();
        headers.insert(
            "Authorization",
            HeaderValue::from_str(&format!("Bearer {token}")).expect("header"),
        );
        let peer_addr: SocketAddr = "127.0.0.1:3000".parse().expect("socket addr");
        let secrets = ApiSecrets {
            jwt_secret: "test_jwt_secret_at_least_32_characters_long".to_string(),
            jwt_secret_old: None,
            gemini_api_key: String::new(),
            oss_endpoint: String::new(),
            oss_bucket: String::new(),
            oss_role_arn: None,
            oss_access_key_id: None,
            oss_access_key_secret: None,
        };

        let key = rate_limit_key_for_request(&headers, Some(peer_addr), &secrets);
        assert_eq!(key, "uid:user-123");
    }

    #[test]
    fn rate_limit_key_falls_back_to_peer_ip_without_auth() {
        let headers = HeaderMap::new();
        let peer_addr: SocketAddr = "127.0.0.9:4000".parse().expect("socket addr");
        let secrets = ApiSecrets {
            jwt_secret: "test_jwt_secret_at_least_32_characters_long".to_string(),
            jwt_secret_old: None,
            gemini_api_key: String::new(),
            oss_endpoint: String::new(),
            oss_bucket: String::new(),
            oss_role_arn: None,
            oss_access_key_id: None,
            oss_access_key_secret: None,
        };

        let key = rate_limit_key_for_request(&headers, Some(peer_addr), &secrets);
        assert_eq!(key, "ip:127.0.0.9");
    }

    #[test]
    fn rate_limit_key_falls_back_to_stable_header_fingerprint_without_peer_or_auth() {
        let mut headers = HeaderMap::new();
        headers.insert("user-agent", HeaderValue::from_static("goods4ncu-test"));
        headers.insert("host", HeaderValue::from_static("example.test"));
        let secrets = ApiSecrets {
            jwt_secret: "test_jwt_secret_at_least_32_characters_long".to_string(),
            jwt_secret_old: None,
            gemini_api_key: String::new(),
            oss_endpoint: String::new(),
            oss_bucket: String::new(),
            oss_role_arn: None,
            oss_access_key_id: None,
            oss_access_key_secret: None,
        };

        let key_one = rate_limit_key_for_request(&headers, None, &secrets);
        let key_two = rate_limit_key_for_request(&headers, None, &secrets);

        assert_eq!(key_one, key_two);
        assert!(key_one.starts_with("anon:"));
        assert_ne!(key_one, "anon:missing-peer");
    }

    #[test]
    fn rate_limit_key_uses_missing_peer_bucket_when_no_peer_or_fingerprint_headers_exist() {
        let headers = HeaderMap::new();
        let secrets = ApiSecrets {
            jwt_secret: "test_jwt_secret_at_least_32_characters_long".to_string(),
            jwt_secret_old: None,
            gemini_api_key: String::new(),
            oss_endpoint: String::new(),
            oss_bucket: String::new(),
            oss_role_arn: None,
            oss_access_key_id: None,
            oss_access_key_secret: None,
        };

        let key = rate_limit_key_for_request(&headers, None, &secrets);
        assert_eq!(key, "anon:missing-peer");
    }

    #[test]
    fn peer_addr_from_extensions_prefers_connect_info() {
        let mut extensions = axum::http::Extensions::new();
        let socket_addr: SocketAddr = "127.0.0.9:4000".parse().expect("socket addr");
        let connect_info_addr: SocketAddr = "10.0.0.5:8080".parse().expect("socket addr");
        extensions.insert(socket_addr);
        extensions.insert(axum::extract::connect_info::ConnectInfo(connect_info_addr));

        let addr = peer_addr_from_extensions(&extensions);
        assert_eq!(addr, Some(connect_info_addr));
    }

    #[test]
    fn peer_addr_from_extensions_falls_back_to_socket_addr() {
        let mut extensions = axum::http::Extensions::new();
        let socket_addr: SocketAddr = "127.0.0.9:4000".parse().expect("socket addr");
        extensions.insert(socket_addr);

        let addr = peer_addr_from_extensions(&extensions);
        assert_eq!(addr, Some(socket_addr));
    }
}
