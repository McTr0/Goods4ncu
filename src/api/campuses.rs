use axum::{extract::State, Json};

use crate::api::error::ApiError;
use crate::api::AppState;
use crate::services::campus::{CampusService, CampusView};

/// GET /api/campuses - public list used before authentication and registration.
pub async fn list_campuses(
    State(state): State<AppState>,
) -> Result<Json<Vec<CampusView>>, ApiError> {
    let service = CampusService::new(state.infra.db.clone());
    Ok(Json(service.list_active_campuses().await?))
}
