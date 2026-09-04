use crate::api::metrics::MetricsService;
use crate::llm::LlmProvider;
use crate::services::moderation::ModerationService;
use crate::services::notification::NotificationService;
use crate::services::order;
use axum::{
    extract::State,
    middleware,
    response::Response,
    routing::{delete, get, patch, post, put},
    Router,
};
pub mod admin;
pub mod agent_memory;
pub mod agent_plans;
pub mod agent_runs;
pub mod agent_skills;
pub mod agreements;
pub mod auth;
pub mod camphor;
pub mod campuses;
pub mod chat;
pub mod companion;
pub mod content_reports;
pub mod error;
pub mod feed;
pub mod intents;
pub mod interruptions;
pub mod listings;
pub mod metrics;
pub mod mfa;
pub mod moderation_cases;
pub mod negotiate;
pub mod notifications;
pub mod orders;
pub mod posts;
pub mod price_discovery;
pub mod recommendations;
pub mod reputation;
pub mod request_context;
pub mod session;
pub mod social_persona;
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
    auth::extract_user_id_from_token(headers, &secrets.jwt_secret)
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

    if is_whitelisted(request.method(), &path) {
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
///
/// On successful token verification, the decoded [`auth::AuthSessionContext`]
/// is injected into request extensions so downstream extractors (`Session`,
/// `OptionalSession`, `VerifiedTenant`) can reuse it without repeating HMAC-SHA256
/// verification and JSON deserialization.
pub async fn token_denylist_middleware(
    State(state): State<AppState>,
    mut request: axum::extract::Request,
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
            let session =
                match auth::extract_auth_session_from_token_str(token, &state.secrets.jwt_secret) {
                    Ok(session) => session,
                    Err(_) => return ApiError::Unauthorized.into_response(),
                };
            if let Err(err) = auth::ensure_user_not_banned(&state, &session.user_id).await {
                return err.into_response();
            }
            request.extensions_mut().insert(session);
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

// ---------------------------------------------------------------------------
// Grouped AppState sub-structs — reduce God Object feel while keeping zero
// breaking changes (handlers still receive State<AppState>).
// ---------------------------------------------------------------------------

/// Static config loaded at startup (secrets, keys, endpoints).
#[derive(Clone)]
pub struct ApiSecrets {
    pub jwt_secret: String,
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
    pub rate_limit: RateLimitStateHandle,
    pub notification: NotificationService,
    pub ws_hub: Arc<ws::WsHub>,
    pub metrics: Arc<MetricsService>,
    pub order_service: order::OrderService,
    pub admin_service: crate::services::admin::AdminService,
    pub moderation: ModerationService,
    pub token_denylist: crate::services::token_denylist::TokenDenylist,
    /// When set, the media bucket is private and approved media is served as
    /// short-lived presigned URLs instead of raw bucket links. `None` keeps the
    /// legacy public-bucket behaviour.
    pub media_signer: Option<Arc<MediaSigner>>,
    /// Observes process draining so readiness probes can shed traffic before
    /// the listener closes. Defaults to a signal that never fires, which is the
    /// correct behaviour for tests and any embedding without a supervisor.
    pub shutdown: crate::lifecycle::ShutdownSignal,
    pub deployment_profile: crate::config::DeploymentProfile,
    #[cfg(feature = "redis")]
    pub replicated_runtime: Option<Arc<crate::services::replicated_runtime::ReplicatedRuntime>>,
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
        if let Ok(parsed) = reqwest::Url::parse(stored) {
            if !matches!(parsed.scheme(), "http" | "https")
                || !platform_media_host_matches(&parsed, &self.bucket.endpoint, &self.bucket.bucket)
            {
                return None;
            }
        } else if stored.contains("://") || stored.starts_with("//") {
            return None;
        }
        let key =
            crate::services::storage::object_key_from_stored_url(stored, &self.bucket.bucket)?;
        if key.is_empty() {
            return None;
        }
        Some(self.bucket.presigned_get(&key, self.ttl_secs))
    }
}

/// LLM provider + intent routing.
#[derive(Clone)]
pub struct ApiAgents {
    pub llm_provider: Arc<dyn LlmProvider>,
    pub tri_tier_router: crate::agents::router::TriTierIntentRouter,
    /// When false, AI assistant endpoints return ServiceUnavailable.
    pub agent_enabled: bool,
}

#[derive(Clone)]
pub struct AppState {
    pub secrets: ApiSecrets,
    pub infra: ApiInfrastructure,
    pub agents: ApiAgents,
    pub listing_repo: crate::repositories::PostgresListingRepository,
    pub user_repo: crate::repositories::PostgresUserRepository,
    pub auth_repo: crate::repositories::PostgresAuthRepository,
    #[allow(dead_code)]
    pub order_repo: crate::repositories::PostgresOrderRepository,
}

impl AppState {
    /// Public media URL for an already moderation-approved value. With a
    /// private bucket this returns a presigned URL; otherwise the stored value
    /// passes through unchanged. Callers must have applied the moderation gate
    /// first — this function does not check approval.
    pub fn public_media_url(&self, stored: Option<String>) -> Option<String> {
        let stored = stored?;
        match self.infra.media_signer.as_ref() {
            // A private bucket is also the boundary for legacy rows: if a
            // value cannot be mapped back to our bucket, do not hand an
            // arbitrary foreign URL to a client that will auto-load it.
            Some(signer) => signer.sign(&stored),
            None => Some(stored),
        }
    }

    /// Media presentation for chat messages. Even when the legacy public
    /// bucket mode is enabled, conversation bodies must not cause clients to
    /// auto-load an arbitrary external URL.
    pub fn public_chat_media_url(&self, stored: Option<String>) -> Option<String> {
        let stored = stored?;
        match self.infra.media_signer.as_ref() {
            Some(signer) => signer.sign(&stored),
            None if is_platform_media_reference(self, &stored) => Some(stored),
            None => None,
        }
    }

    /// Return an explicit platform URL for a server-owned object key. Private
    /// deployments receive a short-lived signature; public deployments use
    /// the same virtual-host addressing shape as the existing upload client.
    pub fn public_platform_media_url(&self, object_key: &str) -> Option<String> {
        let key = object_key.trim().trim_start_matches('/');
        if key.is_empty() || key.contains("..") || key.contains('?') || key.contains('#') {
            return None;
        }
        if let Some(signer) = self.infra.media_signer.as_ref() {
            return signer.sign(key);
        }
        let endpoint = reqwest::Url::parse(&self.secrets.oss_endpoint).ok()?;
        let host = endpoint.host_str()?;
        let authority = match endpoint.port() {
            Some(port) => format!("{}.{}:{}", self.secrets.oss_bucket, host, port),
            None => format!("{}.{}", self.secrets.oss_bucket, host),
        };
        Some(format!("{}://{}/{}", endpoint.scheme(), authority, key))
    }

    /// Probe a server-generated object key without trusting a client upload
    /// claim. The range request transfers at most the first 512 bytes when the
    /// platform honours Range, while Content-Range/Length supplies the object
    /// size used by the shared-object lifecycle.
    pub async fn probe_platform_object(
        &self,
        object_key: &str,
    ) -> Result<PlatformObjectMetadata, ApiError> {
        let url = self
            .public_platform_media_url(object_key)
            .ok_or_else(|| ApiError::NotImplemented("平台文件服务未配置".to_string()))?;
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .map_err(|error| ApiError::Internal(anyhow::anyhow!(error)))?;
        let mut response = client
            .get(url)
            .header(reqwest::header::RANGE, "bytes=0-511")
            .send()
            .await
            .map_err(|error| {
                tracing::warn!(%error, "platform storage probe failed");
                ApiError::ServiceUnavailable("平台文件服务")
            })?;
        if response.status() == reqwest::StatusCode::NOT_FOUND {
            return Err(ApiError::CodedConflict {
                code: "shared_object_upload_missing",
                message: "平台文件尚未上传完成".to_string(),
            });
        }
        if !response.status().is_success() {
            return Err(ApiError::ServiceUnavailable("平台文件服务"));
        }
        let headers = response.headers();
        let size_bytes = headers
            .get(reqwest::header::CONTENT_RANGE)
            .and_then(|value| value.to_str().ok())
            .and_then(parse_content_range_total)
            .or_else(|| {
                headers
                    .get(reqwest::header::CONTENT_LENGTH)
                    .and_then(|value| value.to_str().ok())
                    .and_then(|value| value.parse::<i64>().ok())
            })
            .ok_or_else(|| ApiError::CodedConflict {
                code: "shared_object_storage_metadata_missing",
                message: "平台没有返回文件大小".to_string(),
            })?;
        let mime_type = headers
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .map(str::to_string);
        let etag = headers
            .get(reqwest::header::ETAG)
            .and_then(|value| value.to_str().ok())
            .map(str::to_string);
        let mut prefix_bytes = Vec::with_capacity(512);
        while prefix_bytes.len() < 512 {
            let Some(chunk) = response.chunk().await.map_err(|error| {
                tracing::warn!(%error, "platform storage prefix probe failed");
                ApiError::ServiceUnavailable("平台文件服务")
            })?
            else {
                break;
            };
            let remaining = 512 - prefix_bytes.len();
            prefix_bytes.extend_from_slice(&chunk[..chunk.len().min(remaining)]);
            if chunk.len() >= remaining {
                break;
            }
        }
        Ok(PlatformObjectMetadata {
            size_bytes,
            mime_type,
            etag,
            prefix_bytes,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlatformObjectMetadata {
    pub size_bytes: i64,
    pub mime_type: Option<String>,
    pub etag: Option<String>,
    /// Bounded prefix read used by image lifecycles to validate file headers.
    /// It is never persisted or returned to clients.
    pub prefix_bytes: Vec<u8>,
}

fn parse_content_range_total(value: &str) -> Option<i64> {
    let (_, total) = value.trim().split_once('/')?;
    if total == "*" {
        return None;
    }
    total.parse().ok()
}

fn is_platform_media_reference(state: &AppState, stored: &str) -> bool {
    let stored = stored.trim();
    if stored.is_empty() || stored.starts_with("//") {
        return false;
    }
    let Ok(parsed) = reqwest::Url::parse(stored) else {
        return !stored.contains("://");
    };
    matches!(parsed.scheme(), "http" | "https")
        && platform_media_host_matches(
            &parsed,
            &state.secrets.oss_endpoint,
            &state.secrets.oss_bucket,
        )
}

/// Normalize a media URL only when it points at the configured platform
/// storage. Chat messages must not turn an arbitrary third-party URL into a
/// server-persisted, sender-visible media reference. Both virtual-host and
/// path-style S3/OSS URLs are accepted because existing upload deployments use
/// both forms; presigned query parameters are intentionally ignored here.
pub(crate) fn normalize_platform_media_url(
    state: &AppState,
    value: Option<String>,
    field: &str,
) -> Result<Option<String>, ApiError> {
    let value = value
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    if let Some(url) = value.as_deref() {
        let parsed = reqwest::Url::parse(url)
            .map_err(|_| ApiError::BadRequest(format!("{field} 格式无效")))?;
        if !matches!(parsed.scheme(), "http" | "https")
            || !platform_media_host_matches(
                &parsed,
                &state.secrets.oss_endpoint,
                &state.secrets.oss_bucket,
            )
        {
            return Err(ApiError::CodedConflict {
                code: "media_external_url_blocked",
                message: "聊天媒体必须先上传到平台存储".to_string(),
            });
        }
    }
    Ok(value)
}

fn platform_media_host_matches(parsed: &reqwest::Url, endpoint: &str, bucket: &str) -> bool {
    let Some(endpoint) = reqwest::Url::parse(endpoint).ok() else {
        return false;
    };
    let (Some(parsed_host), Some(endpoint_host)) = (parsed.host_str(), endpoint.host_str()) else {
        return false;
    };
    if parsed.port_or_known_default() != endpoint.port_or_known_default()
        || parsed.username() != ""
        || parsed.password().is_some()
    {
        return false;
    }

    // Virtual-host style: https://{bucket}.{endpoint-host}/{key}
    if parsed_host == format!("{bucket}.{endpoint_host}") {
        return !parsed.path().trim_matches('/').is_empty();
    }

    // Path style: https://{endpoint-host}/{bucket}/{key}
    parsed_host == endpoint_host
        && parsed
            .path()
            .strip_prefix(&format!("/{bucket}/"))
            .is_some_and(|key| !key.is_empty())
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
            "/api/admin/listings/{id}/restore",
            post(admin::restore_listing),
        )
        .route(
            "/api/admin/outbox/dead-letter",
            get(admin::list_dead_letter_outbox_events),
        )
        .route(
            "/api/admin/outbox/replay/{id}",
            post(admin::replay_outbox_event),
        )
        .route(
            "/api/recommendations/feed",
            get(recommendations::get_recommendation_feed),
        )
        .route(
            "/api/recommendations/similar",
            get(recommendations::get_similar_listings),
        )
        .route("/api/feed/feedback", post(feed::submit_feedback))
        .route(
            "/api/feed/preferences",
            get(feed::get_preferences).put(feed::update_preferences),
        )
        .route(
            "/api/feed/personalization/clear",
            post(feed::clear_personalization),
        )
        .route("/api/categories", get(listings::get_categories))
        .route(
            "/api/posts",
            get(posts::list_posts).post(posts::create_post),
        )
        .route("/api/posts/categories", get(posts::list_categories))
        .route("/api/camphor", get(camphor::get_balance))
        .route("/api/posts/{id}/fertilize", post(camphor::fertilize_post))
        .route(
            "/api/agent/turns/{conversation_id}/cancel",
            post(chat::cancel_turn),
        )
        .route(
            "/api/posts/by-listing/{listing_id}",
            get(posts::get_post_by_listing),
        )
        .route(
            "/api/posts/{id}",
            get(posts::get_post)
                .put(posts::update_post)
                .delete(posts::delete_post),
        )
        .route(
            "/api/posts/{id}/replies",
            get(posts::list_replies).post(posts::create_reply),
        )
        .route(
            "/api/posts/{post_id}/replies/{reply_id}",
            put(posts::update_reply).delete(posts::delete_reply),
        )
        .route("/api/campuses", get(campuses::list_campuses))
        .route("/api/chat/stream", post(chat::handle_chat_stream_post))
        .route(
            "/api/chat/assistant",
            get(chat::get_assistant_history).delete(chat::clear_assistant_history),
        )
        .route("/api/auth/register", post(auth::register))
        .route("/api/auth/login", post(auth::login))
        .route("/api/auth/reauth", post(auth::reauthenticate))
        .route("/api/auth/mfa/totp", get(mfa::totp_status))
        .route("/api/auth/mfa/totp/setup", post(mfa::totp_setup))
        .route("/api/auth/mfa/totp/confirm", post(mfa::totp_confirm))
        .route("/api/agent/plans", get(agent_plans::list_plans))
        .route("/api/agent/runs", get(agent_runs::list_runs))
        .route(
            "/api/companion/relationship",
            get(companion::get_relationship),
        )
        .route(
            "/api/companion/relationship/events",
            post(companion::record_relationship_event),
        )
        .route(
            "/api/agent/profile",
            get(agent_memory::get_profile).put(agent_memory::update_profile),
        )
        .route(
            "/api/agent/memories",
            get(agent_memory::list_memories)
                .post(agent_memory::create_memory)
                .delete(agent_memory::clear_memories),
        )
        .route(
            "/api/agent/session-memory",
            delete(agent_memory::clear_session_memory),
        )
        .route(
            "/api/agent/memories/{id}",
            axum::routing::delete(agent_memory::delete_memory),
        )
        .route(
            "/api/agent/skills",
            get(agent_skills::list_skills)
                .post(agent_skills::upsert_skill)
                .delete(agent_skills::clear_skills),
        )
        .route(
            "/api/agent/skills/{id}",
            axum::routing::patch(agent_skills::patch_skill)
                .merge(axum::routing::delete(agent_skills::delete_skill)),
        )
        .route(
            "/api/agent/plans/{id}/confirm",
            post(agent_plans::confirm_plan),
        )
        .route(
            "/api/agent/plans/{id}/cancel",
            post(agent_plans::cancel_plan),
        )
        .route(
            "/api/intents",
            get(intents::list_intents).post(intents::create_intent),
        )
        .route(
            "/api/intents/{id}",
            axum::routing::delete(intents::withdraw_intent),
        )
        .route(
            "/api/intents/draft-batch",
            post(intents::create_draft_batch),
        )
        .route("/api/intents/decompose", post(intents::decompose_intent))
        .route(
            "/api/intents/decompose-photo",
            post(intents::decompose_photo),
        )
        .route("/api/price-discovery", post(price_discovery::propose))
        .route(
            "/api/price-discovery/{id}",
            get(price_discovery::get_session),
        )
        .route(
            "/api/price-discovery/{id}/accept",
            post(price_discovery::accept),
        )
        .route(
            "/api/price-discovery/{id}/decline",
            post(price_discovery::decline),
        )
        .route(
            "/api/price-discovery/{id}/limit",
            post(price_discovery::state_limit),
        )
        .route("/api/handoffs/pending", get(reputation::pending))
        .route("/api/handoffs/{id}/confirm", post(reputation::confirm))
        .route("/api/users/{id}/reputation", get(reputation::of_user))
        .route("/api/agreements", post(agreements::ensure))
        .route("/api/agreements/{id}", get(agreements::get_agreement))
        .route(
            "/api/agreements/{id}/terms",
            axum::routing::put(agreements::set_term),
        )
        .route("/api/agreements/{id}/adopt", post(agreements::adopt))
        .route("/api/agreements/{id}/settle", post(agreements::settle))
        .route("/api/intents/feed", get(intents::intent_feed))
        .route(
            "/api/intents/{id}/respond",
            post(intents::respond_to_intent),
        )
        .route("/api/intents/{id}/confirm", post(intents::confirm_intent))
        .route("/api/intents/{id}/fulfil", post(intents::fulfil_intent))
        .route("/api/intents/{id}/matches", get(intents::intent_matches))
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
        .route("/api/listings", get(listings::get_listings))
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
        .route(
            "/api/listings/{id}/report",
            post(content_reports::report_listing),
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
            "/api/user/persona",
            get(social_persona::get_persona).put(social_persona::upsert_persona),
        )
        .route(
            "/api/user/persona/publish",
            post(social_persona::publish_persona),
        )
        .route(
            "/api/user/persona/archive",
            post(social_persona::archive_persona),
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
        .route("/api/user/posts", get(user::get_user_posts))
        .route("/api/users/search", get(user::search_users))
        .route("/api/users/lookup", get(user::lookup_users))
        .route(
            "/api/users/{id}/listings",
            get(user::get_public_user_listings),
        )
        .route("/api/persona/catalog", get(social_persona::get_catalog))
        .route(
            "/api/users/{id}/persona",
            get(social_persona::get_public_persona),
        )
        .route("/api/users/{id}/report", post(content_reports::report_user))
        .route("/api/users/{id}", get(user::get_user_profile))
        .route(
            "/api/orders",
            get(orders::get_orders).post(orders::create_order),
        )
        .route("/api/orders/{id}", get(orders::get_order))
        .route("/api/orders/{id}/cancel", post(orders::cancel_order))
        .route("/api/orders/{id}/confirm", post(orders::confirm_order))
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
            "/api/chat/threads/{peer_user_id}/space-events",
            get(user_chat::get_relationship_space),
        )
        .route(
            "/api/chat/conversations/{id}/shared-objects",
            post(user_chat::create_shared_object),
        )
        .route(
            "/api/chat/shared-objects/{id}",
            get(user_chat::get_shared_object).delete(user_chat::revoke_shared_object),
        )
        .route(
            "/api/chat/shared-objects/{id}/complete",
            post(user_chat::complete_shared_object),
        )
        .route(
            "/api/chat/shared-objects/{id}/media",
            get(user_chat::get_shared_object_media),
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
            "/api/chat/conversations/{id}/avatar-interactions",
            post(user_chat::send_avatar_interaction),
        )
        .route("/api/chat/messages/{id}", patch(user_chat::edit_message))
        .route(
            "/api/chat/messages/{id}/reaction",
            post(user_chat::set_message_reaction).delete(user_chat::delete_message_reaction),
        )
        .route(
            "/api/chat/messages/{id}/acknowledgement",
            post(user_chat::set_message_acknowledgement)
                .delete(user_chat::delete_message_acknowledgement),
        )
        .route(
            "/api/chat/messages/{id}/hide",
            post(user_chat::hide_message),
        )
        .route(
            "/api/chat/messages/{id}/pin",
            post(user_chat::pin_message).delete(user_chat::unpin_message),
        )
        .route(
            "/api/chat/messages/{id}/report",
            post(user_chat::report_message),
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
            "/api/chat/connection-preferences",
            get(user_chat::get_connection_preferences).put(user_chat::set_connection_preferences),
        )
        .route(
            "/api/chat/avatar-interactions/preferences",
            get(user_chat::get_avatar_interaction_preferences)
                .put(user_chat::set_avatar_interaction_preferences),
        )
        .route(
            "/api/chat/contacts",
            get(user_chat::list_contact_permissions),
        )
        .route(
            "/api/chat/contacts/{peer_user_id}",
            put(user_chat::set_contact_permission).delete(user_chat::delete_contact_permission),
        )
        .route(
            "/api/chat/contacts/{peer_user_id}/avatar-interaction-preferences",
            get(user_chat::get_avatar_interaction_contact_preferences)
                .put(user_chat::set_avatar_interaction_contact_preferences)
                .delete(user_chat::delete_avatar_interaction_contact_preferences),
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
        .layer(RequestBodyLimitLayer::new(10 * 1024 * 1024))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            token_denylist_middleware,
        ))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            rate_limit_middleware,
        ))
        .layer(TimeoutLayer::with_status_code(
            axum::http::StatusCode::GATEWAY_TIMEOUT,
            std::time::Duration::from_secs(60),
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

/// Shared readiness logic for `/api/readyz`.
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

    if state.infra.deployment_profile == crate::config::DeploymentProfile::Replicated {
        #[cfg(feature = "redis")]
        {
            if let Some(runtime) = &state.infra.replicated_runtime {
                runtime.check_health().await?;
            } else {
                tracing::error!(
                    "Readiness check failed: replicated profile missing replicated_runtime"
                );
                return Err(ApiError::ServiceUnavailable("redis_unreachable"));
            }
        }
        #[cfg(not(feature = "redis"))]
        {
            return Err(ApiError::ServiceUnavailable("redis_feature_disabled"));
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::{HeaderMap, HeaderValue};

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

    #[test]
    fn platform_media_urls_accept_both_oss_addressing_styles() {
        let endpoint = "https://oss.example.com";
        assert!(platform_media_host_matches(
            &reqwest::Url::parse("https://goods.oss.example.com/chat/a.jpg?sig=1").unwrap(),
            endpoint,
            "goods"
        ));
        assert!(platform_media_host_matches(
            &reqwest::Url::parse("https://oss.example.com/goods/chat/a.jpg").unwrap(),
            endpoint,
            "goods"
        ));
    }

    #[test]
    fn platform_media_urls_reject_foreign_hosts_and_bucket_roots() {
        let endpoint = "https://oss.example.com";
        assert!(!platform_media_host_matches(
            &reqwest::Url::parse("https://cdn.example.com/chat/a.jpg").unwrap(),
            endpoint,
            "goods"
        ));
        assert!(!platform_media_host_matches(
            &reqwest::Url::parse("https://oss.example.com/goods").unwrap(),
            endpoint,
            "goods"
        ));
        assert!(!platform_media_host_matches(
            &reqwest::Url::parse("https://goods.evil.example.com/chat/a.jpg").unwrap(),
            endpoint,
            "goods"
        ));
        assert!(!platform_media_host_matches(
            &reqwest::Url::parse("https://goods.oss.example.com/").unwrap(),
            endpoint,
            "goods"
        ));
    }

    #[test]
    fn content_range_parser_prefers_total_object_size() {
        assert_eq!(parse_content_range_total("bytes 0-0/4096"), Some(4096));
        assert_eq!(parse_content_range_total("bytes 0-0/*"), None);
        assert_eq!(parse_content_range_total("garbage"), None);
    }
}
