//! Recommendation API — pgvector similarity and preference-aware home feed.
//!
//! Endpoints:
//!   GET /api/recommendations/similar?listing_id=xxx — Top-N similar listings (cosine distance)
//!   GET /api/recommendations/feed                  — Home feed (personalized when auth present)

use axum::{
    extract::{Query, State},
    Json,
};
use serde::{Deserialize, Serialize};

use crate::api::error::ApiError;
use crate::api::session::OptionalSession;
use crate::api::AppState;
use crate::services::campus::CampusService;
#[cfg(test)]
use crate::services::feed::similar_candidate_pool_limit;
use crate::services::feed::{FeedService, RecommendationItem};

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

/// GET /api/recommendations/similar?listing_id=xxx
/// Returns Top-N similar active listings using pgvector cosine distance.
pub async fn get_similar_listings(
    State(state): State<AppState>,
    session: OptionalSession,
    Query(params): Query<SimilarQuery>,
) -> Result<Json<RecommendationResponse>, ApiError> {
    let limit = params.limit.unwrap_or(10).clamp(1, 20);
    let (viewer_id, campus_id) = resolve_recommendation_context(&state, session).await?;

    let feed_service = FeedService::new(state.infra.db.clone());
    let source_embedding = feed_service
        .get_source_listing_embedding(&params.listing_id, campus_id)
        .await?;

    let source_vec = match source_embedding {
        Some(v) => v,
        None => {
            let items = feed_service
                .fetch_similar_recency(campus_id, viewer_id.as_deref(), &params.listing_id, limit)
                .await?;
            let items = sign_recommendation_media(&state, items);
            return Ok(Json(RecommendationResponse {
                items,
                ranking_version: SIMILAR_RANKING_VERSION,
            }));
        }
    };

    let items = feed_service
        .fetch_vector_similar(
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

    let feed_service = FeedService::new(state.infra.db.clone());
    let items = match user_id.as_deref() {
        Some(uid) => {
            feed_service
                .fetch_personalized_feed(uid, campus_id, direction, limit, offset)
                .await?
        }
        None => {
            feed_service
                .fetch_recency_feed(campus_id, direction, limit, offset)
                .await?
        }
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
