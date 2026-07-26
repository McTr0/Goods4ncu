use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::api::auth::extract_auth_session_from_token_with_fallback;
use crate::api::error::ApiError;
use crate::api::AppState;
use crate::services::campus::CampusService;
use crate::services::moderation_case::{
    ModerationAppealRecord, ModerationCaseRecord, ModerationCaseService,
};

#[derive(Debug, Default, Deserialize)]
pub struct CaseListQuery {
    pub status: Option<String>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

#[derive(Debug, Deserialize)]
pub struct SubmitAppealBody {
    pub reason: String,
}

#[derive(Debug, Serialize)]
pub struct PublicModerationCase {
    pub id: Uuid,
    pub campus_id: Uuid,
    pub resource_type: String,
    pub resource_id: String,
    pub status: String,
    pub reason_category: String,
    pub public_reason: String,
    pub resolution: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub decided_at: Option<DateTime<Utc>>,
    pub pending_appeal: bool,
    pub can_appeal: bool,
}

#[derive(Debug, Serialize)]
pub struct PublicAppeal {
    pub id: Uuid,
    pub case_id: Uuid,
    pub campus_id: Uuid,
    pub reason: String,
    pub status: String,
    pub decision_note: Option<String>,
    pub created_at: DateTime<Utc>,
    pub decided_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Serialize)]
pub struct ModerationCasesResponse {
    pub campus_id: Uuid,
    pub items: Vec<PublicModerationCase>,
    pub total: i64,
    pub limit: i64,
    pub offset: i64,
}

/// GET /api/moderation/cases - cases affecting the authenticated user.
pub async fn list_my_cases(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<CaseListQuery>,
) -> Result<Json<ModerationCasesResponse>, ApiError> {
    let (user_id, campus_id) = authenticated_scope(&state, &headers).await?;
    let limit = query.limit.unwrap_or(20).clamp(1, 100);
    let offset = query.offset.unwrap_or(0).max(0);
    let service = ModerationCaseService::new(state.infra.db.clone());
    let (cases, total) = service
        .list_for_subject(&user_id, campus_id, query.status.as_deref(), limit, offset)
        .await?;
    Ok(Json(ModerationCasesResponse {
        campus_id,
        items: cases.into_iter().map(public_case).collect(),
        total,
        limit,
        offset,
    }))
}

/// GET /api/moderation/cases/{id} - safe case summary for its subject.
pub async fn get_my_case(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(case_id): Path<Uuid>,
) -> Result<Json<PublicModerationCase>, ApiError> {
    let (user_id, campus_id) = authenticated_scope(&state, &headers).await?;
    let moderation_case = ModerationCaseService::new(state.infra.db.clone())
        .get_for_subject(case_id, &user_id, campus_id)
        .await?;
    Ok(Json(public_case(moderation_case)))
}

/// POST /api/moderation/cases/{id}/appeals - submit one appeal.
pub async fn submit_appeal(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(case_id): Path<Uuid>,
    Json(body): Json<SubmitAppealBody>,
) -> Result<Json<PublicAppeal>, ApiError> {
    let (user_id, campus_id) = authenticated_scope(&state, &headers).await?;
    let appeal = ModerationCaseService::new(state.infra.db.clone())
        .submit_appeal(case_id, &user_id, campus_id, &body.reason)
        .await?;
    Ok(Json(public_appeal(appeal)))
}

/// GET /api/moderation/appeals/{id} - appeal status for its appellant.
pub async fn get_my_appeal(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(appeal_id): Path<Uuid>,
) -> Result<Json<PublicAppeal>, ApiError> {
    let (user_id, campus_id) = authenticated_scope(&state, &headers).await?;
    let appeal = ModerationCaseService::new(state.infra.db.clone())
        .get_appeal_for_subject(appeal_id, &user_id, campus_id)
        .await?;
    Ok(Json(public_appeal(appeal)))
}

async fn authenticated_scope(
    state: &AppState,
    headers: &HeaderMap,
) -> Result<(String, Uuid), ApiError> {
    let session = extract_auth_session_from_token_with_fallback(
        headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)?;
    let campus_id = CampusService::new(state.infra.db.clone())
        .resolve_session_campus(&session.user_id, session.campus_id)
        .await?;
    Ok((session.user_id, campus_id))
}

fn public_case(value: ModerationCaseRecord) -> PublicModerationCase {
    let pending_appeal = value.pending_appeal_count > 0;
    let can_appeal = !pending_appeal
        && matches!(value.status.as_str(), "actioned" | "resolved")
        && matches!(
            value.resolution.as_deref(),
            Some("content_restricted" | "warning" | "account_action")
        );
    PublicModerationCase {
        id: value.id,
        campus_id: value.campus_id,
        resource_type: value.resource_type,
        resource_id: value.resource_id,
        status: value.status,
        reason_category: value.reason_category,
        public_reason: value.public_reason,
        resolution: value.resolution,
        created_at: value.created_at,
        updated_at: value.updated_at,
        decided_at: value.decided_at,
        pending_appeal,
        can_appeal,
    }
}

fn public_appeal(value: ModerationAppealRecord) -> PublicAppeal {
    PublicAppeal {
        id: value.id,
        case_id: value.case_id,
        campus_id: value.campus_id,
        reason: value.reason,
        status: value.status,
        decision_note: value.decision_note,
        created_at: value.created_at,
        decided_at: value.decided_at,
    }
}
