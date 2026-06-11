//! Content moderation service — text and image.
//!
//! Provides text keyword filtering, contact-info detection, and async image
//! moderation job submission for user-generated content.

use crate::config::AppConfig;
use regex::Regex;
use serde::{Deserialize, Serialize};
use sqlx::PgPool;

/// Moderation result code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)]
pub enum ModerationCode {
    Ok,
    /// Blocked keyword detected.
    Profanity,
    /// Phone / WeChat / QQ / email detected.
    ContactInfo,
    /// External URL detected.
    ExternalLink,
    /// Image rejected by external API.
    InappropriateImage,
}

impl ModerationCode {
    #[allow(dead_code)]
    pub fn label(&self) -> &'static str {
        match self {
            ModerationCode::Ok => "ok",
            ModerationCode::Profanity => "profanity",
            ModerationCode::ContactInfo => "contact_info",
            ModerationCode::ExternalLink => "external_link",
            ModerationCode::InappropriateImage => "inappropriate_image",
        }
    }

    /// Human-readable Chinese message for each code.
    pub fn message(&self) -> &'static str {
        match self {
            ModerationCode::Ok => "",
            ModerationCode::Profanity => "内容包含违规信息",
            ModerationCode::ContactInfo => "内容包含联系方式",
            ModerationCode::ExternalLink => "内容包含外部链接",
            ModerationCode::InappropriateImage => "图片内容不合规",
        }
    }
}

/// Moderation check result.
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct ModerationResult {
    pub passed: bool,
    pub code: ModerationCode,
    pub reason: Option<String>,
}

impl ModerationResult {
    pub fn passed() -> Self {
        Self {
            passed: true,
            code: ModerationCode::Ok,
            reason: None,
        }
    }

    pub fn rejected(code: ModerationCode) -> Self {
        Self {
            passed: false,
            code,
            reason: Some(code.message().to_string()),
        }
    }

    #[allow(dead_code)]
    pub fn rejected_with_reason(code: ModerationCode, reason: String) -> Self {
        Self {
            passed: false,
            code,
            reason: Some(reason),
        }
    }
}

/// Image moderation job status.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[allow(dead_code)]
#[serde(rename_all = "lowercase")]
pub enum ImageModerationStatus {
    Pending,
    Approved,
    Rejected,
    Failed,
}

/// Image moderation job record.
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct ImageModerationJob {
    pub id: String,
    pub resource_type: String,
    pub resource_id: String,
    pub image_url: String,
    pub status: ImageModerationStatus,
    pub reject_reason: Option<String>,
}

/// Content moderation service.
#[derive(Clone)]
pub struct ModerationService {
    /// Blocked keywords loaded from config.
    blocked_keywords: Vec<String>,
    /// Pre-built contact-info regexes.
    phone_re: Regex,
    /// WeChat: 微信/微信号 followed by content.
    wechat_re: Regex,
    /// QQ number pattern.
    qq_re: Regex,
    /// Email pattern.
    email_re: Regex,
    /// External URL pattern (http/https).
    url_re: Regex,
    /// Whether image moderation is enabled.
    image_enabled: bool,
    /// Alibaba IMAN API endpoint.
    #[allow(dead_code)]
    image_api_url: Option<String>,
    /// Alibaba IMAN API key.
    #[allow(dead_code)]
    image_api_key: Option<String>,
}

impl ModerationService {
    /// Build a new ModerationService from app config.
    pub fn new(config: &AppConfig) -> Self {
        let phone_re = Regex::new(r"1[3-9]\d{9}").expect("valid phone regex");
        // WeChat: explicit "微信" or "微信号" followed by at least one separator then ID (5-20 alphanum).
        // Separator is mandatory to avoid false positives on words like "微号" in product descriptions.
        let wechat_re = Regex::new(r"(?:微 ?信|微 ?信 ?号)\s*[:：\s　]+[A-Za-z0-9_\-]{5,20}")
            .expect("valid wechat regex");
        // QQ: "QQ" or "QQ号" followed by optional separator then 5-12 digits
        let qq_re = Regex::new(r"QQ\s*号?\s*[:：\s　]*\d{5,12}").expect("valid qq regex");
        let email_re = Regex::new(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")
            .expect("valid email regex");
        let url_re = Regex::new(r"https?://[^\s　]+").expect("valid url regex");

        Self {
            blocked_keywords: config.blocked_keywords.clone(),
            phone_re,
            wechat_re,
            qq_re,
            email_re,
            url_re,
            image_enabled: config.moderation_image_enabled,
            image_api_url: config.moderation_image_api_url.clone(),
            image_api_key: config.moderation_image_api_key.clone(),
        }
    }

    /// Synchronously check text content.
    /// Returns `Ok(ModerationResult)` — errors are logged, never returned.
    pub fn check_text(&self, text: &str) -> ModerationResult {
        if text.is_empty() {
            return ModerationResult::passed();
        }

        // 1. Blocked keywords (case-insensitive)
        let lower = text.to_lowercase();
        for kw in &self.blocked_keywords {
            if lower.contains(&kw.to_lowercase()) {
                tracing::debug!(keyword = %kw, "blocked keyword detected");
                return ModerationResult::rejected(ModerationCode::Profanity);
            }
        }

        // 2. Contact info
        if self.phone_re.is_match(text) {
            tracing::debug!("phone number detected");
            return ModerationResult::rejected(ModerationCode::ContactInfo);
        }
        if self.wechat_re.is_match(text) {
            tracing::debug!("wechat id detected");
            return ModerationResult::rejected(ModerationCode::ContactInfo);
        }
        if self.qq_re.is_match(text) {
            tracing::debug!("qq number detected");
            return ModerationResult::rejected(ModerationCode::ContactInfo);
        }
        if self.email_re.is_match(text) {
            tracing::debug!("email address detected");
            return ModerationResult::rejected(ModerationCode::ContactInfo);
        }

        // 3. External URLs
        if self.url_re.is_match(text) {
            tracing::debug!("external URL detected");
            return ModerationResult::rejected(ModerationCode::ExternalLink);
        }

        ModerationResult::passed()
    }

    /// Submit an image moderation job. Returns the job ID.
    pub async fn submit_image_job(
        &self,
        pool: &PgPool,
        resource_id: &str,
        image_url: &str,
        resource_type: &str,
    ) -> Result<String, sqlx::Error> {
        if !self.image_enabled {
            return Ok(String::new());
        }

        let id = uuid::Uuid::new_v4().to_string();
        sqlx::query(
            r#"INSERT INTO moderation_jobs (id, resource_type, resource_id, image_url, status)
               VALUES ($1, $2, $3, $4, 'pending')"#,
        )
        .bind(&id)
        .bind(resource_type)
        .bind(resource_id)
        .bind(image_url)
        .execute(pool)
        .await?;

        Ok(id)
    }

    /// Check if image moderation is enabled.
    #[allow(dead_code)]
    pub fn is_image_enabled(&self) -> bool {
        self.image_enabled
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_config(keywords: Vec<String>) -> AppConfig {
        // Build a minimal AppConfig for testing.
        // We only need blocked_keywords and image fields.
        AppConfig {
            blocked_keywords: keywords,
            gemini_api_key: String::new(),
            minimax_api_key: None,
            minimax_api_base_url: None,
            llm_api_key: None,
            jwt_secret: "test-jwt-secret-that-is-at-least-32-chars".to_string(),
            jwt_secret_old: None,
            database_url: String::new(),
            llm_provider: "gemini".to_string(),
            llm_model: "gemini-3-flash-preview".to_string(),
            llm_base_url: None,
            vector_dim: 768,
            cors_origins: vec![],
            oss_endpoint: String::new(),
            oss_bucket: String::new(),
            oss_role_arn: None,
            oss_access_key_id: None,
            oss_access_key_secret: None,
            redis_url: None,
            rate_limit_max_requests: 100,
            rate_limit_window_secs: 60,
            server_host: "127.0.0.1".to_string(),
            server_port: 3000,
            event_bus_capacity: 2048,
            hitl_expire_scan_interval_secs: 600,
            hitl_expire_timeout_hours: 48,
            moka_cache_max_capacity: 100_000,
            access_token_ttl_secs: 86400,
            refresh_token_ttl_secs: 604800,
            conversation_history_limit: 10,
            max_keyword_len: 200,
            price_tolerance: 0.5,
            categories: vec![],
            moderation_image_enabled: true,
            moderation_image_api_url: None,
            moderation_image_api_key: None,
        }
    }

    #[test]
    fn test_check_text_empty() {
        let svc = ModerationService::new(&make_config(vec![]));
        assert!(svc.check_text("").passed);
        assert!(svc.check_text("   ").passed);
    }

    #[test]
    fn test_check_text_blocked_keyword() {
        let svc = ModerationService::new(&make_config(vec!["毒品".into(), "gun".into()]));
        let r = svc.check_text("出售毒品，量大从优");
        assert!(!r.passed);
        assert_eq!(r.code, ModerationCode::Profanity);

        let r2 = svc.check_text("This is a gun for sale");
        assert!(!r2.passed);
        assert_eq!(r2.code, ModerationCode::Profanity);

        let r3 = svc.check_text("正常商品描述，没问题");
        assert!(r3.passed);
    }

    #[test]
    fn test_check_text_phone_number() {
        let svc = ModerationService::new(&make_config(vec![]));
        let r = svc.check_text("联系电话：13812345678");
        assert!(!r.passed);
        assert_eq!(r.code, ModerationCode::ContactInfo);

        let r2 = svc.check_text("我的手机是15900001111");
        assert!(!r2.passed);
        assert_eq!(r2.code, ModerationCode::ContactInfo);

        // Invalid phone (starts with 2, too short)
        let r3 = svc.check_text("电话：2123456789");
        assert!(r3.passed);
    }

    #[test]
    fn test_check_text_wechat() {
        let svc = ModerationService::new(&make_config(vec![]));
        let r = svc.check_text("微信:wxid_abc123");
        assert!(!r.passed);
        assert_eq!(r.code, ModerationCode::ContactInfo);

        let r2 = svc.check_text("微信号 abc_def_123");
        assert!(!r2.passed);

        let r3 = svc.check_text("这是微信聊天，不是联系方式");
        assert!(r3.passed);
    }

    #[test]
    fn test_check_text_qq() {
        let svc = ModerationService::new(&make_config(vec![]));
        let r = svc.check_text("QQ: 12345678");
        assert!(!r.passed);
        assert_eq!(r.code, ModerationCode::ContactInfo);

        let r2 = svc.check_text("联系我QQ号 99887766");
        assert!(!r2.passed);

        // Too short (4 digits) - not a QQ
        let r3 = svc.check_text("序号1234");
        assert!(r3.passed);
    }

    #[test]
    fn test_check_text_email() {
        let svc = ModerationService::new(&make_config(vec![]));
        let r = svc.check_text("邮箱: user@example.com");
        assert!(!r.passed);
        assert_eq!(r.code, ModerationCode::ContactInfo);

        let r2 = svc.check_text("联系 test@mail.ncu.edu.cn");
        assert!(!r2.passed);
    }

    #[test]
    fn test_check_text_external_url() {
        let svc = ModerationService::new(&make_config(vec![]));
        let r = svc.check_text("看更多 https://example.com/goods");
        assert!(!r.passed);
        assert_eq!(r.code, ModerationCode::ExternalLink);

        let r2 = svc.check_text("http://钓鱼网站.com");
        assert!(!r2.passed);

        let r3 = svc.check_text("商品描述：九成新，功能完好");
        assert!(r3.passed);
    }

    #[test]
    fn test_check_text_combined() {
        let svc = ModerationService::new(&make_config(vec!["毒品".into()]));
        // First match wins
        let r = svc.check_text("毒品 毒品 电话 13812345678");
        assert!(!r.passed);
        // Order: keyword first
        assert_eq!(r.code, ModerationCode::Profanity);
    }
}
