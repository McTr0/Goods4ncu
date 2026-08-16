//! Business rules for discussion/listing posts and threaded replies.

use crate::api::error::ApiError;
use crate::repositories::{
    NewDiscussionPost, Post, PostFilter, PostReply, PostRepository, PostgresPostRepository,
    UpdateDiscussionPost,
};
use crate::services::moderation::ModerationService;
use sqlx::PgPool;
use std::collections::HashSet;
use uuid::Uuid;

pub const MAX_POST_TITLE_CHARS: usize = 300;
pub const MAX_POST_BODY_CHARS: usize = 50_000;
pub const MAX_REPLY_BODY_CHARS: usize = 20_000;
pub const MAX_CATEGORY_CHARS: usize = 80;
pub const MAX_TAGS: usize = 5;
pub const MAX_TAG_CHARS: usize = 32;

#[derive(Debug, Clone)]
pub struct CreateDiscussion {
    pub campus_id: Uuid,
    pub author_id: String,
    pub title: String,
    pub body: String,
    pub category: Option<String>,
    pub tags: Vec<String>,
}

#[derive(Debug, Clone, Default)]
pub struct EditDiscussion {
    pub title: Option<String>,
    pub body: Option<String>,
    pub category: Option<String>,
    pub tags: Option<Vec<String>>,
    pub locked: Option<bool>,
}

#[derive(Clone)]
pub struct PostService {
    repository: PostgresPostRepository,
    moderation: ModerationService,
}

impl PostService {
    pub fn new(pool: PgPool, moderation: ModerationService) -> Self {
        Self {
            repository: PostgresPostRepository::new(pool),
            moderation,
        }
    }

    #[allow(dead_code)]
    pub async fn list(
        &self,
        campus_id: Uuid,
        filter: &PostFilter,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<Post>, i64), ApiError> {
        self.repository.list(campus_id, filter, limit, offset).await
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
            self.repository.list(campus_id, filter, limit, offset).await
        }
    }

    pub async fn get(&self, campus_id: Uuid, id: Uuid) -> Result<Post, ApiError> {
        self.repository
            .find_by_id(campus_id, id)
            .await?
            .ok_or(ApiError::NotFound)
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

    pub async fn create(&self, input: CreateDiscussion) -> Result<Post, ApiError> {
        let title = required_text(input.title, "title", MAX_POST_TITLE_CHARS)?;
        let body = required_text(input.body, "body", MAX_POST_BODY_CHARS)?;
        let category = normalize_category(input.category)?;
        let tags = normalize_tags(input.tags)?;
        self.ensure_text_allowed(&format!("{title}\n{body}\n{}", tags.join(" ")))?;
        self.repository
            .create_discussion(NewDiscussionPost {
                campus_id: input.campus_id,
                author_id: input.author_id,
                category,
                title,
                body,
                tags,
            })
            .await
    }

    pub async fn update(
        &self,
        campus_id: Uuid,
        id: Uuid,
        author_id: &str,
        input: EditDiscussion,
    ) -> Result<Post, ApiError> {
        if input.title.is_none()
            && input.body.is_none()
            && input.category.is_none()
            && input.tags.is_none()
            && input.locked.is_none()
        {
            return Err(ApiError::BadRequest("没有要更新的字段".to_string()));
        }
        let existing = self.get(campus_id, id).await?;
        if existing.post_type == "listing" {
            return Err(ApiError::BadRequest(
                "商品帖子请通过 listing API 更新".to_string(),
            ));
        }
        if existing.author_id != author_id {
            return Err(ApiError::Forbidden);
        }
        let title = input
            .title
            .map(|value| required_text(value, "title", MAX_POST_TITLE_CHARS))
            .transpose()?;
        let body = input
            .body
            .map(|value| required_text(value, "body", MAX_POST_BODY_CHARS))
            .transpose()?;
        let category = input
            .category
            .map(|value| normalize_category(Some(value)))
            .transpose()?;
        let tags = input.tags.map(normalize_tags).transpose()?;
        self.ensure_text_allowed(&format!(
            "{}\n{}\n{}",
            title.as_deref().unwrap_or_default(),
            body.as_deref().unwrap_or_default(),
            tags.as_deref().unwrap_or_default().join(" ")
        ))?;
        let updated = self
            .repository
            .update_discussion(
                campus_id,
                id,
                author_id,
                &UpdateDiscussionPost {
                    title,
                    body,
                    category,
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
        if existing.post_type == "listing" {
            return Err(ApiError::BadRequest(
                "商品帖子请通过 listing API 删除".to_string(),
            ));
        }
        if existing.author_id != author_id {
            return Err(ApiError::Forbidden);
        }
        if self
            .repository
            .delete_discussion(campus_id, id, author_id)
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

fn normalize_category(value: Option<String>) -> Result<String, ApiError> {
    let value = value.unwrap_or_else(|| "general".to_string());
    required_text(value, "category", MAX_CATEGORY_CHARS)
}

fn normalize_tags(tags: Vec<String>) -> Result<Vec<String>, ApiError> {
    let mut normalized = Vec::new();
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
        let key = tag.to_lowercase();
        if seen.insert(key) {
            normalized.push(tag);
        }
    }
    if normalized.len() > MAX_TAGS {
        return Err(ApiError::BadRequest(format!(
            "每个主题最多 {MAX_TAGS} 个标签"
        )));
    }
    Ok(normalized)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tags_are_trimmed_deduplicated_and_unprefixed() {
        assert_eq!(
            normalize_tags(vec![
                " #Rust ".to_string(),
                "rust".to_string(),
                "campus".to_string(),
            ])
            .unwrap(),
            vec!["Rust", "campus"]
        );
    }

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
    fn category_defaults_to_general() {
        assert_eq!(normalize_category(None).unwrap(), "general");
    }
}
