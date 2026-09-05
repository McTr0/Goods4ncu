use axum::{
    extract::{Path, Query, State},
    Json,
};
use serde::{Deserialize, Serialize};

use crate::api::error::ApiError;
use crate::api::session::{Session, VerifiedTenant};
use crate::api::AppState;
use crate::services::watchlist::{WatchlistError, WatchlistService};
use crate::utils::cents_to_yuan;

impl From<WatchlistError> for ApiError {
    fn from(err: WatchlistError) -> Self {
        match err {
            WatchlistError::NotFound => ApiError::NotFound,
            WatchlistError::CannotWatchOwnListing => {
                ApiError::BadRequest("不能收藏自己的商品".to_string())
            }
            WatchlistError::Database(e) => ApiError::Internal(anyhow::anyhow!("DB error: {}", e)),
        }
    }
}

#[derive(Deserialize)]
pub struct WatchlistQuery {
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

#[derive(Serialize)]
pub struct WatchlistItem {
    pub listing_id: String,
    pub title: String,
    pub category: String,
    pub brand: String,
    pub condition_score: i32,
    pub suggested_price_cny: f64,
    pub status: String,
    pub owner_id: String,
    pub created_at: String,
}

#[derive(Serialize)]
pub struct WatchlistResponse {
    pub items: Vec<WatchlistItem>,
    pub total: i64,
    pub limit: i64,
    pub offset: i64,
}

/// GET /api/watchlist - get user's watchlist (paginated)
pub async fn get_watchlist(
    State(state): State<AppState>,
    Session(session): Session,
    Query(params): Query<WatchlistQuery>,
) -> Result<Json<WatchlistResponse>, ApiError> {
    let limit = params.limit.unwrap_or(20).clamp(1, 100);
    let offset = params.offset.unwrap_or(0).max(0);

    let service = WatchlistService::new(state.infra.db.clone());
    let (rows, total) = service
        .get_user_watchlist(&session.user_id, limit, offset)
        .await?;

    let items: Vec<WatchlistItem> = rows
        .into_iter()
        .map(|row| {
            let created_at = row.created_at.map(|dt| dt.to_rfc3339()).unwrap_or_default();
            WatchlistItem {
                listing_id: row.listing_id,
                title: row.title,
                category: row.category,
                brand: row.brand,
                condition_score: row.condition_score,
                suggested_price_cny: cents_to_yuan(row.suggested_price_cny),
                status: row.status,
                owner_id: row.owner_id,
                created_at,
            }
        })
        .collect();

    Ok(Json(WatchlistResponse {
        items,
        total,
        limit,
        offset,
    }))
}

/// POST /api/watchlist/:listing_id - add listing to watchlist
pub async fn add_to_watchlist(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(listing_id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let service = WatchlistService::new(state.infra.db.clone());
    service
        .add_to_watchlist(&tenant.session.user_id, &listing_id, tenant.campus_id)
        .await?;

    Ok(Json(serde_json::json!({
        "message": "已添加到关注列表",
        "listing_id": listing_id
    })))
}

/// DELETE /api/watchlist/:listing_id - remove listing from watchlist
pub async fn remove_from_watchlist(
    State(state): State<AppState>,
    Session(session): Session,
    Path(listing_id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let service = WatchlistService::new(state.infra.db.clone());
    service
        .remove_from_watchlist(&session.user_id, &listing_id)
        .await?;

    Ok(Json(serde_json::json!({
        "message": "已从关注列表移除",
        "listing_id": listing_id
    })))
}

/// GET /api/watchlist/:listing_id - check if listing is in watchlist
pub async fn check_watchlist(
    State(state): State<AppState>,
    Session(session): Session,
    Path(listing_id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let service = WatchlistService::new(state.infra.db.clone());
    let exists = service
        .check_watchlist(&session.user_id, &listing_id)
        .await?;

    Ok(Json(serde_json::json!({
        "watched": exists,
        "listing_id": listing_id
    })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_watchlist_query_defaults() {
        let query: WatchlistQuery = serde_json::from_str(r#"{}"#).unwrap();
        assert_eq!(query.limit, None);
        assert_eq!(query.offset, None);
    }

    #[test]
    fn test_watchlist_query_with_pagination() {
        let query: WatchlistQuery = serde_json::from_str(r#"{"limit": 10, "offset": 20}"#).unwrap();
        assert_eq!(query.limit, Some(10));
        assert_eq!(query.offset, Some(20));
    }

    #[test]
    fn test_watchlist_item_serialization() {
        let item = WatchlistItem {
            listing_id: "listing-123".to_string(),
            title: "iPhone 13".to_string(),
            category: "electronics".to_string(),
            brand: "Apple".to_string(),
            condition_score: 8,
            suggested_price_cny: 4999.0,
            status: "active".to_string(),
            owner_id: "user-456".to_string(),
            created_at: "2024-01-01T00:00:00Z".to_string(),
        };
        let json = serde_json::to_string(&item).unwrap();
        assert!(json.contains("iPhone 13"));
        assert!(json.contains("electronics"));
        assert!(json.contains("Apple"));
    }

    #[test]
    fn test_watchlist_response_serialization() {
        let response = WatchlistResponse {
            items: vec![],
            total: 0,
            limit: 20,
            offset: 0,
        };
        let json = serde_json::to_string(&response).unwrap();
        assert!(json.contains("\"items\":[]"));
        assert!(json.contains("\"total\":0"));
        assert!(json.contains("\"limit\":20"));
        assert!(json.contains("\"offset\":0"));
    }

    #[test]
    fn test_watchlist_response_with_items() {
        let response = WatchlistResponse {
            items: vec![WatchlistItem {
                listing_id: "listing-1".to_string(),
                title: "Test Item".to_string(),
                category: "electronics".to_string(),
                brand: "TestBrand".to_string(),
                condition_score: 7,
                suggested_price_cny: 2999.0,
                status: "active".to_string(),
                owner_id: "owner-1".to_string(),
                created_at: "2024-01-01T00:00:00Z".to_string(),
            }],
            total: 1,
            limit: 20,
            offset: 0,
        };
        let json = serde_json::to_string(&response).unwrap();
        assert!(json.contains("Test Item"));
        assert!(json.contains("\"total\":1"));
    }
}
