use pgvector::Vector;
use serde::{Deserialize, Serialize};
use sqlx::{PgPool, Row};
use uuid::Uuid;

use crate::api::error::ApiError;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum FeedResourceType {
    Listing,
    Intent,
    Post,
}

impl FeedResourceType {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Listing => "listing",
            Self::Intent => "intent",
            Self::Post => "post",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum FeedFeedbackAction {
    Hide,
    LessLikeThis,
    NotRelevant,
}

impl FeedFeedbackAction {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Hide => "hide",
            Self::LessLikeThis => "less_like_this",
            Self::NotRelevant => "not_relevant",
        }
    }
}

#[derive(Debug, Serialize)]
pub struct FeedFeedbackReceipt {
    pub feedback_id: Uuid,
    pub resource_type: FeedResourceType,
    pub resource_id: String,
    pub action: FeedFeedbackAction,
}

#[derive(Debug, Serialize)]
pub struct FeedPreferences {
    pub personalization_enabled: bool,
    pub signals_reset_at: Option<chrono::DateTime<chrono::Utc>>,
}

#[derive(Clone)]
pub struct FeedService {
    pool: PgPool,
}

impl FeedService {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn submit_feedback(
        &self,
        campus_id: Uuid,
        user_id: &str,
        resource_type: FeedResourceType,
        resource_id: &str,
        action: FeedFeedbackAction,
    ) -> Result<FeedFeedbackReceipt, ApiError> {
        let resource_id = resource_id.trim();
        if resource_id.is_empty() || resource_id.chars().count() > 255 {
            return Err(ApiError::NotFound);
        }

        // Owner and campus checks live in the same target lookup. Missing,
        // cross-campus and self-owned resources all return the same answer so
        // this write endpoint cannot be used as a directory oracle.
        let (canonical_id, signal_key) = match resource_type {
            FeedResourceType::Listing => {
                let row = sqlx::query(
                    "SELECT id, category
                     FROM inventory
                     WHERE id = $1 AND campus_id = $2 AND owner_id <> $3
                       AND status = 'active'
                       AND NOT listing_has_active_restriction(id)",
                )
                .bind(resource_id)
                .bind(campus_id)
                .bind(user_id)
                .fetch_optional(&self.pool)
                .await
                .map_err(db_error)?
                .ok_or(ApiError::NotFound)?;
                let id: String = row.get("id");
                let category: String = row.get("category");
                (
                    id,
                    format!("listing:category:{}", normalized_signal(&category)),
                )
            }
            FeedResourceType::Intent => {
                let intent_id = Uuid::parse_str(resource_id).map_err(|_| ApiError::NotFound)?;
                let row = sqlx::query(
                    "SELECT id, kind
                     FROM intents
                     WHERE id = $1 AND campus_id = $2 AND author_id <> $3
                       AND status = 'active' AND visibility = 'campus'
                       AND (valid_until IS NULL OR valid_until > NOW())",
                )
                .bind(intent_id)
                .bind(campus_id)
                .bind(user_id)
                .fetch_optional(&self.pool)
                .await
                .map_err(db_error)?
                .ok_or(ApiError::NotFound)?;
                let id: Uuid = row.get("id");
                let kind: String = row.get("kind");
                (
                    id.to_string(),
                    format!("intent:kind:{}", normalized_signal(&kind)),
                )
            }
            FeedResourceType::Post => {
                let post_id = Uuid::parse_str(resource_id).map_err(|_| ApiError::NotFound)?;
                let row = sqlx::query(
                    "SELECT id, category
                     FROM posts
                     WHERE id = $1 AND campus_id = $2 AND author_id <> $3
                       AND status IN ('active', 'locked')
                       AND (listing_id IS NULL
                            OR NOT listing_has_active_restriction(listing_id))",
                )
                .bind(post_id)
                .bind(campus_id)
                .bind(user_id)
                .fetch_optional(&self.pool)
                .await
                .map_err(db_error)?
                .ok_or(ApiError::NotFound)?;
                let id: Uuid = row.get("id");
                let category: String = row.get("category");
                (
                    id.to_string(),
                    format!("post:category:{}", normalized_signal(&category)),
                )
            }
        };

        let feedback_id: Uuid = sqlx::query_scalar(
            "INSERT INTO feed_feedback (
                 campus_id, user_id, resource_type, resource_id, action, signal_key
             ) VALUES ($1, $2, $3, $4, $5, $6)
             ON CONFLICT (user_id, campus_id, resource_type, resource_id)
             DO UPDATE SET action = EXCLUDED.action,
                           signal_key = EXCLUDED.signal_key,
                           updated_at = NOW()
             RETURNING id",
        )
        .bind(campus_id)
        .bind(user_id)
        .bind(resource_type.as_str())
        .bind(&canonical_id)
        .bind(action.as_str())
        .bind(signal_key)
        .fetch_one(&self.pool)
        .await
        .map_err(db_error)?;

        Ok(FeedFeedbackReceipt {
            feedback_id,
            resource_type,
            resource_id: canonical_id,
            action,
        })
    }

    pub async fn preferences(
        &self,
        campus_id: Uuid,
        user_id: &str,
    ) -> Result<FeedPreferences, ApiError> {
        let row = sqlx::query(
            "SELECT personalization_enabled, signals_reset_at
             FROM feed_preferences WHERE campus_id = $1 AND user_id = $2",
        )
        .bind(campus_id)
        .bind(user_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(db_error)?;

        Ok(row.map_or(
            FeedPreferences {
                personalization_enabled: true,
                signals_reset_at: None,
            },
            |row| FeedPreferences {
                personalization_enabled: row.get("personalization_enabled"),
                signals_reset_at: row.get("signals_reset_at"),
            },
        ))
    }

    pub async fn update_preferences(
        &self,
        campus_id: Uuid,
        user_id: &str,
        personalization_enabled: bool,
    ) -> Result<FeedPreferences, ApiError> {
        let row = sqlx::query(
            "INSERT INTO feed_preferences (campus_id, user_id, personalization_enabled)
             VALUES ($1, $2, $3)
             ON CONFLICT (campus_id, user_id)
             DO UPDATE SET personalization_enabled = EXCLUDED.personalization_enabled,
                           updated_at = NOW()
             RETURNING personalization_enabled, signals_reset_at",
        )
        .bind(campus_id)
        .bind(user_id)
        .bind(personalization_enabled)
        .fetch_one(&self.pool)
        .await
        .map_err(db_error)?;

        Ok(FeedPreferences {
            personalization_enabled: row.get("personalization_enabled"),
            signals_reset_at: row.get("signals_reset_at"),
        })
    }

    pub async fn clear_personalization(
        &self,
        campus_id: Uuid,
        user_id: &str,
    ) -> Result<FeedPreferences, ApiError> {
        let row = sqlx::query(
            "INSERT INTO feed_preferences (campus_id, user_id, signals_reset_at)
             VALUES ($1, $2, NOW())
             ON CONFLICT (campus_id, user_id)
             DO UPDATE SET signals_reset_at = NOW(), updated_at = NOW()
             RETURNING personalization_enabled, signals_reset_at",
        )
        .bind(campus_id)
        .bind(user_id)
        .fetch_one(&self.pool)
        .await
        .map_err(db_error)?;

        Ok(FeedPreferences {
            personalization_enabled: row.get("personalization_enabled"),
            signals_reset_at: row.get("signals_reset_at"),
        })
    }

    pub async fn fetch_recency_feed(
        &self,
        campus_id: Uuid,
        direction: &str,
        limit: i64,
        offset: i64,
    ) -> Result<Vec<RecommendationItem>, ApiError> {
        let rows = sqlx::query(
            r#"
            SELECT id, title, category, brand, direction, condition_score,
                   suggested_price_cny, status,
                   CASE WHEN images_moderation_status = 'approved' THEN image_url ELSE NULL END AS image_url,
                   defects
            FROM inventory
            WHERE status = 'active'
              AND NOT listing_has_active_restriction(id)
              AND campus_id = $3
              AND ($4 = 'all' OR direction = $4)
            ORDER BY created_at DESC
            LIMIT $1 OFFSET $2
            "#,
        )
        .bind(limit)
        .bind(offset)
        .bind(campus_id)
        .bind(direction)
        .fetch_all(&self.pool)
        .await
        .map_err(db_error)?;

        Ok(rows
            .iter()
            .map(|row| recommendation_item_with_reason(row, "最新发布".to_string(), "recency"))
            .collect())
    }

    pub async fn fetch_personalized_feed(
        &self,
        user_id: &str,
        campus_id: Uuid,
        direction: &str,
        limit: i64,
        offset: i64,
    ) -> Result<Vec<RecommendationItem>, ApiError> {
        let rows = sqlx::query(
            r#"
            WITH preferences AS (
                SELECT COALESCE(pref.personalization_enabled, TRUE) AS personalization_enabled,
                       COALESCE(pref.signals_reset_at, '-infinity'::timestamptz) AS signals_reset_at
                FROM (SELECT 1) seed
                LEFT JOIN feed_preferences pref
                  ON pref.campus_id = $5 AND pref.user_id = $1
            ), affinity AS (
                SELECT i.category, COUNT(*)::float8 AS weight
                FROM (
                    SELECT watch.listing_id
                    FROM watchlist watch CROSS JOIN preferences pref
                    WHERE watch.user_id = $1
                      AND pref.personalization_enabled
                      AND watch.created_at >= pref.signals_reset_at
                    UNION ALL
                    SELECT purchase.listing_id
                    FROM orders purchase CROSS JOIN preferences pref
                    WHERE purchase.buyer_id = $1
                      AND purchase.campus_id = $5
                      AND pref.personalization_enabled
                      AND purchase.created_at >= pref.signals_reset_at
                ) signals
                JOIN inventory i ON i.id = signals.listing_id
                WHERE i.campus_id = $5
                GROUP BY i.category
            ), less_like AS (
                SELECT feedback.signal_key, COUNT(*)::float8 AS weight
                FROM feed_feedback feedback CROSS JOIN preferences pref
                WHERE feedback.user_id = $1
                  AND feedback.campus_id = $5
                  AND feedback.resource_type = 'listing'
                  AND feedback.action = 'less_like_this'
                  AND pref.personalization_enabled
                  AND feedback.updated_at >= pref.signals_reset_at
                GROUP BY feedback.signal_key
            )
            SELECT inv.id, inv.title, inv.category, inv.brand, inv.direction, inv.condition_score,
                   inv.suggested_price_cny, inv.status,
                   CASE WHEN inv.images_moderation_status = 'approved' THEN inv.image_url ELSE NULL END AS image_url,
                   inv.defects,
                   CASE WHEN pref.personalization_enabled
                        THEN COALESCE(a.weight, 0) - COALESCE(downrank.weight, 0)
                        ELSE 0 END AS effective_weight,
                   pref.personalization_enabled
            FROM inventory inv
            CROSS JOIN preferences pref
            LEFT JOIN affinity a ON a.category = inv.category
            LEFT JOIN less_like downrank
              ON downrank.signal_key = 'listing:category:' || LOWER(BTRIM(inv.category))
            WHERE inv.status = 'active'
              AND NOT listing_has_active_restriction(inv.id)
              AND inv.campus_id = $5
              AND inv.owner_id <> $1
              AND ($4 = 'all' OR inv.direction = $4)
              AND NOT EXISTS (
                  SELECT 1 FROM watchlist w
                  WHERE pref.personalization_enabled
                    AND w.user_id = $1 AND w.listing_id = inv.id
                    AND w.created_at >= pref.signals_reset_at
              )
              AND NOT EXISTS (
                  SELECT 1 FROM feed_feedback exact_feedback
                  WHERE exact_feedback.user_id = $1
                    AND exact_feedback.campus_id = $5
                    AND exact_feedback.resource_type = 'listing'
                    AND exact_feedback.resource_id = inv.id
              )
            ORDER BY CASE WHEN pref.personalization_enabled
                          THEN COALESCE(a.weight, 0) - COALESCE(downrank.weight, 0)
                          ELSE 0 END DESC,
                     inv.created_at DESC
            LIMIT $2 OFFSET $3
            "#,
        )
        .bind(user_id)
        .bind(limit)
        .bind(offset)
        .bind(direction)
        .bind(campus_id)
        .fetch_all(&self.pool)
        .await
        .map_err(db_error)?;

        Ok(rows
            .iter()
            .map(|row| {
                let weight: f64 = row.try_get("effective_weight").unwrap_or(0.0);
                let personalization_enabled: bool =
                    row.try_get("personalization_enabled").unwrap_or(true);
                if personalization_enabled && weight > 0.0 {
                    let category: String = row.get("category");
                    recommendation_item_with_reason(
                        row,
                        format!("与你关注的“{}”类相关", category),
                        "category_affinity",
                    )
                } else {
                    recommendation_item_with_reason(row, "最新发布".to_string(), "recency")
                }
            })
            .collect())
    }

    pub async fn fetch_similar_recency(
        &self,
        campus_id: Uuid,
        viewer_id: Option<&str>,
        source_listing_id: &str,
        limit: i64,
    ) -> Result<Vec<RecommendationItem>, ApiError> {
        let rows = sqlx::query(
            r#"
            WITH preferences AS (
                SELECT COALESCE(pref.personalization_enabled, TRUE) AS personalization_enabled,
                       COALESCE(pref.signals_reset_at, '-infinity'::timestamptz) AS signals_reset_at
                FROM (SELECT 1) seed
                LEFT JOIN feed_preferences pref
                  ON pref.campus_id = $2 AND pref.user_id = $3
            ), less_like AS (
                SELECT feedback.signal_key, COUNT(*)::float8 AS weight
                FROM feed_feedback feedback CROSS JOIN preferences pref
                WHERE $3::text IS NOT NULL
                  AND feedback.user_id = $3
                  AND feedback.campus_id = $2
                  AND feedback.resource_type = 'listing'
                  AND feedback.action = 'less_like_this'
                  AND pref.personalization_enabled
                  AND feedback.updated_at >= pref.signals_reset_at
                GROUP BY feedback.signal_key
            )
            SELECT inv.id, inv.title, inv.category, inv.brand, inv.direction,
                   inv.condition_score, inv.suggested_price_cny, inv.status,
                   CASE WHEN inv.images_moderation_status = 'approved'
                        THEN inv.image_url ELSE NULL END AS image_url,
                   inv.defects
            FROM inventory inv
            CROSS JOIN preferences pref
            LEFT JOIN less_like downrank
              ON downrank.signal_key = 'listing:category:' || LOWER(BTRIM(inv.category))
            WHERE inv.id <> $1
              AND inv.status = 'active'
              AND NOT listing_has_active_restriction(inv.id)
              AND inv.direction = 'offer'
              AND inv.campus_id = $2
              AND ($3::text IS NULL OR inv.owner_id <> $3)
              AND (
                  $3::text IS NULL
                  OR NOT EXISTS (
                      SELECT 1 FROM feed_feedback exact_feedback
                      WHERE exact_feedback.user_id = $3
                        AND exact_feedback.campus_id = $2
                        AND exact_feedback.resource_type = 'listing'
                        AND exact_feedback.resource_id = inv.id
                  )
              )
            ORDER BY CASE
                         WHEN $3::text IS NOT NULL AND pref.personalization_enabled
                         THEN COALESCE(downrank.weight, 0)
                         ELSE 0
                     END ASC,
                     inv.created_at DESC,
                     inv.id ASC
            LIMIT $4
            "#,
        )
        .bind(source_listing_id)
        .bind(campus_id)
        .bind(viewer_id)
        .bind(limit)
        .fetch_all(&self.pool)
        .await
        .map_err(db_error)?;

        Ok(rows
            .iter()
            .map(|row| recommendation_item_with_reason(row, "recency".to_string(), "recency"))
            .collect())
    }

    pub async fn fetch_vector_similar(
        &self,
        campus_id: Uuid,
        viewer_id: Option<&str>,
        source_listing_id: &str,
        source_embedding: &Vector,
        limit: i64,
    ) -> Result<Vec<RecommendationItem>, ApiError> {
        let candidate_pool_limit = similar_candidate_pool_limit(limit);
        let mut tx = self.pool.begin().await.map_err(db_error)?;

        sqlx::query("SET LOCAL hnsw.iterative_scan = strict_order")
            .execute(&mut *tx)
            .await
            .map_err(db_error)?;

        let rows = sqlx::query(
            r#"
            WITH semantic_candidates AS MATERIALIZED (
                SELECT inv.id, inv.title, inv.category, inv.brand, inv.direction,
                       inv.condition_score, inv.suggested_price_cny, inv.status,
                       CASE WHEN inv.images_moderation_status = 'approved'
                            THEN inv.image_url ELSE NULL END AS image_url,
                       inv.defects, inv.created_at,
                       doc.embedding <=> $2 AS semantic_distance
                FROM documents doc
                JOIN inventory inv ON inv.id = doc.id
                WHERE inv.id <> $1
                  AND inv.status = 'active'
                  AND NOT listing_has_active_restriction(inv.id)
                  AND inv.direction = 'offer'
                  AND inv.campus_id = $4
                  AND doc.embedding IS NOT NULL
                  AND ($5::text IS NULL OR inv.owner_id <> $5)
                  AND (
                      $5::text IS NULL
                      OR NOT EXISTS (
                          SELECT 1 FROM feed_feedback exact_feedback
                          WHERE exact_feedback.user_id = $5
                            AND exact_feedback.campus_id = $4
                            AND exact_feedback.resource_type = 'listing'
                            AND exact_feedback.resource_id = inv.id
                      )
                  )
                ORDER BY doc.embedding <=> $2
                LIMIT $6
            ), preferences AS (
                SELECT COALESCE(pref.personalization_enabled, TRUE) AS personalization_enabled,
                       COALESCE(pref.signals_reset_at, '-infinity'::timestamptz) AS signals_reset_at
                FROM (SELECT 1) seed
                LEFT JOIN feed_preferences pref
                  ON pref.campus_id = $4 AND pref.user_id = $5
            ), less_like AS (
                SELECT feedback.signal_key, COUNT(*)::float8 AS weight
                FROM feed_feedback feedback CROSS JOIN preferences pref
                WHERE $5::text IS NOT NULL
                  AND feedback.user_id = $5
                  AND feedback.campus_id = $4
                  AND feedback.resource_type = 'listing'
                  AND feedback.action = 'less_like_this'
                  AND pref.personalization_enabled
                  AND feedback.updated_at >= pref.signals_reset_at
                GROUP BY feedback.signal_key
            )
            SELECT candidate.id, candidate.title, candidate.category, candidate.brand,
                   candidate.direction, candidate.condition_score,
                   candidate.suggested_price_cny, candidate.status,
                   candidate.image_url, candidate.defects
            FROM semantic_candidates candidate
            CROSS JOIN preferences pref
            LEFT JOIN less_like downrank
              ON downrank.signal_key =
                 'listing:category:' || LOWER(BTRIM(candidate.category))
            ORDER BY CASE
                         WHEN $5::text IS NOT NULL AND pref.personalization_enabled
                         THEN COALESCE(downrank.weight, 0)
                         ELSE 0
                     END ASC,
                     candidate.semantic_distance ASC,
                     candidate.created_at DESC,
                     candidate.id ASC
            LIMIT $3
            "#,
        )
        .bind(source_listing_id)
        .bind(source_embedding)
        .bind(limit)
        .bind(campus_id)
        .bind(viewer_id)
        .bind(candidate_pool_limit)
        .fetch_all(&mut *tx)
        .await
        .map_err(db_error)?;

        tx.commit().await.map_err(db_error)?;

        Ok(rows
            .iter()
            .map(|row| {
                recommendation_item_with_reason(
                    row,
                    "vector_similarity".to_string(),
                    "vector_similarity",
                )
            })
            .collect())
    }

    pub async fn get_source_listing_embedding(
        &self,
        listing_id: &str,
        campus_id: Uuid,
    ) -> Result<Option<Vector>, ApiError> {
        let source = sqlx::query(
            "SELECT d.embedding
             FROM inventory i
             LEFT JOIN documents d ON d.id = i.id
             WHERE i.id = $1
               AND i.campus_id = $2
               AND i.status = 'active'
               AND NOT listing_has_active_restriction(i.id)
               AND i.direction = 'offer'",
        )
        .bind(listing_id)
        .bind(campus_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::NotFound)?;

        let source_embedding: Option<Vector> = source.try_get("embedding").map_err(db_error)?;
        Ok(source_embedding)
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct RecommendationItem {
    pub id: String,
    pub title: String,
    pub category: String,
    pub brand: String,
    pub direction: String,
    pub condition_score: i32,
    pub suggested_price_cny: f64,
    pub status: String,
    pub image_url: Option<String>,
    pub defect_hint: Option<String>,
    pub rank_reason: String,
    pub source: String,
}

fn recommendation_item_from_row(row: &sqlx::postgres::PgRow, source: &str) -> RecommendationItem {
    let defects_raw: Option<String> = row.try_get("defects").ok().flatten();
    let defect_hint = defects_raw
        .and_then(|raw| serde_json::from_str::<Vec<String>>(&raw).ok())
        .and_then(|list| list.into_iter().next());
    let rank_reason = row
        .try_get("rank_reason")
        .ok()
        .flatten()
        .unwrap_or_default();
    RecommendationItem {
        id: row.get("id"),
        title: row.get("title"),
        category: row.get("category"),
        brand: row.try_get("brand").ok().flatten().unwrap_or_default(),
        direction: row
            .try_get("direction")
            .ok()
            .unwrap_or_else(|| "offer".to_string()),
        condition_score: row.get("condition_score"),
        suggested_price_cny: crate::utils::cents_to_yuan(row.get::<i64, _>("suggested_price_cny")),
        status: row.get("status"),
        image_url: row.get("image_url"),
        defect_hint,
        rank_reason,
        source: source.to_string(),
    }
}

fn recommendation_item_with_reason(
    row: &sqlx::postgres::PgRow,
    reason: String,
    source: &str,
) -> RecommendationItem {
    let mut item = recommendation_item_from_row(row, source);
    item.rank_reason = reason;
    item
}

pub fn similar_candidate_pool_limit(limit: i64) -> i64 {
    limit.saturating_mul(10).clamp(50, 200)
}

fn normalized_signal(value: &str) -> String {
    value.trim().to_lowercase()
}

fn db_error(error: sqlx::Error) -> ApiError {
    ApiError::Internal(anyhow::anyhow!("DB error: {error}"))
}
