//! Private-bucket media storage: AWS SigV4 presigned URLs.
//!
//! Why this exists: the client used to PUT media to a public bucket and store
//! the raw `https://{bucket}.{endpoint}/{key}` URL. The API-layer moderation
//! gate can stop that URL from appearing in responses, but it cannot stop
//! anyone who already holds the link from fetching the object — the bucket
//! itself is the authority. So production keeps the bucket **private**: the
//! server hands out short-lived, one-object presigned PUT URLs for server-
//! generated upload keys, and short-lived presigned GET URLs only for media
//! whose moderation status is `approved`.
//!
//! Signing is implemented directly on `hmac`/`sha2` (already in the tree)
//! rather than pulling an AWS SDK: the GET/PUT/DELETE variants share a
//! well-specified signer, and are verified against a real S3-compatible server
//! (MinIO) in `tests/storage_acl_integration.rs` — including that an unsigned
//! request is refused and a tampered signature is rejected.

use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

type HmacSha256 = Hmac<Sha256>;

/// Connection + credential material for the private media bucket.
#[derive(Clone, Debug)]
pub struct PrivateBucket {
    /// Base endpoint, e.g. `http://127.0.0.1:9000` or
    /// `https://oss-cn-beijing.aliyuncs.com`.
    pub endpoint: String,
    pub bucket: String,
    pub region: String,
    pub access_key_id: String,
    pub secret_access_key: String,
    /// Path-style addressing (`{endpoint}/{bucket}/{key}`) as MinIO and most
    /// self-hosted gateways expect; virtual-host style otherwise.
    pub path_style: bool,
}

fn hex_sha256(data: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data);
    hex::encode(hasher.finalize())
}

fn hmac(key: &[u8], data: &[u8]) -> Vec<u8> {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(data);
    mac.finalize().into_bytes().to_vec()
}

/// RFC 3986 encoding. Object keys keep `/` unescaped (they are path
/// separators); query values escape everything else.
fn uri_encode(value: &str, keep_slash: bool) -> String {
    let mut out = String::with_capacity(value.len() * 3);
    for byte in value.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char)
            }
            b'/' if keep_slash => out.push('/'),
            other => out.push_str(&format!("%{:02X}", other)),
        }
    }
    out
}

impl PrivateBucket {
    fn host(&self) -> String {
        let stripped = self
            .endpoint
            .trim_end_matches('/')
            .trim_start_matches("https://")
            .trim_start_matches("http://")
            .to_string();
        if self.path_style {
            stripped
        } else {
            format!("{}.{}", self.bucket, stripped)
        }
    }

    fn scheme(&self) -> &str {
        if self.endpoint.starts_with("http://") {
            "http"
        } else {
            "https"
        }
    }

    fn canonical_path(&self, object_key: &str) -> String {
        let key = uri_encode(object_key.trim_start_matches('/'), true);
        if self.path_style {
            format!("/{}/{}", self.bucket, key)
        } else {
            format!("/{}", key)
        }
    }

    /// Presigned GET URL valid for `expires_in_secs`.
    ///
    /// `now` is injected rather than read from the clock so tests can produce
    /// deterministic signatures and exercise expiry.
    pub fn presigned_get_at(
        &self,
        object_key: &str,
        expires_in_secs: u32,
        now: chrono::DateTime<chrono::Utc>,
    ) -> String {
        self.presigned_request_at("GET", object_key, expires_in_secs, now)
    }

    /// Presigned DELETE URL valid for `expires_in_secs` from now.
    ///
    /// Cleanup uses the same bucket authority as media serving. A missing
    /// object is treated as success by the cleanup worker, so retries are
    /// idempotent even after a partial delete.
    pub fn presigned_delete(&self, object_key: &str, expires_in_secs: u32) -> String {
        self.presigned_request_at("DELETE", object_key, expires_in_secs, chrono::Utc::now())
    }

    /// Presigned PUT URL valid for `expires_in_secs` from now.
    ///
    /// The caller must obtain the object key from a server-owned row.  The
    /// signature is intentionally scoped to one exact key; the completion
    /// endpoint still probes the resulting object and validates its bytes.
    pub fn presigned_put(&self, object_key: &str, expires_in_secs: u32) -> String {
        self.presigned_request_at("PUT", object_key, expires_in_secs, chrono::Utc::now())
    }

    fn presigned_request_at(
        &self,
        method: &str,
        object_key: &str,
        expires_in_secs: u32,
        now: chrono::DateTime<chrono::Utc>,
    ) -> String {
        let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
        let date_stamp = now.format("%Y%m%d").to_string();
        let scope = format!("{}/{}/s3/aws4_request", date_stamp, self.region);
        let credential = format!("{}/{}", self.access_key_id, scope);
        let host = self.host();

        // Canonical query string: sorted by key, both key and value encoded.
        let mut params = [
            (
                "X-Amz-Algorithm".to_string(),
                "AWS4-HMAC-SHA256".to_string(),
            ),
            ("X-Amz-Credential".to_string(), credential),
            ("X-Amz-Date".to_string(), amz_date.clone()),
            ("X-Amz-Expires".to_string(), expires_in_secs.to_string()),
            ("X-Amz-SignedHeaders".to_string(), "host".to_string()),
        ];
        params.sort_by(|a, b| a.0.cmp(&b.0));
        let canonical_query = params
            .iter()
            .map(|(k, v)| format!("{}={}", uri_encode(k, false), uri_encode(v, false)))
            .collect::<Vec<_>>()
            .join("&");

        let canonical_path = self.canonical_path(object_key);
        let canonical_request = format!(
            "{}\n{}\n{}\nhost:{}\n\nhost\nUNSIGNED-PAYLOAD",
            method, canonical_path, canonical_query, host
        );
        let string_to_sign = format!(
            "AWS4-HMAC-SHA256\n{}\n{}\n{}",
            amz_date,
            scope,
            hex_sha256(canonical_request.as_bytes())
        );

        // Derive the signing key: date -> region -> service -> terminator.
        let k_date = hmac(
            format!("AWS4{}", self.secret_access_key).as_bytes(),
            date_stamp.as_bytes(),
        );
        let k_region = hmac(&k_date, self.region.as_bytes());
        let k_service = hmac(&k_region, b"s3");
        let k_signing = hmac(&k_service, b"aws4_request");
        let signature = hex::encode(hmac(&k_signing, string_to_sign.as_bytes()));

        format!(
            "{}://{}{}?{}&X-Amz-Signature={}",
            self.scheme(),
            host,
            canonical_path,
            canonical_query,
            signature
        )
    }

    /// Presigned GET URL valid for `expires_in_secs` from now.
    pub fn presigned_get(&self, object_key: &str, expires_in_secs: u32) -> String {
        self.presigned_get_at(object_key, expires_in_secs, chrono::Utc::now())
    }
}

/// Extract the object key from a stored media URL.
///
/// Historical rows hold absolute bucket URLs (virtual-host or path style);
/// newer writes may store bare keys. Returning `None` for anything that is not
/// recognisably this bucket's object keeps foreign URLs from being presigned
/// with our credentials.
pub fn object_key_from_stored_url(stored: &str, bucket: &str) -> Option<String> {
    let stored = stored.trim();
    if stored.is_empty() {
        return None;
    }
    if !stored.starts_with("http://") && !stored.starts_with("https://") {
        // Already a bare key.
        return Some(stored.trim_start_matches('/').to_string());
    }
    let without_scheme = stored
        .trim_start_matches("https://")
        .trim_start_matches("http://");
    let (host, path) = without_scheme.split_once('/')?;
    let path = path.split('?').next().unwrap_or(path);
    if host.starts_with(&format!("{bucket}.")) {
        // Virtual-host style: the whole path is the key.
        Some(path.trim_start_matches('/').to_string())
    } else {
        // Path style: strip the leading bucket segment.
        path.trim_start_matches('/')
            .strip_prefix(&format!("{bucket}/"))
            .map(|key| key.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bucket() -> PrivateBucket {
        PrivateBucket {
            endpoint: "http://127.0.0.1:9000".to_string(),
            bucket: "media".to_string(),
            region: "us-east-1".to_string(),
            access_key_id: "AKIAIOSFODNN7EXAMPLE".to_string(),
            secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY".to_string(),
            path_style: true,
        }
    }

    #[test]
    fn presigned_url_has_all_required_sigv4_parameters() {
        let url = bucket().presigned_get("listings/a.jpg", 600);
        for expected in [
            "X-Amz-Algorithm=AWS4-HMAC-SHA256",
            "X-Amz-Credential=",
            "X-Amz-Date=",
            "X-Amz-Expires=600",
            "X-Amz-SignedHeaders=host",
            "X-Amz-Signature=",
        ] {
            assert!(url.contains(expected), "missing {expected} in {url}");
        }
        assert!(url.starts_with("http://127.0.0.1:9000/media/listings/a.jpg?"));
    }

    #[test]
    fn signature_is_deterministic_and_key_sensitive() {
        let at = chrono::DateTime::from_timestamp(1_700_000_000, 0)
            .expect("timestamp")
            .to_utc();
        let a = bucket().presigned_get_at("x/1.jpg", 300, at);
        let b = bucket().presigned_get_at("x/1.jpg", 300, at);
        assert_eq!(a, b, "same inputs must produce the same signature");
        let c = bucket().presigned_get_at("x/2.jpg", 300, at);
        assert_ne!(a, c, "a different object key must change the signature");
    }

    #[test]
    fn virtual_host_style_puts_bucket_in_the_host() {
        let mut b = bucket();
        b.path_style = false;
        b.endpoint = "https://oss.example.com".to_string();
        let url = b.presigned_get("k.jpg", 60);
        assert!(
            url.starts_with("https://media.oss.example.com/k.jpg?"),
            "{url}"
        );
    }

    #[test]
    fn presigned_delete_uses_delete_method_and_same_object_scope() {
        let at = chrono::DateTime::from_timestamp(1_700_000_000, 0)
            .expect("timestamp")
            .to_utc();
        let delete = bucket().presigned_request_at("DELETE", "chat/object.bin", 300, at);
        let get = bucket().presigned_get_at("chat/object.bin", 300, at);
        assert!(delete.contains("X-Amz-Signature="));
        assert_ne!(delete, get, "HTTP method must be part of the signature");
        assert!(delete.contains("/media/chat/object.bin?"));
    }

    #[test]
    fn presigned_put_uses_put_method_and_same_object_scope() {
        let at = chrono::DateTime::from_timestamp(1_700_000_000, 0)
            .expect("timestamp")
            .to_utc();
        let put = bucket().presigned_request_at("PUT", "persona/candidate.png", 300, at);
        let get = bucket().presigned_get_at("persona/candidate.png", 300, at);
        assert!(put.contains("X-Amz-Signature="));
        assert_ne!(put, get, "HTTP method must be part of the signature");
        assert!(put.contains("/media/persona/candidate.png?"));
    }

    #[test]
    fn object_keys_are_recovered_from_both_url_styles() {
        assert_eq!(
            object_key_from_stored_url("http://127.0.0.1:9000/media/listings/a.jpg", "media")
                .as_deref(),
            Some("listings/a.jpg")
        );
        assert_eq!(
            object_key_from_stored_url("https://media.oss.example.com/listings/b.jpg", "media")
                .as_deref(),
            Some("listings/b.jpg")
        );
        assert_eq!(
            object_key_from_stored_url("listings/c.jpg", "media").as_deref(),
            Some("listings/c.jpg")
        );
    }

    #[test]
    fn foreign_urls_are_not_presigned_with_our_credentials() {
        // A URL from someone else's bucket must not be rewritten — signing it
        // would leak nothing but would silently produce a broken link and
        // imply we vouch for the object.
        assert!(object_key_from_stored_url("https://evil.example.com/x.jpg", "media").is_none());
        assert!(object_key_from_stored_url("", "media").is_none());
    }
}
