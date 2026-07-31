//! Recommendation API — pgvector similarity and preference-aware home feed.
//!
//! Endpoints:
//!   GET /api/recommendations/similar?listing_id=xxx — Top-N similar listings (cosine distance)
//!   GET /api/recommendations/feed                  — Home feed (personalized when auth present)

use axum::{
    extract::{Query, State},
    Json,
};
use pgvector::Vector;
use serde::{Deserialize, Serialize};
use sqlx::{postgres::PgRow, Row};

use crate::api::error::ApiError;
use crate::api::session::OptionalSession;
use crate::api::AppState;
use crate::services::campus::CampusService;

#[derive(Deserialize)]
pub struct SimilarQuery {
    pub listing_id: String,
    pub limit: Option<i64>,
}

#[derive(Deserialize)]
pub struct FeedQuery {
    pub limit: Option<i64>,
    pub offset: Option<i64>,
    pub direction: Option<String>,
}

#[derive(Serialize)]
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
    /// User-facing explanation of why this item ranks here (Phase 2: every
    /// personalized recommendation must carry an understandable reason).
    pub rank_reason: String,
    /// Machine-readable recall source: `recency` | `category_affinity` | `vector_similarity`.
    pub source: String,
}

/// Version tag for the current ranking logic. Clients and offline evaluation
/// reference this when comparing ranking behaviour across releases.
pub const RANKING_VERSION: &str = "2026.07-feedback-v2";
pub const SIMILAR_RANKING_VERSION: &str = "2026.07-similar-feedback-v1";

#[derive(Serialize)]
pub struct RecommendationResponse {
    pub items: Vec<RecommendationItem>,
    pub ranking_version: &'static str,
}

async fn resolve_recommendation_context(
    state: &AppState,
    session: OptionalSession,
) -> Result<(Option<String>, uuid::Uuid), ApiError> {
    let campus_service = CampusService::new(state.infra.db.clone());
    match session.0 {
        Some(session) => {
            let campus_id = campus_service
                .resolve_session_campus(&session.user_id, session.campus_id)
                .await?;
            Ok((Some(session.user_id), campus_id))
        }
        None => Ok((None, campus_service.default_public_campus_id().await?)),
    }
}

fn clamp_feed_limit(limit: Option<i64>) -> i64 {
    limit.unwrap_or(20).clamp(1, 50)
}

/// Rewrite approved media to presigned URLs when the bucket is private.
fn sign_recommendation_media(
    state: &AppState,
    items: Vec<RecommendationItem>,
) -> Vec<RecommendationItem> {
    items
        .into_iter()
        .map(|mut item| {
            item.image_url = state.public_media_url(item.image_url);
            item
        })
        .collect()
}

fn recommendation_item_from_row(row: &PgRow) -> RecommendationItem {
    recommendation_item_with_reason(row, "最新发布".to_string(), "recency")
}

fn recommendation_item_with_reason(
    row: &PgRow,
    rank_reason: String,
    source: &str,
) -> RecommendationItem {
    let defects_text: String = row.get("defects");
    let defects: Vec<String> = serde_json::from_str(&defects_text).unwrap_or_default();
    let defect_hint = defects.first().cloned();
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

fn similar_candidate_pool_limit(limit: i64) -> i64 {
    limit.saturating_mul(10).clamp(50, 200)
}

async fn fetch_recency_feed(
    state: &AppState,
    campus_id: uuid::Uuid,
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
    .fetch_all(&state.infra.db)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    Ok(rows.iter().map(recommendation_item_from_row).collect())
}

/// Preference-aware feed for authenticated users.
///
/// Ranking signal (higher first):
/// 1. Category affinity from watchlist + buyer order intents
/// 2. Recency
///
/// Excludes the viewer's own listings and items already on their watchlist so
/// the home feed surfaces fresh candidates instead of replaying favorites.
async fn fetch_personalized_feed(
    state: &AppState,
    user_id: &str,
    campus_id: uuid::Uuid,
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
    .fetch_all(&state.infra.db)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

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

/// Recency fallback for a source listing without an embedding.
///
/// Exact feedback is an explicit standing instruction and therefore remains
/// active even when personalization is disabled or old ranking signals have
/// been cleared. Category downranking is a generalized signal, so it observes
/// both controls.
async fn fetch_similar_recency(
    state: &AppState,
    campus_id: uuid::Uuid,
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
    .fetch_all(&state.infra.db)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    Ok(rows
        .iter()
        .map(|row| recommendation_item_with_reason(row, "recency".to_string(), "recency"))
        .collect())
}

/// Vector recall with a bounded semantic candidate pool followed by
/// preference-aware re-ranking.
///
/// Keeping the inner ordering as the bare cosine-distance expression allows
/// PostgreSQL to use the pgvector HNSW index. Exact exclusions happen inside
/// that pool so a hidden top result cannot consume one of its slots.
async fn fetch_vector_similar(
    state: &AppState,
    campus_id: uuid::Uuid,
    viewer_id: Option<&str>,
    source_listing_id: &str,
    source_embedding: &Vector,
    limit: i64,
) -> Result<Vec<RecommendationItem>, ApiError> {
    let candidate_pool_limit = similar_candidate_pool_limit(limit);
    let mut tx = state
        .infra
        .db
        .begin()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
    // pgvector otherwise applies selective campus/lifecycle/viewer filters
    // after one approximate HNSW pass, which can underfill the candidate pool.
    // Iterative scan keeps expanding until it has enough eligible rows while
    // preserving the strict distance order used by the bounded reranker.
    sqlx::query("SET LOCAL hnsw.iterative_scan = strict_order")
        .execute(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
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
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
    tx.commit()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

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

/// GET /api/recommendations/similar?listing_id=xxx
/// Returns Top-N similar active listings using pgvector cosine distance.
pub async fn get_similar_listings(
    State(state): State<AppState>,
    session: OptionalSession,
    Query(params): Query<SimilarQuery>,
) -> Result<Json<RecommendationResponse>, ApiError> {
    let limit = params.limit.unwrap_or(10).clamp(1, 20);
    let (viewer_id, campus_id) = resolve_recommendation_context(&state, session).await?;

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
    .bind(&params.listing_id)
    .bind(campus_id)
    .fetch_optional(&state.infra.db)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
    .ok_or(ApiError::NotFound)?;
    let source_embedding: Option<Vector> = source
        .try_get("embedding")
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    let source_vec = match source_embedding {
        Some(v) => v,
        None => {
            let items = fetch_similar_recency(
                &state,
                campus_id,
                viewer_id.as_deref(),
                &params.listing_id,
                limit,
            )
            .await?;
            let items = sign_recommendation_media(&state, items);
            return Ok(Json(RecommendationResponse {
                items,
                ranking_version: SIMILAR_RANKING_VERSION,
            }));
        }
    };

    let items = fetch_vector_similar(
        &state,
        campus_id,
        viewer_id.as_deref(),
        &params.listing_id,
        &source_vec,
        limit,
    )
    .await?;
    let items = sign_recommendation_media(&state, items);
    Ok(Json(RecommendationResponse {
        items,
        ranking_version: SIMILAR_RANKING_VERSION,
    }))
}

/// GET /api/recommendations/feed
///
/// Anonymous clients get newest active listings.
/// Authenticated clients get a category-affinity ranking from watchlist +
/// buyer order history, excluding own listings and already-watched items.
pub async fn get_recommendation_feed(
    State(state): State<AppState>,
    session: OptionalSession,
    Query(params): Query<FeedQuery>,
) -> Result<Json<RecommendationResponse>, ApiError> {
    let limit = clamp_feed_limit(params.limit);
    let offset = params.offset.unwrap_or(0).max(0);
    let direction = params.direction.as_deref().unwrap_or("offer");
    let (user_id, campus_id) = resolve_recommendation_context(&state, session).await?;
    if !["offer", "wanted", "all"].contains(&direction) {
        return Err(ApiError::BadRequest(
            "无效的 direction 参数，可选值：offer, wanted, all".to_string(),
        ));
    }

    let items = match user_id.as_deref() {
        Some(uid) => {
            fetch_personalized_feed(&state, uid, campus_id, direction, limit, offset).await?
        }
        None => fetch_recency_feed(&state, campus_id, direction, limit, offset).await?,
    };

    let items = sign_recommendation_media(&state, items);
    Ok(Json(RecommendationResponse {
        items,
        ranking_version: RANKING_VERSION,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recommendation_item_serializes_image_url() {
        let item = RecommendationItem {
            id: "listing-1".to_string(),
            title: "Demo listing".to_string(),
            category: "electronics".to_string(),
            brand: "Demo".to_string(),
            direction: "offer".to_string(),
            condition_score: 9,
            suggested_price_cny: 299.0,
            status: "active".to_string(),
            image_url: Some("http://localhost/image.webp".to_string()),
            defect_hint: None,
            rank_reason: "最新发布".to_string(),
            source: "recency".to_string(),
        };

        let json = serde_json::to_value(item).expect("recommendation should serialize");
        assert_eq!(json["image_url"], "http://localhost/image.webp");
    }

    #[test]
    fn feed_limit_clamps_to_safe_range() {
        let high = clamp_feed_limit(Some(999));
        let low = clamp_feed_limit(Some(0));
        let missing = clamp_feed_limit(None);
        assert_eq!(high, 50);
        assert_eq!(low, 1);
        assert_eq!(missing, 20);
    }

    #[test]
    fn vector_rerank_candidate_pool_is_bounded() {
        assert_eq!(similar_candidate_pool_limit(1), 50);
        assert_eq!(similar_candidate_pool_limit(10), 100);
        assert_eq!(similar_candidate_pool_limit(20), 200);
        assert_eq!(similar_candidate_pool_limit(i64::MAX), 200);
    }
}
