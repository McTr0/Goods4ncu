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

use crate::api::auth::{extract_auth_session_from_token_str, AuthSessionContext};
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
    extract_auth_session_from_token_str(token, &state.secrets.jwt_secret)
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
        if let Some(session) = parts.extensions.get::<AuthSessionContext>() {
            return Ok(Session(session.clone()));
        }
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
        if let Some(session) = parts.extensions.get::<AuthSessionContext>() {
            return Ok(OptionalSession(Some(session.clone())));
        }
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
        let session = if let Some(session) = parts.extensions.get::<AuthSessionContext>() {
            session.clone()
        } else {
            let token = bearer_token(parts).ok_or(ApiError::Unauthorized)?;
            decode_session(token, state)?
        };
        let tenant = CampusService::new(state.infra.db.clone())
            .require_tenant_context_for_session(&session.user_id, session.campus_id)
            .await?;
        Ok(VerifiedTenant {
            session,
            campus_id: tenant.campus_id,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::auth;
    use axum::extract::FromRequestParts;
    use axum::http::Request;

    fn test_state() -> AppState {
        let pool = sqlx::PgPool::connect_lazy("postgres://unused/unused").expect("lazy pool");
        crate::api::auth::tests::build_test_state(pool)
    }

    fn sample_session() -> AuthSessionContext {
        AuthSessionContext {
            user_id: "user-test-123".to_string(),
            role: "user".to_string(),
            campus_id: Some(Uuid::new_v4()),
            auth_time: Some(chrono::Utc::now().timestamp()),
        }
    }

    #[tokio::test]
    async fn session_prefers_injected_extension_without_header() {
        let state = test_state();
        let expected = sample_session();

        let req = Request::builder()
            .extension(expected.clone())
            .body(())
            .unwrap();
        let (mut parts, _) = req.into_parts();

        let session = Session::from_request_parts(&mut parts, &state)
            .await
            .expect("Session extraction from extension should succeed");
        assert_eq!(session.0, expected);
    }

    #[tokio::test]
    async fn session_prefers_injected_extension_over_invalid_header() {
        let state = test_state();
        let expected = sample_session();

        // Even with an invalid Authorization header, the injected extension takes precedence
        let req = Request::builder()
            .header("Authorization", "Bearer invalid-garbage-token")
            .extension(expected.clone())
            .body(())
            .unwrap();
        let (mut parts, _) = req.into_parts();

        let session = Session::from_request_parts(&mut parts, &state)
            .await
            .expect("Session extraction should prefer extension");
        assert_eq!(session.0, expected);
    }

    #[tokio::test]
    async fn session_falls_back_to_header_decoding() {
        let state = test_state();
        let (token, _, _) = auth::generate_access_token(
            "user-fallback-456",
            "user",
            &state.secrets.jwt_secret,
            3600,
        )
        .expect("token generation");

        let req = Request::builder()
            .header("Authorization", format!("Bearer {token}"))
            .body(())
            .unwrap();
        let (mut parts, _) = req.into_parts();

        let session = Session::from_request_parts(&mut parts, &state)
            .await
            .expect("Session should decode valid fallback token");
        assert_eq!(session.0.user_id, "user-fallback-456");
        assert_eq!(session.0.role, "user");
    }

    #[tokio::test]
    async fn session_rejects_missing_extension_and_header() {
        let state = test_state();
        let req = Request::builder().body(()).unwrap();
        let (mut parts, _) = req.into_parts();

        let err = Session::from_request_parts(&mut parts, &state)
            .await
            .expect_err("Session should fail when missing");
        assert!(matches!(err, ApiError::Unauthorized));
    }

    #[tokio::test]
    async fn session_rejects_invalid_token_header_without_extension() {
        let state = test_state();
        let req = Request::builder()
            .header("Authorization", "Bearer bad-token")
            .body(())
            .unwrap();
        let (mut parts, _) = req.into_parts();

        let err = Session::from_request_parts(&mut parts, &state)
            .await
            .expect_err("Session should fail with invalid token");
        assert!(matches!(err, ApiError::Unauthorized));
    }

    #[tokio::test]
    async fn optional_session_prefers_injected_extension() {
        let state = test_state();
        let expected = sample_session();

        let req = Request::builder()
            .extension(expected.clone())
            .body(())
            .unwrap();
        let (mut parts, _) = req.into_parts();

        let optional_session = OptionalSession::from_request_parts(&mut parts, &state)
            .await
            .expect("OptionalSession should succeed");
        assert_eq!(optional_session.0, Some(expected));
    }

    #[tokio::test]
    async fn optional_session_guest_without_token_or_extension() {
        let state = test_state();
        let req = Request::builder().body(()).unwrap();
        let (mut parts, _) = req.into_parts();

        let optional_session = OptionalSession::from_request_parts(&mut parts, &state)
            .await
            .expect("Guest should succeed with None");
        assert_eq!(optional_session.0, None);
    }

    #[tokio::test]
    async fn optional_session_falls_back_to_header_decoding() {
        let state = test_state();
        let (token, _, _) = auth::generate_access_token(
            "guest-become-user",
            "user",
            &state.secrets.jwt_secret,
            3600,
        )
        .expect("token generation");

        let req = Request::builder()
            .header("Authorization", format!("Bearer {token}"))
            .body(())
            .unwrap();
        let (mut parts, _) = req.into_parts();

        let optional_session = OptionalSession::from_request_parts(&mut parts, &state)
            .await
            .expect("OptionalSession should decode token");
        assert_eq!(
            optional_session.0.map(|s| s.user_id),
            Some("guest-become-user".to_string())
        );
    }

    #[tokio::test]
    async fn optional_session_rejects_invalid_token_without_extension() {
        let state = test_state();
        let req = Request::builder()
            .header("Authorization", "Bearer invalid-guest-token")
            .body(())
            .unwrap();
        let (mut parts, _) = req.into_parts();

        let err = OptionalSession::from_request_parts(&mut parts, &state)
            .await
            .expect_err("Malformed token must be rejected, not downgraded to guest");
        assert!(matches!(err, ApiError::Unauthorized));
    }
}
