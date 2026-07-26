//! Platform-admin TOTP MFA enrollment endpoints.
//!
//! Enforcement happens in `POST /api/auth/reauth` (see `api::auth`): once an
//! admin has a confirmed factor, the password step-up additionally requires a
//! fresh TOTP code, so every sensitive admin write sits behind
//! password + possession within a 10-minute window.
//!
//! All three endpoints require the caller to already be inside a recent-auth
//! window: enrollment changes an authentication factor, and a stolen ordinary
//! session must not be enough to attach an attacker's authenticator.

use axum::{extract::State, Json};
use serde::{Deserialize, Serialize};

use crate::api::error::ApiError;
use crate::api::session::Session;
use crate::api::AppState;
use crate::services::admin_mfa::{AdminMfaService, TotpRejection};
use crate::services::totp;

const TOTP_ISSUER: &str = "Goods4ncu";

/// The caller must be an active platform admin, verified against the database
/// rather than the token role claim alone, inside a recent-auth window.
async fn require_recent_admin(
    state: &AppState,
    session: &crate::api::auth::AuthSessionContext,
) -> Result<(), ApiError> {
    let row = sqlx::query_as::<_, (String, String)>("SELECT role, status FROM users WHERE id = $1")
        .bind(&session.user_id)
        .fetch_optional(&state.infra.db)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        .ok_or(ApiError::Unauthorized)?;
    if row.1 != "active" || session.role != "admin" || row.0 != "admin" {
        return Err(ApiError::Forbidden);
    }
    if !session.has_recent_authentication() {
        return Err(ApiError::RecentAuthenticationRequired);
    }
    Ok(())
}

#[derive(Serialize)]
pub struct TotpStatusResponse {
    pub enrolled: bool,
    pub confirmed: bool,
}

/// GET /api/auth/mfa/totp — enrollment state for the current admin.
pub async fn totp_status(
    State(state): State<AppState>,
    Session(session): Session,
) -> Result<Json<TotpStatusResponse>, ApiError> {
    require_recent_admin(&state, &session).await?;
    let status = AdminMfaService::new(state.infra.db.clone())
        .status(&session.user_id)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(TotpStatusResponse {
        enrolled: status.is_some(),
        confirmed: status.map(|s| s.confirmed).unwrap_or(false),
    }))
}

#[derive(Serialize)]
pub struct TotpSetupResponse {
    pub secret_base32: String,
    pub otpauth_uri: String,
}

/// POST /api/auth/mfa/totp/setup — generate a pending secret.
///
/// Returns 409 if a confirmed factor already exists: rotating an active factor
/// is deliberately not self-service, because the ability to swap MFA from a
/// (possibly hijacked) session defeats the factor.
pub async fn totp_setup(
    State(state): State<AppState>,
    Session(session): Session,
) -> Result<Json<TotpSetupResponse>, ApiError> {
    require_recent_admin(&state, &session).await?;
    let secret = AdminMfaService::new(state.infra.db.clone())
        .begin_enrollment(&session.user_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| {
            ApiError::Conflict("动态验证码已启用，如需更换请联系平台运维".to_string())
        })?;
    let otpauth_uri = totp::provisioning_uri(&secret, &session.user_id, TOTP_ISSUER);
    Ok(Json(TotpSetupResponse {
        secret_base32: secret,
        otpauth_uri,
    }))
}

#[derive(Deserialize)]
pub struct TotpConfirmRequest {
    pub code: String,
}

/// POST /api/auth/mfa/totp/confirm — prove possession, activate enforcement.
pub async fn totp_confirm(
    State(state): State<AppState>,
    Session(session): Session,
    Json(payload): Json<TotpConfirmRequest>,
) -> Result<Json<TotpStatusResponse>, ApiError> {
    require_recent_admin(&state, &session).await?;
    let now = chrono::Utc::now().timestamp();
    let outcome = AdminMfaService::new(state.infra.db.clone())
        .confirm_enrollment(&session.user_id, &payload.code, now)
        .await
        .map_err(ApiError::Internal)?;
    match outcome {
        Ok(()) => {
            tracing::info!(user_id = %session.user_id, "Admin TOTP MFA confirmed");
            Ok(Json(TotpStatusResponse {
                enrolled: true,
                confirmed: true,
            }))
        }
        Err(TotpRejection::InvalidCode) | Err(TotpRejection::Replayed) => Err(
            ApiError::BadRequest("动态验证码不正确或已使用，请重试".to_string()),
        ),
    }
}
