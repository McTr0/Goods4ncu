use axum::{
    body::{to_bytes, Body},
    extract::Request,
    http::{
        header::{CONTENT_LENGTH, CONTENT_TYPE},
        HeaderName, HeaderValue, StatusCode,
    },
    middleware::Next,
    response::Response,
};

use super::error::error_payload;

use crate::api::error::ApiError;
use axum::http::HeaderMap;
use std::future::Future;

pub const REQUEST_ID_HEADER: HeaderName = HeaderName::from_static("x-request-id");

/// Parse the optional idempotency key shared by state-changing endpoints.
/// Keep the validation at the HTTP boundary so services only receive a
/// normalized, bounded opaque value.
pub fn idempotency_key_from_headers(headers: &HeaderMap) -> Result<Option<String>, ApiError> {
    let Some(value) = headers.get("idempotency-key") else {
        return Ok(None);
    };
    let key = value
        .to_str()
        .map_err(|_| ApiError::BadRequest("Idempotency-Key 必须是 ASCII 文本".to_string()))?;
    if key.is_empty() || key.len() > 128 || !key.bytes().all(|byte| (0x21..=0x7e).contains(&byte)) {
        return Err(ApiError::BadRequest(
            "Idempotency-Key 必须为 1–128 个不含空格的 ASCII 字符".to_string(),
        ));
    }
    Ok(Some(key.to_string()))
}

tokio::task_local! {
    static REQUEST_ID: String;
}

pub fn current_request_id() -> Option<String> {
    REQUEST_ID.try_with(Clone::clone).ok()
}

pub fn current_or_new_request_id() -> String {
    current_request_id().unwrap_or_else(|| uuid::Uuid::new_v4().to_string())
}

/// Run a future with a caller-supplied request trace.  HTTP always uses the
/// middleware-generated value; this small boundary is also useful for trusted
/// background/adaptor code and integration tests that need to prove trace
/// propagation without accepting a client-provided header.
#[allow(dead_code)]
pub async fn with_request_id<F, Fut, T>(request_id: String, future: F) -> T
where
    F: FnOnce() -> Fut,
    Fut: Future<Output = T>,
{
    REQUEST_ID.scope(request_id, future()).await
}

fn framework_error_code(status: StatusCode) -> &'static str {
    match status {
        StatusCode::BAD_REQUEST => "bad_request",
        StatusCode::UNAUTHORIZED => "unauthorized",
        StatusCode::FORBIDDEN => "forbidden",
        StatusCode::NOT_FOUND => "not_found",
        StatusCode::METHOD_NOT_ALLOWED => "method_not_allowed",
        StatusCode::PAYLOAD_TOO_LARGE => "payload_too_large",
        StatusCode::UNSUPPORTED_MEDIA_TYPE => "unsupported_media_type",
        StatusCode::UNPROCESSABLE_ENTITY => "validation_failed",
        StatusCode::TOO_MANY_REQUESTS => "rate_limited",
        _ if status.is_server_error() => "internal_error",
        _ => "request_failed",
    }
}

fn framework_error_fallback_message(status: StatusCode) -> &'static str {
    match status {
        StatusCode::BAD_REQUEST => "请求格式不正确",
        StatusCode::UNAUTHORIZED => "请先登录后再操作",
        StatusCode::FORBIDDEN => "你没有权限执行此操作",
        StatusCode::NOT_FOUND => "请求的接口不存在",
        StatusCode::METHOD_NOT_ALLOWED => "该接口不支持此请求方法",
        StatusCode::PAYLOAD_TOO_LARGE => "请求内容超过大小限制",
        StatusCode::UNSUPPORTED_MEDIA_TYPE => "不支持的请求内容类型",
        StatusCode::UNPROCESSABLE_ENTITY => "请求参数校验失败",
        StatusCode::TOO_MANY_REQUESTS => "请求过于频繁，请稍后再试",
        _ => "请求处理失败，请稍后再试",
    }
}

async fn normalize_framework_error(response: Response) -> Response {
    let status = response.status();
    if !(status.is_client_error() || status.is_server_error()) {
        return response;
    }

    let is_json = response
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.starts_with("application/json"));
    if is_json {
        return response;
    }

    let (mut parts, body) = response.into_parts();
    let original_message = to_bytes(body, 64 * 1024)
        .await
        .ok()
        .and_then(|bytes| String::from_utf8(bytes.to_vec()).ok())
        .map(|message| message.trim().to_string())
        .filter(|message| !message.is_empty());
    let message = if status.is_server_error() {
        framework_error_fallback_message(status).to_string()
    } else {
        original_message.unwrap_or_else(|| framework_error_fallback_message(status).to_string())
    };
    let trace_id = current_or_new_request_id();
    let payload = error_payload(framework_error_code(status), &message, &trace_id);
    let body = serde_json::to_vec(&payload).expect("error payload is serializable");

    parts.headers.remove(CONTENT_LENGTH);
    parts.headers.insert(
        CONTENT_TYPE,
        HeaderValue::from_static("application/json; charset=utf-8"),
    );
    Response::from_parts(parts, Body::from(body))
}

pub async fn request_id_middleware(request: Request, next: Next) -> Response {
    // Generate IDs at the trust boundary instead of accepting arbitrary client values.
    let request_id = uuid::Uuid::new_v4().to_string();
    let response_request_id = request_id.clone();
    let is_api_request = request.uri().path().starts_with("/api/");

    REQUEST_ID
        .scope(request_id, async move {
            let mut response = next.run(request).await;
            if is_api_request {
                response = normalize_framework_error(response).await;
            }
            if let Ok(value) = HeaderValue::from_str(&response_request_id) {
                response.headers_mut().insert(REQUEST_ID_HEADER, value);
            }
            response
        })
        .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::error::ApiError;
    use axum::{
        body::{to_bytes, Body},
        extract::Json,
        http::{Request as HttpRequest, StatusCode},
        middleware,
        routing::{get, post},
        Router,
    };
    use serde::Deserialize;
    use tower::ServiceExt;

    async fn failing_handler() -> Result<(), ApiError> {
        Err(ApiError::BadRequest("invalid input".to_string()))
    }

    #[derive(Deserialize)]
    struct RequiredBody {
        _title: String,
    }

    async fn json_handler(Json(_body): Json<RequiredBody>) {}

    #[tokio::test]
    async fn response_header_matches_error_trace_id() {
        let app = Router::new()
            .route("/fail", get(failing_handler))
            .layer(middleware::from_fn(request_id_middleware));

        let response = app
            .oneshot(
                HttpRequest::builder()
                    .uri("/fail")
                    .body(Body::empty())
                    .expect("request"),
            )
            .await
            .expect("response");

        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let header_request_id = response
            .headers()
            .get(REQUEST_ID_HEADER)
            .and_then(|value| value.to_str().ok())
            .expect("request id response header")
            .to_string();
        assert!(uuid::Uuid::parse_str(&header_request_id).is_ok());

        let body = to_bytes(response.into_body(), 64 * 1024)
            .await
            .expect("response body");
        let json: serde_json::Value = serde_json::from_slice(&body).expect("error json");
        assert_eq!(json["trace_id"], header_request_id);
        assert_eq!(json["code"], "bad_request");
        assert_eq!(json["error"], json["message"]);
    }

    #[tokio::test]
    async fn framework_json_rejection_uses_error_envelope() {
        let app = Router::new()
            .route("/api/items", post(json_handler))
            .layer(middleware::from_fn(request_id_middleware));

        let response = app
            .oneshot(
                HttpRequest::builder()
                    .method("POST")
                    .uri("/api/items")
                    .header(CONTENT_TYPE, "application/json")
                    .body(Body::from("{}"))
                    .expect("request"),
            )
            .await
            .expect("response");

        assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
        let header_request_id = response
            .headers()
            .get(REQUEST_ID_HEADER)
            .and_then(|value| value.to_str().ok())
            .expect("request id response header")
            .to_string();
        assert_eq!(
            response
                .headers()
                .get(CONTENT_TYPE)
                .and_then(|v| v.to_str().ok()),
            Some("application/json; charset=utf-8")
        );

        let body = to_bytes(response.into_body(), 64 * 1024)
            .await
            .expect("response body");
        let json: serde_json::Value = serde_json::from_slice(&body).expect("error json");
        assert_eq!(json["trace_id"], header_request_id);
        assert_eq!(json["code"], "validation_failed");
        assert_eq!(json["error"], json["message"]);
        assert!(json["message"].as_str().unwrap().contains("missing field"));
    }

    #[test]
    fn idempotency_key_parser_accepts_opaque_ascii_and_rejects_spaces() {
        let mut headers = HeaderMap::new();
        headers.insert("Idempotency-Key", HeaderValue::from_static("retry-123"));
        assert_eq!(
            idempotency_key_from_headers(&headers).unwrap().as_deref(),
            Some("retry-123")
        );

        headers.insert("Idempotency-Key", HeaderValue::from_static("has space"));
        assert!(idempotency_key_from_headers(&headers).is_err());
    }
}
