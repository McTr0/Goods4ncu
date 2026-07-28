use axum::{
    extract::{Path, State},
    Json,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::api::session::VerifiedTenant;
use crate::api::AppState;
use crate::services::content_report::ContentReportService;

#[derive(Deserialize)]
pub struct SubmitContentReportRequest {
    pub reason: String,
    pub details: Option<String>,
}

#[derive(Serialize)]
pub struct SubmitContentReportResponse {
    pub report_id: Uuid,
}

pub async fn report_listing(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(listing_id): Path<String>,
    Json(body): Json<SubmitContentReportRequest>,
) -> Result<Json<SubmitContentReportResponse>, ApiError> {
    let report_id = ContentReportService::new(state.infra.db.clone())
        .report_listing(
            tenant.campus_id,
            &tenant.session.user_id,
            &listing_id,
            &body.reason,
            body.details.as_deref(),
        )
        .await?;
    Ok(Json(SubmitContentReportResponse { report_id }))
}

pub async fn report_user(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(user_id): Path<String>,
    Json(body): Json<SubmitContentReportRequest>,
) -> Result<Json<SubmitContentReportResponse>, ApiError> {
    let report_id = ContentReportService::new(state.infra.db.clone())
        .report_user(
            tenant.campus_id,
            &tenant.session.user_id,
            &user_id,
            &body.reason,
            body.details.as_deref(),
        )
        .await?;
    Ok(Json(SubmitContentReportResponse { report_id }))
}
