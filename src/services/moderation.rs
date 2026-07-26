//! Content moderation service — text and image.
//!
//! Provides text safety checks, contact-info detection, and async image
//! moderation job submission for user-generated content.
//!
//! The built-in text rules focus on marketplace and campus-community safety:
//! illegal goods, adult content, gambling, fraud, violence/extremism, hate or
//! harassment, privacy leakage, off-platform contact, and external links. Local
//! policy-sensitive words should stay configurable through `BLOCKED_KEYWORDS`
//! instead of being hard-coded in source.

use crate::config::AppConfig;
use regex::Regex;
use serde::{Deserialize, Serialize};
use sqlx::PgPool;

/// Moderation result code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)]
pub enum ModerationCode {
    Ok,
    /// Operator-configured blocked keyword detected.
    BlockedKeyword,
    /// Illegal or controlled goods/services.
    IllegalGoods,
    /// Pornographic, vulgar, or explicit adult content.
    AdultContent,
    /// Gambling, casino, lottery, or betting content.
    Gambling,
    /// Fraud, phishing, credential abuse, or grey-market account trading.
    Fraud,
    /// Violence, weapons, terrorism, or self-harm instructions.
    ViolenceExtremism,
    /// Hate, harassment, abuse, or humiliating attacks.
    HateHarassment,
    /// Personal information leakage or doxxing.
    PersonalInfo,
    /// Legacy alias kept for older tests and callers.
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
            ModerationCode::BlockedKeyword => "blocked_keyword",
            ModerationCode::IllegalGoods => "illegal_goods",
            ModerationCode::AdultContent => "adult_content",
            ModerationCode::Gambling => "gambling",
            ModerationCode::Fraud => "fraud",
            ModerationCode::ViolenceExtremism => "violence_extremism",
            ModerationCode::HateHarassment => "hate_harassment",
            ModerationCode::PersonalInfo => "personal_info",
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
            ModerationCode::BlockedKeyword | ModerationCode::Profanity => "内容包含违规信息",
            ModerationCode::IllegalGoods => "内容涉及违禁或管制物品",
            ModerationCode::AdultContent => "内容包含低俗或成人信息",
            ModerationCode::Gambling => "内容涉及赌博或博彩信息",
            ModerationCode::Fraud => "内容疑似诈骗、钓鱼或灰产交易",
            ModerationCode::ViolenceExtremism => "内容涉及暴力、武器或极端风险",
            ModerationCode::HateHarassment => "内容包含攻击、辱骂或歧视信息",
            ModerationCode::PersonalInfo => "内容包含他人隐私或敏感个人信息",
            ModerationCode::ContactInfo => "内容包含联系方式",
            ModerationCode::ExternalLink => "内容包含外部链接",
            ModerationCode::InappropriateImage => "图片内容不合规",
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct BuiltinTextRule {
    code: ModerationCode,
    phrase: &'static str,
}

const BUILTIN_TEXT_RULES: &[BuiltinTextRule] = &[
    // Illegal or controlled goods and services.
    BuiltinTextRule {
        code: ModerationCode::IllegalGoods,
        phrase: "毒品",
    },
    BuiltinTextRule {
        code: ModerationCode::IllegalGoods,
        phrase: "冰毒",
    },
    BuiltinTextRule {
        code: ModerationCode::IllegalGoods,
        phrase: "麻古",
    },
    BuiltinTextRule {
        code: ModerationCode::IllegalGoods,
        phrase: "摇头丸",
    },
    BuiltinTextRule {
        code: ModerationCode::IllegalGoods,
        phrase: "大麻",
    },
    BuiltinTextRule {
        code: ModerationCode::IllegalGoods,
        phrase: "k粉",
    },
    BuiltinTextRule {
        code: ModerationCode::IllegalGoods,
        phrase: "枪支",
    },
    BuiltinTextRule {
        code: ModerationCode::IllegalGoods,
        phrase: "仿真枪",
    },
    BuiltinTextRule {
        code: ModerationCode::IllegalGoods,
        phrase: "管制刀具",
    },
    BuiltinTextRule {
        code: ModerationCode::IllegalGoods,
        phrase: "代开发票",
    },
    BuiltinTextRule {
        code: ModerationCode::IllegalGoods,
        phrase: "假证",
    },
    BuiltinTextRule {
        code: ModerationCode::IllegalGoods,
        phrase: "代办证",
    },
    BuiltinTextRule {
        code: ModerationCode::IllegalGoods,
        phrase: "考试答案",
    },
    BuiltinTextRule {
        code: ModerationCode::IllegalGoods,
        phrase: "代考",
    },
    BuiltinTextRule {
        code: ModerationCode::IllegalGoods,
        phrase: "代写论文",
    },
    // Adult or vulgar content.
    BuiltinTextRule {
        code: ModerationCode::AdultContent,
        phrase: "色情",
    },
    BuiltinTextRule {
        code: ModerationCode::AdultContent,
        phrase: "裸聊",
    },
    BuiltinTextRule {
        code: ModerationCode::AdultContent,
        phrase: "约炮",
    },
    BuiltinTextRule {
        code: ModerationCode::AdultContent,
        phrase: "成人视频",
    },
    BuiltinTextRule {
        code: ModerationCode::AdultContent,
        phrase: "援交",
    },
    // Gambling and betting.
    BuiltinTextRule {
        code: ModerationCode::Gambling,
        phrase: "赌博",
    },
    BuiltinTextRule {
        code: ModerationCode::Gambling,
        phrase: "博彩",
    },
    BuiltinTextRule {
        code: ModerationCode::Gambling,
        phrase: "赌球",
    },
    BuiltinTextRule {
        code: ModerationCode::Gambling,
        phrase: "彩票站",
    },
    BuiltinTextRule {
        code: ModerationCode::Gambling,
        phrase: "老虎机",
    },
    // Fraud, account abuse, and grey-market services.
    BuiltinTextRule {
        code: ModerationCode::Fraud,
        phrase: "刷单",
    },
    BuiltinTextRule {
        code: ModerationCode::Fraud,
        phrase: "跑分",
    },
    BuiltinTextRule {
        code: ModerationCode::Fraud,
        phrase: "洗钱",
    },
    BuiltinTextRule {
        code: ModerationCode::Fraud,
        phrase: "套现",
    },
    BuiltinTextRule {
        code: ModerationCode::Fraud,
        phrase: "钓鱼链接",
    },
    BuiltinTextRule {
        code: ModerationCode::Fraud,
        phrase: "出售账号",
    },
    BuiltinTextRule {
        code: ModerationCode::Fraud,
        phrase: "买卖账号",
    },
    BuiltinTextRule {
        code: ModerationCode::Fraud,
        phrase: "校园贷",
    },
    // Violence, weapons, extremism, or self-harm instructions.
    BuiltinTextRule {
        code: ModerationCode::ViolenceExtremism,
        phrase: "炸药",
    },
    BuiltinTextRule {
        code: ModerationCode::ViolenceExtremism,
        phrase: "爆炸物",
    },
    BuiltinTextRule {
        code: ModerationCode::ViolenceExtremism,
        phrase: "杀人教程",
    },
    BuiltinTextRule {
        code: ModerationCode::ViolenceExtremism,
        phrase: "自杀教程",
    },
    BuiltinTextRule {
        code: ModerationCode::ViolenceExtremism,
        phrase: "恐怖主义",
    },
    // Hate, harassment, and humiliating attacks.
    BuiltinTextRule {
        code: ModerationCode::HateHarassment,
        phrase: "人肉搜索",
    },
    BuiltinTextRule {
        code: ModerationCode::HateHarassment,
        phrase: "开盒挂人",
    },
    BuiltinTextRule {
        code: ModerationCode::HateHarassment,
        phrase: "网暴",
    },
    // Privacy leakage.
    BuiltinTextRule {
        code: ModerationCode::PersonalInfo,
        phrase: "身份证号",
    },
    BuiltinTextRule {
        code: ModerationCode::PersonalInfo,
        phrase: "银行卡号",
    },
    BuiltinTextRule {
        code: ModerationCode::PersonalInfo,
        phrase: "家庭住址",
    },
];

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
    /// Normalized blocked keywords for obfuscation-resistant matching.
    normalized_blocked_keywords: Vec<String>,
    /// Pre-built contact-info regexes.
    phone_re: Regex,
    /// Mainland China resident ID number pattern.
    id_card_re: Regex,
    /// Bank card-like long digit sequence.
    bank_card_re: Regex,
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
    /// Test-only constructor with image moderation toggled explicitly and no
    /// provider configuration. Lives in the lib (not #[cfg(test)]) so
    /// integration tests can exercise the quarantine path.
    #[allow(dead_code)] // used from the lib crate by integration tests
    pub fn new_for_test(image_enabled: bool) -> Self {
        let mut service = Self::new(&crate::config::AppConfig::test_defaults());
        service.image_enabled = image_enabled;
        service
    }

    /// Build a new ModerationService from app config.
    pub fn new(config: &AppConfig) -> Self {
        let phone_re = Regex::new(r"1[3-9]\d{9}").expect("valid phone regex");
        let id_card_re = Regex::new(
            r"\d{6}(?:18|19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dXx]",
        )
        .expect("valid id card regex");
        let bank_card_re = Regex::new(r"(?:\d[ -]?){16,19}").expect("valid bank card regex");
        // WeChat: explicit "微信" or "微信号" followed by at least one separator then ID (5-20 alphanum).
        // Separator is mandatory to avoid false positives on words like "微号" in product descriptions.
        let wechat_re = Regex::new(r"(?:微 ?信|微 ?信 ?号)\s*[:：\s　]+[A-Za-z0-9_\-]{5,20}")
            .expect("valid wechat regex");
        // QQ: "QQ" or "QQ号" followed by optional separator then 5-12 digits
        let qq_re = Regex::new(r"QQ\s*号?\s*[:：\s　]*\d{5,12}").expect("valid qq regex");
        let email_re = Regex::new(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")
            .expect("valid email regex");
        let url_re = Regex::new(r"https?://[^\s　]+").expect("valid url regex");
        let normalized_blocked_keywords = config
            .blocked_keywords
            .iter()
            .map(|keyword| normalize_for_moderation(keyword))
            .filter(|keyword| !keyword.is_empty())
            .collect();

        Self {
            blocked_keywords: config.blocked_keywords.clone(),
            normalized_blocked_keywords,
            phone_re,
            id_card_re,
            bank_card_re,
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
        if text.trim().is_empty() {
            return ModerationResult::passed();
        }

        let normalized = normalize_for_moderation(text);

        // 1. Operator-configured blocked keywords. Match both raw lowercase
        // text and normalized text so "毒 品" and full-width variants are
        // treated the same as "毒品".
        let lower = text.to_lowercase();
        for (index, kw) in self.blocked_keywords.iter().enumerate() {
            let normalized_kw = self
                .normalized_blocked_keywords
                .get(index)
                .map(String::as_str)
                .unwrap_or_default();
            if lower.contains(&kw.to_lowercase())
                || (!normalized_kw.is_empty() && normalized.contains(normalized_kw))
            {
                tracing::debug!(keyword = %kw, "blocked keyword detected");
                return ModerationResult::rejected(ModerationCode::BlockedKeyword);
            }
        }

        // 2. Built-in mainland marketplace safety rules. These are deliberately
        // broad, high-risk categories; more local policy terms belong in config.
        for rule in BUILTIN_TEXT_RULES {
            let normalized_phrase = normalize_for_moderation(rule.phrase);
            if normalized.contains(&normalized_phrase) {
                tracing::debug!(
                    code = rule.code.label(),
                    phrase = rule.phrase,
                    "builtin moderation rule detected"
                );
                return ModerationResult::rejected(rule.code);
            }
        }

        // 3. Personal information and contact info.
        if self.id_card_re.is_match(text) {
            tracing::debug!("mainland id card number detected");
            return ModerationResult::rejected(ModerationCode::PersonalInfo);
        }
        if self.bank_card_re.is_match(text) {
            tracing::debug!("bank card number detected");
            return ModerationResult::rejected(ModerationCode::PersonalInfo);
        }
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

        // 4. External URLs.
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
        campus_id: uuid::Uuid,
        resource_id: &str,
        image_url: &str,
        resource_type: &str,
    ) -> Result<String, sqlx::Error> {
        if !self.image_enabled {
            // Moderation is off: mark the media explicitly reviewed-exempt so
            // the serving gate (`= 'approved'`) still works. Leaving it
            // 'pending' forever would hide every image in deployments without
            // a moderation provider.
            let mut tx = pool.begin().await?;
            set_media_moderation_status(&mut tx, resource_type, resource_id, "approved").await?;
            tx.commit().await?;
            return Ok(String::new());
        }

        // Quarantine and job enqueue commit atomically: from this moment the
        // media is hidden from public serving until the worker approves it. A
        // crash between the two would otherwise leave an unreviewed image
        // publicly visible with no job to ever review it.
        let id = uuid::Uuid::new_v4().to_string();
        let mut tx = pool.begin().await?;
        sqlx::query(
            r#"INSERT INTO moderation_jobs (
                   id, campus_id, resource_type, resource_id, image_url, status
               ) VALUES ($1, $2, $3, $4, $5, 'pending')"#,
        )
        .bind(&id)
        .bind(campus_id)
        .bind(resource_type)
        .bind(resource_id)
        .bind(image_url)
        .execute(&mut *tx)
        .await?;
        set_media_moderation_status(&mut tx, resource_type, resource_id, "pending").await?;
        tx.commit().await?;

        Ok(id)
    }

    /// Check if image moderation is enabled.
    #[allow(dead_code)]
    pub fn is_image_enabled(&self) -> bool {
        self.image_enabled
    }
}

/// Write a media moderation status onto the owning resource. Shared by job
/// submission (quarantine to 'pending') and the worker (final verdict), so the
/// resource-type mapping cannot drift between the two.
pub(crate) async fn set_media_moderation_status(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    resource_type: &str,
    resource_id: &str,
    status: &str,
) -> Result<(), sqlx::Error> {
    match resource_type {
        "listing_image" => {
            sqlx::query("UPDATE inventory SET images_moderation_status = $1 WHERE id = $2")
                .bind(status)
                .bind(resource_id)
                .execute(&mut **tx)
                .await?;
        }
        "chat_image" => {
            if let Ok(message_id) = resource_id.parse::<i64>() {
                sqlx::query("UPDATE chat_messages SET moderation_status = $1 WHERE id = $2")
                    .bind(status)
                    .bind(message_id)
                    .execute(&mut **tx)
                    .await?;
            } else {
                tracing::warn!(resource_id, "invalid chat_image resource id");
            }
        }
        "avatar" => {
            sqlx::query("UPDATE users SET avatar_moderation_status = $1 WHERE id = $2")
                .bind(status)
                .bind(resource_id)
                .execute(&mut **tx)
                .await?;
        }
        other => {
            tracing::warn!(resource_type = other, "unknown media resource type");
        }
    }
    Ok(())
}

fn normalize_for_moderation(text: &str) -> String {
    text.chars()
        .filter_map(normalize_char_for_moderation)
        .collect::<String>()
        .to_lowercase()
}

fn normalize_char_for_moderation(ch: char) -> Option<char> {
    let normalized = match ch {
        '\u{200b}' | '\u{200c}' | '\u{200d}' | '\u{feff}' => return None,
        '\u{3000}' => return None,
        // Full-width ASCII range.
        '\u{ff01}'..='\u{ff5e}' => char::from_u32(ch as u32 - 0xfee0).unwrap_or(ch),
        _ => ch,
    };

    if normalized.is_ascii_punctuation()
        || normalized.is_ascii_whitespace()
        || matches!(
            normalized,
            '，' | '。'
                | '、'
                | '；'
                | '：'
                | '！'
                | '？'
                | '（'
                | '）'
                | '【'
                | '】'
                | '《'
                | '》'
                | '“'
                | '”'
                | '‘'
                | '’'
                | '￥'
                | '·'
                | '…'
                | '—'
                | ' '
                | '\t'
                | '\n'
                | '\r'
        )
    {
        None
    } else {
        Some(normalized)
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
            shutdown_drain_secs: 5,
            shutdown_timeout_secs: 25,
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
            secret_chat_new_sessions_enabled: false,
            media_private_bucket: false,
            media_url_ttl_secs: 600,
            media_path_style: true,
            media_region: "us-east-1".to_string(),
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
        let r = svc.check_text("出售自定义违禁词毒品，量大从优");
        assert!(!r.passed);
        assert_eq!(r.code, ModerationCode::BlockedKeyword);

        let r2 = svc.check_text("This is a gun for sale");
        assert!(!r2.passed);
        assert_eq!(r2.code, ModerationCode::BlockedKeyword);

        let r3 = svc.check_text("正常商品描述，没问题");
        assert!(r3.passed);
    }

    #[test]
    fn test_check_text_normalizes_obfuscated_keywords() {
        let svc = ModerationService::new(&make_config(vec!["违禁测试词".into()]));

        let r = svc.check_text("违 禁　测-试_词");
        assert!(!r.passed);
        assert_eq!(r.code, ModerationCode::BlockedKeyword);

        let r2 = svc.check_text("ＶＩＰ 会员卡，正常转让");
        assert!(r2.passed);
    }

    #[test]
    fn test_check_text_builtin_illegal_goods() {
        let svc = ModerationService::new(&make_config(vec![]));
        let r = svc.check_text("出一个管 制 刀 具，寝室自提");
        assert!(!r.passed);
        assert_eq!(r.code, ModerationCode::IllegalGoods);

        let r2 = svc.check_text("出售考试答案和资料");
        assert!(!r2.passed);
        assert_eq!(r2.code, ModerationCode::IllegalGoods);
    }

    #[test]
    fn test_check_text_builtin_adult_gambling_fraud_and_violence() {
        let svc = ModerationService::new(&make_config(vec![]));

        let adult = svc.check_text("提供裸 聊服务");
        assert!(!adult.passed);
        assert_eq!(adult.code, ModerationCode::AdultContent);

        let gambling = svc.check_text("赌球平台优惠");
        assert!(!gambling.passed);
        assert_eq!(gambling.code, ModerationCode::Gambling);

        let fraud = svc.check_text("刷单兼职，日结");
        assert!(!fraud.passed);
        assert_eq!(fraud.code, ModerationCode::Fraud);

        let violence = svc.check_text("自杀教程资料");
        assert!(!violence.passed);
        assert_eq!(violence.code, ModerationCode::ViolenceExtremism);
    }

    #[test]
    fn test_check_text_builtin_harassment_and_privacy() {
        let svc = ModerationService::new(&make_config(vec![]));

        let harassment = svc.check_text("帮忙人肉搜索一个同学");
        assert!(!harassment.passed);
        assert_eq!(harassment.code, ModerationCode::HateHarassment);

        let open_box_listing = svc.check_text("耳机仅开盒检查，配件齐全");
        assert!(open_box_listing.passed);

        let privacy = svc.check_text("身份证号 110105199001011234");
        assert!(!privacy.passed);
        assert_eq!(privacy.code, ModerationCode::PersonalInfo);

        let bank_card = svc.check_text("银行卡 6222 0202 0000 0000 000");
        assert!(!bank_card.passed);
        assert_eq!(bank_card.code, ModerationCode::PersonalInfo);
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
        assert_eq!(r.code, ModerationCode::BlockedKeyword);
    }

    #[test]
    fn test_normalize_for_moderation_removes_common_separators() {
        assert_eq!(normalize_for_moderation("毒 品"), "毒品");
        assert_eq!(normalize_for_moderation("管-制_刀　具"), "管制刀具");
        assert_eq!(normalize_for_moderation("ＡＢＣ１２３"), "abc123");
    }
}
