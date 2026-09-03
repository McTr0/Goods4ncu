use crate::api::error::ApiError;
use axum::http::HeaderMap;
use axum::response::Response;
use axum::{extract::Request, middleware::Next};

/// Middleware that enforces admin role for protected routes.
/// Returns 403 Forbidden if the user is not an admin.
///
/// NOTE: This middleware is reserved for future use. Admin protection is currently handled
/// directly in handlers via `require_admin()` function.
#[allow(dead_code)]
pub async fn admin_middleware(mut request: Request, next: Next) -> Response {
    // Extract extensions from request - reserved for future use
    let _ = request.extensions_mut();

    next.run(request).await
}

/// Extract and validate admin role from Authorization header.
/// Returns Ok(admin_id) if admin, Err(ApiError::Forbidden) otherwise.
#[allow(dead_code)]
pub fn require_admin(headers: &HeaderMap, jwt_secret: &str) -> Result<String, ApiError> {
    let (user_id, role) =
        crate::api::auth::extract_user_id_and_role_from_token(headers, jwt_secret)
            .map_err(|_| ApiError::Unauthorized)?;

    if role != "admin" {
        tracing::warn!(role = %role, "Non-admin user attempted to access admin endpoint");
        return Err(ApiError::Forbidden);
    }

    Ok(user_id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::auth::generate_access_token;

    const SECRET: &str = "test_jwt_secret_at_least_32_characters_long";

    fn bearer_headers(token: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            "Authorization",
            format!("Bearer {}", token)
                .parse()
                .expect("Bearer header must be valid"),
        );
        headers
    }

    #[test]
    fn require_admin_accepts_admin_token() {
        let (token, _, _) = generate_access_token("admin-1", "admin", SECRET, 3600).expect("token");
        let headers = bearer_headers(&token);
        let user_id = require_admin(&headers, SECRET).expect("admin should be accepted");
        assert_eq!(user_id, "admin-1");
    }

    #[test]
    fn require_admin_rejects_non_admin_token() {
        let (token, _, _) = generate_access_token("user-1", "user", SECRET, 3600).expect("token");
        let headers = bearer_headers(&token);
        let err = require_admin(&headers, SECRET).expect_err("non-admin rejected");
        assert!(matches!(err, ApiError::Forbidden));
    }

    #[test]
    fn require_admin_rejects_missing_header() {
        let headers = HeaderMap::new();
        let err = require_admin(&headers, SECRET).expect_err("missing header rejected");
        assert!(matches!(err, ApiError::Unauthorized));
    }
}
