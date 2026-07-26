//! Unified authenticated-session extractors.
//!
//! Before these existed, every handler repeated the same three-step ritual:
//! read the Authorization header, decode the JWT with old-secret fallback, map
//! the error to `ApiError::Unauthorized` — and the handlers that needed a
//! verified campus membership then repeated the tenant lookup as well. Sixty
//! copies of a security check is sixty chances for one of them to drift (skip
//! the fallback secret, forget the membership check, map the error
//! differently). An extractor makes the check a type: a handler that takes
//! [`Session`] or [`VerifiedTenant`] cannot forget to authenticate, and the
//! behaviour is defined in exactly one place.
//!
//! Choosing a parameter type is choosing a security level:
//!
//! - [`Session`] — any valid access token. Read paths and per-user resources
//!   that do not touch campus-scoped marketplace state.
//! - [`VerifiedTenant`] — valid token *and* verified membership in the active
//!   campus. Every marketplace write path.
//! - [`OptionalSession`] — guest-tolerant endpoints (public feeds) that
//!   personalise when a valid token is present. An *invalid* token is still an
//!   error rather than a silent downgrade to guest: a client with an expired
//!   token should refresh, not quietly lose personalisation.

use axum::http::request::Parts;
use uuid::Uuid;

use crate::api::auth::{extract_auth_session_from_token_str_with_fallback, AuthSessionContext};
use crate::api::error::ApiError;
use crate::api::AppState;
use crate::services::campus::CampusService;

fn bearer_token(parts: &Parts) -> Option<&str> {
    parts
        .headers
        .get("Authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
}

fn decode_session(token: &str, state: &AppState) -> Result<AuthSessionContext, ApiError> {
    extract_auth_session_from_token_str_with_fallback(
        token,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)
}

/// A valid access token. See the module docs for when to use which extractor.
#[derive(Clone, Debug)]
pub struct Session(pub AuthSessionContext);

impl axum::extract::FromRequestParts<AppState> for Session {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let token = bearer_token(parts).ok_or(ApiError::Unauthorized)?;
        decode_session(token, state).map(Session)
    }
}

/// A valid access token if one is presented; `None` for guests.
///
/// A malformed or expired token is rejected, not treated as a guest — the
/// difference is user-visible (personalised vs. public results), and silently
/// downgrading would mask client-side token bugs instead of surfacing them.
#[derive(Clone, Debug)]
pub struct OptionalSession(pub Option<AuthSessionContext>);

impl axum::extract::FromRequestParts<AppState> for OptionalSession {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        match bearer_token(parts) {
            None => Ok(OptionalSession(None)),
            Some(token) => decode_session(token, state).map(|s| OptionalSession(Some(s))),
        }
    }
}

/// A valid access token whose holder is a verified member of the session's
/// active campus. The campus in the token is re-validated against the database
/// on every request, so a revoked or suspended membership takes effect
/// immediately rather than at token expiry.
#[derive(Clone, Debug)]
pub struct VerifiedTenant {
    pub session: AuthSessionContext,
    pub campus_id: Uuid,
}

impl axum::extract::FromRequestParts<AppState> for VerifiedTenant {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let token = bearer_token(parts).ok_or(ApiError::Unauthorized)?;
        let session = decode_session(token, state)?;
        let tenant = CampusService::new(state.infra.db.clone())
            .require_tenant_context_for_session(&session.user_id, session.campus_id)
            .await?;
        Ok(VerifiedTenant {
            session,
            campus_id: tenant.campus_id,
        })
    }
}
