//! Campus post/topic API.
//!
//! Listings appear here as `post_type=listing` topics but continue to be
//! created and edited through the backwards-compatible listing API.

use axum::{
    extract::{Path, Query, State},
    response::Response,
    Json,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::api::agent_plans::no_store_json;
use crate::api::error::ApiError;
use crate::api::session::{OptionalSession, VerifiedTenant};
use crate::api::{normalize_platform_media_url, AppState};
use crate::repositories::{ListingPostPreview, Post, PostFilter, PostReply, PostSort};
use crate::services::campus::CampusService;
use crate::services::post::{CreatePost, EditPost, PostService};

pub const UNIFIED_POST_RANKING_VERSION: &str = "2026.08-post-v2";

#[derive(Debug, Deserialize)]
pub struct PostListQuery {
    pub limit: Option<i64>,
    pub offset: Option<i64>,
    /// offer | wanted | discussion (the post kind). Omit for all.
    pub category: Option<String>,
    pub space_id: Option<Uuid>,
    pub search: Option<String>,
    pub sort: Option<String>,
    #[serde(default)]
    pub tags: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ReplyListQuery {
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

#[derive(Debug, Deserialize)]
pub struct CreatePostRequest {
    pub title: String,
    pub body: String,
    /// offer | wanted | discussion. Defaults to discussion.
    pub category: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    pub cover_image_url: Option<String>,
    pub listing_id: Option<String>,
    pub space_id: Option<Uuid>,
    #[serde(default)]
    pub attributes: serde_json::Value,
}

#[derive(Debug, Deserialize)]
pub struct UpdatePostRequest {
    pub title: Option<String>,
    pub body: Option<String>,
    pub category: Option<String>,
    pub tags: Option<Vec<String>>,
    pub locked: Option<bool>,
    pub attributes: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
pub struct CreateReplyRequest {
    pub body: String,
    pub reply_to_id: Option<Uuid>,
}

#[derive(Debug, Deserialize)]
pub struct UpdateReplyRequest {
    pub body: String,
}

#[derive(Debug, Serialize)]
pub struct PostAuthor {
    pub id: String,
    pub username: String,
    pub avatar_url: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct PostSummary {
    pub id: Uuid,
    pub category: String,
    pub space_id: Option<Uuid>,
    pub title: String,
    pub body_excerpt: String,
    pub tags: Vec<String>,
    pub listing_id: Option<String>,
    pub cover_image_url: Option<String>,
    pub author: PostAuthor,
    pub reply_count: i32,
    pub status: String,
    pub attributes: serde_json::Value,
    pub fertilizer_count: i32,
    pub is_locked: bool,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub updated_at: chrono::DateTime<chrono::Utc>,
    pub last_activity_at: chrono::DateTime<chrono::Utc>,
    pub rank_reason: String,
    pub rank_source: String,
    pub ranking_score: Option<f64>,
    pub listing: Option<ListingPostPreviewView>,
}

#[derive(Debug, Serialize)]
pub struct PostDetail {
    pub id: Uuid,
    pub category: String,
    pub space_id: Option<Uuid>,
    pub title: String,
    pub body: String,
    pub tags: Vec<String>,
    pub listing_id: Option<String>,
    pub cover_image_url: Option<String>,
    pub author: PostAuthor,
    pub reply_count: i32,
    pub status: String,
    pub attributes: serde_json::Value,
    pub fertilizer_count: i32,
    pub is_locked: bool,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub updated_at: chrono::DateTime<chrono::Utc>,
    pub last_activity_at: chrono::DateTime<chrono::Utc>,
    pub listing: Option<ListingPostPreviewView>,
}

#[derive(Debug, Serialize)]
pub struct ListingPostPreviewView {
    pub id: String,
    pub content_revision: i64,
    pub title: String,
    pub category: String,
    pub brand: String,
    pub direction: String,
    pub condition_score: i32,
    pub suggested_price_cny: f64,
    pub status: String,
    pub image_url: Option<String>,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Serialize)]
pub struct ReplyView {
    pub id: Uuid,
    pub post_id: Uuid,
    pub body: String,
    pub reply_to_id: Option<Uuid>,
    pub author: PostAuthor,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub updated_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Serialize)]
pub struct PostListResponse {
    pub items: Vec<PostSummary>,
    pub total: i64,
    pub limit: i64,
    pub offset: i64,
    pub ranking_version: &'static str,
}

#[derive(Debug, Serialize)]
pub struct ReplyListResponse {
    pub items: Vec<ReplyView>,
    pub total: i64,
    pub limit: i64,
    pub offset: i64,
}

async fn resolve_read_campus(state: &AppState, session: OptionalSession) -> Result<Uuid, ApiError> {
    let campus = CampusService::new(state.infra.db.clone());
    match session.0 {
        Some(session) => {
            campus
                .resolve_session_campus(&session.user_id, session.campus_id)
                .await
        }
        None => campus.default_public_campus_id().await,
    }
}

fn post_service(state: &AppState) -> PostService {
    PostService::new(state.infra.db.clone(), state.infra.moderation.clone())
}

fn normalize_filter(query: &PostListQuery) -> Result<PostFilter, ApiError> {
    let sort = match query.sort.as_deref().map(str::trim) {
        None | Some("") | Some("active") => PostSort::Active,
        Some("latest") => PostSort::Latest,
        Some("replies") => PostSort::Replies,
        Some("for_you") => PostSort::ForYou,
        Some(_) => {
            return Err(ApiError::BadRequest(
                "sort 可选值为 active、latest、replies、for_you".to_string(),
            ))
        }
    };
    let category = match query.category.as_deref().map(str::trim) {
        None | Some("") | Some("all") => None,
        Some(value) if crate::categories::is_valid_post_category(value) => Some(value.to_string()),
        Some(_) => {
            return Err(ApiError::BadRequest(
                "category 可选值为 all、offer、wanted、discussion".to_string(),
            ))
        }
    };
    Ok(PostFilter {
        category,
        space_id: query.space_id,
        search: normalized_optional_query(&query.search, "search", 200)?,
        tags: query
            .tags
            .as_deref()
            .unwrap_or_default()
            .split(',')
            .map(str::trim)
            .filter(|tag| !tag.is_empty())
            .map(str::to_string)
            .collect(),
        sort,
    })
}

fn normalized_optional_query(
    value: &Option<String>,
    field: &str,
    max_chars: usize,
) -> Result<Option<String>, ApiError> {
    let value = value
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    if value
        .as_ref()
        .is_some_and(|value| value.chars().count() > max_chars)
    {
        return Err(ApiError::BadRequest(format!(
            "{field} 不能超过 {max_chars} 个字符"
        )));
    }
    Ok(value)
}

fn clamp_page(limit: Option<i64>, offset: Option<i64>) -> (i64, i64) {
    (limit.unwrap_or(20).clamp(1, 50), offset.unwrap_or(0).max(0))
}

fn summary_view(state: &AppState, post: Post, _viewer_id: Option<&str>) -> PostSummary {
    let listing = post
        .listing
        .map(|listing| listing_preview_view(state, listing));
    PostSummary {
        id: post.id,
        category: post.category.clone(),
        space_id: post.space_id,
        title: post.title,
        body_excerpt: excerpt(&post.body, 180),
        tags: post.tags,
        listing_id: post.listing_id,
        cover_image_url: state.public_media_url(post.cover_image_url),
        author: PostAuthor {
            id: post.author_id,
            username: post.author_username,
            avatar_url: state.public_media_url(post.author_avatar_url),
        },
        reply_count: post.reply_count,
        is_locked: post.status == "locked",
        status: post.status.clone(),
        attributes: post.attributes.clone(),
        fertilizer_count: post.fertilizer_count,
        created_at: post.created_at,
        updated_at: post.updated_at,
        last_activity_at: post.last_activity_at,
        rank_reason: post.rank_reason,
        rank_source: post.rank_source,
        ranking_score: post.ranking_score,
        listing,
    }
}

pub(crate) fn detail_view(state: &AppState, post: Post, _viewer_id: Option<&str>) -> PostDetail {
    let listing = post
        .listing
        .map(|listing| listing_preview_view(state, listing));
    PostDetail {
        id: post.id,
        category: post.category,
        space_id: post.space_id,
        title: post.title,
        body: post.body,
        tags: post.tags,
        listing_id: post.listing_id,
        cover_image_url: state.public_media_url(post.cover_image_url),
        author: PostAuthor {
            id: post.author_id,
            username: post.author_username,
            avatar_url: state.public_media_url(post.author_avatar_url),
        },
        reply_count: post.reply_count,
        is_locked: post.status == "locked",
        status: post.status.clone(),
        attributes: post.attributes.clone(),
        fertilizer_count: post.fertilizer_count,
        created_at: post.created_at,
        updated_at: post.updated_at,
        last_activity_at: post.last_activity_at,
        listing,
    }
}

fn listing_preview_view(state: &AppState, listing: ListingPostPreview) -> ListingPostPreviewView {
    ListingPostPreviewView {
        id: listing.id,
        content_revision: listing.content_revision,
        title: listing.title,
        category: listing.category,
        brand: listing.brand,
        direction: listing.direction,
        condition_score: listing.condition_score,
        suggested_price_cny: crate::utils::cents_to_yuan(listing.suggested_price_cny),
        status: listing.status,
        image_url: state.public_media_url(listing.image_url),
        created_at: listing.created_at,
    }
}

fn reply_view(state: &AppState, reply: PostReply) -> ReplyView {
    ReplyView {
        id: reply.id,
        post_id: reply.post_id,
        body: reply.body,
        reply_to_id: reply.reply_to_id,
        author: PostAuthor {
            id: reply.author_id,
            username: reply.author_username,
            avatar_url: state.public_media_url(reply.author_avatar_url),
        },
        created_at: reply.created_at,
        updated_at: reply.updated_at,
    }
}

fn excerpt(body: &str, max_chars: usize) -> String {
    let mut chars = body.chars();
    let excerpt: String = chars.by_ref().take(max_chars).collect();
    if chars.next().is_some() {
        format!("{excerpt}…")
    } else {
        excerpt
    }
}

/// GET /api/posts — public campus topic feed.
/// GET /api/posts/categories — enabled taxonomy for pickers (extensible).
pub async fn list_categories(State(state): State<AppState>) -> Result<Response, ApiError> {
    let rows: Vec<(String, String, String, String, i32)> = sqlx::query_as(
        "SELECT key, label_zh, label_en, kind, sort_order
         FROM post_categories WHERE enabled ORDER BY sort_order ASC",
    )
    .fetch_all(&state.infra.db)
    .await
    .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {error}")))?;
    let categories: Vec<serde_json::Value> = rows
        .into_iter()
        .map(|(key, label_zh, label_en, kind, _sort)| {
            serde_json::json!({
                "key": key,
                "label_zh": label_zh,
                "label_en": label_en,
                "kind": kind,
            })
        })
        .collect();
    Ok(no_store_json(
        serde_json::json!({ "categories": categories }),
    ))
}

pub async fn list_posts(
    State(state): State<AppState>,
    session: OptionalSession,
    Query(query): Query<PostListQuery>,
) -> Result<Json<PostListResponse>, ApiError> {
    let viewer_id = session.0.as_ref().map(|session| session.user_id.clone());
    let campus_id = resolve_read_campus(&state, session).await?;
    let filter = normalize_filter(&query)?;
    let (limit, offset) = clamp_page(query.limit, query.offset);
    let (posts, total) = post_service(&state)
        .list_for_viewer(campus_id, viewer_id.as_deref(), &filter, limit, offset)
        .await?;
    Ok(Json(PostListResponse {
        items: posts
            .into_iter()
            .map(|post| summary_view(&state, post, viewer_id.as_deref()))
            .collect(),
        total,
        limit,
        offset,
        ranking_version: UNIFIED_POST_RANKING_VERSION,
    }))
}

/// GET /api/posts/:id — public topic detail.
pub async fn get_post(
    State(state): State<AppState>,
    session: OptionalSession,
    Path(id): Path<Uuid>,
) -> Result<Json<PostDetail>, ApiError> {
    let viewer_id = session.0.as_ref().map(|session| session.user_id.clone());
    let campus_id = resolve_read_campus(&state, session).await?;
    let post = post_service(&state)
        .get_for_viewer(campus_id, id, viewer_id.as_deref())
        .await?;
    Ok(Json(detail_view(&state, post, viewer_id.as_deref())))
}

/// GET /api/posts/by-listing/:listing_id — stable listing-to-topic lookup.
pub async fn get_post_by_listing(
    State(state): State<AppState>,
    session: OptionalSession,
    Path(listing_id): Path<String>,
) -> Result<Json<PostDetail>, ApiError> {
    let viewer_id = session.0.as_ref().map(|session| session.user_id.clone());
    let campus_id = resolve_read_campus(&state, session).await?;
    let post = post_service(&state)
        .get_by_listing_for_viewer(campus_id, &listing_id, viewer_id.as_deref())
        .await?;
    Ok(Json(detail_view(&state, post, viewer_id.as_deref())))
}

/// POST /api/posts — create a discussion topic.
pub async fn create_post(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Json(payload): Json<CreatePostRequest>,
) -> Result<Json<PostDetail>, ApiError> {
    let cover_image_url =
        normalize_platform_media_url(&state, payload.cover_image_url, "cover_image_url")?;
    let post = post_service(&state)
        .create(CreatePost {
            campus_id: tenant.campus_id,
            author_id: tenant.session.user_id.clone(),
            title: payload.title,
            body: payload.body,
            category: payload.category.unwrap_or_else(|| "discussion".to_string()),
            tags: payload.tags,
            cover_image_url,
            listing_id: payload.listing_id,
            space_id: payload.space_id,
            attributes: payload.attributes,
        })
        .await?;
    Ok(Json(detail_view(
        &state,
        post,
        Some(&tenant.session.user_id),
    )))
}

/// PUT /api/posts/:id — owner-only discussion edit/lock.
pub async fn update_post(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(id): Path<Uuid>,
    Json(payload): Json<UpdatePostRequest>,
) -> Result<Json<PostDetail>, ApiError> {
    let post = post_service(&state)
        .update(
            tenant.campus_id,
            id,
            &tenant.session.user_id,
            EditPost {
                title: payload.title,
                body: payload.body,
                category: payload.category,
                tags: payload.tags,
                locked: payload.locked,
                attributes: payload.attributes,
            },
        )
        .await?;
    Ok(Json(detail_view(
        &state,
        post,
        Some(&tenant.session.user_id),
    )))
}

/// DELETE /api/posts/:id — owner-only soft delete for discussions.
pub async fn delete_post(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    post_service(&state)
        .delete(tenant.campus_id, id, &tenant.session.user_id)
        .await?;
    Ok(Json(serde_json::json!({"id": id, "status": "deleted"})))
}

/// GET /api/posts/:id/replies — chronological topic replies.
pub async fn list_replies(
    State(state): State<AppState>,
    session: OptionalSession,
    Path(post_id): Path<Uuid>,
    Query(query): Query<ReplyListQuery>,
) -> Result<Json<ReplyListResponse>, ApiError> {
    let campus_id = resolve_read_campus(&state, session).await?;
    let (limit, offset) = clamp_page(query.limit, query.offset);
    let (replies, total) = post_service(&state)
        .list_replies(campus_id, post_id, limit, offset)
        .await?;
    Ok(Json(ReplyListResponse {
        items: replies
            .into_iter()
            .map(|reply| reply_view(&state, reply))
            .collect(),
        total,
        limit,
        offset,
    }))
}

/// POST /api/posts/:id/replies — reply to a topic or another visible reply.
pub async fn create_reply(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(post_id): Path<Uuid>,
    Json(payload): Json<CreateReplyRequest>,
) -> Result<Json<ReplyView>, ApiError> {
    let reply = post_service(&state)
        .create_reply(
            tenant.campus_id,
            post_id,
            &tenant.session.user_id,
            payload.body,
            payload.reply_to_id,
        )
        .await?;
    Ok(Json(reply_view(&state, reply)))
}

/// PUT /api/posts/:post_id/replies/:reply_id — author-only reply edit.
pub async fn update_reply(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path((post_id, reply_id)): Path<(Uuid, Uuid)>,
    Json(payload): Json<UpdateReplyRequest>,
) -> Result<Json<ReplyView>, ApiError> {
    let reply = post_service(&state)
        .update_reply(
            tenant.campus_id,
            post_id,
            reply_id,
            &tenant.session.user_id,
            payload.body,
        )
        .await?;
    Ok(Json(reply_view(&state, reply)))
}

/// DELETE /api/posts/:post_id/replies/:reply_id — author-only soft delete.
pub async fn delete_reply(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path((post_id, reply_id)): Path<(Uuid, Uuid)>,
) -> Result<Json<serde_json::Value>, ApiError> {
    post_service(&state)
        .delete_reply(tenant.campus_id, post_id, reply_id, &tenant.session.user_id)
        .await?;
    Ok(Json(
        serde_json::json!({"id": reply_id, "post_id": post_id, "status": "deleted"}),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn excerpt_is_unicode_safe_and_marks_truncation() {
        assert_eq!(excerpt("校园闲置", 2), "校园…");
        assert_eq!(excerpt("校园", 2), "校园");
    }

    #[test]
    fn validates_filter_vocabulary() {
        let valid = normalize_filter(&PostListQuery {
            limit: None,
            offset: None,
            category: Some("offer".to_string()),
            space_id: None,
            search: None,
            tags: None,
            sort: Some("replies".to_string()),
        })
        .unwrap();
        assert_eq!(valid.category.as_deref(), Some("offer"));
        assert_eq!(valid.sort, PostSort::Replies);

        let all = normalize_filter(&PostListQuery {
            limit: None,
            offset: None,
            category: Some("all".to_string()),
            space_id: None,
            search: None,
            tags: None,
            sort: Some("for_you".to_string()),
        })
        .unwrap();
        assert_eq!(all.category, None);
        assert_eq!(all.sort, PostSort::ForYou);

        let invalid = normalize_filter(&PostListQuery {
            limit: None,
            offset: None,
            category: Some("listing".to_string()),
            space_id: None,
            search: None,
            tags: None,
            sort: None,
        });
        assert!(invalid.is_err());
    }

    #[test]
    fn pagination_is_bounded() {
        assert_eq!(clamp_page(Some(500), Some(-3)), (50, 0));
    }
}
