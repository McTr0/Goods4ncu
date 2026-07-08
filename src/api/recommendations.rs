//! Recommendation API — pgvector embedding-based similar listings and personalized feed.
//!
//! Endpoints:
//!   GET /api/recommendations?listing_id=xxx — Top-N similar listings (cosine distance)
//!   GET /api/recommendations/feed          — Personalized feed (for now: newest active listings)

use axum::{
    extract::{Query, State},
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;

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
}

#[derive(Serialize)]
pub struct RecommendationItem {
    pub id: String,
    pub title: String,
    pub category: String,
    pub brand: String,
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

/// GET /api/recommendations?listing_id=xxx
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
            return get_recommendation_feed(
                State(state),
                Query(FeedQuery {
                    limit: Some(limit),
                    offset: None,
                }),
            )
            .await;
        }
    };

    // Cosine distance: ORDER BY embedding <=> $1 (lower = more similar)
    let rows = sqlx::query(
        r#"
        SELECT i.id, i.title, i.category, i.brand,
               i.condition_score, i.suggested_price_cny, i.status,
               i.image_url, i.defects
        FROM inventory i
        JOIN documents d ON d.id = i.id
        WHERE i.id != $1 AND i.status = 'active'
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

    let items = rows
        .iter()
        .map(|row| {
            let defects_text: String = row.get("defects");
            let defects: Vec<String> = serde_json::from_str(&defects_text).unwrap_or_default();
            let defect_hint = defects.first().cloned();
            RecommendationItem {
                id: row.get("id"),
                title: row.get("title"),
                category: row.get("category"),
                brand: row.try_get("brand").ok().flatten().unwrap_or_default(),
                condition_score: row.get("condition_score"),
                suggested_price_cny: crate::utils::cents_to_yuan(
                    row.get::<i32, _>("suggested_price_cny") as i64,
                ),
                status: row.get("status"),
                image_url: row.get("image_url"),
                defect_hint,
            }
        })
        .collect();

    Ok(Json(RecommendationResponse { items }))
}

/// GET /api/recommendations/feed
/// Returns newest active listings as feed (placeholder for collaborative filtering).
pub async fn get_recommendation_feed(
    State(state): State<AppState>,
    Query(params): Query<FeedQuery>,
) -> Result<Json<RecommendationResponse>, ApiError> {
    let limit = params.limit.unwrap_or(20).clamp(1, 50);
    let offset = params.offset.unwrap_or(0).max(0);

    let rows = sqlx::query(
        r#"
        SELECT id, title, category, brand, condition_score,
               suggested_price_cny, status, image_url, defects
        FROM inventory
        WHERE status = 'active'
        ORDER BY created_at DESC
        LIMIT $1 OFFSET $2
        "#,
    )
    .bind(limit)
    .bind(offset)
    .fetch_all(&state.infra.db)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    let items = rows
        .iter()
        .map(|row| {
            let defects_text: String = row.get("defects");
            let defects: Vec<String> = serde_json::from_str(&defects_text).unwrap_or_default();
            let defect_hint = defects.first().cloned();
            RecommendationItem {
                id: row.get("id"),
                title: row.get("title"),
                category: row.get("category"),
                brand: row.try_get("brand").ok().flatten().unwrap_or_default(),
                condition_score: row.get("condition_score"),
                suggested_price_cny: crate::utils::cents_to_yuan(
                    row.get::<i32, _>("suggested_price_cny") as i64,
                ),
                status: row.get("status"),
                image_url: row.get("image_url"),
                defect_hint,
            }
        })
        .collect();

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
            condition_score: 9,
            suggested_price_cny: 299.0,
            status: "active".to_string(),
            image_url: Some("http://localhost/image.webp".to_string()),
            defect_hint: None,
        };

        let json = serde_json::to_value(item).expect("recommendation should serialize");
        assert_eq!(json["image_url"], "http://localhost/image.webp");
    }
}
