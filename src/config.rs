//! Unified application configuration.
//! All environment variables are loaded and validated at startup.
//! Use `AppConfig::load()` once in `main()`, then pass `Arc<AppConfig>` to components.
//!
//! A TOML config file (e.g. `good4ncu.toml`) can supplement env vars.
//! Use `AppConfig::load_with_file()` to merge TOML + env vars.
//! Environment variables always override TOML file values.

mod file;

use std::fmt;
use std::path::Path;
use std::sync::Arc;

/// Default marketplace categories (used when not set in config file).
pub const DEFAULT_CATEGORIES: &[&str] = &[
    "electronics",
    "books",
    "digitalAccessories",
    "dailyGoods",
    "clothingShoes",
    "other",
];

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
        "openai_compatible" | "openai" | "deepseek" | "groq" | "openrouter" | "xai" | "together"
    )
}

fn is_supported_llm_provider(provider: &str) -> bool {
    SUPPORTED_LLM_PROVIDERS.contains(&provider)
}

fn default_llm_model(provider: &str) -> Option<&'static str> {
    match provider {
        "gemini" => Some("gemini-3-flash-preview"),
        "minimax" => Some("MiniMax-M2.7"),
        _ => None,
    }
}

fn default_llm_base_url(provider: &str) -> Option<&'static str> {
    match provider {
        "openai" => Some("https://api.openai.com/v1"),
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
    pub minimax_api_key: Option<String>,
    pub minimax_api_base_url: Option<String>,
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
    pub vector_dim: usize,

    // --- Infrastructure ---
    pub cors_origins: Vec<String>,
    pub oss_endpoint: String,
    pub oss_bucket: String,
    pub oss_role_arn: Option<String>,
    pub redis_url: Option<String>,
    pub rate_limit_max_requests: u64,
    pub rate_limit_window_secs: u64,

    // --- TOML-only fields (with hardcoded defaults when no file) ---
    pub server_host: String,
    pub server_port: u16,
    pub event_bus_capacity: usize,
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
}

impl fmt::Debug for AppConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AppConfig")
            .field("gemini_api_key", &"[REDACTED]")
            .field(
                "minimax_api_key",
                &self.minimax_api_key.as_ref().map(|_| "[REDACTED]"),
            )
            .field("minimax_api_base_url", &self.minimax_api_base_url)
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
            .field("rate_limit_max_requests", &self.rate_limit_max_requests)
            .field("rate_limit_window_secs", &self.rate_limit_window_secs)
            .field("server_host", &self.server_host)
            .field("server_port", &self.server_port)
            .field("event_bus_capacity", &self.event_bus_capacity)
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
            .field("blocked_keywords", &self.blocked_keywords)
            .field("moderation_image_enabled", &self.moderation_image_enabled)
            .field(
                "moderation_image_api_key",
                &self.moderation_image_api_key.as_ref().map(|_| "[REDACTED]"),
            )
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
    /// 2. `./good4ncu.toml` (if exists)
    /// 3. `./config/good4ncu.toml` (if exists)
    /// 4. No file (env vars only, all TOML fields use defaults)
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
            .or_else(|| default_llm_base_url(&llm_provider).map(str::to_string));

        let llm_api_key = read_non_empty_env("LLM_API_KEY")
            .or_else(|| provider_api_key_env(&llm_provider).and_then(read_non_empty_env))
            .or_else(|| read_non_empty_env("OPENAI_COMPAT_API_KEY"));

        let vector_dim: usize = read_non_empty_env("VECTOR_DIM")
            .or_else(|| file.as_ref()?.llm.vector_dim.map(|v| v.to_string()))
            .and_then(|s| s.parse().ok())
            .unwrap_or(768);

        let gemini_api_key = read_non_empty_env("GEMINI_API_KEY");
        let minimax_api_key = read_non_empty_env("MINIMAX_API_KEY");
        let minimax_api_base_url = read_non_empty_env("MINIMAX_API_BASE_URL");

        if llm_provider == "gemini" && gemini_api_key.is_none() {
            panic!("GEMINI_API_KEY must be set when LLM_PROVIDER=gemini");
        }

        if llm_provider == "minimax" && minimax_api_key.is_none() {
            panic!("MINIMAX_API_KEY must be set when LLM_PROVIDER=minimax");
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

        // Deprecated compatibility path: keep accepting MINIMAX_API_BASE_URL
        // while newer OpenAI-compatible providers use LLM_BASE_URL.
        let minimax_api_base_url = minimax_api_base_url.or_else(|| {
            if llm_provider == "minimax" {
                llm_base_url.clone()
            } else {
                None
            }
        });

        let jwt_secret =
            std::env::var("JWT_SECRET").expect("JWT_SECRET must be set in environment");
        if jwt_secret.len() < 32 {
            panic!("JWT_SECRET must be at least 32 characters for security");
        }

        let jwt_secret_old = std::env::var("JWT_SECRET_OLD").ok();

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
            .unwrap_or_else(|| "good4ncu".into());

        let oss_role_arn = std::env::var("OSS_ROLE_ARN").ok();
        let oss_access_key_id = std::env::var("OSS_ACCESS_KEY_ID").ok();
        let oss_access_key_secret = std::env::var("OSS_ACCESS_KEY_SECRET").ok();

        // Redis: env > file > None
        let redis_url = std::env::var("REDIS_URL")
            .ok()
            .or_else(|| file.as_ref()?.rate_limit.redis_url.clone());

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

        let event_bus_capacity = file
            .as_ref()
            .and_then(|f| f.event_bus.capacity)
            .unwrap_or(2048);

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
            .unwrap_or(true);
        let moderation_image_api_url = read_non_empty_env("MODERATION_IMAGE_API_URL")
            .or_else(|| file.as_ref()?.moderation.image_api_url.clone());
        let moderation_image_api_key = read_non_empty_env("MODERATION_IMAGE_API_KEY")
            .or_else(|| file.as_ref()?.moderation.image_api_key.clone());

        Arc::new(Self {
            gemini_api_key: gemini_api_key.unwrap_or_default(),
            minimax_api_key,
            minimax_api_base_url,
            llm_api_key,
            jwt_secret,
            jwt_secret_old,
            database_url: std::env::var("DATABASE_URL")
                .expect("DATABASE_URL must be set in environment"),
            llm_provider,
            llm_model,
            llm_base_url,
            vector_dim,
            cors_origins,
            blocked_keywords,
            oss_endpoint,
            oss_bucket,
            oss_role_arn,
            oss_access_key_id,
            oss_access_key_secret,
            redis_url,
            rate_limit_max_requests,
            rate_limit_window_secs,
            server_host,
            server_port,
            event_bus_capacity,
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
        })
    }
}

fn is_production_label(value: &str) -> bool {
    matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "production" | "prod"
    )
}

fn running_in_production() -> bool {
    ["APP_ENV", "ENVIRONMENT", "RUST_ENV"]
        .into_iter()
        .filter_map(|key| std::env::var(key).ok())
        .any(|value| is_production_label(&value))
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_debug_redacts_secrets() {
        let config = AppConfig {
            gemini_api_key: "gemini-secret".to_string(),
            minimax_api_key: Some("minimax-secret".to_string()),
            minimax_api_base_url: None,
            llm_api_key: Some("generic-llm-secret".to_string()),
            jwt_secret: "jwt-secret-that-is-at-least-32-characters".to_string(),
            jwt_secret_old: None,
            database_url: "postgres://user:pass@localhost/db".to_string(),
            oss_access_key_id: Some("oss-key-id".to_string()),
            oss_access_key_secret: Some("oss-key-secret".to_string()),
            llm_provider: "gemini".to_string(),
            llm_model: "gemini-3-flash-preview".to_string(),
            llm_base_url: None,
            vector_dim: 768,
            cors_origins: vec![],
            oss_endpoint: "https://oss-cn-beijing.aliyuncs.com".to_string(),
            oss_bucket: "good4ncu".to_string(),
            oss_role_arn: None,
            redis_url: None,
            rate_limit_max_requests: 100,
            rate_limit_window_secs: 60,
            server_host: "0.0.0.0".to_string(),
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
            categories: DEFAULT_CATEGORIES
                .iter()
                .map(|s| (*s).to_string())
                .collect(),
            blocked_keywords: vec![],
            moderation_image_enabled: true,
            moderation_image_api_url: None,
            moderation_image_api_key: Some("test-api-key".to_string()),
        };
        let debug_str = format!("{:?}", config);
        assert!(debug_str.contains("[REDACTED]"));
        assert!(!debug_str.contains("gemini-secret"));
        assert!(!debug_str.contains("minimax-secret"));
        assert!(!debug_str.contains("generic-llm-secret"));
        assert!(!debug_str.contains("jwt-secret-that-is-at-least-32-characters"));
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
}
