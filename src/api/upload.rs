//! Upload token API — STS temporary credential issuance for OSS direct upload.
//!
//! Flow: Flutter → GET /api/upload/token → Backend generates STS AssumeRole credentials
//!       → Flutter uses credentials to PUT directly to OSS → no media traffic through App Server
//!
//! Security: Credentials are short-lived (1 hour), scoped to PutObject only.

use crate::api::auth::extract_user_id_from_token_with_fallback;
use crate::api::error::ApiError;
use crate::api::AppState;
use axum::{extract::State, http::HeaderMap, Json};
use base64::Engine;
use hmac::{Hmac, Mac};
use reqwest::Client;
use serde::Serialize;
use sha1::Sha1;
use std::time::Duration;
type HmacSha1 = Hmac<Sha1>;

/// GET /api/upload/token — returns STS temporary credentials for OSS direct upload.
pub async fn get_upload_token(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<StsResponse>, ApiError> {
    let _user_id = extract_user_id_from_token_with_fallback(
        &headers,
        &state.secrets.jwt_secret,
        state.secrets.jwt_secret_old.as_deref(),
    )
    .map_err(|_| ApiError::Unauthorized)?;

    // Read OSS config from AppState (passed from AppConfig at startup).
    let role_arn = state
        .secrets
        .oss_role_arn
        .as_ref()
        .ok_or_else(|| ApiError::Internal(anyhow::anyhow!("OSS_ROLE_ARN not configured")))?;
    let access_key_id =
        state.secrets.oss_access_key_id.as_ref().ok_or_else(|| {
            ApiError::Internal(anyhow::anyhow!("OSS_ACCESS_KEY_ID not configured"))
        })?;
    let access_key_secret = state
        .secrets
        .oss_access_key_secret
        .as_ref()
        .ok_or_else(|| {
            ApiError::Internal(anyhow::anyhow!("OSS_ACCESS_KEY_SECRET not configured"))
        })?;

    let sts_credentials = assume_role_sts(
        access_key_id,
        access_key_secret,
        role_arn,
        "goods4ncu-mobile",
        3600,
    )
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("STS AssumeRole failed: {}", e)))?;

    Ok(Json(StsResponse {
        access_key_id: sts_credentials.access_key_id,
        access_key_secret: sts_credentials.access_key_secret,
        security_token: sts_credentials.security_token,
        expiration: sts_credentials.expiration,
        endpoint: state.secrets.oss_endpoint.clone(),
        bucket: state.secrets.oss_bucket.clone(),
    }))
}

/// Call Alibaba Cloud STS AssumeRole API directly via HTTP + HMAC-SHA1 signing.
/// No external SDK dependency — keeps compile times fast.
async fn assume_role_sts(
    access_key_id: &str,
    access_key_secret: &str,
    role_arn: &str,
    session_name: &str,
    duration_seconds: u32,
) -> anyhow::Result<StsCredentials> {
    let client = Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|e| anyhow::anyhow!("reqwest build error: {}", e))?;

    let iso_timestamp = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let signature_nonce = uuid::Uuid::new_v4().to_string();

    // Build query parameters (must be sorted alphabetically for signing).
    let params = [
        ("Action", "AssumeRole"),
        ("Format", "JSON"),
        ("RoleArn", role_arn),
        ("RoleSessionName", session_name),
        ("SignatureMethod", "HMAC-SHA1"),
        ("SignatureNonce", &signature_nonce),
        ("SignatureVersion", "1.0"),
        ("Timestamp", &iso_timestamp),
        ("Version", "2015-04-01"),
        ("AccessKeyId", access_key_id),
        ("DurationSeconds", &duration_seconds.to_string()),
    ];

    // Build the "StringToSign" for HMAC-SHA1.
    // Format: "GET&%2F&<sorted query string>"
    let query_string: String = params
        .iter()
        .map(|(k, v)| format!("{}={}", percent_encode(k), percent_encode(v)))
        .collect::<Vec<_>>()
        .join("&");
    let string_to_sign = format!("GET&%2F&{}", percent_encode(&query_string));

    // HMAC-SHA1 signature.
    let mut mac = HmacSha1::new_from_slice(format!("{}&", access_key_secret).as_bytes())
        .map_err(|_| anyhow::anyhow!("HMAC init error"))?;
    mac.update(string_to_sign.as_bytes());
    let signature = base64::engine::general_purpose::STANDARD.encode(mac.finalize().into_bytes());

    // Final URL with signature.
    let final_url = format!(
        "https://sts.aliyuncs.com/?{}&Signature={}",
        query_string,
        percent_encode(&signature)
    );

    let resp = client
        .get(&final_url)
        .send()
        .await
        .map_err(|e| anyhow::anyhow!("STS HTTP error: {}", e))?;

    let status = resp.status();
    let body = resp
        .text()
        .await
        .map_err(|e| anyhow::anyhow!("STS body read error: {}", e))?;

    if !status.is_success() {
        anyhow::bail!("STS API error {}: {}", status, body);
    }

    // Parse AssumeRoleResponse.
    // XML response: <AssumeRoleResponse><Credentials><AccessKeyId>...</AccessKeyId>...</Credentials><Credentials><Expiration>...</Expiration></Credentials></AssumeRoleResponse>
    let credentials = parse_assume_role_response(&body)?;

    Ok(credentials)
}

/// Parse the XML AssumeRoleResponse to extract credentials.
fn parse_assume_role_response(body: &str) -> anyhow::Result<StsCredentials> {
    let access_key_id = extract_xml_tag(body, "AccessKeyId")
        .ok_or_else(|| anyhow::anyhow!("AccessKeyId not found in STS response"))?;
    let access_key_secret = extract_xml_tag(body, "AccessKeySecret")
        .ok_or_else(|| anyhow::anyhow!("AccessKeySecret not found in STS response"))?;
    let security_token = extract_xml_tag(body, "SecurityToken")
        .ok_or_else(|| anyhow::anyhow!("SecurityToken not found in STS response"))?;
    let expiration = extract_xml_tag(body, "Expiration")
        .ok_or_else(|| anyhow::anyhow!("Expiration not found in STS response"))?;

    Ok(StsCredentials {
        access_key_id,
        access_key_secret,
        security_token,
        expiration,
    })
}

/// Extract the content of an XML tag (simple regex-free parser for known tags).
fn extract_xml_tag(body: &str, tag: &str) -> Option<String> {
    let start_pattern = format!("<{}>", tag);
    let end_pattern = format!("</{}>", tag);
    let start_idx = body.find(&start_pattern)? + start_pattern.len();
    let end_idx = body.find(&end_pattern)?;
    Some(body[start_idx..end_idx].to_string())
}

/// RFC 3986 percent encoding (same as Alibaba Cloud API).
/// Only a subset of characters need encoding for query parameters.
fn percent_encode(s: &str) -> String {
    let mut result = String::with_capacity(s.len() * 3);
    for byte in s.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                result.push(byte as char);
            }
            _ => {
                result.push('%');
                result.push_str(&format!("{:02X}", byte));
            }
        }
    }
    result
}

#[derive(Debug, Clone, Serialize)]
pub struct StsResponse {
    pub access_key_id: String,
    pub access_key_secret: String,
    pub security_token: String,
    pub expiration: String,
    pub endpoint: String,
    pub bucket: String,
}

#[derive(Debug)]
struct StsCredentials {
    access_key_id: String,
    access_key_secret: String,
    security_token: String,
    expiration: String,
}

// ---------------------------------------------------------------------------
// HMAC-SHA1 signing via hmac + sha1 crates.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_percent_encode_simple() {
        assert_eq!(percent_encode("hello"), "hello");
        assert_eq!(percent_encode("a/b"), "a%2Fb");
        assert_eq!(percent_encode("aliyun"), "aliyun");
    }

    #[test]
    fn test_percent_encode_special() {
        assert_eq!(percent_encode("&"), "%26");
        assert_eq!(percent_encode("="), "%3D");
        assert_eq!(percent_encode(" STS"), "%20STS");
        assert_eq!(percent_encode("+"), "%2B");
    }

    #[test]
    fn test_xml_tag_extraction() {
        let xml = r#"<AssumeRoleResponse><Credentials><AccessKeyId>STS.xxx</AccessKeyId><AccessKeySecret>xxx</AccessKeySecret><SecurityToken>token</SecurityToken><Expiration>2026-03-26T00:00:00Z</Expiration></Credentials></AssumeRoleResponse>"#;
        assert_eq!(extract_xml_tag(xml, "AccessKeyId").unwrap(), "STS.xxx");
        assert_eq!(
            extract_xml_tag(xml, "Expiration").unwrap(),
            "2026-03-26T00:00:00Z"
        );
        assert_eq!(extract_xml_tag(xml, "SecurityToken").unwrap(), "token");
    }

    #[test]
    fn test_xml_tag_missing() {
        assert!(extract_xml_tag("<foo>bar</foo>", "MissingTag").is_none());
    }
}
