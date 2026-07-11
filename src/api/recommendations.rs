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

use crate::api::auth::extract_user_id_from_token_with_fallback;
use crate::api::error::ApiError;
use crate::api::AppState;

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
}

#[derive(Serialize)]
pub struct RecommendationResponse {
    pub items: Vec<RecommendationItem>,
}

fn clamp_feed_limit(limit: Option<i64>) -> i64 {
    limit.unwrap_or(20).clamp(1, 50)
}

fn recommendation_item_from_row(row: &PgRow) -> RecommendationItem {
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
        suggested_price_cny: crate::utils::cents_to_yuan(
            row.get::<i32, _>("suggested_price_cny") as i64
        ),
        status: row.get("status"),
        image_url: row.get("image_url"),
        defect_hint,
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
    direction: &str,
    limit: i64,
    offset: i64,
) -> Result<Vec<RecommendationItem>, ApiError> {
    let rows = sqlx::query(
        r#"
        SELECT id, title, category, brand, direction, condition_score,
               suggested_price_cny, status, image_url, defects
        FROM inventory
        WHERE status = 'active'
          AND ($3 = 'all' OR direction = $3)
        ORDER BY created_at DESC
        LIMIT $1 OFFSET $2
        "#,
    )
    .bind(limit)
    .bind(offset)
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
               inv.suggested_price_cny, inv.status, inv.image_url, inv.defects
        FROM inventory inv
        LEFT JOIN affinity a ON a.category = inv.category
        WHERE inv.status = 'active'
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
    .fetch_all(&state.infra.db)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    Ok(rows.iter().map(recommendation_item_from_row).collect())
}

/// GET /api/recommendations/similar?listing_id=xxx
/// Returns Top-N similar active listings using pgvector cosine distance.
pub async fn get_similar_listings(
    State(state): State<AppState>,
    Query(params): Query<SimilarQuery>,
) -> Result<Json<RecommendationResponse>, ApiError> {
    let limit = params.limit.unwrap_or(10).clamp(1, 20);

    let source_embedding: Option<Vec<f32>> =
        sqlx::query_scalar("SELECT embedding FROM documents WHERE id = $1")
            .bind(&params.listing_id)
            .fetch_optional(&state.infra.db)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    let source_vec = match source_embedding {
        Some(v) => v,
        None => {
            // No embedding for this listing — return newest active as fallback
            let candidates = fetch_recency_feed(&state, "offer", limit + 1, 0).await?;
            let items = remove_source_listing(candidates, &params.listing_id, limit);
            return Ok(Json(RecommendationResponse { items }));
        }
    };

    // Cosine distance: ORDER BY embedding <=> $1 (lower = more similar)
    let rows = sqlx::query(
        r#"
        SELECT i.id, i.title, i.category, i.brand, i.direction,
               i.condition_score, i.suggested_price_cny, i.status,
               i.image_url, i.defects
        FROM inventory i
        JOIN documents d ON d.id = i.id
        WHERE i.id != $1 AND i.status = 'active' AND i.direction = 'offer'
        ORDER BY d.embedding <=> $2
        LIMIT $3
        "#,
    )
    .bind(&params.listing_id)
    .bind(&source_vec)
    .bind(limit)
    .fetch_all(&state.infra.db)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    let items = rows.iter().map(recommendation_item_from_row).collect();
    Ok(Json(RecommendationResponse { items }))
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
    if !["offer", "wanted", "all"].contains(&direction) {
        return Err(ApiError::BadRequest(
            "无效的 direction 参数，可选值：offer, wanted, all".to_string(),
        ));
    }

    let user_id = extract_user_id_from_token_with_fallback(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .ok();

    let items = match user_id.as_deref() {
        Some(uid) => fetch_personalized_feed(&state, uid, direction, limit, offset).await?,
        None => fetch_recency_feed(&state, direction, limit, offset).await?,
    };

    Ok(Json(RecommendationResponse { items }))
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
