//! Unified application configuration.
//! All environment variables are loaded and validated at startup.
//! Use `AppConfig::load()` once in `main()`, then pass `Arc<AppConfig>` to components.
//!
//! A TOML config file (e.g. `goods4ncu.toml`) can supplement env vars.
//! Use `AppConfig::load_with_file()` to merge TOML + env vars.
//! Environment variables always override TOML file values.

mod file;

use std::fmt;
use std::path::Path;
use std::sync::Arc;

use crate::agents::runtime::api_drivers::ApiStyle;

/// Default marketplace categories (used when not set in config file).
pub const DEFAULT_CATEGORIES: &[&str] = &[
    "electronics",
    "books",
    "digitalAccessories",
    "dailyGoods",
    "clothingShoes",
    "other",
];

/// Deployment topology mode. Local mode runs in-process; replicated mode
/// coordinates multi-instance state via Redis and fails fast if Redis is unavailable.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DeploymentProfile {
    #[default]
    Local,
    Replicated,
}

pub const SUPPORTED_LLM_PROVIDERS: &[&str] = &[
    "gemini",
    "minimax",
    "openai_compatible",
    "openai",
    "deepseek",
    "groq",
    "openrouter",
    "xai",
    "together",
];

fn normalize_llm_provider(provider: &str) -> String {
    provider.trim().to_ascii_lowercase().replace('-', "_")
}

pub fn is_openai_compatible_provider(provider: &str) -> bool {
    matches!(
        provider,
        "minimax"
            | "openai_compatible"
            | "openai"
            | "deepseek"
            | "groq"
            | "openrouter"
            | "xai"
            | "together"
    )
}

fn is_supported_llm_provider(provider: &str) -> bool {
    SUPPORTED_LLM_PROVIDERS.contains(&provider)
}

fn default_llm_model(provider: &str) -> Option<&'static str> {
    match provider {
        "gemini" => Some("gemini-3.5-flash-lite"),
        "minimax" => Some("MiniMax-M2.7"),
        _ => None,
    }
}

fn default_llm_base_url(provider: &str) -> Option<&'static str> {
    match provider {
        "openai" => Some("https://api.openai.com/v1"),
        "minimax" => Some("https://api.minimaxi.com/v1"),
        "deepseek" => Some("https://api.deepseek.com/v1"),
        "groq" => Some("https://api.groq.com/openai/v1"),
        "openrouter" => Some("https://openrouter.ai/api/v1"),
        "xai" => Some("https://api.x.ai/v1"),
        "together" => Some("https://api.together.xyz/v1"),
        _ => None,
    }
}

fn provider_api_key_env(provider: &str) -> Option<&'static str> {
    match provider {
        "openai" => Some("OPENAI_API_KEY"),
        "minimax" => Some("MINIMAX_API_KEY"),
        "deepseek" => Some("DEEPSEEK_API_KEY"),
        "groq" => Some("GROQ_API_KEY"),
        "openrouter" => Some("OPENROUTER_API_KEY"),
        "xai" => Some("XAI_API_KEY"),
        "together" => Some("TOGETHER_API_KEY"),
        _ => None,
    }
}

/// Centralized application configuration loaded from environment variables.
#[derive(Clone)]
pub struct AppConfig {
    // --- Secrets (env var only, never from TOML) ---
    pub gemini_api_key: String,
    pub llm_api_key: Option<String>,
    pub jwt_secret: String,
    pub jwt_secret_old: Option<String>,
    pub database_url: String,
    pub oss_access_key_id: Option<String>,
    pub oss_access_key_secret: Option<String>,

    // --- LLM config (env var, with TOML override) ---
    pub llm_provider: String,
    pub llm_model: String,
    pub llm_base_url: Option<String>,
    /// When false, all AI/agent features are disabled and the platform
    /// operates as the original non-AI demo.
    pub agent_enabled: bool,
    pub llm_api_style: ApiStyle,
    pub vector_dim: usize,

    // --- Infrastructure ---
    pub cors_origins: Vec<String>,
    pub oss_endpoint: String,
    pub oss_bucket: String,
    pub oss_role_arn: Option<String>,
    pub redis_url: Option<String>,
    pub deployment_profile: DeploymentProfile,
    pub rate_limit_max_requests: u64,
    pub rate_limit_window_secs: u64,

    // --- TOML-only fields (with hardcoded defaults when no file) ---
    pub server_host: String,
    pub server_port: u16,
    pub shutdown_drain_secs: u64,
    pub shutdown_timeout_secs: u64,
    pub hitl_expire_scan_interval_secs: u64,
    pub hitl_expire_timeout_hours: u64,
    pub moka_cache_max_capacity: u64,
    pub access_token_ttl_secs: u64,
    pub refresh_token_ttl_secs: u64,
    pub conversation_history_limit: usize,
    pub max_keyword_len: usize,
    pub price_tolerance: f64,
    pub categories: Vec<String>,
    pub blocked_keywords: Vec<String>,
    // Moderation
    pub moderation_image_enabled: bool,
    pub moderation_image_api_url: Option<String>,
    pub moderation_image_api_key: Option<String>,
    // Media serving: when the bucket is private, approved media is served via
    // short-lived presigned URLs instead of raw bucket links.
    pub media_private_bucket: bool,
    pub media_url_ttl_secs: u32,
    pub media_path_style: bool,
    pub media_region: String,
}

impl fmt::Debug for AppConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AppConfig")
            .field("gemini_api_key", &"[REDACTED]")
            .field(
                "llm_api_key",
                &self.llm_api_key.as_ref().map(|_| "[REDACTED]"),
            )
            .field("jwt_secret", &"[REDACTED]")
            .field(
                "jwt_secret_old",
                &self.jwt_secret_old.as_ref().map(|_| "[REDACTED]"),
            )
            .field("database_url", &"[REDACTED]")
            .field("llm_provider", &self.llm_provider)
            .field("llm_model", &self.llm_model)
            .field("llm_base_url", &self.llm_base_url)
            .field("llm_api_style", &self.llm_api_style)
            .field("vector_dim", &self.vector_dim)
            .field("cors_origins", &self.cors_origins)
            .field("oss_endpoint", &self.oss_endpoint)
            .field("oss_bucket", &self.oss_bucket)
            .field(
                "oss_role_arn",
                &self.oss_role_arn.as_ref().map(|_| "[REDACTED]"),
            )
            .field(
                "oss_access_key_id",
                &self.oss_access_key_id.as_ref().map(|_| "[REDACTED]"),
            )
            .field(
                "oss_access_key_secret",
                &self.oss_access_key_secret.as_ref().map(|_| "[REDACTED]"),
            )
            .field("redis_url", &self.redis_url)
            .field("deployment_profile", &self.deployment_profile)
            .field("rate_limit_max_requests", &self.rate_limit_max_requests)
            .field("rate_limit_window_secs", &self.rate_limit_window_secs)
            .field("server_host", &self.server_host)
            .field("server_port", &self.server_port)
            .field("shutdown_drain_secs", &self.shutdown_drain_secs)
            .field("shutdown_timeout_secs", &self.shutdown_timeout_secs)
            .field(
                "hitl_expire_scan_interval_secs",
                &self.hitl_expire_scan_interval_secs,
            )
            .field("hitl_expire_timeout_hours", &self.hitl_expire_timeout_hours)
            .field("moka_cache_max_capacity", &self.moka_cache_max_capacity)
            .field("access_token_ttl_secs", &self.access_token_ttl_secs)
            .field("refresh_token_ttl_secs", &self.refresh_token_ttl_secs)
            .field(
                "conversation_history_limit",
                &self.conversation_history_limit,
            )
            .field("max_keyword_len", &self.max_keyword_len)
            .field("price_tolerance", &self.price_tolerance)
            .field("categories", &self.categories)
            // Policy terms are operational secrets. Expose only their count
            // so diagnostics cannot leak the active moderation vocabulary.
            .field("blocked_keyword_count", &self.blocked_keywords.len())
            .field("moderation_image_enabled", &self.moderation_image_enabled)
            .field(
                "moderation_image_api_key",
                &self.moderation_image_api_key.as_ref().map(|_| "[REDACTED]"),
            )
            .field("media_private_bucket", &self.media_private_bucket)
            .finish()
    }
}

impl AppConfig {
    /// Load all configuration from environment variables only (no config file).
    /// Panics if any required variable is missing.
    #[allow(dead_code)]
    pub fn load() -> Arc<Self> {
        Self::load_with_file(None)
    }

    /// Load configuration from environment variables, optionally merged with a TOML file.
    ///
    /// Priority: **env var > TOML file > hardcoded default**
    ///
    /// The config file path is determined by (in order):
    /// 1. `$CONFIG_FILE` env var (if set)
    /// 2. `./goods4ncu.toml` (if exists)
    /// 3. `./config/goods4ncu.toml` (if exists)
    /// 4. legacy `./good4ncu.toml` or `./config/good4ncu.toml` (if exists)
    /// 5. No file (env vars only, all TOML fields use defaults)
    pub fn load_with_file(config_path: Option<&Path>) -> Arc<Self> {
        // Phase 1: Load TOML file (ignore if missing or invalid)
        let file = file::load(config_path);

        // Phase 2: Build config with env var override of file override of default

        let read_non_empty_env = |key: &str| {
            std::env::var(key)
                .ok()
                .map(|v| v.trim().to_string())
                .filter(|v| !v.is_empty())
        };

        // LLM provider: env > file > "gemini"
        let llm_provider = read_non_empty_env("LLM_PROVIDER")
            .or_else(|| file.as_ref()?.llm.provider.clone())
            .map(|provider| normalize_llm_provider(&provider))
            .unwrap_or_else(|| "gemini".into());

        if !is_supported_llm_provider(&llm_provider) {
            panic!(
                "LLM_PROVIDER must be one of {}, got: {}",
                SUPPORTED_LLM_PROVIDERS.join(", "),
                llm_provider
            );
        }

        let llm_model = read_non_empty_env("LLM_MODEL")
            .or_else(|| file.as_ref()?.llm.model.clone())
            .or_else(|| default_llm_model(&llm_provider).map(str::to_string))
            .unwrap_or_else(|| {
                panic!(
                    "LLM_MODEL must be set when LLM_PROVIDER={} (or llm.model in TOML)",
                    llm_provider
                )
            });

        let llm_base_url = read_non_empty_env("LLM_BASE_URL")
            .or_else(|| file.as_ref()?.llm.base_url.clone())
            .or_else(|| {
                (llm_provider == "minimax")
                    .then(|| read_non_empty_env("MINIMAX_API_BASE_URL"))
                    .flatten()
            })
            .or_else(|| default_llm_base_url(&llm_provider).map(str::to_string));

        let configured_api_style = ApiStyle::parse(
            read_non_empty_env("LLM_API_STYLE")
                .as_deref()
                .unwrap_or("auto"),
        )
        .unwrap_or_else(|message| panic!("{message}"));
        if llm_provider == "gemini" && configured_api_style != ApiStyle::Auto {
            panic!("LLM_API_STYLE is only valid for OpenAI-compatible providers");
        }
        let llm_api_style = configured_api_style.resolve(&llm_provider);

        let llm_api_key = read_non_empty_env("LLM_API_KEY")
            .or_else(|| provider_api_key_env(&llm_provider).and_then(read_non_empty_env))
            .or_else(|| read_non_empty_env("OPENAI_COMPAT_API_KEY"));

        let vector_dim: usize = read_non_empty_env("VECTOR_DIM")
            .or_else(|| file.as_ref()?.llm.vector_dim.map(|v| v.to_string()))
            .and_then(|s| s.parse().ok())
            .unwrap_or(768);

        let gemini_api_key = read_non_empty_env("GEMINI_API_KEY");

        if llm_provider == "gemini" && gemini_api_key.is_none() {
            panic!("GEMINI_API_KEY must be set when LLM_PROVIDER=gemini");
        }

        if is_openai_compatible_provider(&llm_provider) && llm_api_key.is_none() {
            panic!(
                "LLM_API_KEY or provider-specific key must be set when LLM_PROVIDER={}",
                llm_provider
            );
        }

        // All non-Gemini chat providers currently reuse Gemini embeddings so
        // the existing pgvector schema and RAG pipeline stay stable.
        if llm_provider != "gemini" && gemini_api_key.is_none() {
            panic!(
                "GEMINI_API_KEY must be set when LLM_PROVIDER={} (used for embeddings)",
                llm_provider
            );
        }

        let jwt_secret =
            std::env::var("JWT_SECRET").expect("JWT_SECRET must be set in environment");
        if jwt_secret.len() < 32 {
            panic!("JWT_SECRET must be at least 32 characters for security");
        }
        if running_in_production() {
            validate_production_secret_hygiene(&jwt_secret)
                .unwrap_or_else(|message| panic!("{message}"));
        }

        let jwt_secret_old = std::env::var("JWT_SECRET_OLD").ok();

        validate_campus_verification_delivery(
            running_in_production(),
            read_non_empty_env("CAMPUS_VERIFICATION_DELIVERY_URL").as_deref(),
            read_non_empty_env("CAMPUS_VERIFICATION_DELIVERY_TOKEN").as_deref(),
        )
        .unwrap_or_else(|message| panic!("{message}"));

        // CORS: env > file > default (empty = allow all in non-production only)
        let cors_origins = std::env::var("CORS_ORIGINS")
            .ok()
            .map(|s| s.split(',').map(|v| v.trim().to_string()).collect())
            .or_else(|| file.as_ref()?.cors.origins.clone())
            .unwrap_or_default();
        validate_cors_origins(&cors_origins).unwrap_or_else(|msg| panic!("{msg}"));

        // Blocked keywords: env > file > default
        let blocked_keywords = std::env::var("BLOCKED_KEYWORDS")
            .ok()
            .map(|s| s.split(',').map(|v| v.trim().to_string()).collect())
            .or_else(|| file.as_ref()?.moderation.blocked_keywords.clone())
            .unwrap_or_default();

        // OSS: env > file > hardcoded default
        let oss_endpoint = std::env::var("OSS_ENDPOINT")
            .ok()
            .or_else(|| file.as_ref()?.oss.endpoint.clone())
            .unwrap_or_else(|| "https://oss-cn-beijing.aliyuncs.com".into());

        let oss_bucket = std::env::var("OSS_BUCKET")
            .ok()
            .or_else(|| file.as_ref()?.oss.bucket.clone())
            .unwrap_or_else(|| "goods4ncu".into());

        let oss_role_arn = std::env::var("OSS_ROLE_ARN").ok();
        let oss_access_key_id = std::env::var("OSS_ACCESS_KEY_ID").ok();
        let oss_access_key_secret = std::env::var("OSS_ACCESS_KEY_SECRET").ok();

        // Redis: env > file > None
        let redis_url = std::env::var("REDIS_URL")
            .ok()
            .or_else(|| file.as_ref()?.rate_limit.redis_url.clone());

        // Deployment profile: local vs replicated (fail-fast if replicated lacks redis)
        let deployment_profile = match read_non_empty_env("DEPLOYMENT_PROFILE")
            .or_else(|| read_non_empty_env("APP_PROFILE"))
            .as_deref()
        {
            Some("replicated") | Some("cluster") => DeploymentProfile::Replicated,
            _ => DeploymentProfile::Local,
        };

        if deployment_profile == DeploymentProfile::Replicated {
            assert!(
                redis_url.is_some(),
                "DEPLOYMENT_PROFILE=replicated requires REDIS_URL to be set; refusing to boot with silent downgrade to local state"
            );
        }

        // Rate limit: env > file > default (fail-fast on invalid env value)
        let rate_limit_max_requests: u64 = if let Ok(v) = std::env::var("RATE_LIMIT_MAX_REQUESTS") {
            v.parse()
                .expect("RATE_LIMIT_MAX_REQUESTS must be a valid u64")
        } else {
            file.as_ref()
                .and_then(|f| f.rate_limit.max_requests)
                .unwrap_or(100)
        };

        let rate_limit_window_secs: u64 = if let Ok(v) = std::env::var("RATE_LIMIT_WINDOW_SECS") {
            v.parse()
                .expect("RATE_LIMIT_WINDOW_SECS must be a valid u64")
        } else {
            file.as_ref()
                .and_then(|f| f.rate_limit.window_secs)
                .unwrap_or(60)
        };

        // Server bind address: env > file > safe container default
        let server_host = read_non_empty_env("SERVER_HOST")
            .or_else(|| file.as_ref()?.server.host.clone())
            .unwrap_or_else(|| "0.0.0.0".into());

        let server_port: u16 = if let Some(v) = read_non_empty_env("SERVER_PORT") {
            v.parse().expect("SERVER_PORT must be a valid u16")
        } else {
            file.as_ref().and_then(|f| f.server.port).unwrap_or(3000)
        };

        // Shutdown timings: env > file > default. Deploy tooling usually sets
        // these per environment, so env has to win over a baked-in TOML.
        let shutdown_drain_secs: u64 = if let Some(v) = read_non_empty_env("SHUTDOWN_DRAIN_SECS") {
            v.parse().expect("SHUTDOWN_DRAIN_SECS must be a valid u64")
        } else {
            file.as_ref()
                .and_then(|f| f.server.shutdown_drain_secs)
                .unwrap_or(5)
        };

        let shutdown_timeout_secs: u64 =
            if let Some(v) = read_non_empty_env("SHUTDOWN_TIMEOUT_SECS") {
                v.parse()
                    .expect("SHUTDOWN_TIMEOUT_SECS must be a valid u64")
            } else {
                file.as_ref()
                    .and_then(|f| f.server.shutdown_timeout_secs)
                    .unwrap_or(25)
            };

        let hitl_expire_scan_interval_secs = file
            .as_ref()
            .and_then(|f| f.workers.hitl_expire.scan_interval_secs)
            .unwrap_or(600);

        let hitl_expire_timeout_hours = file
            .as_ref()
            .and_then(|f| f.workers.hitl_expire.expire_timeout_hours)
            .unwrap_or(48);

        let moka_cache_max_capacity = file
            .as_ref()
            .and_then(|f| f.rate_limit.moka_cache_max_capacity)
            .unwrap_or(100_000);

        let access_token_ttl_secs = file
            .as_ref()
            .and_then(|f| f.auth.access_token_ttl_secs)
            .unwrap_or(86400);

        let refresh_token_ttl_secs = file
            .as_ref()
            .and_then(|f| f.auth.refresh_token_ttl_secs)
            .unwrap_or(604800);

        let conversation_history_limit = file
            .as_ref()
            .and_then(|f| f.marketplace.conversation_history_limit)
            .unwrap_or(10);

        let max_keyword_len = file
            .as_ref()
            .and_then(|f| f.marketplace.max_keyword_len)
            .unwrap_or(200);

        let price_tolerance = file
            .as_ref()
            .and_then(|f| f.marketplace.price_tolerance)
            .unwrap_or(0.50);

        let categories = file
            .as_ref()
            .and_then(|f| f.marketplace.categories.clone())
            .unwrap_or_else(|| {
                DEFAULT_CATEGORIES
                    .iter()
                    .map(|s| (*s).to_string())
                    .collect()
            });

        let moderation_image_enabled = read_non_empty_env("MODERATION_IMAGE_ENABLED")
            .and_then(|v| v.parse::<bool>().ok())
            .or_else(|| file.as_ref()?.moderation.image_enabled)
            // Development deployments do not have a moderation provider by
            // default. Keep uploaded discussion covers visible there while
            // preserving the fail-closed production default and validation.
            .unwrap_or_else(running_in_production);
        let moderation_image_api_url = read_non_empty_env("MODERATION_IMAGE_API_URL")
            .or_else(|| file.as_ref()?.moderation.image_api_url.clone());
        let moderation_image_api_key = read_non_empty_env("MODERATION_IMAGE_API_KEY")
            .or_else(|| file.as_ref()?.moderation.image_api_key.clone());
        validate_image_moderation_config(
            running_in_production(),
            moderation_image_enabled,
            moderation_image_api_url.as_deref(),
            moderation_image_api_key.as_deref(),
        )
        .unwrap_or_else(|message| panic!("{message}"));

        // Private-bucket media serving. Default OFF so existing public-bucket
        // deployments keep working; production should enable it together with a
        // private bucket policy (see docs/.env.production.example).
        let media_private_bucket = read_non_empty_env("MEDIA_PRIVATE_BUCKET")
            .and_then(|v| v.parse::<bool>().ok())
            .unwrap_or(false);
        let media_url_ttl_secs = read_non_empty_env("MEDIA_URL_TTL_SECS")
            .and_then(|v| v.parse::<u32>().ok())
            .unwrap_or(600);
        let media_path_style = read_non_empty_env("MEDIA_PATH_STYLE")
            .and_then(|v| v.parse::<bool>().ok())
            .unwrap_or(false);
        let media_region =
            read_non_empty_env("MEDIA_REGION").unwrap_or_else(|| "us-east-1".to_string());
        validate_media_storage_config(
            running_in_production(),
            media_private_bucket,
            &oss_endpoint,
            &oss_bucket,
            oss_access_key_id.as_deref(),
            oss_access_key_secret.as_deref(),
        )
        .unwrap_or_else(|message| panic!("{message}"));

        Arc::new(Self {
            gemini_api_key: gemini_api_key.unwrap_or_default(),
            llm_api_key,
            jwt_secret,
            jwt_secret_old,
            database_url: std::env::var("DATABASE_URL")
                .expect("DATABASE_URL must be set in environment"),
            llm_provider,
            llm_model,
            llm_base_url,
            agent_enabled: read_non_empty_env("AGENT_ENABLED")
                .map(|v| v.to_lowercase() != "false" && v != "0")
                .unwrap_or(true),
            llm_api_style,
            vector_dim,
            cors_origins,
            blocked_keywords,
            oss_endpoint,
            oss_bucket,
            oss_role_arn,
            oss_access_key_id,
            oss_access_key_secret,
            redis_url,
            deployment_profile,
            rate_limit_max_requests,
            rate_limit_window_secs,
            server_host,
            server_port,
            shutdown_drain_secs,
            shutdown_timeout_secs,
            hitl_expire_scan_interval_secs,
            hitl_expire_timeout_hours,
            moka_cache_max_capacity,
            access_token_ttl_secs,
            refresh_token_ttl_secs,
            conversation_history_limit,
            max_keyword_len,
            price_tolerance,
            categories,
            moderation_image_enabled,
            moderation_image_api_url,
            moderation_image_api_key,
            media_private_bucket,
            media_url_ttl_secs,
            media_path_style,
            media_region,
        })
    }
}

impl AppConfig {
    /// Deterministic config for tests and test-only service constructors.
    /// No secrets are real; nothing here reads the environment.
    #[allow(dead_code)] // used from the lib crate by integration tests
    pub fn test_defaults() -> Self {
        Self {
            gemini_api_key: "test-gemini-key".to_string(),
            llm_api_key: None,
            jwt_secret: "test_jwt_secret_at_least_32_characters_long".to_string(),
            jwt_secret_old: None,
            database_url: "postgres://test/test".to_string(),
            oss_access_key_id: None,
            oss_access_key_secret: None,
            llm_provider: "gemini".to_string(),
            llm_model: "gemini-3-flash-preview".to_string(),
            llm_base_url: None,
            agent_enabled: true,
            llm_api_style: ApiStyle::ChatCompletions,
            vector_dim: 768,
            cors_origins: vec![],
            oss_endpoint: "https://oss-cn-beijing.aliyuncs.com".to_string(),
            oss_bucket: "test-bucket".to_string(),
            oss_role_arn: None,
            redis_url: None,
            deployment_profile: DeploymentProfile::Local,
            rate_limit_max_requests: 100,
            rate_limit_window_secs: 60,
            server_host: "127.0.0.1".to_string(),
            server_port: 3000,
            shutdown_drain_secs: 5,
            shutdown_timeout_secs: 25,
            hitl_expire_scan_interval_secs: 600,
            hitl_expire_timeout_hours: 48,
            moka_cache_max_capacity: 100_000,
            access_token_ttl_secs: 86_400,
            refresh_token_ttl_secs: 604_800,
            conversation_history_limit: 10,
            max_keyword_len: 200,
            price_tolerance: 0.5,
            categories: DEFAULT_CATEGORIES
                .iter()
                .map(|s| (*s).to_string())
                .collect(),
            blocked_keywords: vec![],
            moderation_image_enabled: false,
            moderation_image_api_url: None,
            moderation_image_api_key: None,
            media_private_bucket: false,
            media_url_ttl_secs: 600,
            media_path_style: true,
            media_region: "us-east-1".to_string(),
        }
    }
}

fn is_production_label(value: &str) -> bool {
    matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "production" | "prod"
    )
}

/// Whether this process is configured as a production deployment. Public so
/// startup guards (secret hygiene, demo-seed rejection) can key on it.
pub fn running_in_production() -> bool {
    ["APP_ENV", "ENVIRONMENT", "RUST_ENV"]
        .into_iter()
        .filter_map(|key| std::env::var(key).ok())
        .any(|value| is_production_label(&value))
}

/// Refuse to boot production with development-grade secrets (staging/production
/// secret isolation, Phase 1). This catches the classic incident where a dev
/// `.env` or an example template is copied to a production host: the token
/// signing key would be public knowledge and every session forgeable.
fn validate_production_secret_hygiene(jwt_secret: &str) -> Result<(), String> {
    let lowered = jwt_secret.to_ascii_lowercase();
    const DEV_MARKERS: &[&str] = &["test", "example", "changeme", "placeholder", "dev-secret"];
    if let Some(marker) = DEV_MARKERS.iter().find(|m| lowered.contains(**m)) {
        return Err(format!(
            "JWT_SECRET contains development marker '{marker}'; production must use a \
             dedicated randomly generated secret (see docs/.env.production.example)"
        ));
    }
    // A secret of one repeated character passes the length check but has no
    // entropy worth speaking of.
    let distinct = jwt_secret
        .chars()
        .collect::<std::collections::HashSet<_>>()
        .len();
    if distinct < 8 {
        return Err(
            "JWT_SECRET has too little character variety for production; generate one with \
             `openssl rand -base64 48`"
                .to_string(),
        );
    }
    Ok(())
}

fn validate_cors_origins(cors_origins: &[String]) -> Result<(), String> {
    let allows_any_origin =
        cors_origins.is_empty() || cors_origins.iter().any(|origin| origin == "*");
    if running_in_production() && allows_any_origin {
        return Err(
            "Refusing to start with permissive CORS in production. Set CORS_ORIGINS to explicit origins.".to_string(),
        );
    }
    Ok(())
}

fn validate_campus_verification_delivery(
    production: bool,
    delivery_url: Option<&str>,
    delivery_token: Option<&str>,
) -> Result<(), String> {
    if production && (delivery_url.is_none() || delivery_token.is_none()) {
        return Err(
            "CAMPUS_VERIFICATION_DELIVERY_URL and CAMPUS_VERIFICATION_DELIVERY_TOKEN are required in production"
                .to_string(),
        );
    }
    Ok(())
}

fn validate_image_moderation_config(
    production: bool,
    enabled: bool,
    api_url: Option<&str>,
    api_key: Option<&str>,
) -> Result<(), String> {
    if !production || !enabled {
        return Ok(());
    }
    let Some(api_url) = api_url.filter(|value| !value.trim().is_empty()) else {
        return Err(
            "MODERATION_IMAGE_API_URL is required when image moderation is enabled in production"
                .to_string(),
        );
    };
    let Some(api_key) = api_key.filter(|value| !value.trim().is_empty()) else {
        return Err(
            "MODERATION_IMAGE_API_KEY is required when image moderation is enabled in production"
                .to_string(),
        );
    };
    let parsed = reqwest::Url::parse(api_url)
        .map_err(|_| "MODERATION_IMAGE_API_URL must be a valid http(s) URL".to_string())?;
    if !matches!(parsed.scheme(), "http" | "https") || parsed.host_str().is_none() {
        return Err("MODERATION_IMAGE_API_URL must be a valid http(s) URL".to_string());
    }
    if api_key.len() < 8 {
        return Err(
            "MODERATION_IMAGE_API_KEY is too short for production; use the provider secret"
                .to_string(),
        );
    }
    Ok(())
}

fn validate_media_storage_config(
    production: bool,
    private_bucket: bool,
    endpoint: &str,
    bucket: &str,
    access_key_id: Option<&str>,
    access_key_secret: Option<&str>,
) -> Result<(), String> {
    if production && !private_bucket {
        return Err(
            "MEDIA_PRIVATE_BUCKET=true is required in production; public media serving is disabled"
                .to_string(),
        );
    }
    if !private_bucket {
        return Ok(());
    }
    let parsed = reqwest::Url::parse(endpoint)
        .map_err(|_| "OSS_ENDPOINT must be a valid http(s) URL".to_string())?;
    if !matches!(parsed.scheme(), "http" | "https") || parsed.host_str().is_none() {
        return Err("OSS_ENDPOINT must be a valid http(s) URL".to_string());
    }
    if bucket.trim().is_empty() {
        return Err("OSS_BUCKET must be non-empty when private media is enabled".to_string());
    }
    if access_key_id
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .is_none()
        || access_key_secret
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .is_none()
    {
        return Err(
            "MEDIA_PRIVATE_BUCKET=true requires OSS_ACCESS_KEY_ID and OSS_ACCESS_KEY_SECRET"
                .to_string(),
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_debug_redacts_secrets() {
        let config = AppConfig {
            gemini_api_key: "gemini-secret".to_string(),
            llm_api_key: Some("generic-llm-secret".to_string()),
            jwt_secret: "jwt-secret-that-is-at-least-32-characters".to_string(),
            jwt_secret_old: None,
            database_url: "postgres://user:pass@localhost/db".to_string(),
            oss_access_key_id: Some("oss-key-id".to_string()),
            oss_access_key_secret: Some("oss-key-secret".to_string()),
            llm_provider: "gemini".to_string(),
            llm_model: "gemini-3-flash-preview".to_string(),
            llm_base_url: None,
            agent_enabled: true,
            llm_api_style: ApiStyle::ChatCompletions,
            vector_dim: 768,
            cors_origins: vec![],
            oss_endpoint: "https://oss-cn-beijing.aliyuncs.com".to_string(),
            oss_bucket: "goods4ncu".to_string(),
            oss_role_arn: None,
            redis_url: None,
            deployment_profile: DeploymentProfile::Local,
            rate_limit_max_requests: 100,
            rate_limit_window_secs: 60,
            server_host: "0.0.0.0".to_string(),
            server_port: 3000,
            shutdown_drain_secs: 5,
            shutdown_timeout_secs: 25,
            hitl_expire_scan_interval_secs: 600,
            hitl_expire_timeout_hours: 48,
            moka_cache_max_capacity: 100_000,
            access_token_ttl_secs: 86_400,
            refresh_token_ttl_secs: 604_800,
            conversation_history_limit: 10,
            max_keyword_len: 200,
            price_tolerance: 0.5,
            categories: DEFAULT_CATEGORIES
                .iter()
                .map(|s| (*s).to_string())
                .collect(),
            blocked_keywords: vec![],
            moderation_image_enabled: true,
            moderation_image_api_url: None,
            moderation_image_api_key: Some("test-api-key".to_string()),
            media_private_bucket: false,
            media_url_ttl_secs: 600,
            media_path_style: true,
            media_region: "us-east-1".to_string(),
        };
        let debug_str = format!("{:?}", config);
        assert!(debug_str.contains("[REDACTED]"));
        assert!(!debug_str.contains("gemini-secret"));
        assert!(!debug_str.contains("minimax-secret"));
        assert!(!debug_str.contains("generic-llm-secret"));
        assert!(!debug_str.contains("jwt-secret-that-is-at-least-32-characters"));
    }

    #[test]
    fn production_secret_hygiene_rejects_dev_markers_and_low_entropy() {
        for bad in [
            "test_jwt_secret_at_least_32_characters_long",
            "example-secret-value-with-enough-length!!",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ] {
            assert!(
                validate_production_secret_hygiene(bad).is_err(),
                "{bad:?} must be rejected in production"
            );
        }
        assert!(
            validate_production_secret_hygiene("u8Zr#kQ2pV9wLx4TmN7cGdY5bHsJfE3aRi6oW1").is_ok()
        );
    }

    #[test]
    fn test_valid_llm_providers() {
        for provider in [
            "gemini",
            "minimax",
            "openai_compatible",
            "openai",
            "deepseek",
            "groq",
            "openrouter",
            "xai",
            "together",
        ] {
            assert!(is_supported_llm_provider(provider));
        }
    }

    #[test]
    fn test_openai_compatible_provider_detection() {
        assert!(is_openai_compatible_provider("deepseek"));
        assert!(is_openai_compatible_provider("openai_compatible"));
        assert!(!is_openai_compatible_provider("gemini"));
    }

    #[test]
    fn test_llm_provider_normalization_accepts_hyphen() {
        assert_eq!(
            normalize_llm_provider("OpenAI-Compatible"),
            "openai_compatible"
        );
    }

    #[test]
    fn test_jwt_secret_minimum_length() {
        let valid_secret = "a".repeat(32);
        assert!(valid_secret.len() >= 32);
        let invalid_secret = "a".repeat(31);
        assert!(invalid_secret.len() < 32);
    }

    #[test]
    fn test_cors_origins_parsing() {
        let origins = "https://example.com,https://app.example.com, http://localhost:3000";
        let parsed: Vec<String> = origins.split(',').map(|v| v.trim().to_string()).collect();
        assert_eq!(parsed.len(), 3);
    }

    #[test]
    fn test_categories_default() {
        let categories: Vec<String> = DEFAULT_CATEGORIES
            .iter()
            .map(|s| (*s).to_string())
            .collect();
        assert_eq!(categories.len(), 6);
        assert!(categories.contains(&"electronics".to_string()));
    }

    #[test]
    fn test_file_config_load_missing_file() {
        // load() returns None when no file exists
        let result = file::load(Some(Path::new("/nonexistent/path.toml")));
        assert!(result.is_none());
    }

    #[test]
    fn test_validate_cors_origins_allows_empty_in_non_production() {
        assert!(validate_cors_origins(&[]).is_ok());
    }

    #[test]
    fn test_is_production_label_matches_expected_values() {
        assert!(is_production_label("production"));
        assert!(is_production_label(" PROD "));
        assert!(!is_production_label("development"));
    }

    #[test]
    fn production_requires_campus_verification_delivery_credentials() {
        assert!(validate_campus_verification_delivery(true, None, None).is_err());
        assert!(validate_campus_verification_delivery(
            true,
            Some("https://mailer.example.test/send"),
            None
        )
        .is_err());
        assert!(validate_campus_verification_delivery(
            true,
            Some("https://mailer.example.test/send"),
            Some("secret")
        )
        .is_ok());
        assert!(validate_campus_verification_delivery(false, None, None).is_ok());
    }

    #[test]
    fn production_requires_image_moderation_provider_when_enabled() {
        assert!(validate_image_moderation_config(true, true, None, None).is_err());
        assert!(validate_image_moderation_config(
            true,
            true,
            Some("https://moderation.example.test/check"),
            None
        )
        .is_err());
        assert!(validate_image_moderation_config(
            true,
            true,
            Some("https://moderation.example.test/check"),
            Some("provider-secret")
        )
        .is_ok());
        assert!(
            validate_image_moderation_config(true, true, Some("not a url"), Some("secret"))
                .is_err()
        );
        assert!(validate_image_moderation_config(true, false, None, None).is_ok());
        assert!(validate_image_moderation_config(false, true, None, None).is_ok());
    }

    #[test]
    fn production_requires_private_media_storage() {
        assert!(validate_media_storage_config(
            true,
            false,
            "https://oss.example.test",
            "goods4ncu",
            None,
            None,
        )
        .is_err());
        assert!(validate_media_storage_config(
            true,
            true,
            "https://oss.example.test",
            "goods4ncu",
            Some("access"),
            Some("secret"),
        )
        .is_ok());
        assert!(validate_media_storage_config(
            true,
            true,
            "not-a-url",
            "goods4ncu",
            Some("access"),
            Some("secret"),
        )
        .is_err());
        assert!(validate_media_storage_config(false, false, "not-a-url", "", None, None,).is_ok());
        assert!(validate_media_storage_config(
            false,
            true,
            "https://oss.example.test",
            "goods4ncu",
            None,
            None,
        )
        .is_err());
    }
}
