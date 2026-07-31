use axum::extract::State;
use axum::Json;
use serde::Serialize;
use sqlx::Row;
use tokio::try_join;

use crate::api::AppState;
use crate::categories::normalize_category_or_other;

#[derive(Serialize)]
pub struct MarketplaceStats {
    pub total_listings: i64,
    pub active_listings: i64,
    pub total_users: i64,
    pub total_orders: i64,
    pub categories: Vec<CategoryCount>,
}

#[derive(Serialize)]
pub struct CategoryCount {
    pub category: String,
    pub count: i64,
}

async fn count_query(db: &sqlx::PgPool, sql: &str) -> Result<i64, crate::api::error::ApiError> {
    let row = sqlx::query(sql)
        .fetch_one(db)
        .await
        .map_err(|e| crate::api::error::ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
    row.try_get::<i64, _>("cnt").map_err(|_| {
        crate::api::error::ApiError::Internal(anyhow::anyhow!("Failed to parse count"))
    })
}

/// GET /api/stats - public marketplace statistics
pub async fn get_stats(
    State(state): State<AppState>,
) -> Result<Json<MarketplaceStats>, crate::api::error::ApiError> {
    let (total_listings, active_listings, total_users, total_orders) = try_join!(
        count_query(&state.infra.db, "SELECT COUNT(*) as cnt FROM inventory"),
        count_query(
            &state.infra.db,
            "SELECT COUNT(*) as cnt FROM inventory WHERE status = 'active'
               AND NOT listing_has_active_restriction(id)"
        ),
        count_query(&state.infra.db, "SELECT COUNT(*) as cnt FROM users"),
        count_query(&state.infra.db, "SELECT COUNT(*) as cnt FROM orders"),
    )?;

    let category_rows = sqlx::query(
        "SELECT category, COUNT(*) as cnt FROM inventory
         WHERE status = 'active' AND NOT listing_has_active_restriction(id)
         GROUP BY category ORDER BY cnt DESC",
    )
    .fetch_all(&state.infra.db)
    .await
    .map_err(|e| crate::api::error::ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    let mut merged = std::collections::BTreeMap::<String, i64>::new();
    for row in category_rows {
        let category: String = row.get("category");
        let count: i64 = row.get("cnt");
        *merged
            .entry(normalize_category_or_other(&category).to_string())
            .or_default() += count;
    }
    let mut categories: Vec<CategoryCount> = merged
        .into_iter()
        .map(|(category, count)| CategoryCount { category, count })
        .collect();
    categories.sort_by(|a, b| {
        b.count
            .cmp(&a.count)
            .then_with(|| a.category.cmp(&b.category))
    });

    Ok(Json(MarketplaceStats {
        total_listings,
        active_listings,
        total_users,
        total_orders,
        categories,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_category_count_serialization() {
        let cat = CategoryCount {
            category: "electronics".to_string(),
            count: 42,
        };
        let json = serde_json::to_string(&cat).unwrap();
        assert!(json.contains("electronics"));
        assert!(json.contains("42"));
    }

    #[test]
    fn test_marketplace_stats_serialization() {
        let stats = MarketplaceStats {
            total_listings: 100,
            active_listings: 75,
            total_users: 50,
            total_orders: 30,
            categories: vec![
                CategoryCount {
                    category: "electronics".to_string(),
                    count: 20,
                },
                CategoryCount {
                    category: "books".to_string(),
                    count: 15,
                },
            ],
        };
        let json = serde_json::to_string(&stats).unwrap();
        assert!(json.contains("total_listings"));
        assert!(json.contains("100"));
        assert!(json.contains("categories"));
        assert!(json.contains("electronics"));
    }

    #[test]
    fn test_marketplace_stats_empty_categories() {
        let stats = MarketplaceStats {
            total_listings: 0,
            active_listings: 0,
            total_users: 0,
            total_orders: 0,
            categories: vec![],
        };
        let json = serde_json::to_string(&stats).unwrap();
        assert!(json.contains("\"categories\":[]"));
    }
}
