//! Business rules for discussion/listing posts and threaded replies.

use crate::api::error::ApiError;
use crate::repositories::{
    NewPost, Post, PostFilter, PostReply, PostRepository, PostgresPostRepository, UpdatePostInput,
};
use crate::services::moderation::ModerationService;
use sqlx::{PgPool, Postgres, Transaction};
use std::collections::HashSet;
use uuid::Uuid;

pub use crate::categories::MarketplaceCategory;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

pub const MAX_POST_TITLE_CHARS: usize = 300;
pub const MAX_POST_BODY_CHARS: usize = 50_000;
pub const MAX_REPLY_BODY_CHARS: usize = 20_000;
pub const MAX_TAG_CHARS: usize = 32;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MarketplaceDetails {
    pub category: MarketplaceCategory,
    pub brand: String,
    pub condition_score: i32,
    pub suggested_price_cny: f64,
    pub defects: Vec<String>,
    pub description: Option<String>,
}

impl MarketplaceDetails {
    pub fn new(
        category: MarketplaceCategory,
        brand: impl Into<String>,
        condition_score: i32,
        suggested_price_cny: f64,
        defects: Vec<String>,
        description: Option<String>,
    ) -> Result<Self, ApiError> {
        if !(1..=10).contains(&condition_score) {
            return Err(ApiError::BadRequest(
                "成色评分 (condition_score) 必须在 1 到 10 之间".to_string(),
            ));
        }
        if suggested_price_cny < 0.0
            || suggested_price_cny.is_nan()
            || suggested_price_cny.is_infinite()
        {
            return Err(ApiError::BadRequest(
                "商品价格 (suggested_price_cny) 必须为非负有效数值".to_string(),
            ));
        }
        Ok(Self {
            category,
            brand: brand.into(),
            condition_score,
            suggested_price_cny,
            defects,
            description,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", content = "details")]
pub enum PostContent {
    Announcement,
    Share,
    Question,
    Discussion,
    Recruit,
    TeamUp,
    Offer(MarketplaceDetails),
    Wanted(MarketplaceDetails),
}

pub type PostKind = PostContent;

impl PostContent {
    pub fn category(&self) -> PostCategory {
        match self {
            Self::Announcement => PostCategory::Announcement,
            Self::Share => PostCategory::Share,
            Self::Question => PostCategory::Question,
            Self::Discussion => PostCategory::Discussion,
            Self::Recruit => PostCategory::Recruit,
            Self::TeamUp => PostCategory::TeamUp,
            Self::Offer(_) => PostCategory::Offer,
            Self::Wanted(_) => PostCategory::Wanted,
        }
    }

    pub fn category_str(&self) -> &'static str {
        self.category().as_str()
    }

    pub fn marketplace(&self) -> Option<&MarketplaceDetails> {
        match self {
            Self::Offer(mp) | Self::Wanted(mp) => Some(mp),
            _ => None,
        }
    }

    #[allow(dead_code)]
    pub fn is_marketplace(&self) -> bool {
        self.marketplace().is_some()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreatePost {
    pub campus_id: Uuid,
    pub author_id: String,
    pub title: String,
    pub body: String,
    pub content: PostContent,
    pub tags: Vec<String>,
    pub cover_image_url: Option<String>,
    pub space_id: Option<Uuid>,
    pub idempotency_key: Option<String>,
}

#[allow(dead_code)]
impl CreatePost {
    pub fn new(
        campus_id: Uuid,
        author_id: impl Into<String>,
        title: impl Into<String>,
        body: impl Into<String>,
        content: PostContent,
    ) -> Self {
        Self {
            campus_id,
            author_id: author_id.into(),
            title: title.into(),
            body: body.into(),
            content,
            tags: Vec::new(),
            cover_image_url: None,
            space_id: None,
            idempotency_key: None,
        }
    }

    pub fn new_discussion(
        campus_id: Uuid,
        author_id: impl Into<String>,
        title: impl Into<String>,
        body: impl Into<String>,
    ) -> Self {
        Self::new(campus_id, author_id, title, body, PostContent::Discussion)
    }

    pub fn new_offer(
        campus_id: Uuid,
        author_id: impl Into<String>,
        title: impl Into<String>,
        body: impl Into<String>,
        marketplace: MarketplaceDetails,
    ) -> Self {
        Self::new(
            campus_id,
            author_id,
            title,
            body,
            PostContent::Offer(marketplace),
        )
    }

    pub fn new_wanted(
        campus_id: Uuid,
        author_id: impl Into<String>,
        title: impl Into<String>,
        body: impl Into<String>,
        marketplace: MarketplaceDetails,
    ) -> Self {
        Self::new(
            campus_id,
            author_id,
            title,
            body,
            PostContent::Wanted(marketplace),
        )
    }

    pub fn category(&self) -> PostCategory {
        self.content.category()
    }

    pub fn category_str(&self) -> &'static str {
        self.content.category_str()
    }

    pub fn marketplace(&self) -> Option<&MarketplaceDetails> {
        self.content.marketplace()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PostCategory {
    Announcement,
    Offer,
    Wanted,
    Share,
    Question,
    Discussion,
    Recruit,
    TeamUp,
}

impl PostCategory {
    pub const ALL: [PostCategory; 8] = [
        Self::Announcement,
        Self::Offer,
        Self::Wanted,
        Self::Share,
        Self::Question,
        Self::Discussion,
        Self::Recruit,
        Self::TeamUp,
    ];

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Announcement => "announcement",
            Self::Offer => "offer",
            Self::Wanted => "wanted",
            Self::Share => "share",
            Self::Question => "question",
            Self::Discussion => "discussion",
            Self::Recruit => "recruit",
            Self::TeamUp => "team_up",
        }
    }

    pub fn label_zh(&self) -> &'static str {
        match self {
            Self::Announcement => "公告",
            Self::Offer => "出",
            Self::Wanted => "收",
            Self::Share => "分享",
            Self::Question => "提问",
            Self::Discussion => "讨论",
            Self::Recruit => "召集",
            Self::TeamUp => "组队",
        }
    }

    pub fn label_en(&self) -> &'static str {
        match self {
            Self::Announcement => "Announcement",
            Self::Offer => "Offer",
            Self::Wanted => "Wanted",
            Self::Share => "Share",
            Self::Question => "Question",
            Self::Discussion => "Discussion",
            Self::Recruit => "Recruit",
            Self::TeamUp => "Team Up",
        }
    }

    pub fn kind(&self) -> &'static str {
        if self.is_marketplace() {
            "goods"
        } else {
            "discussion"
        }
    }

    pub fn is_marketplace(&self) -> bool {
        matches!(self, Self::Offer | Self::Wanted)
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "announcement" => Some(Self::Announcement),
            "offer" => Some(Self::Offer),
            "wanted" => Some(Self::Wanted),
            "share" => Some(Self::Share),
            "question" => Some(Self::Question),
            "discussion" => Some(Self::Discussion),
            "recruit" => Some(Self::Recruit),
            "team_up" => Some(Self::TeamUp),
            _ => None,
        }
    }
}

impl std::fmt::Display for PostCategory {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PublishPostCommand {
    pub campus_id: Uuid,
    pub author_id: String,
    pub title: String,
    pub body: String,
    pub kind: PostContent,
    pub tags: Vec<String>,
    pub cover_image_url: Option<String>,
    pub space_id: Option<Uuid>,
    pub idempotency_key: Option<String>,
}

impl PublishPostCommand {
    pub fn new(
        campus_id: Uuid,
        author_id: impl Into<String>,
        title: impl Into<String>,
        body: impl Into<String>,
        kind: PostContent,
    ) -> Result<Self, ApiError> {
        let title = required_text(title.into(), "title", MAX_POST_TITLE_CHARS)?;
        let body = required_text(body.into(), "body", MAX_POST_BODY_CHARS)?;

        if let PostContent::Offer(ref mp) = kind {
            if mp.brand.trim().is_empty() {
                return Err(ApiError::BadRequest(
                    "发布闲置商品 (offer) 必须提供品牌或来源".to_string(),
                ));
            }
        }

        Ok(Self {
            campus_id,
            author_id: author_id.into(),
            title,
            body,
            kind,
            tags: Vec::new(),
            cover_image_url: None,
            space_id: None,
            idempotency_key: None,
        })
    }

    pub fn from_input(input: CreatePost) -> Result<Self, ApiError> {
        let mut cmd = Self::new(
            input.campus_id,
            input.author_id,
            input.title,
            input.body,
            input.content,
        )?;
        cmd.tags = input.tags;
        cmd.cover_image_url = input.cover_image_url;
        cmd.space_id = input.space_id;
        cmd.idempotency_key = input.idempotency_key;
        Ok(cmd)
    }
}

impl TryFrom<CreatePost> for PublishPostCommand {
    type Error = ApiError;

    fn try_from(input: CreatePost) -> Result<Self, Self::Error> {
        Self::from_input(input)
    }
}

pub fn publish_post_request_hash(cmd: &PublishPostCommand) -> Result<String, ApiError> {
    let canonical = serde_json::to_vec(cmd).map_err(|error| {
        ApiError::Internal(anyhow::anyhow!(
            "Failed to serialize normalized post command: {}",
            error
        ))
    })?;
    Ok(hex::encode(Sha256::digest(canonical)))
}

#[allow(dead_code)]
pub fn create_post_request_hash(input: &CreatePost) -> Result<String, ApiError> {
    let cmd = PublishPostCommand::try_from(input.clone())?;
    publish_post_request_hash(&cmd)
}

#[derive(Debug, Clone, Default)]
pub struct EditPost {
    pub title: Option<String>,
    pub body: Option<String>,
    pub tags: Option<Vec<String>>,
    pub locked: Option<bool>,
}

pub fn allowed_post_categories() -> Vec<String> {
    PostCategory::ALL
        .iter()
        .map(|c| c.as_str().to_string())
        .collect()
}

#[derive(Clone)]
pub struct PostService<R: PostRepository = PostgresPostRepository> {
    pool: PgPool,
    repository: R,
    moderation: ModerationService,
}

impl PostService<PostgresPostRepository> {
    pub fn new(pool: PgPool, moderation: ModerationService) -> Self {
        Self {
            repository: PostgresPostRepository::new(pool.clone()),
            pool,
            moderation,
        }
    }
}

impl<R: PostRepository> PostService<R> {
    #[allow(dead_code)]
    pub fn new_with_repo(pool: PgPool, repository: R, moderation: ModerationService) -> Self {
        Self {
            pool,
            repository,
            moderation,
        }
    }

    /// Tags must exist in the curated catalog; keys are matched exactly
    /// (they are camelCase identifiers like freeShipping, never lowercased).
    async fn normalize_tags(&self, tags: Vec<String>) -> Result<Vec<String>, ApiError> {
        let mut normalized: Vec<String> = Vec::new();
        let mut seen = HashSet::new();
        for tag in tags {
            let tag = tag.trim().trim_start_matches('#').trim().to_string();
            if tag.is_empty() {
                continue;
            }
            if tag.chars().count() > MAX_TAG_CHARS {
                return Err(ApiError::BadRequest(format!(
                    "每个标签不能超过 {MAX_TAG_CHARS} 个字符"
                )));
            }
            if seen.insert(tag.clone()) {
                normalized.push(tag);
            }
        }
        if normalized.is_empty() {
            return Ok(normalized);
        }
        #[derive(sqlx::FromRow)]
        struct CatalogRow {
            key: String,
            group_key: Option<String>,
        }
        let rows: Vec<CatalogRow> =
            sqlx::query_as("SELECT key, group_key FROM post_tag_catalog WHERE key = ANY($1)")
                .bind(&normalized)
                .fetch_all(&self.pool)
                .await
                .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {error}")))?;
        let mut groups: std::collections::HashMap<String, u32> = std::collections::HashMap::new();
        for tag in &normalized {
            let row = rows.iter().find(|row| row.key == *tag);
            let Some(row) = row else {
                return Err(ApiError::BadRequest(format!(
                    "标签 “{tag}” 不在预定义标签目录中"
                )));
            };
            if let Some(group) = &row.group_key {
                let count = groups.entry(group.clone()).or_insert(0);
                *count += 1;
                if *count > 1 {
                    return Err(ApiError::BadRequest(format!(
                        "标签组 “{group}” 内最多选择一个"
                    )));
                }
            }
        }
        Ok(normalized)
    }

    #[allow(dead_code)]
    pub async fn list(
        &self,
        campus_id: Uuid,
        filter: &PostFilter,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<Post>, i64), ApiError> {
        self.repository
            .list(campus_id, None, filter, limit, offset)
            .await
    }

    pub async fn list_for_viewer(
        &self,
        campus_id: Uuid,
        viewer_id: Option<&str>,
        filter: &PostFilter,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<Post>, i64), ApiError> {
        if filter.sort == crate::repositories::PostSort::ForYou {
            self.repository
                .list_for_you(campus_id, viewer_id, filter, limit, offset)
                .await
        } else {
            self.repository
                .list(campus_id, viewer_id, filter, limit, offset)
                .await
        }
    }

    /// Author-scoped listing for the 我的发布 manager (includes deleted).
    pub async fn list_by_author(
        &self,
        campus_id: Uuid,
        author_id: &str,
        status: Option<&str>,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<Post>, i64), ApiError> {
        self.repository
            .list_by_author(campus_id, author_id, status, limit, offset)
            .await
    }

    pub async fn get(&self, campus_id: Uuid, id: Uuid) -> Result<Post, ApiError> {
        self.repository
            .find_by_id(campus_id, id)
            .await?
            .ok_or(ApiError::NotFound)
    }

    /// Detail read with group-visibility enforcement.
    pub async fn get_for_viewer(
        &self,
        campus_id: Uuid,
        id: Uuid,
        viewer_id: Option<&str>,
    ) -> Result<Post, ApiError> {
        let post = self.get(campus_id, id).await?;
        ensure_post_visible(&self.pool, &post, viewer_id).await?;
        Ok(post)
    }

    pub async fn get_by_listing_for_viewer(
        &self,
        campus_id: Uuid,
        listing_id: &str,
        viewer_id: Option<&str>,
    ) -> Result<Post, ApiError> {
        let post = self.get_by_listing(campus_id, listing_id).await?;
        ensure_post_visible(&self.pool, &post, viewer_id).await?;
        Ok(post)
    }

    pub async fn get_by_listing(
        &self,
        campus_id: Uuid,
        listing_id: &str,
    ) -> Result<Post, ApiError> {
        let listing_id = listing_id.trim();
        if listing_id.is_empty() || listing_id.chars().count() > 255 {
            return Err(ApiError::NotFound);
        }
        self.repository
            .find_by_listing_id(campus_id, listing_id)
            .await?
            .ok_or(ApiError::NotFound)
    }

    /// Announcements are campus-staff only (operator+ or platform admin).
    async fn ensure_can_announce(&self, campus_id: Uuid, user_id: &str) -> Result<(), ApiError> {
        let allowed: bool = sqlx::query_scalar(
            "SELECT EXISTS (
                 SELECT 1 FROM campus_memberships m
                 JOIN users u ON u.id = m.user_id
                 WHERE m.user_id = $1 AND m.campus_id = $2 AND m.status = 'verified'
                   AND (m.role = 'operator' OR u.role = 'admin')
             )",
        )
        .bind(user_id)
        .bind(campus_id)
        .fetch_one(&self.pool)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {error}")))?;
        if allowed {
            Ok(())
        } else {
            Err(ApiError::Forbidden)
        }
    }

    pub async fn create(&self, input: CreatePost) -> Result<Post, ApiError> {
        let cmd = PublishPostCommand::try_from(input)?;
        self.publish(cmd).await
    }

    pub async fn publish(&self, mut cmd: PublishPostCommand) -> Result<Post, ApiError> {
        if cmd.kind.category() == PostCategory::Announcement {
            self.ensure_can_announce(cmd.campus_id, cmd.author_id.as_str())
                .await?;
        }
        cmd.tags = self.normalize_tags(cmd.tags).await?;
        if let Some(space_id) = cmd.space_id {
            ensure_space_member(&self.pool, cmd.author_id.as_str(), space_id).await?;
        }

        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {e}")))?;
        let post = self.publish_in_tx(&mut tx, cmd).await?;
        tx.commit()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {e}")))?;
        Ok(post)
    }

    pub async fn publish_in_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        cmd: PublishPostCommand,
    ) -> Result<Post, ApiError> {
        let title = required_text(cmd.title, "title", MAX_POST_TITLE_CHARS)?;
        let body = required_text(cmd.body, "body", MAX_POST_BODY_CHARS)?;
        let category = cmd.kind.category_str().to_string();

        if let PostKind::Offer(ref mp) = cmd.kind {
            if mp.brand.trim().is_empty() {
                return Err(ApiError::BadRequest(
                    "发布闲置商品 (offer) 必须提供品牌或来源".to_string(),
                ));
            }
        }

        let cover_image_url = normalize_cover_image_url(cmd.cover_image_url)?;
        self.ensure_text_allowed(&format!("{title}\n{body}\n{}", cmd.tags.join(" ")))?;

        let normalized_cmd = PublishPostCommand {
            campus_id: cmd.campus_id,
            author_id: cmd.author_id.clone(),
            title: title.clone(),
            body: body.clone(),
            kind: cmd.kind.clone(),
            tags: cmd.tags.clone(),
            cover_image_url: cover_image_url.clone(),
            space_id: cmd.space_id,
            idempotency_key: cmd.idempotency_key.clone(),
        };

        let request_hash = if cmd.idempotency_key.is_some() {
            let hash = publish_post_request_hash(&normalized_cmd)?;
            let existing: Option<(Uuid, Option<String>)> =
                sqlx::query_as::<_, (Uuid, Option<String>)>(
                    "SELECT id, idempotency_hash FROM posts WHERE author_id = $1 AND idempotency_key = $2",
                )
                .bind(&cmd.author_id)
                .bind(cmd.idempotency_key.as_deref())
                .fetch_optional(&mut **tx)
                .await
                .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {e}")))?;

            if let Some((existing_id, existing_hash)) = existing {
                if existing_hash.as_deref() != Some(&hash) {
                    return Err(ApiError::Conflict(
                        "Idempotency-Key 重复且请求体不一致".to_string(),
                    ));
                }
                return self
                    .repository
                    .find_by_id_in_tx(tx, cmd.campus_id, existing_id)
                    .await?
                    .ok_or(ApiError::NotFound);
            }
            Some(hash)
        } else {
            None
        };

        let listing_id = if let Some(mp) = cmd.kind.marketplace() {
            let listing_service = crate::services::listing_command::ListingCommandService::new(
                self.pool.clone(),
                self.moderation.clone(),
            );
            let listing_res = listing_service
                .create_in_tx(
                    tx,
                    crate::services::listing_command::CreateListingDraft {
                        campus_id: cmd.campus_id,
                        owner_id: cmd.author_id.clone(),
                        title: title.clone(),
                        category: mp.category.as_str().to_string(),
                        brand: mp.brand.clone(),
                        direction: Some(category.clone()),
                        condition_score: mp.condition_score,
                        suggested_price_cny: mp.suggested_price_cny,
                        defects: mp.defects.clone(),
                        description: mp.description.clone().or_else(|| Some(body.clone())),
                        image_url: cover_image_url.clone(),
                    },
                    cmd.idempotency_key.as_deref(),
                )
                .await?;
            Some(listing_res.id)
        } else {
            None
        };

        let post_res = self
            .repository
            .create_post_in_tx(
                tx,
                NewPost {
                    campus_id: cmd.campus_id,
                    author_id: cmd.author_id.clone(),
                    category,
                    title,
                    body,
                    tags: cmd.tags,
                    image_url: cover_image_url.clone(),
                    listing_id,
                    space_id: cmd.space_id,
                    idempotency_key: cmd.idempotency_key.clone(),
                    idempotency_hash: request_hash,
                },
            )
            .await?;

        if post_res.replayed {
            return self
                .repository
                .find_by_id_in_tx(tx, cmd.campus_id, post_res.id)
                .await?
                .ok_or(ApiError::NotFound);
        }

        let post_id = post_res.id;

        if let Some(ref image_url) = cover_image_url {
            self.moderation
                .submit_image_job_in_tx(
                    tx,
                    cmd.campus_id,
                    &post_id.to_string(),
                    image_url,
                    "post_image",
                )
                .await
                .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {error}")))?;
        }

        self.repository
            .find_by_id_in_tx(tx, cmd.campus_id, post_id)
            .await?
            .ok_or(ApiError::NotFound)
    }

    pub async fn update(
        &self,
        campus_id: Uuid,
        id: Uuid,
        author_id: &str,
        input: EditPost,
    ) -> Result<Post, ApiError> {
        if input.title.is_none()
            && input.body.is_none()
            && input.tags.is_none()
            && input.locked.is_none()
        {
            return Err(ApiError::BadRequest("没有要更新的字段".to_string()));
        }
        let existing = self.get(campus_id, id).await?;
        if existing.author_id != author_id {
            return Err(ApiError::Forbidden);
        }
        // Category is immutable after publish (taxonomy v4).
        let effective_category = existing.category.clone();
        let title = input
            .title
            .map(|value| required_text(value, "title", MAX_POST_TITLE_CHARS))
            .transpose()?;
        let body = input
            .body
            .map(|value| required_text(value, "body", MAX_POST_BODY_CHARS))
            .transpose()?;
        if effective_category == "announcement" && existing.author_id == author_id {
            // Re-check on edits that touch an announcement.
            self.ensure_can_announce(campus_id, author_id).await?;
        }
        let tags = match &input.tags {
            Some(tags) => Some(self.normalize_tags(tags.clone()).await?),
            None => None,
        };
        self.ensure_text_allowed(&format!(
            "{}\n{}\n{}",
            title.as_deref().unwrap_or_default(),
            body.as_deref().unwrap_or_default(),
            tags.as_deref().unwrap_or_default().join(" ")
        ))?;
        let updated = self
            .repository
            .update_post(
                campus_id,
                id,
                author_id,
                &UpdatePostInput {
                    title,
                    body,
                    category: None,
                    tags,
                    locked: input.locked,
                },
            )
            .await?;
        if !updated {
            return Err(ApiError::NotFound);
        }
        self.get(campus_id, id).await
    }

    pub async fn delete(&self, campus_id: Uuid, id: Uuid, author_id: &str) -> Result<(), ApiError> {
        let existing = self.get(campus_id, id).await?;
        if existing.author_id != author_id {
            return Err(ApiError::Forbidden);
        }
        if self
            .repository
            .delete_post(campus_id, id, author_id)
            .await?
        {
            Ok(())
        } else {
            Err(ApiError::NotFound)
        }
    }

    pub async fn list_replies(
        &self,
        campus_id: Uuid,
        post_id: Uuid,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<PostReply>, i64), ApiError> {
        self.get(campus_id, post_id).await?;
        self.repository
            .list_replies(campus_id, post_id, limit, offset)
            .await
    }

    pub async fn create_reply(
        &self,
        campus_id: Uuid,
        post_id: Uuid,
        author_id: &str,
        body: String,
        reply_to_id: Option<Uuid>,
    ) -> Result<PostReply, ApiError> {
        let post = self.get(campus_id, post_id).await?;
        if post.status == "locked" {
            return Err(ApiError::Conflict("该主题已锁定，不能继续回复".to_string()));
        }
        let body = required_text(body, "body", MAX_REPLY_BODY_CHARS)?;
        self.ensure_text_allowed(&body)?;
        match self
            .repository
            .create_reply(campus_id, post_id, author_id, &body, reply_to_id)
            .await?
        {
            Some(reply) => Ok(reply),
            None if reply_to_id.is_some() => Err(ApiError::BadRequest(
                "reply_to_id 必须属于当前主题且仍然可见".to_string(),
            )),
            None => Err(ApiError::Conflict(
                "主题状态已变化，请刷新后重试".to_string(),
            )),
        }
    }

    pub async fn update_reply(
        &self,
        campus_id: Uuid,
        post_id: Uuid,
        reply_id: Uuid,
        author_id: &str,
        body: String,
    ) -> Result<PostReply, ApiError> {
        self.get(campus_id, post_id).await?;
        let existing = self
            .repository
            .find_reply(campus_id, post_id, reply_id)
            .await?
            .ok_or(ApiError::NotFound)?;
        if existing.author_id != author_id {
            return Err(ApiError::Forbidden);
        }
        let body = required_text(body, "body", MAX_REPLY_BODY_CHARS)?;
        self.ensure_text_allowed(&body)?;
        if !self
            .repository
            .update_reply(campus_id, post_id, reply_id, author_id, &body)
            .await?
        {
            return Err(ApiError::NotFound);
        }
        self.repository
            .find_reply(campus_id, post_id, reply_id)
            .await?
            .ok_or(ApiError::NotFound)
    }

    pub async fn delete_reply(
        &self,
        campus_id: Uuid,
        post_id: Uuid,
        reply_id: Uuid,
        author_id: &str,
    ) -> Result<(), ApiError> {
        self.get(campus_id, post_id).await?;
        let existing = self
            .repository
            .find_reply(campus_id, post_id, reply_id)
            .await?
            .ok_or(ApiError::NotFound)?;
        if existing.author_id != author_id {
            return Err(ApiError::Forbidden);
        }
        if self
            .repository
            .delete_reply(campus_id, post_id, reply_id, author_id)
            .await?
        {
            Ok(())
        } else {
            Err(ApiError::NotFound)
        }
    }

    fn ensure_text_allowed(&self, text: &str) -> Result<(), ApiError> {
        let result = self.moderation.check_text(text);
        if result.passed {
            Ok(())
        } else {
            Err(ApiError::ContentViolation(
                result.reason.unwrap_or_default(),
            ))
        }
    }
}

fn normalize_cover_image_url(value: Option<String>) -> Result<Option<String>, ApiError> {
    value
        .map(|url| {
            let url = url.trim().to_string();
            if url.starts_with("http://") || url.starts_with("https://") {
                Ok(url)
            } else {
                Err(ApiError::BadRequest("cover_image_url格式无效".to_string()))
            }
        })
        .transpose()
}

fn required_text(value: String, field: &str, max_chars: usize) -> Result<String, ApiError> {
    let value = value.trim().to_string();
    if value.is_empty() {
        return Err(ApiError::BadRequest(format!("{field} 不能为空")));
    }
    if value.chars().count() > max_chars {
        return Err(ApiError::BadRequest(format!(
            "{field} 不能超过 {max_chars} 个字符"
        )));
    }
    Ok(value)
}

pub fn normalize_post_category(value: Option<&str>) -> Result<PostCategory, ApiError> {
    let value = value.unwrap_or("discussion");
    let trimmed = value.trim();
    PostCategory::parse(trimmed).ok_or_else(|| {
        let allowed: Vec<&str> = PostCategory::ALL.iter().map(|k| k.as_str()).collect();
        ApiError::BadRequest(format!("category 可选值为 {}", allowed.join("、")))
    })
}

async fn ensure_space_member(
    pool: &sqlx::PgPool,
    user_id: &str,
    space_id: Uuid,
) -> Result<(), ApiError> {
    let member: Option<(String,)> =
        sqlx::query_as("SELECT role FROM chat_space_members WHERE space_id = $1 AND user_id = $2")
            .bind(space_id)
            .bind(user_id)
            .fetch_optional(pool)
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {error}")))?;
    match member {
        Some((role,)) if role != "banned" => Ok(()),
        _ => Err(ApiError::Forbidden),
    }
}

async fn ensure_post_visible(
    pool: &sqlx::PgPool,
    post: &Post,
    viewer_id: Option<&str>,
) -> Result<(), ApiError> {
    let Some(space_id) = post.space_id else {
        return Ok(());
    };
    let Some(viewer_id) = viewer_id else {
        return Err(ApiError::NotFound);
    };
    let member: Option<(String,)> =
        sqlx::query_as("SELECT role FROM chat_space_members WHERE space_id = $1 AND user_id = $2")
            .bind(space_id)
            .bind(viewer_id)
            .fetch_optional(pool)
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {error}")))?;
    match member {
        Some((role,)) if role != "banned" => Ok(()),
        _ => Err(ApiError::NotFound),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn post_and_reply_limits_count_characters() {
        assert!(required_text(
            "好".repeat(MAX_POST_TITLE_CHARS),
            "title",
            MAX_POST_TITLE_CHARS
        )
        .is_ok());
        assert!(required_text(
            "好".repeat(MAX_POST_TITLE_CHARS + 1),
            "title",
            MAX_POST_TITLE_CHARS
        )
        .is_err());
    }

    #[test]
    fn post_category_vocabulary_has_all_8_categories() {
        assert_eq!(PostCategory::ALL.len(), 8);
        for cat in PostCategory::ALL {
            assert_eq!(PostCategory::parse(cat.as_str()), Some(cat));
        }
    }

    #[test]
    fn type_level_domain_invariants_make_invalid_states_unrepresentable() {
        let campus_id = Uuid::new_v4();

        // 1. General posts (discussion, announcement, share, question, recruit, team_up)
        // structurally cannot hold marketplace data:
        let general_contents = [
            PostContent::Discussion,
            PostContent::Announcement,
            PostContent::Share,
            PostContent::Question,
            PostContent::Recruit,
            PostContent::TeamUp,
        ];

        for content in general_contents {
            assert!(!content.is_marketplace());
            assert!(content.marketplace().is_none());
            let post = CreatePost::new(campus_id, "user-1", "General Post", "Body text", content);
            assert!(post.marketplace().is_none());
            let cmd = PublishPostCommand::from_input(post);
            assert!(cmd.is_ok());
            let cmd = cmd.unwrap();
            assert!(cmd.kind.marketplace().is_none());
            assert!(!cmd.kind.is_marketplace());
        }

        // 2. Marketplace post must hold valid MarketplaceDetails with MarketplaceCategory enum
        let valid_mp = MarketplaceDetails::new(
            MarketplaceCategory::Electronics,
            "Apple",
            9,
            1299.99,
            vec!["scratch".to_string()],
            Some("Used iPad".to_string()),
        )
        .expect("valid marketplace details");

        let offer_post = CreatePost::new_offer(
            campus_id,
            "user-1",
            "Selling iPad",
            "iPad in good condition",
            valid_mp.clone(),
        );
        assert!(offer_post.marketplace().is_some());
        assert_eq!(
            offer_post.marketplace().unwrap().category,
            MarketplaceCategory::Electronics
        );

        let cmd = PublishPostCommand::from_input(offer_post).expect("valid offer command");
        assert_eq!(cmd.kind.category(), PostCategory::Offer);
        assert!(cmd.kind.is_marketplace());
        assert_eq!(cmd.kind.marketplace().unwrap().brand, "Apple");

        let wanted_post = CreatePost::new_wanted(
            campus_id,
            "user-2",
            "Looking for textbook",
            "Need calculus book",
            valid_mp,
        );
        assert!(wanted_post.marketplace().is_some());
        assert_eq!(wanted_post.category(), PostCategory::Wanted);
    }

    #[test]
    fn marketplace_details_enforces_range_and_pricing_invariants() {
        // Invalid condition score (< 1 or > 10)
        let err_score_low = MarketplaceDetails::new(
            MarketplaceCategory::Books,
            "Publisher",
            0,
            50.0,
            vec![],
            None,
        );
        assert!(err_score_low.is_err());

        let err_score_high = MarketplaceDetails::new(
            MarketplaceCategory::Books,
            "Publisher",
            11,
            50.0,
            vec![],
            None,
        );
        assert!(err_score_high.is_err());

        // Negative or invalid price
        let err_price_neg = MarketplaceDetails::new(
            MarketplaceCategory::Books,
            "Publisher",
            8,
            -1.0,
            vec![],
            None,
        );
        assert!(err_price_neg.is_err());

        let err_price_nan = MarketplaceDetails::new(
            MarketplaceCategory::Books,
            "Publisher",
            8,
            f64::NAN,
            vec![],
            None,
        );
        assert!(err_price_nan.is_err());

        // Valid details
        let ok_details = MarketplaceDetails::new(
            MarketplaceCategory::Books,
            "Publisher",
            10,
            0.0, // Free items allowed (0.0 CNY)
            vec![],
            None,
        );
        assert!(ok_details.is_ok());
    }

    #[test]
    fn publish_post_command_enforces_offer_brand_and_text_invariants() {
        let campus_id = Uuid::new_v4();

        // Offer requires non-empty brand
        let empty_brand_mp = MarketplaceDetails::new(
            MarketplaceCategory::Electronics,
            "   ",
            8,
            100.0,
            vec![],
            None,
        )
        .expect("constructed details");

        let offer_err = PublishPostCommand::new(
            campus_id,
            "user-1",
            "Valid Title",
            "Valid Body",
            PostContent::Offer(empty_brand_mp),
        );
        assert!(offer_err.is_err());

        // Empty title or body rejected
        let title_err = PublishPostCommand::new(
            campus_id,
            "user-1",
            "   ",
            "Valid Body",
            PostContent::Discussion,
        );
        assert!(title_err.is_err());

        let body_err = PublishPostCommand::new(
            campus_id,
            "user-1",
            "Valid Title",
            "   ",
            PostContent::Discussion,
        );
        assert!(body_err.is_err());
    }
}
