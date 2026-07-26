//! Recommendation API — pgvector similarity and preference-aware home feed.
//!
//! Endpoints:
//!   GET /api/recommendations/similar?listing_id=xxx — Top-N similar listings (cosine distance)
//!   GET /api/recommendations/feed                  — Home feed (personalized when auth present)

use axum::{
    extract::{Query, State},
    http::HeaderMap,
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::{postgres::PgRow, Row};

use crate::api::auth::extract_auth_session_from_token_with_fallback;
use crate::api::error::ApiError;
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
pub const RANKING_VERSION: &str = "2026.07-affinity-v1";

#[derive(Serialize)]
pub struct RecommendationResponse {
    pub items: Vec<RecommendationItem>,
    pub ranking_version: &'static str,
}

async fn resolve_recommendation_context(
    state: &AppState,
    headers: &HeaderMap,
) -> Result<(Option<String>, uuid::Uuid), ApiError> {
    let campus_service = CampusService::new(state.infra.db.clone());
    match extract_auth_session_from_token_with_fallback(
        headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    ) {
        Ok(session) => {
            let campus_id = campus_service
                .resolve_session_campus(&session.user_id, session.campus_id)
                .await?;
            Ok((Some(session.user_id), campus_id))
        }
        Err(_) => Ok((None, campus_service.default_public_campus_id().await?)),
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

fn remove_source_listing(
    items: Vec<RecommendationItem>,
    source_listing_id: &str,
    limit: i64,
) -> Vec<RecommendationItem> {
    items
        .into_iter()
        .filter(|item| item.id != source_listing_id)
        .take(limit as usize)
        .collect()
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
        WITH affinity AS (
            SELECT i.category, COUNT(*)::float8 AS weight
            FROM (
                SELECT listing_id FROM watchlist WHERE user_id = $1
                UNION ALL
                SELECT listing_id FROM orders WHERE buyer_id = $1
            ) signals
            JOIN inventory i ON i.id = signals.listing_id
            GROUP BY i.category
        )
        SELECT inv.id, inv.title, inv.category, inv.brand, inv.direction, inv.condition_score,
               inv.suggested_price_cny, inv.status,
               CASE WHEN inv.images_moderation_status = 'approved' THEN inv.image_url ELSE NULL END AS image_url,
               inv.defects,
               COALESCE(a.weight, 0) AS affinity_weight
        FROM inventory inv
        LEFT JOIN affinity a ON a.category = inv.category
        WHERE inv.status = 'active'
          AND inv.campus_id = $5
          AND inv.owner_id <> $1
          AND ($4 = 'all' OR inv.direction = $4)
          AND NOT EXISTS (
              SELECT 1 FROM watchlist w
              WHERE w.user_id = $1 AND w.listing_id = inv.id
          )
        ORDER BY COALESCE(a.weight, 0) DESC, inv.created_at DESC
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
            let weight: f64 = row.try_get("affinity_weight").unwrap_or(0.0);
            if weight > 0.0 {
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

/// GET /api/recommendations/similar?listing_id=xxx
/// Returns Top-N similar active listings using pgvector cosine distance.
pub async fn get_similar_listings(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(params): Query<SimilarQuery>,
) -> Result<Json<RecommendationResponse>, ApiError> {
    let limit = params.limit.unwrap_or(10).clamp(1, 20);
    let (_, campus_id) = resolve_recommendation_context(&state, &headers).await?;

    let source_embedding: Option<Vec<f32>> = sqlx::query_scalar(
        "SELECT d.embedding
         FROM documents d
         JOIN inventory i ON i.id = d.id
         WHERE d.id = $1 AND i.campus_id = $2",
    )
    .bind(&params.listing_id)
    .bind(campus_id)
    .fetch_optional(&state.infra.db)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    let source_vec = match source_embedding {
        Some(v) => v,
        None => {
            // No embedding for this listing — return newest active as fallback
            let candidates = fetch_recency_feed(&state, campus_id, "offer", limit + 1, 0).await?;
            let items = remove_source_listing(candidates, &params.listing_id, limit);
            let items = sign_recommendation_media(&state, items);
            return Ok(Json(RecommendationResponse {
                items,
                ranking_version: RANKING_VERSION,
            }));
        }
    };

    // Cosine distance: ORDER BY embedding <=> $1 (lower = more similar)
    let rows = sqlx::query(
        r#"
        SELECT i.id, i.title, i.category, i.brand, i.direction,
               i.condition_score, i.suggested_price_cny, i.status,
               CASE WHEN i.images_moderation_status = 'approved' THEN i.image_url ELSE NULL END AS image_url,
               i.defects
        FROM inventory i
        JOIN documents d ON d.id = i.id
        WHERE i.id != $1 AND i.status = 'active' AND i.direction = 'offer'
          AND i.campus_id = $4
        ORDER BY d.embedding <=> $2
        LIMIT $3
        "#,
    )
    .bind(&params.listing_id)
    .bind(&source_vec)
    .bind(limit)
    .bind(campus_id)
    .fetch_all(&state.infra.db)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    let items = rows
        .iter()
        .map(|row| {
            recommendation_item_with_reason(row, "与当前商品相似".to_string(), "vector_similarity")
        })
        .collect();
    let items = sign_recommendation_media(&state, items);
    Ok(Json(RecommendationResponse {
        items,
        ranking_version: RANKING_VERSION,
    }))
}

/// GET /api/recommendations/feed
///
/// Anonymous clients get newest active listings.
/// Authenticated clients get a category-affinity ranking from watchlist +
/// buyer order history, excluding own listings and already-watched items.
pub async fn get_recommendation_feed(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(params): Query<FeedQuery>,
) -> Result<Json<RecommendationResponse>, ApiError> {
    let limit = clamp_feed_limit(params.limit);
    let offset = params.offset.unwrap_or(0).max(0);
    let direction = params.direction.as_deref().unwrap_or("offer");
    let (user_id, campus_id) = resolve_recommendation_context(&state, &headers).await?;
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
    fn recency_fallback_removes_source_and_preserves_limit() {
        let make_item = |id: &str| RecommendationItem {
            id: id.to_string(),
            title: id.to_string(),
            category: "electronics".to_string(),
            brand: "Demo".to_string(),
            direction: "offer".to_string(),
            condition_score: 8,
            suggested_price_cny: 10.0,
            status: "active".to_string(),
            image_url: None,
            defect_hint: None,
            rank_reason: "最新发布".to_string(),
            source: "recency".to_string(),
        };
        let items = vec![
            make_item("source"),
            make_item("next-1"),
            make_item("next-2"),
        ];

        let filtered = remove_source_listing(items, "source", 2);
        assert_eq!(filtered.len(), 2);
        assert_eq!(filtered[0].id, "next-1");
        assert_eq!(filtered[1].id, "next-2");
    }
}
