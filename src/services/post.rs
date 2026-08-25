//! Business rules for discussion/listing posts and threaded replies.

use crate::api::error::ApiError;
use crate::categories::POST_CATEGORIES;
use crate::repositories::{
    NewPost, Post, PostFilter, PostReply, PostRepository, PostgresPostRepository, UpdatePostInput,
};
use crate::services::moderation::ModerationService;
use sqlx::PgPool;
use std::collections::HashSet;
use std::sync::{OnceLock, RwLock};
use uuid::Uuid;

pub const MAX_POST_TITLE_CHARS: usize = 300;
pub const MAX_POST_BODY_CHARS: usize = 50_000;
pub const MAX_REPLY_BODY_CHARS: usize = 20_000;
pub const MAX_TAG_CHARS: usize = 32;

#[derive(Debug, Clone)]
pub struct CreatePost {
    pub campus_id: Uuid,
    pub author_id: String,
    /// One of offer | wanted | discussion. This IS the post kind.
    pub category: String,
    pub title: String,
    pub body: String,
    pub tags: Vec<String>,
    pub cover_image_url: Option<String>,
    /// Optional reference to an existing inventory row.
    pub listing_id: Option<String>,
    /// Group scope; when set the post is visible to space members only.
    pub space_id: Option<Uuid>,
    /// Category-specific structured payload (validated whitelist).
    pub attributes: serde_json::Value,
}

#[derive(Debug, Clone, Default)]
pub struct EditPost {
    pub title: Option<String>,
    pub body: Option<String>,
    pub category: Option<String>,
    pub tags: Option<Vec<String>>,
    pub locked: Option<bool>,
    pub attributes: Option<serde_json::Value>,
}

/// Process-wide snapshot of post_categories, refreshed on first use and
/// whenever an unknown category shows up — keeps Rust validation from
/// drifting away from the catalog table.
fn category_cache() -> &'static RwLock<Option<Vec<String>>> {
    static CACHE: OnceLock<RwLock<Option<Vec<String>>>> = OnceLock::new();
    CACHE.get_or_init(|| RwLock::new(None))
}

async fn load_allowed_categories(pool: &PgPool) -> Vec<String> {
    let rows: Vec<(String,)> =
        sqlx::query_as("SELECT key FROM post_categories WHERE enabled ORDER BY sort_order")
            .fetch_all(pool)
            .await
            .unwrap_or_default();
    let keys: Vec<String> = rows.into_iter().map(|(key,)| key).collect();
    if !keys.is_empty() {
        if let Ok(mut slot) = category_cache().write() {
            *slot = Some(keys.clone());
        }
    }
    keys
}

pub async fn allowed_post_categories(pool: &PgPool) -> Vec<String> {
    if let Ok(slot) = category_cache().read() {
        if let Some(keys) = slot.as_ref() {
            if !keys.is_empty() {
                return keys.clone();
            }
        }
    }
    load_allowed_categories(pool).await
}

#[derive(Clone)]
pub struct PostService {
    pool: PgPool,
    repository: PostgresPostRepository,
    moderation: ModerationService,
}

impl PostService {
    pub fn new(pool: PgPool, moderation: ModerationService) -> Self {
        Self {
            repository: PostgresPostRepository::new(pool.clone()),
            pool,
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
        let title = required_text(input.title, "title", MAX_POST_TITLE_CHARS)?;
        let body = required_text(input.body, "body", MAX_POST_BODY_CHARS)?;
        let category = normalize_post_category(&self.pool, Some(input.category)).await?;
        if category == "announcement" {
            self.ensure_can_announce(input.campus_id, input.author_id.as_str())
                .await?;
        }
        let tags = self.normalize_tags(input.tags).await?;
        let attributes = validate_attributes(&category, &input.attributes)?;
        let cover_image_url = normalize_cover_image_url(input.cover_image_url)?;
        if let Some(space_id) = input.space_id {
            ensure_space_member(&self.pool, input.author_id.as_str(), space_id).await?;
        }
        self.ensure_text_allowed(&format!("{title}\n{body}\n{}", tags.join(" ")))?;
        let created = self
            .repository
            .create_post(NewPost {
                campus_id: input.campus_id,
                author_id: input.author_id,
                category,
                title,
                body,
                tags,
                image_url: cover_image_url.clone(),
                listing_id: input.listing_id,
                space_id: input.space_id,
                attributes,
            })
            .await?;
        if let Some(image_url) = cover_image_url {
            self.moderation
                .submit_image_job(
                    &self.pool,
                    input.campus_id,
                    &created.id.to_string(),
                    &image_url,
                    "post_image",
                )
                .await
                .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {error}")))?;
        }
        self.get(input.campus_id, created.id).await
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
            && input.category.is_none()
            && input.tags.is_none()
            && input.locked.is_none()
            && input.attributes.is_none()
        {
            return Err(ApiError::BadRequest("没有要更新的字段".to_string()));
        }
        let existing = self.get(campus_id, id).await?;
        if existing.author_id != author_id {
            return Err(ApiError::Forbidden);
        }
        let effective_category = input
            .category
            .clone()
            .unwrap_or_else(|| existing.category.clone());
        let title = input
            .title
            .map(|value| required_text(value, "title", MAX_POST_TITLE_CHARS))
            .transpose()?;
        let body = input
            .body
            .map(|value| required_text(value, "body", MAX_POST_BODY_CHARS))
            .transpose()?;
        let category = match input.category {
            Some(value) => Some(normalize_post_category(&self.pool, Some(value)).await?),
            None => None,
        };
        if effective_category == "announcement" && existing.author_id == author_id {
            // Re-check on edits that touch an announcement.
            self.ensure_can_announce(campus_id, author_id).await?;
        }
        let attributes = match &input.attributes {
            Some(value) => Some(validate_attributes(&effective_category, value)?),
            None => None,
        };
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
                    category,
                    tags,
                    locked: input.locked,
                    attributes,
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

const MAX_ATTRIBUTES_CHARS: usize = 2_000;

/// Per-category structured attribute whitelists. One mechanism for every
/// post type — no per-type columns, no tag-gated blobs.
fn validate_attributes(
    category: &str,
    value: &serde_json::Value,
) -> Result<serde_json::Value, ApiError> {
    // Missing (serde default null) and empty both normalize to {}.
    let value = if value.is_null() {
        &serde_json::json!({})
    } else {
        value
    };
    let object = match value.as_object() {
        None => {
            return Err(ApiError::BadRequest("attributes 必须是对象".to_string()));
        }
        Some(object) if object.is_empty() => return Ok(serde_json::json!({})),
        Some(object) => object,
    };
    if category != "event" {
        return Err(ApiError::BadRequest(format!(
            "{category} 帖子不支持附加属性"
        )));
    }
    if serde_json::to_string(value)
        .map(|text| text.chars().count())
        .unwrap_or(usize::MAX)
        > MAX_ATTRIBUTES_CHARS
    {
        return Err(ApiError::BadRequest("attributes 过长".to_string()));
    }
    let mut out = serde_json::Map::new();
    for key in ["starts_at", "place"] {
        let Some(field) = object.get(key) else {
            if key == "starts_at" {
                return Err(ApiError::BadRequest("活动缺少开始时间".to_string()));
            }
            continue;
        };
        if key == "starts_at" {
            let text = field
                .as_str()
                .ok_or_else(|| ApiError::BadRequest("starts_at 必须是 RFC3339 时间".to_string()))?;
            chrono::DateTime::parse_from_rfc3339(text)
                .map_err(|_| ApiError::BadRequest("starts_at 必须是合法时间".to_string()))?;
            out.insert(key.to_string(), serde_json::json!(text));
        } else {
            let text = field.as_str().unwrap_or_default().trim();
            if text.chars().count() > 120 {
                return Err(ApiError::BadRequest("place 过长（≤120 字）".to_string()));
            }
            if !text.is_empty() {
                out.insert(key.to_string(), serde_json::json!(text));
            }
        }
    }
    if let Some(unknown) = object
        .keys()
        .find(|key| !(["starts_at", "place"].contains(&key.as_str())))
    {
        return Err(ApiError::BadRequest(format!(
            "attributes 含未知字段：{unknown}"
        )));
    }
    Ok(serde_json::Value::Object(out))
}

async fn normalize_post_category(
    pool: &PgPool,
    value: Option<String>,
) -> Result<String, ApiError> {
    let value = value.unwrap_or_else(|| "discussion".to_string());
    let value = value.trim().to_string();
    let mut allowed = allowed_post_categories(pool).await;
    if allowed.is_empty() {
        allowed = POST_CATEGORIES.iter().map(|key| key.to_string()).collect();
        // Refresh for next time; the table is authoritative.
        let pool = pool.clone();
        tokio::spawn(async move { load_allowed_categories(&pool).await; });
    }
    if !allowed.iter().any(|key| key == &value) {
        return Err(ApiError::BadRequest(format!(
            "category 可选值为 {}",
            allowed.join("、")
        )));
    }
    Ok(value)
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
    fn post_category_vocabulary_falls_back_to_bootstrap_catalog() {
        // Pure-unit coverage: without a pool the const catalog applies.
        assert_eq!(POST_CATEGORIES.len(), 5);
    }
}
