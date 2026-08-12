//! Matching active offers to a legacy wanted listing.
//!
//! The listing API predates the unified intent model, but it still needs the
//! same guarantees: campus and lifecycle constraints are hard filters, while
//! per-viewer feedback may only affect what that viewer sees and in which
//! order. Keeping the query here prevents those rules from drifting into an
//! HTTP handler.

use sqlx::PgPool;
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::repositories::Listing;

#[derive(Debug, sqlx::FromRow)]
struct WantedConstraints {
    id: String,
    owner_id: String,
    direction: String,
    status: String,
    title: String,
    category: String,
    suggested_price_cny: i64,
    condition_score: i32,
}

#[derive(Clone)]
pub struct WantedMatchService {
    db: PgPool,
}

impl WantedMatchService {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    /// Return active offers compatible with one wanted listing.
    ///
    /// Guests keep the public, non-personalized behaviour. For an authenticated
    /// viewer, every explicit feedback action is an exact exclusion. Only a
    /// recent `less_like_this` signal participates in generalized ranking, and
    /// only while personalization is enabled. Because category is already a
    /// hard constraint on this surface, generalized feedback uses the
    /// server-known normalized brand of the feedback target to demote genuinely
    /// similar siblings instead of applying the same no-op category penalty to
    /// every candidate.
    pub async fn matches(
        &self,
        campus_id: Uuid,
        viewer_id: Option<&str>,
        wanted_id: &str,
    ) -> Result<Vec<Listing>, ApiError> {
        // Scope the lookup in SQL so a guessed cross-campus id is
        // indistinguishable from a missing listing.
        let wanted = sqlx::query_as::<_, WantedConstraints>(
            "SELECT id, owner_id, direction, status, title, category,
                    suggested_price_cny, condition_score
             FROM inventory
             WHERE id = $1 AND campus_id = $2",
        )
        .bind(wanted_id)
        .bind(campus_id)
        .fetch_optional(&self.db)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::NotFound)?;

        if wanted.direction != "wanted" {
            return Err(ApiError::BadRequest(
                "只有收物需求可以查看匹配商品".to_string(),
            ));
        }
        if wanted.status != "active"
            || sqlx::query_scalar::<_, bool>("SELECT listing_has_active_restriction($1)")
                .bind(wanted_id)
                .fetch_one(&self.db)
                .await
                .map_err(db_error)?
        {
            return Ok(Vec::new());
        }

        let search_text = literal_contains_pattern(&wanted.title);
        sqlx::query_as::<_, Listing>(
            r#"
            WITH preferences AS (
                SELECT COALESCE(pref.personalization_enabled, TRUE)
                           AS personalization_enabled,
                       COALESCE(pref.signals_reset_at, '-infinity'::timestamptz)
                           AS signals_reset_at
                FROM (SELECT 1) seed
                LEFT JOIN feed_preferences pref
                  ON $8::text IS NOT NULL
                 AND pref.campus_id = $7
                 AND pref.user_id = $8
            ), less_like_brand AS (
                SELECT LOWER(BTRIM(target.brand)) AS brand_key,
                       COUNT(*)::bigint AS weight
                FROM feed_feedback feedback
                JOIN inventory target
                  ON target.id = feedback.resource_id
                 AND target.campus_id = feedback.campus_id
                CROSS JOIN preferences pref
                WHERE $8::text IS NOT NULL
                  AND feedback.campus_id = $7
                  AND feedback.user_id = $8
                  AND feedback.resource_type = 'listing'
                  AND feedback.action = 'less_like_this'
                  AND pref.personalization_enabled
                  AND feedback.updated_at >= pref.signals_reset_at
                  AND NULLIF(LOWER(BTRIM(target.brand)), '') IS NOT NULL
                GROUP BY LOWER(BTRIM(target.brand))
            )
            SELECT i.id, i.campus_id, i.content_revision, i.title, i.category, i.brand, i.direction,
                   i.condition_score, i.suggested_price_cny, i.defects, i.description,
                   CASE WHEN i.images_moderation_status = 'approved'
                        THEN i.image_url ELSE NULL END AS image_url,
                   i.owner_id, i.status, i.created_at
            FROM inventory i
            CROSS JOIN preferences pref
            LEFT JOIN less_like_brand downrank
              ON downrank.brand_key = LOWER(BTRIM(i.brand))
            LEFT JOIN documents wanted_doc ON wanted_doc.id = $1
            LEFT JOIN documents offer_doc ON offer_doc.id = i.id
            WHERE i.status = 'active'
              AND NOT listing_has_active_restriction(i.id)
              AND i.direction = 'offer'
              AND i.owner_id <> $2
              AND ($8::text IS NULL OR i.owner_id <> $8)
              AND i.category = $3
              AND i.suggested_price_cny <= $4
              AND i.condition_score >= $5
              AND i.campus_id = $7
              AND (
                  $8::text IS NULL
                  OR NOT EXISTS (
                      SELECT 1
                      FROM feed_feedback exact_feedback
                      WHERE exact_feedback.user_id = $8
                        AND exact_feedback.campus_id = $7
                        AND exact_feedback.resource_type = 'listing'
                        AND exact_feedback.resource_id = i.id
                  )
              )
            ORDER BY
              CASE WHEN pref.personalization_enabled
                   THEN COALESCE(downrank.weight, 0) ELSE 0 END ASC,
              CASE WHEN wanted_doc.embedding IS NULL OR offer_doc.embedding IS NULL
                   THEN 1 ELSE 0 END ASC,
              CASE WHEN wanted_doc.embedding IS NULL OR offer_doc.embedding IS NULL
                   THEN NULL ELSE offer_doc.embedding <=> wanted_doc.embedding END ASC,
              CASE WHEN i.title ILIKE $6
                         OR COALESCE(i.description, '') ILIKE $6
                   THEN 0 ELSE 1 END ASC,
              i.created_at DESC,
              i.id ASC
            LIMIT 20
            "#,
        )
        .bind(&wanted.id)
        .bind(&wanted.owner_id)
        .bind(&wanted.category)
        .bind(wanted.suggested_price_cny)
        .bind(wanted.condition_score)
        .bind(search_text)
        .bind(campus_id)
        .bind(viewer_id)
        .fetch_all(&self.db)
        .await
        .map_err(db_error)
    }
}

fn literal_contains_pattern(value: &str) -> String {
    let escaped = value
        .replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_");
    format!("%{escaped}%")
}

fn db_error(error: sqlx::Error) -> ApiError {
    ApiError::Internal(anyhow::anyhow!("DB error: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wanted_title_is_a_literal_like_pattern() {
        assert_eq!(
            literal_contains_pattern(r"100%_working\item"),
            r"%100\%\_working\\item%"
        );
    }
}
