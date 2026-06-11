use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;

use crate::api::auth::extract_user_id_from_token_with_fallback;
use crate::api::error::ApiError;
use crate::api::AppState;
use crate::utils::cents_to_yuan;

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
    headers: HeaderMap,
    Query(params): Query<WatchlistQuery>,
) -> Result<Json<WatchlistResponse>, ApiError> {
    let user_id = extract_user_id_from_token_with_fallback(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)?;

    let limit = params.limit.unwrap_or(20).clamp(1, 100);
    let offset = params.offset.unwrap_or(0).max(0);

    let count_row = sqlx::query(
        "SELECT COUNT(*) as cnt FROM watchlist w \
         JOIN inventory i ON w.listing_id = i.id \
         WHERE w.user_id = $1 AND i.status = 'active'",
    )
    .bind(&user_id)
    .fetch_one(&state.infra.db)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
    let total: i64 = count_row.try_get("cnt").unwrap_or(0);

    let rows = sqlx::query(
        r#"
        SELECT i.id as listing_id, i.title, i.category, i.brand, i.condition_score,
               i.suggested_price_cny, i.status, i.owner_id, i.created_at
        FROM watchlist w
        JOIN inventory i ON w.listing_id = i.id
        WHERE w.user_id = $1 AND i.status = 'active'
        ORDER BY w.created_at DESC
        LIMIT $2 OFFSET $3
        "#,
    )
    .bind(&user_id)
    .bind(limit)
    .bind(offset)
    .fetch_all(&state.infra.db)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    let items: Vec<WatchlistItem> = rows
        .iter()
        .map(|row| {
            let created_at: String = row
                .try_get::<sqlx::types::chrono::DateTime<sqlx::types::chrono::Utc>, _>("created_at")
                .map(|dt| dt.to_rfc3339())
                .unwrap_or_else(|_| String::new());
            WatchlistItem {
                listing_id: row.get("listing_id"),
                title: row.get("title"),
                category: row.get("category"),
                brand: row.try_get("brand").ok().flatten().unwrap_or_default(),
                condition_score: row.get("condition_score"),
                suggested_price_cny: cents_to_yuan(row.get::<i32, _>("suggested_price_cny") as i64),
                status: row.get("status"),
                owner_id: row.get("owner_id"),
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
    headers: HeaderMap,
    Path(listing_id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let user_id = extract_user_id_from_token_with_fallback(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)?;

    // Verify listing exists and reject self-watchlisting.
    let owner_id = sqlx::query_scalar::<_, String>("SELECT owner_id FROM inventory WHERE id = $1")
        .bind(&listing_id)
        .fetch_optional(&state.infra.db)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    let Some(owner_id) = owner_id else {
        return Err(ApiError::NotFound);
    };
    if owner_id == user_id {
        return Err(ApiError::BadRequest("不能收藏自己的商品".to_string()));
    }

    // Insert into watchlist (ignore if already exists)
    sqlx::query(
        "INSERT INTO watchlist (user_id, listing_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
    )
    .bind(&user_id)
    .bind(&listing_id)
    .execute(&state.infra.db)
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    Ok(Json(serde_json::json!({
        "message": "已添加到关注列表",
        "listing_id": listing_id
    })))
}

/// DELETE /api/watchlist/:listing_id - remove listing from watchlist
pub async fn remove_from_watchlist(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(listing_id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let user_id = extract_user_id_from_token_with_fallback(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)?;

    sqlx::query("DELETE FROM watchlist WHERE user_id = $1 AND listing_id = $2")
        .bind(&user_id)
        .bind(&listing_id)
        .execute(&state.infra.db)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    Ok(Json(serde_json::json!({
        "message": "已从关注列表移除",
        "listing_id": listing_id
    })))
}

/// GET /api/watchlist/:listing_id - check if listing is in watchlist
pub async fn check_watchlist(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(listing_id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let user_id = extract_user_id_from_token_with_fallback(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)?;

    let exists = sqlx::query("SELECT 1 FROM watchlist WHERE user_id = $1 AND listing_id = $2")
        .bind(&user_id)
        .bind(&listing_id)
        .fetch_optional(&state.infra.db)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        .is_some();

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
