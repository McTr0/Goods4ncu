//! Camphor leaf (香樟叶) endpoints: balance, daily grant, fertilize.

use axum::extract::{Path, State};
use axum::response::Response;
use serde::Serialize;
use uuid::Uuid;

use crate::api::agent_plans::no_store_json;
use crate::api::error::ApiError;
use crate::api::session::VerifiedTenant;
use crate::api::AppState;
use crate::services::camphor::CamphorService;

/// GET /api/camphor — balance; also settles today's login grant.
pub async fn get_balance(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
) -> Result<Response, ApiError> {
    let service = CamphorService::new(state.infra.db.clone());
    let balance = service
        .settle_daily_grant(tenant.campus_id, &tenant.session.user_id)
        .await?;
    Ok(no_store_json(
        serde_json::json!({ "balance": balance, "granted_today": true }),
    ))
}

#[derive(Debug, Serialize)]
pub struct FertilizeView {
    pub balance: i64,
    pub fertilizer_count: i32,
}

/// POST /api/posts/{id}/fertilize — spend one leaf on a post.
pub async fn fertilize_post(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(id): Path<Uuid>,
) -> Result<Response, ApiError> {
    let service = CamphorService::new(state.infra.db.clone());
    let (balance, fertilizer_count) = service
        .fertilize(tenant.campus_id, &tenant.session.user_id, id)
        .await?;
    Ok(no_store_json(serde_json::json!(FertilizeView {
        balance,
        fertilizer_count,
    })))
}
