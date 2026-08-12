//! Object-storage ACL enforcement against a REAL S3-compatible server.
//!
//! This is the layer the API-level moderation gate cannot cover: once a media
//! URL has leaked, only the bucket's own access control decides whether the
//! bytes are served. These tests prove, against a live server:
//!
//!   * an anonymous GET of a private object is REFUSED (the bucket, not the
//!     app, is the authority)
//!   * a server-issued presigned GET is honoured (our SigV4 implementation is
//!     accepted by a real S3 implementation, not just by our own unit tests)
//!   * a tampered signature is refused
//!   * an expired presigned URL is refused
//!
//! Set `S3_TEST_ENDPOINT`, `S3_TEST_BUCKET`, `S3_TEST_ACCESS_KEY`,
//! `S3_TEST_SECRET_KEY` to run; otherwise the tests skip so CI without an
//! object store stays green. Local setup (see scripts/production_rehearsal.sh):
//!   minio server <dir> --address 127.0.0.1:9100
//!   mc mb g4n/media          # private by default

use goods4ncu::services::storage::PrivateBucket;

fn bucket_from_env() -> Option<PrivateBucket> {
    let endpoint = std::env::var("S3_TEST_ENDPOINT").ok()?;
    if endpoint.trim().is_empty() {
        return None;
    }
    Some(PrivateBucket {
        endpoint,
        bucket: std::env::var("S3_TEST_BUCKET").unwrap_or_else(|_| "media".to_string()),
        region: std::env::var("S3_TEST_REGION").unwrap_or_else(|_| "us-east-1".to_string()),
        access_key_id: std::env::var("S3_TEST_ACCESS_KEY").ok()?,
        secret_access_key: std::env::var("S3_TEST_SECRET_KEY").ok()?,
        path_style: true,
    })
}

/// Direct client without proxy interference (loopback endpoints).
fn client() -> reqwest::Client {
    reqwest::Client::builder()
        .no_proxy()
        .build()
        .expect("http client")
}

/// Upload a probe object using a presigned PUT is out of scope for the serving
/// path, so the fixture object is placed by the harness (mc) before the test
/// runs. `S3_TEST_OBJECT` names it.
fn probe_object() -> String {
    std::env::var("S3_TEST_OBJECT").unwrap_or_else(|_| "acl-probe.txt".to_string())
}

#[tokio::test]
async fn anonymous_get_of_private_object_is_refused() {
    let Some(bucket) = bucket_from_env() else {
        eprintln!("skipping: set S3_TEST_* to run storage ACL tests");
        return;
    };
    let url = format!(
        "{}/{}/{}",
        bucket.endpoint.trim_end_matches('/'),
        bucket.bucket,
        probe_object()
    );
    let response = client().get(&url).send().await.expect("request");
    assert!(
        response.status() == reqwest::StatusCode::FORBIDDEN
            || response.status() == reqwest::StatusCode::UNAUTHORIZED,
        "a private object must not be anonymously readable (got {} for {})",
        response.status(),
        url
    );
}

#[tokio::test]
async fn presigned_get_is_accepted_by_a_real_s3_server() {
    let Some(bucket) = bucket_from_env() else {
        eprintln!("skipping: set S3_TEST_* to run storage ACL tests");
        return;
    };
    let url = bucket.presigned_get(&probe_object(), 300);
    let response = client().get(&url).send().await.expect("request");
    assert!(
        response.status().is_success(),
        "presigned GET must be honoured (got {} for {})",
        response.status(),
        url
    );
    let body = response.text().await.expect("body");
    assert!(!body.is_empty(), "presigned GET returned an empty object");
}

#[tokio::test]
async fn tampered_presigned_signature_is_refused() {
    let Some(bucket) = bucket_from_env() else {
        eprintln!("skipping: set S3_TEST_* to run storage ACL tests");
        return;
    };
    let url = bucket.presigned_get(&probe_object(), 300);
    // Flip the last signature character — any alteration must invalidate it.
    let mut tampered = url.clone();
    let last = tampered.pop().expect("signature char");
    tampered.push(if last == '0' { '1' } else { '0' });
    let response = client().get(&tampered).send().await.expect("request");
    assert!(
        !response.status().is_success(),
        "a tampered signature must be refused (got {})",
        response.status()
    );
}

#[tokio::test]
async fn expired_presigned_url_is_refused() {
    let Some(bucket) = bucket_from_env() else {
        eprintln!("skipping: set S3_TEST_* to run storage ACL tests");
        return;
    };
    // Signed as of an hour ago with a 60s lifetime: already expired.
    let past = chrono::Utc::now() - chrono::Duration::hours(1);
    let url = bucket.presigned_get_at(&probe_object(), 60, past);
    let response = client().get(&url).send().await.expect("request");
    assert!(
        !response.status().is_success(),
        "an expired presigned URL must be refused (got {})",
        response.status()
    );
}

/// A key belonging to no object still must not be readable anonymously — i.e.
/// the bucket denies by default rather than only protecting known objects.
#[tokio::test]
async fn private_bucket_denies_by_default_not_per_object() {
    let Some(bucket) = bucket_from_env() else {
        eprintln!("skipping: set S3_TEST_* to run storage ACL tests");
        return;
    };
    let url = format!(
        "{}/{}/never-uploaded-{}.bin",
        bucket.endpoint.trim_end_matches('/'),
        bucket.bucket,
        uuid::Uuid::new_v4().simple()
    );
    let response = client().get(&url).send().await.expect("request");
    assert!(
        !response.status().is_success(),
        "unknown keys must not be anonymously readable (got {})",
        response.status()
    );
}

/// End-to-end: with a private bucket configured, the API serves APPROVED media
/// as a presigned URL that actually fetches the object, and serves nothing for
/// unapproved media — so the storage layer and the moderation gate agree.
#[tokio::test]
async fn api_serves_approved_media_as_a_working_presigned_url() {
    let Some(bucket) = bucket_from_env() else {
        eprintln!("skipping: set S3_TEST_* to run storage ACL tests");
        return;
    };
    let signer = goods4ncu::api::MediaSigner {
        bucket: bucket.clone(),
        ttl_secs: 300,
    };

    // Stored value as the client writes it today: an absolute bucket URL.
    let stored = format!(
        "{}/{}/{}",
        bucket.endpoint.trim_end_matches('/'),
        bucket.bucket,
        probe_object()
    );

    // Raw stored URL is NOT fetchable (bucket is private) …
    let raw = client().get(&stored).send().await.expect("raw request");
    assert!(
        !raw.status().is_success(),
        "the raw stored URL must not be publicly fetchable (got {})",
        raw.status()
    );

    // … but the signed form the API hands out is.
    let signed = signer
        .sign(&stored)
        .expect("stored URL belongs to our bucket");
    assert!(
        signed.contains("X-Amz-Signature="),
        "API must serve a presigned URL, not the raw link: {signed}"
    );
    let ok = client().get(&signed).send().await.expect("signed request");
    assert!(
        ok.status().is_success(),
        "the presigned URL the API serves must actually fetch the object (got {})",
        ok.status()
    );
}

/// Opt-in destructive check for the cleanup authority. The rehearsal creates a
/// dedicated object and sets `S3_TEST_DELETE_OBJECT`; normal ACL runs do not
/// delete their shared fixture.
#[tokio::test]
async fn presigned_delete_removes_opt_in_object() {
    let Some(bucket) = bucket_from_env() else {
        eprintln!("skipping: set S3_TEST_* to run storage ACL tests");
        return;
    };
    let Some(object) = std::env::var("S3_TEST_DELETE_OBJECT").ok() else {
        eprintln!("skipping: set S3_TEST_DELETE_OBJECT for destructive cleanup check");
        return;
    };
    let response = client()
        .delete(bucket.presigned_delete(&object, 300))
        .send()
        .await
        .expect("presigned DELETE request");
    assert!(
        response.status().is_success() || response.status() == reqwest::StatusCode::NOT_FOUND,
        "presigned DELETE must be accepted (got {} for {})",
        response.status(),
        object
    );
    let verify = client()
        .get(bucket.presigned_get(&object, 300))
        .send()
        .await
        .expect("verify deleted object");
    assert_eq!(
        verify.status(),
        reqwest::StatusCode::NOT_FOUND,
        "deleted object must no longer be readable through a signed URL"
    );
}
