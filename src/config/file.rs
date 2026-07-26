//! TOML configuration file support.
//!
//! Non-secret configuration lives in a TOML file (e.g., `goods4ncu.toml`).
//! Environment variables always override file values — env vars win.
//!
//! Secrets (API keys, JWT secret, DATABASE_URL) MUST stay in environment variables.

use serde::Deserialize;
use std::path::Path;
use std::sync::OnceLock;

// ---------------------------------------------------------------------------
// FileConfig — deserialized from TOML, never contains secrets
// ---------------------------------------------------------------------------

/// Root of the TOML configuration file.
/// All fields are Optional — missing fields use AppConfig defaults or env vars.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct FileConfig {
    #[serde(default)]
    pub server: ServerConfig,

    #[serde(default)]
    pub llm: LlmConfig,

    #[serde(default)]
    pub rate_limit: RateLimitConfig,

    #[serde(default)]
    pub event_bus: EventBusConfig,

    #[serde(default)]
    pub workers: WorkersConfig,

    #[serde(default)]
    pub auth: AuthConfig,

    #[serde(default)]
    pub marketplace: MarketplaceConfig,

    #[serde(default)]
    pub moderation: ModerationConfig,

    #[serde(default)]
    pub chat: ChatConfig,

    #[serde(default)]
    pub cors: CorsConfig,

    #[serde(default)]
    pub oss: OssConfig,
}

/// Server bind configuration.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct ServerConfig {
    /// IP address to bind. Defaults to "0.0.0.0".
    #[serde(default)]
    pub host: Option<String>,
    /// TCP port to listen on. Defaults to 3000.
    #[serde(default)]
    pub port: Option<u16>,
    /// Seconds to keep serving after SIGTERM while readiness reports failure,
    /// so the load balancer can deregister this instance before it stops
    /// accepting. Defaults to 5.
    #[serde(default)]
    pub shutdown_drain_secs: Option<u64>,
    /// Seconds to wait for in-flight requests and workers to finish once the
    /// listener has closed. Must fit inside the orchestrator's grace period.
    /// Defaults to 25.
    #[serde(default)]
    pub shutdown_timeout_secs: Option<u64>,
}

/// LLM provider configuration.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct LlmConfig {
    /// "gemini", "minimax", or an OpenAI-compatible provider alias.
    /// Defaults to "gemini".
    #[serde(default)]
    pub provider: Option<String>,
    /// Chat model name. Defaults are only provided for first-party built-ins.
    #[serde(default)]
    pub model: Option<String>,
    /// OpenAI-compatible API base URL. Secrets still come from env vars.
    #[serde(default)]
    pub base_url: Option<String>,
    /// Embedding vector dimensions. Defaults to 768.
    #[serde(default)]
    pub vector_dim: Option<usize>,
}

/// Rate limiting configuration.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct RateLimitConfig {
    /// Maximum requests per window per IP. Defaults to 100.
    #[serde(default)]
    pub max_requests: Option<u64>,
    /// Window in seconds. Defaults to 60.
    #[serde(default)]
    pub window_secs: Option<u64>,
    /// Maximum cache entries for local rate limiter. Defaults to 100_000.
    #[serde(default)]
    pub moka_cache_max_capacity: Option<u64>,
    /// Redis connection URL for distributed rate limiting.
    #[serde(default)]
    pub redis_url: Option<String>,
}

/// Event bus channel capacity. Defaults to 2048.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct EventBusConfig {
    #[serde(default)]
    pub capacity: Option<usize>,
}

/// Background worker configuration.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct WorkersConfig {
    #[serde(default)]
    pub hitl_expire: HitlExpireConfig,
}

/// HITL (Human-In-The-Loop) negotiation expiration.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct HitlExpireConfig {
    /// How often (seconds) to scan for expired pending negotiations. Defaults to 600.
    #[serde(default)]
    pub scan_interval_secs: Option<u64>,
    /// How many hours before pending negotiations expire. Defaults to 48.
    #[serde(default)]
    pub expire_timeout_hours: Option<u64>,
}

/// Authentication token TTL configuration.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct AuthConfig {
    /// Access token TTL in seconds. Defaults to 86400 (24 hours).
    #[serde(default)]
    pub access_token_ttl_secs: Option<u64>,
    /// Refresh token TTL in seconds. Defaults to 604800 (7 days).
    #[serde(default)]
    pub refresh_token_ttl_secs: Option<u64>,
}

/// Marketplace configuration.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct MarketplaceConfig {
    /// Number of chat messages to include in context. Defaults to 10.
    #[serde(default)]
    pub conversation_history_limit: Option<usize>,
    /// Maximum keyword search length. Defaults to 200.
    #[serde(default)]
    pub max_keyword_len: Option<usize>,
    /// Negotiation price tolerance (0.0–1.0). Defaults to 0.50.
    #[serde(default)]
    pub price_tolerance: Option<f64>,
    /// Allowed listing categories.
    #[serde(default)]
    pub categories: Option<Vec<String>>,
}

/// Chat feature configuration.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct ChatConfig {
    /// Whether new Secret Chat sessions may be created. Secret Chat is
    /// deprecated (it conflicts with server-side moderation duties); existing
    /// sessions stay readable regardless of this flag. Defaults to false.
    #[serde(default)]
    pub secret_new_sessions_enabled: Option<bool>,
}

/// Content moderation configuration.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct ModerationConfig {
    /// Blocked keyword list (loaded from env var BLOCKED_KEYWORDS, not file).
    #[serde(default)]
    pub blocked_keywords: Option<Vec<String>>,
    /// Whether image moderation is enabled. Defaults to true.
    #[serde(default)]
    pub image_enabled: Option<bool>,
    /// Alibaba IMAN API URL for image moderation.
    #[serde(default)]
    pub image_api_url: Option<String>,
    /// Alibaba IMAN API key (secret — loaded from env, not file).
    #[serde(default)]
    pub image_api_key: Option<String>,
}

/// CORS configuration.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct CorsConfig {
    /// Allow all origins. Defaults to false.
    #[serde(default)]
    #[allow(dead_code)]
    pub wildcard: Option<bool>,
    /// Allowed origin list.
    #[serde(default)]
    pub origins: Option<Vec<String>>,
}

/// Alibaba Cloud OSS configuration (non-secret fields only).
#[derive(Debug, Clone, Deserialize, Default)]
pub struct OssConfig {
    /// OSS endpoint URL. Defaults to "https://oss-cn-beijing.aliyuncs.com".
    #[serde(default)]
    pub endpoint: Option<String>,
    /// OSS bucket name. Defaults to "goods4ncu".
    #[serde(default)]
    pub bucket: Option<String>,
}

// ---------------------------------------------------------------------------
// FileConfig loading
// ---------------------------------------------------------------------------

/// Cached config file path (set once via CONFIG_FILE env var).
static CONFIG_FILE_PATH: OnceLock<Option<String>> = OnceLock::new();

/// Returns the config file path from the CONFIG_FILE env var, or None for default.
pub fn config_file_env() -> Option<String> {
    CONFIG_FILE_PATH
        .get_or_init(|| std::env::var("CONFIG_FILE").ok())
        .clone()
}

/// Default config file search paths (checked in order).
const DEFAULT_CONFIG_PATHS: [&str; 4] = [
    "./goods4ncu.toml",
    "./config/goods4ncu.toml",
    "./good4ncu.toml",
    "./config/good4ncu.toml",
];

/// Attempt to load FileConfig from a TOML file.
/// Returns None if the file does not exist or is invalid.
pub fn load(config_path: Option<&Path>) -> Option<FileConfig> {
    let path = if let Some(p) = config_path {
        p
    } else if let Some(ref env_path) = config_file_env() {
        return FileConfig::load_from_path(Path::new(env_path));
    } else {
        // Search default locations
        for candidate in DEFAULT_CONFIG_PATHS {
            let p = Path::new(candidate);
            if p.exists() {
                return FileConfig::load_from_path(p);
            }
        }
        return None;
    };

    FileConfig::load_from_path(path)
}

impl FileConfig {
    fn load_from_path(path: &Path) -> Option<FileConfig> {
        let content = std::fs::read_to_string(path).ok()?;
        toml::from_str(&content)
            .inspect_err(|e| {
                tracing::warn!(
                    path = %path.display(),
                    error = %e,
                    "Failed to parse config file — using env vars only",
                )
            })
            .ok()
    }
}
