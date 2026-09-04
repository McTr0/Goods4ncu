use axum::extract::State;
use axum::Json;
use serde::Serialize;

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

/// GET /api/stats - public marketplace statistics
pub async fn get_stats(
    State(state): State<AppState>,
) -> Result<Json<MarketplaceStats>, crate::api::error::ApiError> {
    let stats = state.listing_repo.get_marketplace_stats().await?;

    let mut merged = std::collections::BTreeMap::<String, i64>::new();
    for (category, count) in stats.category_counts {
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
        total_listings: stats.total_listings,
        active_listings: stats.active_listings,
        total_users: stats.total_users,
        total_orders: stats.total_orders,
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
