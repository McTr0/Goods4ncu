//! The arrangement card for a conversation.
//!
//! Everything here is scoped to a participant, and every write records who said
//! it. The assistant reaches [`set_term`] through the same path a person does,
//! with `proposed_by = "assistant"` — which is what makes its proposals land
//! unconfirmed instead of becoming the plan.

use axum::{
    extract::{Path, State},
    Json,
};
use serde::Deserialize;
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::api::session::VerifiedTenant;
use crate::api::AppState;
use crate::services::agreement::{slots, AgreementService};

#[derive(Deserialize)]
pub struct EnsureRequest {
    pub conversation_id: Uuid,
    /// `deal` or `meetup`. Determines which terms the card can hold — a meetup
    /// has no price, because pricing a game of badminton is a category error.
    pub kind: String,
}

/// POST /api/agreements — the card for a conversation, created on first use.
pub async fn ensure(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Json(payload): Json<EnsureRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    // Membership of the conversation is the authorisation. Checked before
    // creating anything, so this cannot be used to probe which conversations
    // exist.
    let participates: bool = sqlx::query_scalar(
        "SELECT EXISTS (
             SELECT 1 FROM chat_conversations
             WHERE id = $1 AND campus_id = $2 AND (initiator_id = $3 OR recipient_id = $3)
         )",
    )
    .bind(payload.conversation_id)
    .bind(tenant.campus_id)
    .bind(&tenant.session.user_id)
    .fetch_one(&state.infra.db)
    .await
    .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
    if !participates {
        return Err(ApiError::NotFound);
    }

    let service = AgreementService::new(state.infra.db.clone());
    let id = service
        .ensure_for_conversation(tenant.campus_id, payload.conversation_id, &payload.kind)
        .await
        .map_err(|error| ApiError::BadRequest(error.to_string()))?;
    respond(&service, id, &tenant.session.user_id).await
}

/// GET /api/agreements/{id}
pub async fn get_agreement(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    respond(
        &AgreementService::new(state.infra.db.clone()),
        id,
        &tenant.session.user_id,
    )
    .await
}

#[derive(Deserialize)]
pub struct SetTermRequest {
    pub slot: String,
    /// In the author's own words. Not normalised: the card exists so both people
    /// recognise their own arrangement in it.
    pub value: String,
    #[serde(default)]
    pub value_cents: Option<i64>,
}

/// PUT /api/agreements/{id}/terms — state or change a term.
///
/// Stating it counts as agreeing to it; changing it withdraws the *other* side's
/// agreement, because their yes was to the old value.
pub async fn set_term(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(id): Path<Uuid>,
    Json(payload): Json<SetTermRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let service = AgreementService::new(state.infra.db.clone());
    // Participation first, so a stranger cannot write a term into someone's
    // arrangement.
    if service
        .view(id, &tenant.session.user_id)
        .await
        .map_err(ApiError::Internal)?
        .is_none()
    {
        return Err(ApiError::NotFound);
    }
    if payload.value.trim().is_empty() {
        return Err(ApiError::BadRequest("请填写内容".to_string()));
    }
    if payload.value.chars().count() > 200 {
        return Err(ApiError::BadRequest("请控制在 200 字以内".to_string()));
    }

    let applied = service
        .set_term(
            id,
            &payload.slot,
            &payload.value,
            payload.value_cents,
            &tenant.session.user_id,
            None,
        )
        .await
        .map_err(|error| ApiError::BadRequest(error.to_string()))?;
    if !applied {
        return Err(ApiError::NotFound);
    }
    respond(&service, id, &tenant.session.user_id).await
}

#[derive(Deserialize)]
pub struct AdoptRequest {
    pub slot: String,
    /// The value being agreed to. Checked, so a tap on a card that changed while
    /// it was on screen cannot agree to something else — the "I agreed to 300 and
    /// it says 350" failure.
    pub expected_value: String,
}

/// POST /api/agreements/{id}/adopt — say yes to a term as it stands.
pub async fn adopt(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(id): Path<Uuid>,
    Json(payload): Json<AdoptRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let service = AgreementService::new(state.infra.db.clone());
    if service
        .view(id, &tenant.session.user_id)
        .await
        .map_err(ApiError::Internal)?
        .is_none()
    {
        return Err(ApiError::NotFound);
    }
    if !service
        .adopt_term(
            id,
            &payload.slot,
            &tenant.session.user_id,
            &payload.expected_value,
        )
        .await
        .map_err(ApiError::Internal)?
    {
        // Either the slot is absent or the value moved on. Returning the card
        // rather than an error lets the client show what it actually says now.
        return Err(ApiError::Conflict(
            "这一项已经变了，请看最新的内容".to_string(),
        ));
    }
    respond(&service, id, &tenant.session.user_id).await
}

/// POST /api/agreements/{id}/settle — mark it agreed.
pub async fn settle(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let service = AgreementService::new(state.infra.db.clone());
    if !service
        .settle(id, &tenant.session.user_id)
        .await
        .map_err(ApiError::Internal)?
    {
        return Err(ApiError::Conflict("还有没谈定的内容".to_string()));
    }
    respond(&service, id, &tenant.session.user_id).await
}

async fn respond(
    service: &AgreementService,
    id: Uuid,
    user_id: &str,
) -> Result<Json<serde_json::Value>, ApiError> {
    let view = service
        .view(id, user_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or(ApiError::NotFound)?;
    let fully_agreed = view.is_fully_agreed();
    Ok(Json(serde_json::json!({
        "agreement": view,
        "fully_agreed": fully_agreed,
        // Which slots this kind of arrangement can hold, so the client does not
        // hardcode a list that drifts from the server's.
        "available_slots": match view.kind.as_str() {
            "meetup" => slots::MEETUP,
            _ => slots::DEAL,
        },
    })))
}
