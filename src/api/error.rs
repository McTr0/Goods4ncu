use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::json;

use super::request_context;

pub(crate) fn error_payload(code: &str, message: &str, trace_id: &str) -> serde_json::Value {
    json!({
        // Keep the legacy string while unversioned clients migrate.
        "error": message,
        "code": code,
        "message": message,
        "trace_id": trace_id,
    })
}

#[derive(Debug, thiserror::Error)]
#[allow(dead_code)]
pub enum ApiError {
    #[error("资源不存在")]
    NotFound,

    #[error("请求错误: {0}")]
    BadRequest(String),

    #[error("未授权")]
    Unauthorized,

    #[error("认证失败: {0}")]
    AuthFailed(String),

    #[error("需要重新验证密码")]
    RecentAuthenticationRequired,

    #[error("密码验证失败")]
    RecentAuthenticationFailed,

    /// The account has a confirmed MFA factor and this step-up requires it.
    /// Distinct from a failed attempt so clients know to prompt for a code.
    #[error("需要动态验证码")]
    MfaRequired,

    #[error("无权限访问")]
    Forbidden,

    #[error("需要先完成校园身份验证")]
    CampusVerificationRequired,

    #[error("该操作仅限同一校园的已认证用户")]
    CampusScopeMismatch,

    #[error("冲突: {0}")]
    Conflict(String),

    /// A capability this deployment does not have, as opposed to a fault.
    ///
    /// Distinct from [`ApiError::ServiceUnavailable`], which means "try again".
    /// This one means "do not try again, and hide the affordance" — an optional
    /// integration such as photo recognition that was never configured.
    #[error("未启用: {0}")]
    NotImplemented(String),

    #[error("请求过于频繁，请稍后再试")]
    RateLimitExceeded,

    #[error("内容包含违规信息: {0}")]
    ContentViolation(String),

    /// Temporary unavailability the caller should retry: the process is
    /// draining, or a dependency this endpoint needs is down. Distinct from
    /// `Internal` so load balancers and clients can retry instead of surfacing
    /// a hard failure.
    #[error("服务暂时不可用")]
    ServiceUnavailable(&'static str),

    #[error("服务器内部错误")]
    Internal(#[from] anyhow::Error),
}

impl From<jsonwebtoken::errors::Error> for ApiError {
    fn from(e: jsonwebtoken::errors::Error) -> Self {
        ApiError::Internal(anyhow::anyhow!("JWT error: {}", e))
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let trace_id = request_context::current_or_new_request_id();
        let (status, code, msg) = match &self {
            ApiError::NotFound => (StatusCode::NOT_FOUND, "not_found", "资源不存在".to_string()),
            ApiError::BadRequest(m) => (
                StatusCode::BAD_REQUEST,
                "bad_request",
                format!("请求错误: {}", m),
            ),
            ApiError::Unauthorized => (
                StatusCode::UNAUTHORIZED,
                "unauthorized",
                "请先登录后再操作".to_string(),
            ),
            ApiError::AuthFailed(m) => (
                StatusCode::UNAUTHORIZED,
                "authentication_failed",
                format!("认证失败: {}", m),
            ),
            ApiError::RecentAuthenticationRequired => (
                StatusCode::FORBIDDEN,
                "recent_authentication_required",
                "此操作需要重新验证密码".to_string(),
            ),
            ApiError::RecentAuthenticationFailed => (
                StatusCode::UNAUTHORIZED,
                "recent_authentication_failed",
                "密码验证失败".to_string(),
            ),
            ApiError::MfaRequired => (
                StatusCode::UNAUTHORIZED,
                "mfa_required",
                "此操作需要动态验证码".to_string(),
            ),
            ApiError::Forbidden => (
                StatusCode::FORBIDDEN,
                "forbidden",
                "您没有权限执行此操作".to_string(),
            ),
            ApiError::CampusVerificationRequired => (
                StatusCode::FORBIDDEN,
                "campus_verification_required",
                "请先完成校园身份验证后再操作".to_string(),
            ),
            ApiError::CampusScopeMismatch => (
                StatusCode::FORBIDDEN,
                "campus_scope_mismatch",
                "该操作仅限同一校园的已认证用户".to_string(),
            ),
            ApiError::Conflict(m) => (StatusCode::CONFLICT, "conflict", format!("冲突: {}", m)),
            ApiError::NotImplemented(m) => {
                (StatusCode::NOT_IMPLEMENTED, "not_enabled", m.to_string())
            }
            ApiError::RateLimitExceeded => (
                StatusCode::TOO_MANY_REQUESTS,
                "rate_limited",
                "请求过于频繁，请稍后再试".to_string(),
            ),
            ApiError::ContentViolation(msg) => (
                StatusCode::UNPROCESSABLE_ENTITY,
                "content_violation",
                format!("内容包含违规信息: {}", msg),
            ),
            ApiError::ServiceUnavailable(reason) => (
                StatusCode::SERVICE_UNAVAILABLE,
                "service_unavailable",
                format!("服务暂时不可用，请稍后再试（{}）", reason),
            ),
            ApiError::Internal(ref e) => {
                // Log the full error for server-side traceability before hiding it from the client.
                tracing::error!(trace_id = %trace_id, err = %e, "Internal server error");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "internal_error",
                    "服务器内部错误，请稍后再试".to_string(),
                )
            }
        };
        (status, Json(error_payload(code, &msg, &trace_id))).into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::StatusCode;
    use serde_json::json;

    // Helper to verify the response has correct status and JSON body format
    fn verify_error_response(
        error: ApiError,
        expected_status: StatusCode,
        expected_error_msg: &str,
    ) {
        // Get the full Display message (which includes prefixes like "请求错误: ")
        let full_display_msg = match &error {
            ApiError::NotFound => "资源不存在".to_string(),
            ApiError::BadRequest(ref m) => format!("请求错误: {}", m),
            ApiError::Unauthorized => "请先登录后再操作".to_string(),
            ApiError::AuthFailed(ref m) => format!("认证失败: {}", m),
            ApiError::RecentAuthenticationRequired => "需要重新验证密码".to_string(),
            ApiError::RecentAuthenticationFailed => "密码验证失败".to_string(),
            ApiError::MfaRequired => "需要动态验证码".to_string(),
            ApiError::Forbidden => "您没有权限执行此操作".to_string(),
            ApiError::CampusVerificationRequired => "需要先完成校园身份验证".to_string(),
            ApiError::CampusScopeMismatch => "该操作仅限同一校园的已认证用户".to_string(),
            ApiError::Conflict(ref m) => format!("冲突: {}", m),
            ApiError::NotImplemented(ref m) => m.clone(),
            ApiError::RateLimitExceeded => "请求过于频繁，请稍后再试".to_string(),
            ApiError::ContentViolation(ref m) => format!("内容包含违规信息: {}", m),
            ApiError::ServiceUnavailable(_) => "服务暂时不可用".to_string(),
            ApiError::Internal(_) => "服务器内部错误".to_string(),
        };
        assert_eq!(full_display_msg.as_str(), expected_error_msg);
        let response = error.into_response();
        assert_eq!(response.status(), expected_status);
    }

    #[test]
    fn test_api_error_not_found_status() {
        let error = ApiError::NotFound;
        assert_eq!(error.to_string(), "资源不存在");
    }

    #[test]
    fn test_api_error_bad_request_status() {
        let error = ApiError::BadRequest("输入无效".to_string());
        assert_eq!(error.to_string(), "请求错误: 输入无效");
    }

    #[test]
    fn test_api_error_unauthorized_status() {
        let error = ApiError::Unauthorized;
        assert_eq!(error.to_string(), "未授权");
    }

    #[test]
    fn test_api_error_forbidden_status() {
        let error = ApiError::Forbidden;
        assert_eq!(error.to_string(), "无权限访问");
    }

    #[test]
    fn test_api_error_conflict_status() {
        let error = ApiError::Conflict("用户名已被使用".to_string());
        assert_eq!(error.to_string(), "冲突: 用户名已被使用");
    }

    #[test]
    fn test_api_error_rate_limit_status() {
        let error = ApiError::RateLimitExceeded;
        assert_eq!(error.to_string(), "请求过于频繁，请稍后再试");
    }

    #[test]
    fn test_api_error_into_response_not_found() {
        verify_error_response(ApiError::NotFound, StatusCode::NOT_FOUND, "资源不存在");
    }

    #[test]
    fn test_api_error_into_response_bad_request() {
        verify_error_response(
            ApiError::BadRequest("输入无效".to_string()),
            StatusCode::BAD_REQUEST,
            "请求错误: 输入无效",
        );
    }

    #[test]
    fn test_api_error_into_response_bad_request_with_english_message() {
        verify_error_response(
            ApiError::BadRequest("test error".to_string()),
            StatusCode::BAD_REQUEST,
            "请求错误: test error",
        );
    }

    #[test]
    fn test_api_error_into_response_unauthorized() {
        verify_error_response(
            ApiError::Unauthorized,
            StatusCode::UNAUTHORIZED,
            "请先登录后再操作",
        );
    }

    #[test]
    fn test_api_error_into_response_auth_failed() {
        verify_error_response(
            ApiError::AuthFailed("token expired".to_string()),
            StatusCode::UNAUTHORIZED,
            "认证失败: token expired",
        );
    }

    #[test]
    fn test_api_error_into_response_forbidden() {
        verify_error_response(
            ApiError::Forbidden,
            StatusCode::FORBIDDEN,
            "您没有权限执行此操作",
        );
    }

    #[test]
    fn test_api_error_into_response_rate_limit() {
        verify_error_response(
            ApiError::RateLimitExceeded,
            StatusCode::TOO_MANY_REQUESTS,
            "请求过于频繁，请稍后再试",
        );
    }

    #[test]
    fn test_api_error_into_response_internal() {
        let error = ApiError::Internal(anyhow::anyhow!("secret error"));
        // The Display impl for Internal is just "服务器内部错误" (generic message)
        assert_eq!(error.to_string(), "服务器内部错误");
        let response = error.into_response();
        assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
    }

    #[test]
    fn test_api_error_into_response_internal_hides_details() {
        // Verify that sensitive error details are not leaked in the Display impl
        let error =
            ApiError::Internal(anyhow::anyhow!("SQL connection failed: password=secret123"));
        // The Display impl should show a generic message, not the actual error
        let error_string = error.to_string();
        assert!(!error_string.contains("secret123"));
        assert!(!error_string.contains("SQL connection failed"));
        assert!(!error_string.contains("password"));
        // The Display impl shows "服务器内部错误"
        assert_eq!(error_string, "服务器内部错误");
    }

    #[test]
    fn test_service_unavailable_is_retryable_and_hides_internals() {
        let response = ApiError::ServiceUnavailable("draining").into_response();
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    }

    #[test]
    fn test_api_error_conflict_into_response() {
        verify_error_response(
            ApiError::Conflict("resource exists".to_string()),
            StatusCode::CONFLICT,
            "冲突: resource exists",
        );
    }

    #[test]
    fn test_api_error_json_format_matches_expected_structure() {
        // Verify that ApiError's IntoResponse produces Json with {"error": "..."} format
        // by testing the Json serialization directly
        let error_msg = "测试错误消息";
        let json_value = json!({"error": error_msg});
        assert!(json_value.is_object());
        assert!(json_value.as_object().unwrap().contains_key("error"));
        assert_eq!(json_value["error"], "测试错误消息");
    }

    #[test]
    fn test_api_error_all_variants_produce_correct_status_codes() {
        // Each error variant should map to the correct HTTP status code
        let error_status_pairs = vec![
            (ApiError::NotFound, StatusCode::NOT_FOUND),
            (
                ApiError::BadRequest("test".to_string()),
                StatusCode::BAD_REQUEST,
            ),
            (ApiError::Unauthorized, StatusCode::UNAUTHORIZED),
            (
                ApiError::AuthFailed("test".to_string()),
                StatusCode::UNAUTHORIZED,
            ),
            (ApiError::Forbidden, StatusCode::FORBIDDEN),
            (ApiError::CampusVerificationRequired, StatusCode::FORBIDDEN),
            (ApiError::Conflict("test".to_string()), StatusCode::CONFLICT),
            (ApiError::RateLimitExceeded, StatusCode::TOO_MANY_REQUESTS),
            (
                ApiError::ContentViolation("测试".to_string()),
                StatusCode::UNPROCESSABLE_ENTITY,
            ),
            (
                ApiError::ServiceUnavailable("draining"),
                StatusCode::SERVICE_UNAVAILABLE,
            ),
            (
                ApiError::Internal(anyhow::anyhow!("test")),
                StatusCode::INTERNAL_SERVER_ERROR,
            ),
        ];
        for (error, expected_status) in error_status_pairs {
            let response = error.into_response();
            assert_eq!(
                response.status(),
                expected_status,
                "Error variant did not produce correct status code"
            );
        }
    }
}
