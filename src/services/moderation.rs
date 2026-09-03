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

use std::{
    collections::HashSet,
    env,
    fs::File,
    io::{BufRead, BufReader},
    path::{Path, PathBuf},
    sync::Arc,
};

use crate::config::AppConfig;
use aho_corasick::{AhoCorasick, AhoCorasickBuilder, MatchKind};
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
    // High-confidence network-circumvention tool names. These remain built in
    // as a fail-safe; deployments should maintain broader political policy in
    // external lexicons.
    BuiltinTextRule {
        code: ModerationCode::BlockedKeyword,
        phrase: "shadowsocks",
    },
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
    /// Compiled multi-pattern matcher for normalized policy terms. Keeping the
    /// terms out of this struct also prevents accidental Debug/log exposure.
    blocked_keyword_matcher: Option<Arc<AhoCorasick>>,
    /// Single-character policies only match the complete normalized input to
    /// prevent a one-character rule from suppressing normal Chinese prose.
    exact_short_blocked_keywords: Arc<HashSet<String>>,
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
        let mut blocked_keywords = config.blocked_keywords.clone();
        blocked_keywords.extend(load_external_policy_keywords());
        let (blocked_keyword_matcher, exact_short_blocked_keywords, keyword_count) =
            build_policy_matcher(blocked_keywords);

        tracing::info!(
            keyword_count,
            "content moderation policy matcher initialized"
        );

        Self {
            blocked_keyword_matcher,
            exact_short_blocked_keywords: Arc::new(exact_short_blocked_keywords),
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
        let policy_normalized = normalize_policy_evasion(&normalized);

        // 1. Operator-configured blocked keywords. The matcher runs against a
        // separator-free, full-width-normalized view, making common evasion
        // attempts equivalent without ever logging the matched policy term.
        let blocked_by_policy = self
            .blocked_keyword_matcher
            .as_ref()
            .is_some_and(|matcher| {
                matcher.is_match(&normalized)
                    || (policy_normalized != normalized && matcher.is_match(&policy_normalized))
            })
            || self.exact_short_blocked_keywords.contains(&normalized);
        if blocked_by_policy {
            tracing::debug!("blocked keyword detected");
            return ModerationResult::rejected(ModerationCode::BlockedKeyword);
        }

        // 2. Built-in mainland marketplace safety rules. These are deliberately
        // broad, high-risk categories; more local policy terms belong in config.
        for rule in BUILTIN_TEXT_RULES {
            let normalized_phrase = normalize_for_moderation(rule.phrase);
            if normalized.contains(&normalized_phrase)
                || policy_normalized.contains(&normalized_phrase)
            {
                tracing::debug!(code = rule.code.label(), "builtin moderation rule detected");
                return ModerationResult::rejected(rule.code);
            }
        }

        // 3. Personal information and contact info.
        if self.id_card_re.is_match(&normalized) {
            tracing::debug!("mainland id card number detected");
            return ModerationResult::rejected(ModerationCode::PersonalInfo);
        }
        if self.bank_card_re.is_match(&normalized) {
            tracing::debug!("bank card number detected");
            return ModerationResult::rejected(ModerationCode::PersonalInfo);
        }
        if self.phone_re.is_match(&normalized) {
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
        let mut tx = pool.begin().await?;
        let id = self
            .submit_image_job_in_tx(&mut tx, campus_id, resource_id, image_url, resource_type)
            .await?;
        tx.commit().await?;
        Ok(id)
    }

    pub async fn submit_image_job_in_tx(
        &self,
        tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
        campus_id: uuid::Uuid,
        resource_id: &str,
        image_url: &str,
        resource_type: &str,
    ) -> Result<String, sqlx::Error> {
        self.submit_image_job_in_tx_with_storage_key(
            tx,
            campus_id,
            resource_id,
            image_url,
            None,
            resource_type,
        )
        .await
    }

    /// Submit a platform-owned image with its stable storage key. The URL is
    /// retained as a compatibility/fallback value, while private deployments
    /// let the moderation worker sign a fresh URL for every attempt.
    pub async fn submit_image_job_in_tx_with_storage_key(
        &self,
        tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
        campus_id: uuid::Uuid,
        resource_id: &str,
        image_url: &str,
        storage_key: Option<&str>,
        resource_type: &str,
    ) -> Result<String, sqlx::Error> {
        if !self.image_enabled {
            set_media_moderation_status(tx, resource_type, resource_id, "approved").await?;
            return Ok(String::new());
        }

        let id = uuid::Uuid::new_v4().to_string();
        sqlx::query(
            r#"INSERT INTO moderation_jobs (
                   id, campus_id, resource_type, resource_id, image_url, storage_key, status
               ) VALUES ($1, $2, $3, $4, $5, $6, 'pending')"#,
        )
        .bind(&id)
        .bind(campus_id)
        .bind(resource_type)
        .bind(resource_id)
        .bind(image_url)
        .bind(storage_key)
        .execute(&mut **tx)
        .await?;
        set_media_moderation_status(tx, resource_type, resource_id, "pending").await?;

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
        "post_image" => {
            if let Ok(post_id) = resource_id.parse::<uuid::Uuid>() {
                sqlx::query("UPDATE posts SET images_moderation_status = $1 WHERE id = $2")
                    .bind(status)
                    .bind(post_id)
                    .execute(&mut **tx)
                    .await?;
            } else {
                tracing::warn!(resource_id, "invalid post_image resource id");
            }
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
        "chat_shared_object" => {
            if let Ok(object_id) = resource_id.parse::<uuid::Uuid>() {
                sqlx::query(
                    "UPDATE chat_shared_objects
                     SET moderation_status = $1,
                         status = CASE
                             WHEN status IN ('revoked', 'deleted') THEN status
                             WHEN $1 = 'approved' THEN 'active'
                             WHEN $1 = 'rejected' THEN 'rejected'
                             ELSE status
                         END,
                         updated_at = NOW()
                     WHERE id = $2",
                )
                .bind(status)
                .bind(object_id)
                .execute(&mut **tx)
                .await?;
            } else {
                tracing::warn!(resource_id, "invalid chat_shared_object resource id");
            }
        }
        "social_persona_asset" => {
            if let Ok(asset_id) = resource_id.parse::<uuid::Uuid>() {
                sqlx::query(
                    "UPDATE social_persona_assets
                     SET moderation_status = $1,
                         status = CASE
                             WHEN status IN ('revoked', 'deleted') THEN status
                             WHEN $1 = 'approved' THEN 'active'
                             WHEN $1 = 'rejected' THEN 'rejected'
                             ELSE status
                         END,
                         reject_reason = CASE
                             WHEN $1 = 'rejected' THEN '图片内容不合规'
                             WHEN $1 = 'approved' THEN NULL
                             ELSE reject_reason
                         END,
                         updated_at = NOW()
                     WHERE id = $2",
                )
                .bind(status)
                .bind(asset_id)
                .execute(&mut **tx)
                .await?;
            } else {
                tracing::warn!(resource_id, "invalid social_persona_asset resource id");
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

const POLICY_FILE_ENV: &str = "MODERATION_BLOCKED_KEYWORDS_FILE";
const POLICY_FILES_ENV: &str = "MODERATION_BLOCKED_KEYWORDS_FILES";
const MAX_POLICY_TERMS: usize = 1_000_000;
const MAX_POLICY_TERM_CHARS: usize = 256;

/// Load deployment-specific moderation vocabulary without putting the corpus
/// in application config, logs, or source control. A configured but unreadable
/// file fails startup: silently running with a missing political policy would
/// be less safe than refusing to serve content.
fn load_external_policy_keywords() -> Vec<String> {
    let mut paths = Vec::new();
    if let Some(path) = env::var_os(POLICY_FILE_ENV).filter(|value| !value.is_empty()) {
        paths.push(PathBuf::from(path));
    }
    if let Some(value) = env::var_os(POLICY_FILES_ENV).filter(|value| !value.is_empty()) {
        paths.extend(
            value
                .to_string_lossy()
                .split(',')
                .map(str::trim)
                .filter(|path| !path.is_empty())
                .map(PathBuf::from),
        );
    }

    let mut keywords = Vec::new();
    for path in paths {
        let remaining = MAX_POLICY_TERMS.saturating_sub(keywords.len());
        if remaining == 0 {
            panic!("moderation policy contains more than {MAX_POLICY_TERMS} terms");
        }
        let loaded = load_policy_keyword_file(&path, remaining).unwrap_or_else(|error| {
            panic!("failed to load configured moderation policy file: {error}")
        });
        keywords.extend(loaded);
    }
    keywords
}

fn load_policy_keyword_file(path: &Path, limit: usize) -> Result<Vec<String>, String> {
    let file = File::open(path).map_err(|_| "file is unavailable".to_string())?;
    let mut keywords = Vec::new();
    for line in BufReader::new(file).lines() {
        let line = line.map_err(|_| "file contains unreadable data".to_string())?;
        let keyword = line.trim().trim_start_matches('\u{feff}');
        if keyword.is_empty() || keyword.starts_with('#') {
            continue;
        }
        if keyword.chars().count() > MAX_POLICY_TERM_CHARS {
            return Err(format!(
                "a term exceeds the {MAX_POLICY_TERM_CHARS}-character limit"
            ));
        }
        if keywords.len() >= limit {
            return Err(format!("policy exceeds the {MAX_POLICY_TERMS}-term limit"));
        }
        keywords.push(keyword.to_owned());
    }
    Ok(keywords)
}

fn build_policy_matcher(
    keywords: Vec<String>,
) -> (Option<Arc<AhoCorasick>>, HashSet<String>, usize) {
    let normalized: HashSet<String> = keywords
        .into_iter()
        .map(|keyword| normalize_for_moderation(&keyword))
        .filter(|keyword| !keyword.is_empty())
        .collect();

    let mut exact_short = HashSet::new();
    let mut patterns = Vec::with_capacity(normalized.len());
    for keyword in normalized {
        if keyword.chars().count() == 1 {
            exact_short.insert(keyword);
        } else {
            patterns.push(keyword);
        }
    }
    // Stable ordering makes startup memory and matcher construction
    // deterministic across runs even though de-duplication uses a HashSet.
    patterns.sort_unstable();
    let matcher = if patterns.is_empty() {
        None
    } else {
        Some(Arc::new(
            AhoCorasickBuilder::new()
                .match_kind(MatchKind::LeftmostFirst)
                .build(&patterns)
                .expect("normalized moderation policy is valid"),
        ))
    };
    let count = patterns.len() + exact_short.len();
    (matcher, exact_short, count)
}

fn normalize_for_moderation(text: &str) -> String {
    text.chars()
        .filter_map(normalize_char_for_moderation)
        .collect::<String>()
        .to_lowercase()
}

/// Canonicalize common digit substitutions only inside Latin tokens. Numeric
/// identifiers and prices remain untouched, while policy terms written with
/// substitutions such as `0` for `o` cannot bypass the matcher.
fn normalize_policy_evasion(normalized: &str) -> String {
    let chars: Vec<char> = normalized.chars().collect();
    chars
        .iter()
        .enumerate()
        .map(|(index, ch)| {
            let adjacent_to_latin = index
                .checked_sub(1)
                .and_then(|previous| chars.get(previous))
                .is_some_and(|value| value.is_ascii_alphabetic())
                || chars
                    .get(index + 1)
                    .is_some_and(|value| value.is_ascii_alphabetic());
            if !adjacent_to_latin {
                return *ch;
            }
            match ch {
                '0' => 'o',
                '1' => 'i',
                '3' => 'e',
                '4' => 'a',
                '5' => 's',
                '7' => 't',
                '8' => 'b',
                '9' => 'g',
                _ => *ch,
            }
        })
        .collect()
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
        let mut config = AppConfig::test_defaults();
        config.blocked_keywords = keywords;
        config.moderation_image_enabled = true;
        config
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
        let svc = ModerationService::new(&make_config(vec![
            "违禁测试词".into(),
            "campuspolicytoken".into(),
        ]));

        let r = svc.check_text("违 禁　测-试_词");
        assert!(!r.passed);
        assert_eq!(r.code, ModerationCode::BlockedKeyword);

        let r2 = svc.check_text("ＶＩＰ 会员卡，正常转让");
        assert!(r2.passed);

        let latin_evasion = svc.check_text("campusp0licytoken");
        assert!(!latin_evasion.passed);
        assert_eq!(latin_evasion.code, ModerationCode::BlockedKeyword);
    }

    #[test]
    fn test_policy_matcher_deduplicates_and_handles_short_rules_safely() {
        let (matcher, exact_short, count) = build_policy_matcher(vec![
            "校政测试短语".into(),
            "校 政 测试短语".into(),
            "危".into(),
        ]);

        assert_eq!(count, 2);
        assert!(matcher
            .as_ref()
            .is_some_and(|matcher| matcher.is_match("请勿传播校政测试短语")));
        assert!(exact_short.contains("危"));
        assert!(!matcher
            .as_ref()
            .is_some_and(|matcher| matcher.is_match("危险品")));
    }

    #[test]
    fn test_load_policy_keyword_file_enforces_safe_shape() {
        let path = std::env::temp_dir().join(format!(
            "goods4ncu-moderation-policy-{}.txt",
            uuid::Uuid::new_v4()
        ));
        std::fs::write(&path, "\u{feff}校政测试短语\n# comment\n\n另一测试规则\n")
            .expect("write temporary policy");

        let loaded = load_policy_keyword_file(&path, 10).expect("load temporary policy");
        std::fs::remove_file(&path).expect("remove temporary policy");

        assert_eq!(loaded.len(), 2);
        assert_eq!(loaded[0], "校政测试短语");
        assert_eq!(loaded[1], "另一测试规则");
    }

    /// Runs only when explicitly requested with local dataset paths. The test
    /// reports aggregate policy quality and never emits terms or case text.
    #[test]
    #[ignore = "requires the local sensitive moderation dataset"]
    fn audit_local_political_dataset_without_exposing_samples() {
        let lexicon_paths = std::env::var("MODERATION_AUDIT_LEXICONS")
            .ok()
            .map(|value| {
                value
                    .split(',')
                    .map(str::trim)
                    .filter(|path| !path.is_empty())
                    .map(PathBuf::from)
                    .collect::<Vec<_>>()
            })
            .filter(|paths| !paths.is_empty())
            .or_else(|| {
                std::env::var_os("MODERATION_AUDIT_LEXICON").map(|path| vec![PathBuf::from(path)])
            })
            .expect("MODERATION_AUDIT_LEXICON(S) is required");
        let suite_path =
            std::env::var_os("MODERATION_AUDIT_SUITE").expect("MODERATION_AUDIT_SUITE is required");

        let mut keywords = Vec::new();
        for path in lexicon_paths {
            let remaining = MAX_POLICY_TERMS.saturating_sub(keywords.len());
            keywords.extend(load_policy_keyword_file(&path, remaining).expect("load audit policy"));
        }
        let mut config = make_config(keywords);
        config.moderation_image_enabled = false;
        let service = ModerationService::new(&config);
        let raw = std::fs::read_to_string(suite_path).expect("read audit suite");
        let cases: serde_json::Value = serde_json::from_str(&raw).expect("parse audit suite");
        let cases = cases.as_array().expect("audit suite must be a JSON array");

        let mut expected_blocked = 0usize;
        let mut blocked_detected = 0usize;
        let mut expected_allowed = 0usize;
        let mut allowed_passed = 0usize;
        let mut missed_case_ids = Vec::new();
        for case in cases {
            let expected = case
                .get("expected_label")
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default();
            let text = case
                .get("text")
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default();
            let passed = service.check_text(text).passed;
            if expected == "blocked" {
                expected_blocked += 1;
                blocked_detected += usize::from(!passed);
                if passed {
                    missed_case_ids.push(
                        case.get("id")
                            .and_then(serde_json::Value::as_str)
                            .unwrap_or("unknown"),
                    );
                }
            } else {
                expected_allowed += 1;
                allowed_passed += usize::from(passed);
            }
        }

        eprintln!(
            "moderation audit aggregate: blocked={blocked_detected}/{expected_blocked}, allowed={allowed_passed}/{expected_allowed}, missed_ids={missed_case_ids:?}"
        );
        assert_eq!(
            blocked_detected, expected_blocked,
            "strict-policy recall regressed"
        );
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

        let obfuscated = svc.check_text("联系电话：１ ３ ８-１２３４-５６７８");
        assert!(!obfuscated.passed);
        assert_eq!(obfuscated.code, ModerationCode::ContactInfo);
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
