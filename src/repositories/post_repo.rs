//! PostgreSQL data access for campus posts and their replies.

use crate::api::error::ApiError;
use sqlx::{postgres::PgRow, PgPool, Row};
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq)]
pub struct Post {
    pub id: Uuid,
    pub campus_id: Uuid,
    pub post_type: String,
    pub category: String,
    pub title: String,
    pub body: String,
    pub tags: Vec<String>,
    pub listing_id: Option<String>,
    pub cover_image_url: Option<String>,
    pub author_id: String,
    pub author_username: String,
    pub author_avatar_url: Option<String>,
    pub reply_count: i32,
    pub status: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub updated_at: chrono::DateTime<chrono::Utc>,
    pub last_activity_at: chrono::DateTime<chrono::Utc>,
    /// Explainable rank metadata. It is populated for `sort=for_you` and
    /// carries a stable fallback explanation for the legacy sorts.
    pub rank_reason: String,
    pub rank_source: String,
    pub ranking_score: Option<f64>,
    pub listing: Option<ListingPostPreview>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ListingPostPreview {
    pub id: String,
    pub content_revision: i64,
    pub title: String,
    pub category: String,
    pub brand: String,
    pub direction: String,
    pub condition_score: i32,
    pub suggested_price_cny: i64,
    pub status: String,
    pub image_url: Option<String>,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PostReply {
    pub id: Uuid,
    pub post_id: Uuid,
    pub body: String,
    pub reply_to_id: Option<Uuid>,
    pub author_id: String,
    pub author_username: String,
    pub author_avatar_url: Option<String>,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub updated_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Clone)]
pub struct NewDiscussionPost {
    pub campus_id: Uuid,
    pub author_id: String,
    pub category: String,
    pub title: String,
    pub body: String,
    pub tags: Vec<String>,
}

#[derive(Debug, Clone, Default)]
pub struct UpdateDiscussionPost {
    pub title: Option<String>,
    pub body: Option<String>,
    pub category: Option<String>,
    pub tags: Option<Vec<String>>,
    pub locked: Option<bool>,
}

#[derive(Debug, Clone, Default)]
pub struct PostFilter {
    pub post_type: Option<String>,
    pub direction: Option<String>,
    pub category: Option<String>,
    pub search: Option<String>,
    pub sort: PostSort,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum PostSort {
    Latest,
    #[default]
    Active,
    Replies,
    ForYou,
}

#[allow(async_fn_in_trait)]
pub trait PostRepository: Send + Sync {
    async fn list(
        &self,
        campus_id: Uuid,
        filter: &PostFilter,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<Post>, i64), ApiError>;

    async fn list_for_you(
        &self,
        campus_id: Uuid,
        viewer_id: Option<&str>,
        filter: &PostFilter,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<Post>, i64), ApiError>;

    async fn find_by_id(&self, campus_id: Uuid, id: Uuid) -> Result<Option<Post>, ApiError>;

    async fn find_by_listing_id(
        &self,
        campus_id: Uuid,
        listing_id: &str,
    ) -> Result<Option<Post>, ApiError>;

    async fn create_discussion(&self, input: NewDiscussionPost) -> Result<Post, ApiError>;

    async fn update_discussion(
        &self,
        campus_id: Uuid,
        id: Uuid,
        author_id: &str,
        input: &UpdateDiscussionPost,
    ) -> Result<bool, ApiError>;

    async fn delete_discussion(
        &self,
        campus_id: Uuid,
        id: Uuid,
        author_id: &str,
    ) -> Result<bool, ApiError>;

    async fn list_replies(
        &self,
        campus_id: Uuid,
        post_id: Uuid,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<PostReply>, i64), ApiError>;

    async fn find_reply(
        &self,
        campus_id: Uuid,
        post_id: Uuid,
        reply_id: Uuid,
    ) -> Result<Option<PostReply>, ApiError>;

    async fn create_reply(
        &self,
        campus_id: Uuid,
        post_id: Uuid,
        author_id: &str,
        body: &str,
        reply_to_id: Option<Uuid>,
    ) -> Result<Option<PostReply>, ApiError>;

    async fn update_reply(
        &self,
        campus_id: Uuid,
        post_id: Uuid,
        reply_id: Uuid,
        author_id: &str,
        body: &str,
    ) -> Result<bool, ApiError>;

    async fn delete_reply(
        &self,
        campus_id: Uuid,
        post_id: Uuid,
        reply_id: Uuid,
        author_id: &str,
    ) -> Result<bool, ApiError>;
}

#[derive(Clone)]
pub struct PostgresPostRepository {
    pool: PgPool,
}

impl PostgresPostRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    fn post_columns() -> &'static str {
        r#"p.id, p.campus_id, p.post_type, p.category, p.title, p.body,
           p.tags, p.listing_id, p.reply_count, p.status, p.created_at,
           p.updated_at, p.last_activity_at,
           author.id AS author_id, author.username AS author_username,
           CASE WHEN author.avatar_moderation_status = 'approved'
                THEN author.avatar_url ELSE NULL END AS author_avatar_url,
           CASE WHEN p.post_type = 'listing'
                     AND listing.images_moderation_status = 'approved'
                THEN listing.image_url ELSE NULL END AS cover_image_url,
           listing.content_revision AS listing_content_revision,
           listing.title AS listing_title,
           listing.category AS listing_category,
           COALESCE(listing.brand, '') AS listing_brand,
           listing.direction AS listing_direction,
           listing.condition_score AS listing_condition_score,
           listing.suggested_price_cny AS listing_suggested_price_cny,
           listing.status AS listing_status,
           listing.created_at AS listing_created_at"#
    }

    fn post_relations() -> &'static str {
        "FROM posts p JOIN users author ON author.id = p.author_id
         LEFT JOIN inventory listing ON listing.id = p.listing_id"
    }

    fn post_select() -> String {
        format!("SELECT {} {}", Self::post_columns(), Self::post_relations())
    }

    fn reply_select() -> &'static str {
        r#"SELECT reply.id, reply.post_id, reply.body, reply.reply_to_id,
                  reply.created_at, reply.updated_at,
                  author.id AS author_id, author.username AS author_username,
                  CASE WHEN author.avatar_moderation_status = 'approved'
                       THEN author.avatar_url ELSE NULL END AS author_avatar_url
           FROM post_replies reply
           JOIN users author ON author.id = reply.author_id"#
    }

    async fn fetch_reply(&self, campus_id: Uuid, reply_id: Uuid) -> Result<PostReply, ApiError> {
        let sql = format!(
            "{} WHERE reply.id = $1 AND reply.campus_id = $2 AND reply.status = 'active'",
            Self::reply_select()
        );
        let row = sqlx::query(&sql)
            .bind(reply_id)
            .bind(campus_id)
            .fetch_one(&self.pool)
            .await
            .map_err(db_error)?;
        Ok(reply_from_row(&row))
    }
}

impl PostRepository for PostgresPostRepository {
    async fn list(
        &self,
        campus_id: Uuid,
        filter: &PostFilter,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<Post>, i64), ApiError> {
        let search = filter
            .search
            .as_deref()
            .map(escape_like_pattern)
            .map(|value| format!("%{value}%"));
        let order_by = match filter.sort {
            PostSort::Latest => "p.created_at DESC, p.id DESC",
            PostSort::Active => "p.last_activity_at DESC, p.id DESC",
            PostSort::Replies => "p.reply_count DESC, p.last_activity_at DESC, p.id DESC",
            PostSort::ForYou => "p.last_activity_at DESC, p.id DESC",
        };
        let visibility = "p.campus_id = $1
              AND p.status IN ('active', 'locked')
              AND ($2::text IS NULL OR p.post_type = $2)
              AND ($3::text IS NULL OR p.category = $3)
              AND ($4::text IS NULL OR p.title ILIKE $4
                   OR p.body ILIKE $4)
              AND ($5::text IS NULL OR listing.direction = $5)
              AND (p.listing_id IS NULL OR NOT listing_has_active_restriction(p.listing_id))";
        let query = format!(
            "{} WHERE {} ORDER BY {} LIMIT $6 OFFSET $7",
            Self::post_select(),
            visibility,
            order_by
        );
        let rows = sqlx::query(&query)
            .bind(campus_id)
            .bind(filter.post_type.as_deref())
            .bind(filter.category.as_deref())
            .bind(search.as_deref())
            .bind(filter.direction.as_deref())
            .bind(limit)
            .bind(offset)
            .fetch_all(&self.pool)
            .await
            .map_err(db_error)?;
        let count_query = format!(
            "SELECT COUNT(*) {} WHERE {}",
            Self::post_relations(),
            visibility
        );
        let total: i64 = sqlx::query_scalar(&count_query)
            .bind(campus_id)
            .bind(filter.post_type.as_deref())
            .bind(filter.category.as_deref())
            .bind(search.as_deref())
            .bind(filter.direction.as_deref())
            .fetch_one(&self.pool)
            .await
            .map_err(db_error)?;
        Ok((
            rows.iter()
                .map(|row| post_from_row_with_fallback(row, filter.sort))
                .collect(),
            total,
        ))
    }

    async fn list_for_you(
        &self,
        campus_id: Uuid,
        viewer_id: Option<&str>,
        filter: &PostFilter,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<Post>, i64), ApiError> {
        let search = filter
            .search
            .as_deref()
            .map(escape_like_pattern)
            .map(|value| format!("%{value}%"));
        let query = format!(
            r#"WITH preferences AS (
                   SELECT COALESCE(pref.personalization_enabled, TRUE) AS personalization_enabled,
                          COALESCE(pref.signals_reset_at, '-infinity'::timestamptz) AS signals_reset_at
                   FROM (SELECT 1) seed
                   LEFT JOIN feed_preferences pref
                     ON pref.campus_id = $1 AND pref.user_id = $2
               ), affinity AS (
                   SELECT signal.category, SUM(signal.weight)::float8 AS weight
                   FROM (
                       SELECT LOWER(BTRIM(post.category)) AS category,
                              COUNT(*)::float8 * 2.0 AS weight
                       FROM post_replies reply
                       JOIN posts post ON post.id = reply.post_id
                       CROSS JOIN preferences pref
                       WHERE $2::text IS NOT NULL
                         AND reply.author_id = $2
                         AND reply.status = 'active'
                         AND reply.created_at >= pref.signals_reset_at
                         AND pref.personalization_enabled
                       GROUP BY LOWER(BTRIM(post.category))
                       UNION ALL
                       SELECT LOWER(BTRIM(listing.category)) AS category,
                              COUNT(*)::float8 * 2.0 AS weight
                       FROM watchlist watch
                       JOIN inventory listing ON listing.id = watch.listing_id
                       CROSS JOIN preferences pref
                       WHERE $2::text IS NOT NULL
                         AND watch.user_id = $2
                         AND watch.created_at >= pref.signals_reset_at
                         AND listing.campus_id = $1
                         AND pref.personalization_enabled
                       GROUP BY LOWER(BTRIM(listing.category))
                       UNION ALL
                       SELECT LOWER(BTRIM(listing.category)) AS category,
                              COUNT(*)::float8 * 3.0 AS weight
                       FROM orders purchase
                       JOIN inventory listing ON listing.id = purchase.listing_id
                       CROSS JOIN preferences pref
                       WHERE $2::text IS NOT NULL
                         AND purchase.buyer_id = $2
                         AND purchase.campus_id = $1
                         AND purchase.created_at >= pref.signals_reset_at
                         AND listing.campus_id = $1
                         AND pref.personalization_enabled
                       GROUP BY LOWER(BTRIM(listing.category))
                   ) signal
                   GROUP BY signal.category
               ), less_like AS (
                   SELECT LOWER(BTRIM(split_part(feedback.signal_key, ':category:', 2))) AS category,
                          COUNT(*)::float8 AS weight
                   FROM feed_feedback feedback
                   CROSS JOIN preferences pref
                   WHERE $2::text IS NOT NULL
                     AND feedback.user_id = $2
                     AND feedback.campus_id = $1
                     AND feedback.action = 'less_like_this'
                     AND feedback.resource_type IN ('post', 'listing')
                     AND feedback.signal_key LIKE '%:category:%'
                     AND feedback.updated_at >= pref.signals_reset_at
                     AND pref.personalization_enabled
                   GROUP BY LOWER(BTRIM(split_part(feedback.signal_key, ':category:', 2)))
               )
               SELECT {columns},
                      CASE
                        WHEN pref.personalization_enabled AND COALESCE(affinity.weight, 0) > 0
                          THEN '与你互动过的“' || p.category || '”内容相关'
                        WHEN p.reply_count > 0 THEN '校园里正在讨论'
                        ELSE '最新发布'
                      END AS rank_reason,
                      CASE
                        WHEN pref.personalization_enabled AND COALESCE(affinity.weight, 0) > 0
                          THEN 'category_affinity'
                        WHEN p.reply_count > 0 THEN 'engagement'
                        ELSE 'recency'
                      END AS rank_source,
                      (
                        CASE WHEN pref.personalization_enabled
                             THEN COALESCE(affinity.weight, 0) * 3.0
                                  - COALESCE(less_like.weight, 0) * 4.0
                             ELSE 0.0 END
                        + (1.0 / (1.0 + GREATEST(
                              EXTRACT(EPOCH FROM (NOW() - p.created_at)), 0
                            ) / 86400.0)) * 2.0
                        + LN(1.0 + p.reply_count::float8) * 0.25
                      ) AS ranking_score
               {relations}
               CROSS JOIN preferences pref
               LEFT JOIN affinity ON affinity.category = LOWER(BTRIM(p.category))
               LEFT JOIN less_like ON less_like.category = LOWER(BTRIM(p.category))
               WHERE p.campus_id = $1
                 AND p.status IN ('active', 'locked')
                 AND ($3::text IS NULL OR p.post_type = $3)
                 AND ($4::text IS NULL OR p.category = $4)
                 AND ($5::text IS NULL OR p.title ILIKE $5
                      OR p.body ILIKE $5)
                 AND ($6::text IS NULL OR listing.direction = $6)
                 AND ($2::text IS NULL OR p.author_id <> $2)
                 AND (p.listing_id IS NULL
                      OR NOT listing_has_active_restriction(p.listing_id))
                 AND ($2::text IS NULL OR NOT EXISTS (
                       SELECT 1 FROM feed_feedback exact_feedback
                       WHERE exact_feedback.user_id = $2
                         AND exact_feedback.campus_id = $1
                         AND (
                           (exact_feedback.resource_type = 'post'
                            AND exact_feedback.resource_id = p.id::text)
                           OR (exact_feedback.resource_type = 'listing'
                               AND p.listing_id IS NOT NULL
                               AND exact_feedback.resource_id = p.listing_id)
                         )
                     ))
               ORDER BY ranking_score DESC, p.last_activity_at DESC, p.id DESC
               LIMIT $7 OFFSET $8"#,
            columns = Self::post_columns(),
            relations = Self::post_relations(),
        );
        let rows = sqlx::query(&query)
            .bind(campus_id)
            .bind(viewer_id)
            .bind(filter.post_type.as_deref())
            .bind(filter.category.as_deref())
            .bind(search.as_deref())
            .bind(filter.direction.as_deref())
            .bind(limit)
            .bind(offset)
            .fetch_all(&self.pool)
            .await
            .map_err(db_error)?;

        let count_query = r#"SELECT COUNT(*) FROM posts p
               LEFT JOIN inventory listing_filter ON listing_filter.id = p.listing_id
               WHERE p.campus_id = $1
                 AND p.status IN ('active', 'locked')
                 AND ($2::text IS NULL OR p.post_type = $2)
                 AND ($3::text IS NULL OR p.category = $3)
                 AND ($4::text IS NULL OR p.title ILIKE $4
                      OR p.body ILIKE $4)
                 AND ($5::text IS NULL OR listing_filter.direction = $5)
                 AND ($6::text IS NULL OR p.author_id <> $6)
                 AND (p.listing_id IS NULL
                      OR NOT listing_has_active_restriction(p.listing_id))
                 AND ($6::text IS NULL OR NOT EXISTS (
                       SELECT 1 FROM feed_feedback exact_feedback
                       WHERE exact_feedback.user_id = $6
                         AND exact_feedback.campus_id = $1
                         AND (
                           (exact_feedback.resource_type = 'post'
                            AND exact_feedback.resource_id = p.id::text)
                           OR (exact_feedback.resource_type = 'listing'
                               AND p.listing_id IS NOT NULL
                               AND exact_feedback.resource_id = p.listing_id)
                         )
                     ))"#;
        let total: i64 = sqlx::query_scalar(count_query)
            .bind(campus_id)
            .bind(filter.post_type.as_deref())
            .bind(filter.category.as_deref())
            .bind(search.as_deref())
            .bind(filter.direction.as_deref())
            .bind(viewer_id)
            .fetch_one(&self.pool)
            .await
            .map_err(db_error)?;
        Ok((rows.iter().map(post_from_row).collect(), total))
    }

    async fn find_by_id(&self, campus_id: Uuid, id: Uuid) -> Result<Option<Post>, ApiError> {
        let query = format!(
            "{} WHERE p.id = $1 AND p.campus_id = $2
                AND p.status IN ('active', 'locked')
                AND (p.listing_id IS NULL OR NOT listing_has_active_restriction(p.listing_id))",
            Self::post_select()
        );
        sqlx::query(&query)
            .bind(id)
            .bind(campus_id)
            .fetch_optional(&self.pool)
            .await
            .map(|row| row.as_ref().map(post_from_row))
            .map_err(db_error)
    }

    async fn find_by_listing_id(
        &self,
        campus_id: Uuid,
        listing_id: &str,
    ) -> Result<Option<Post>, ApiError> {
        let query = format!(
            "{} WHERE p.listing_id = $1 AND p.campus_id = $2
                AND p.status IN ('active', 'locked')
                AND NOT listing_has_active_restriction(p.listing_id)",
            Self::post_select()
        );
        sqlx::query(&query)
            .bind(listing_id)
            .bind(campus_id)
            .fetch_optional(&self.pool)
            .await
            .map(|row| row.as_ref().map(post_from_row))
            .map_err(db_error)
    }

    async fn create_discussion(&self, input: NewDiscussionPost) -> Result<Post, ApiError> {
        let id: Uuid = sqlx::query_scalar(
            "INSERT INTO posts (
                 campus_id, author_id, post_type, category, title, body, tags
             ) VALUES ($1, $2, 'discussion', $3, $4, $5, $6)
             RETURNING id",
        )
        .bind(input.campus_id)
        .bind(&input.author_id)
        .bind(&input.category)
        .bind(&input.title)
        .bind(&input.body)
        .bind(serde_json::json!(input.tags))
        .fetch_one(&self.pool)
        .await
        .map_err(db_error)?;
        self.find_by_id(input.campus_id, id)
            .await?
            .ok_or_else(|| ApiError::Internal(anyhow::anyhow!("created post disappeared")))
    }

    async fn update_discussion(
        &self,
        campus_id: Uuid,
        id: Uuid,
        author_id: &str,
        input: &UpdateDiscussionPost,
    ) -> Result<bool, ApiError> {
        let updated = sqlx::query(
            "UPDATE posts SET
                 title = COALESCE($4, title),
                 body = COALESCE($5, body),
                 category = COALESCE($6, category),
                 tags = COALESCE($7, tags),
                 status = CASE
                     WHEN $8::boolean IS NULL THEN status
                     WHEN $8 THEN 'locked'
                     ELSE 'active'
                 END,
                 updated_at = NOW()
             WHERE id = $1 AND campus_id = $2 AND author_id = $3
               AND post_type = 'discussion' AND status IN ('active', 'locked')",
        )
        .bind(id)
        .bind(campus_id)
        .bind(author_id)
        .bind(input.title.as_deref())
        .bind(input.body.as_deref())
        .bind(input.category.as_deref())
        .bind(input.tags.as_ref().map(|tags| serde_json::json!(tags)))
        .bind(input.locked)
        .execute(&self.pool)
        .await
        .map_err(db_error)?;
        Ok(updated.rows_affected() == 1)
    }

    async fn delete_discussion(
        &self,
        campus_id: Uuid,
        id: Uuid,
        author_id: &str,
    ) -> Result<bool, ApiError> {
        let deleted = sqlx::query(
            "UPDATE posts SET status = 'deleted', updated_at = NOW()
             WHERE id = $1 AND campus_id = $2 AND author_id = $3
               AND post_type = 'discussion' AND status IN ('active', 'locked')",
        )
        .bind(id)
        .bind(campus_id)
        .bind(author_id)
        .execute(&self.pool)
        .await
        .map_err(db_error)?;
        Ok(deleted.rows_affected() == 1)
    }

    async fn list_replies(
        &self,
        campus_id: Uuid,
        post_id: Uuid,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<PostReply>, i64), ApiError> {
        let query = format!(
            "{} WHERE reply.post_id = $1 AND reply.campus_id = $2
                AND reply.status = 'active'
              ORDER BY reply.created_at ASC, reply.id ASC
              LIMIT $3 OFFSET $4",
            Self::reply_select()
        );
        let rows = sqlx::query(&query)
            .bind(post_id)
            .bind(campus_id)
            .bind(limit)
            .bind(offset)
            .fetch_all(&self.pool)
            .await
            .map_err(db_error)?;
        let total: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM post_replies
             WHERE post_id = $1 AND campus_id = $2 AND status = 'active'",
        )
        .bind(post_id)
        .bind(campus_id)
        .fetch_one(&self.pool)
        .await
        .map_err(db_error)?;
        Ok((rows.iter().map(reply_from_row).collect(), total))
    }

    async fn find_reply(
        &self,
        campus_id: Uuid,
        post_id: Uuid,
        reply_id: Uuid,
    ) -> Result<Option<PostReply>, ApiError> {
        let query = format!(
            "{} WHERE reply.id = $1 AND reply.post_id = $2
                AND reply.campus_id = $3 AND reply.status = 'active'",
            Self::reply_select()
        );
        sqlx::query(&query)
            .bind(reply_id)
            .bind(post_id)
            .bind(campus_id)
            .fetch_optional(&self.pool)
            .await
            .map(|row| row.as_ref().map(reply_from_row))
            .map_err(db_error)
    }

    async fn create_reply(
        &self,
        campus_id: Uuid,
        post_id: Uuid,
        author_id: &str,
        body: &str,
        reply_to_id: Option<Uuid>,
    ) -> Result<Option<PostReply>, ApiError> {
        let id = sqlx::query_scalar::<_, Uuid>(
            "INSERT INTO post_replies (campus_id, post_id, author_id, body, reply_to_id)
             SELECT post.campus_id, post.id, $3, $4, $5
             FROM posts post
             WHERE post.id = $1 AND post.campus_id = $2 AND post.status = 'active'
               AND (post.listing_id IS NULL
                    OR NOT listing_has_active_restriction(post.listing_id))
               AND ($5::uuid IS NULL OR EXISTS (
                   SELECT 1 FROM post_replies parent
                   WHERE parent.id = $5 AND parent.post_id = post.id
                     AND parent.campus_id = post.campus_id
                     AND parent.status = 'active'
               ))
             RETURNING id",
        )
        .bind(post_id)
        .bind(campus_id)
        .bind(author_id)
        .bind(body)
        .bind(reply_to_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(db_error)?;
        match id {
            Some(id) => self.fetch_reply(campus_id, id).await.map(Some),
            None => Ok(None),
        }
    }

    async fn update_reply(
        &self,
        campus_id: Uuid,
        post_id: Uuid,
        reply_id: Uuid,
        author_id: &str,
        body: &str,
    ) -> Result<bool, ApiError> {
        let updated = sqlx::query(
            "UPDATE post_replies SET body = $5, updated_at = NOW()
             WHERE id = $1 AND post_id = $2 AND campus_id = $3
               AND author_id = $4 AND status = 'active'",
        )
        .bind(reply_id)
        .bind(post_id)
        .bind(campus_id)
        .bind(author_id)
        .bind(body)
        .execute(&self.pool)
        .await
        .map_err(db_error)?;
        Ok(updated.rows_affected() == 1)
    }

    async fn delete_reply(
        &self,
        campus_id: Uuid,
        post_id: Uuid,
        reply_id: Uuid,
        author_id: &str,
    ) -> Result<bool, ApiError> {
        let deleted = sqlx::query(
            "UPDATE post_replies SET status = 'deleted', updated_at = NOW()
             WHERE id = $1 AND post_id = $2 AND campus_id = $3
               AND author_id = $4 AND status = 'active'",
        )
        .bind(reply_id)
        .bind(post_id)
        .bind(campus_id)
        .bind(author_id)
        .execute(&self.pool)
        .await
        .map_err(db_error)?;
        Ok(deleted.rows_affected() == 1)
    }
}

fn post_from_row(row: &PgRow) -> Post {
    let tags = row
        .get::<serde_json::Value, _>("tags")
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|tag| tag.as_str().map(str::to_string))
        .collect();
    let listing_id: Option<String> = row.get("listing_id");
    let cover_image_url: Option<String> = row.get("cover_image_url");
    let listing = listing_id.as_ref().map(|id| ListingPostPreview {
        id: id.clone(),
        content_revision: row.get("listing_content_revision"),
        title: row.get("listing_title"),
        category: row.get("listing_category"),
        brand: row.get("listing_brand"),
        direction: row.get("listing_direction"),
        condition_score: row.get("listing_condition_score"),
        suggested_price_cny: row.get("listing_suggested_price_cny"),
        status: row.get("listing_status"),
        image_url: cover_image_url.clone(),
        created_at: row.get("listing_created_at"),
    });
    Post {
        id: row.get("id"),
        campus_id: row.get("campus_id"),
        post_type: row.get("post_type"),
        category: row.get("category"),
        title: row.get("title"),
        body: row.get("body"),
        tags,
        listing_id,
        cover_image_url,
        author_id: row.get("author_id"),
        author_username: row.get("author_username"),
        author_avatar_url: row.get("author_avatar_url"),
        reply_count: row.get("reply_count"),
        status: row.get("status"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
        last_activity_at: row.get("last_activity_at"),
        rank_reason: row
            .try_get("rank_reason")
            .unwrap_or_else(|_| "".to_string()),
        rank_source: row
            .try_get("rank_source")
            .unwrap_or_else(|_| "".to_string()),
        ranking_score: row.try_get("ranking_score").ok(),
        listing,
    }
}

fn post_from_row_with_fallback(row: &PgRow, sort: PostSort) -> Post {
    let mut post = post_from_row(row);
    if post.rank_reason.is_empty() {
        post.rank_reason = match sort {
            PostSort::Latest => "最新发布".to_string(),
            PostSort::Replies => "校园里正在讨论".to_string(),
            PostSort::Active => "最近有新互动".to_string(),
            PostSort::ForYou => "最新发布".to_string(),
        };
    }
    if post.rank_source.is_empty() {
        post.rank_source = match sort {
            PostSort::Latest => "recency".to_string(),
            PostSort::Replies => "engagement".to_string(),
            PostSort::Active => "activity".to_string(),
            PostSort::ForYou => "recency".to_string(),
        };
    }
    post
}

fn reply_from_row(row: &PgRow) -> PostReply {
    PostReply {
        id: row.get("id"),
        post_id: row.get("post_id"),
        body: row.get("body"),
        reply_to_id: row.get("reply_to_id"),
        author_id: row.get("author_id"),
        author_username: row.get("author_username"),
        author_avatar_url: row.get("author_avatar_url"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
    }
}

fn escape_like_pattern(input: &str) -> String {
    input
        .replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_")
}

fn db_error(error: sqlx::Error) -> ApiError {
    ApiError::Internal(anyhow::anyhow!("DB error: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escapes_search_wildcards() {
        assert_eq!(
            escape_like_pattern(r#"50%_off\today"#),
            r#"50\%\_off\\today"#
        );
    }

    #[test]
    fn activity_is_the_default_post_sort() {
        assert_eq!(PostSort::default(), PostSort::Active);
    }

    #[test]
    fn for_you_is_a_distinct_sort_mode() {
        assert_ne!(PostSort::ForYou, PostSort::Active);
    }
}
