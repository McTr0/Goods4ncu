use chrono::{DateTime, Utc};
use hmac::{Hmac, Mac};
use rand::Rng;
use serde::Serialize;
use sha2::Sha256;
use sqlx::{FromRow, PgPool, Row};
use std::sync::OnceLock;
use std::time::Duration;
use uuid::Uuid;

use crate::api::error::ApiError;

#[derive(Debug, Clone, Serialize, FromRow)]
pub struct CampusView {
    pub id: Uuid,
    pub slug: String,
    pub name_zh: String,
    pub name_en: String,
    pub email_domains: Vec<String>,
}

#[derive(Debug, Clone, Serialize, FromRow)]
pub struct CampusMembershipView {
    pub id: Uuid,
    pub campus_id: Uuid,
    pub campus_slug: String,
    pub campus_name_zh: String,
    pub campus_name_en: String,
    pub status: String,
    pub role: String,
    pub verification_method: Option<String>,
    pub verified_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CampusMembershipsResponse {
    pub items: Vec<CampusMembershipView>,
    pub active_campus_id: Option<Uuid>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TenantContext {
    pub user_id: String,
    pub campus_id: Uuid,
}

#[derive(Debug, Clone, Serialize)]
pub struct VerificationRequestResponse {
    pub expires_at: DateTime<Utc>,
    pub resend_after_seconds: u64,
}

#[derive(Debug, FromRow)]
struct VerificationTarget {
    membership_id: Uuid,
    email: Option<String>,
    membership_status: String,
    email_domains: Vec<String>,
}

type HmacSha256 = Hmac<Sha256>;

const VERIFICATION_TTL_MINUTES: i64 = 5;
const VERIFICATION_RESEND_SECONDS: i64 = 60;
const VERIFICATION_HOURLY_LIMIT: i64 = 5;
const VERIFICATION_MAX_ATTEMPTS: i32 = 5;

#[derive(Clone)]
pub struct CampusService {
    db: PgPool,
}

impl CampusService {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    pub async fn list_active_campuses(&self) -> Result<Vec<CampusView>, ApiError> {
        sqlx::query_as::<_, CampusView>(
            "SELECT id, slug, name_zh, name_en, email_domains
             FROM campuses
             WHERE status = 'active'
             ORDER BY name_zh ASC",
        )
        .fetch_all(&self.db)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))
    }

    pub async fn default_public_campus_id(&self) -> Result<Uuid, ApiError> {
        sqlx::query_scalar(
            "SELECT id FROM campuses
             WHERE status = 'active'
             ORDER BY (slug = 'ncu') DESC, created_at ASC
             LIMIT 1",
        )
        .fetch_optional(&self.db)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?
        .ok_or(ApiError::NotFound)
    }

    pub async fn list_user_memberships(
        &self,
        user_id: &str,
    ) -> Result<CampusMembershipsResponse, ApiError> {
        self.list_user_memberships_for_session(user_id, None).await
    }

    pub async fn list_user_memberships_for_session(
        &self,
        user_id: &str,
        active_campus_id: Option<Uuid>,
    ) -> Result<CampusMembershipsResponse, ApiError> {
        let items = sqlx::query_as::<_, CampusMembershipView>(
            "SELECT m.id, m.campus_id, c.slug AS campus_slug,
                    c.name_zh AS campus_name_zh, c.name_en AS campus_name_en,
                    m.status, m.role, m.verification_method,
                    m.verified_at, m.created_at
             FROM campus_memberships m
             JOIN campuses c ON c.id = m.campus_id
             WHERE m.user_id = $1 AND c.status = 'active'
             ORDER BY (m.status = 'verified') DESC, m.created_at ASC",
        )
        .bind(user_id)
        .fetch_all(&self.db)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;

        let active_campus_id = active_campus_id
            .filter(|campus_id| {
                items.iter().any(|membership| {
                    membership.campus_id == *campus_id
                        && matches!(membership.status.as_str(), "verified" | "pending")
                })
            })
            .or_else(|| {
                items
                    .iter()
                    .find(|membership| membership.status == "verified")
                    .map(|membership| membership.campus_id)
            });

        Ok(CampusMembershipsResponse {
            items,
            active_campus_id,
        })
    }

    #[allow(dead_code)]
    pub async fn require_verified_membership(&self, user_id: &str) -> Result<Uuid, ApiError> {
        Ok(self.require_tenant_context(user_id).await?.campus_id)
    }

    #[allow(dead_code)]
    pub async fn require_tenant_context(&self, user_id: &str) -> Result<TenantContext, ApiError> {
        self.require_tenant_context_for_session(user_id, None).await
    }

    pub async fn require_tenant_context_for_session(
        &self,
        user_id: &str,
        active_campus_id: Option<Uuid>,
    ) -> Result<TenantContext, ApiError> {
        if let Some(campus_id) = active_campus_id {
            let status = sqlx::query_scalar::<_, String>(
                "SELECT m.status
                 FROM campus_memberships m
                 JOIN campuses c ON c.id = m.campus_id AND c.status = 'active'
                 WHERE m.user_id = $1 AND m.campus_id = $2",
            )
            .bind(user_id)
            .bind(campus_id)
            .fetch_optional(&self.db)
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
            return match status.as_deref() {
                Some("verified") => Ok(TenantContext {
                    user_id: user_id.to_string(),
                    campus_id,
                }),
                Some("pending") => Err(ApiError::CampusVerificationRequired),
                _ => Err(ApiError::CampusScopeMismatch),
            };
        }

        let campus_id = sqlx::query_scalar::<_, Uuid>(
            "SELECT m.campus_id
             FROM campus_memberships m
             JOIN campuses c ON c.id = m.campus_id
             WHERE m.user_id = $1
               AND m.status = 'verified'
               AND c.status = 'active'
             ORDER BY m.verified_at ASC NULLS LAST
             LIMIT 1",
        )
        .bind(user_id)
        .fetch_optional(&self.db)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?
        .ok_or(ApiError::CampusVerificationRequired)?;
        Ok(TenantContext {
            user_id: user_id.to_string(),
            campus_id,
        })
    }

    pub async fn resolve_user_campus(&self, user_id: &str) -> Result<Uuid, ApiError> {
        self.resolve_session_campus(user_id, None).await
    }

    pub async fn resolve_session_campus(
        &self,
        user_id: &str,
        active_campus_id: Option<Uuid>,
    ) -> Result<Uuid, ApiError> {
        if let Some(campus_id) = active_campus_id {
            let available: bool = sqlx::query_scalar(
                "SELECT EXISTS(
                    SELECT 1
                    FROM campus_memberships m
                    JOIN campuses c ON c.id = m.campus_id AND c.status = 'active'
                    WHERE m.user_id = $1 AND m.campus_id = $2
                      AND m.status IN ('verified', 'pending')
                 )",
            )
            .bind(user_id)
            .bind(campus_id)
            .fetch_one(&self.db)
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
            if available {
                return Ok(campus_id);
            }
            return Err(ApiError::CampusScopeMismatch);
        }

        sqlx::query_scalar(
            "SELECT m.campus_id
             FROM campus_memberships m
             JOIN campuses c ON c.id = m.campus_id AND c.status = 'active'
             WHERE m.user_id = $1 AND m.status IN ('verified', 'pending')
             ORDER BY (m.status = 'verified') DESC, m.created_at ASC
             LIMIT 1",
        )
        .bind(user_id)
        .fetch_optional(&self.db)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?
        .ok_or(ApiError::CampusVerificationRequired)
    }

    pub async fn require_verified_in_campus(
        &self,
        user_id: &str,
        campus_id: Uuid,
    ) -> Result<TenantContext, ApiError> {
        let verified: bool = sqlx::query_scalar(
            "SELECT EXISTS(
                SELECT 1
                FROM campus_memberships m
                JOIN campuses c ON c.id = m.campus_id
                WHERE m.user_id = $1 AND m.campus_id = $2
                  AND m.status = 'verified' AND c.status = 'active'
             )",
        )
        .bind(user_id)
        .bind(campus_id)
        .fetch_one(&self.db)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
        if !verified {
            return Err(ApiError::CampusScopeMismatch);
        }
        Ok(TenantContext {
            user_id: user_id.to_string(),
            campus_id,
        })
    }

    #[allow(dead_code)]
    pub async fn require_shared_verified_campus(
        &self,
        actor_id: &str,
        other_user_id: &str,
    ) -> Result<TenantContext, ApiError> {
        self.require_shared_verified_campus_for_session(actor_id, other_user_id, None)
            .await
    }

    pub async fn require_shared_verified_campus_for_session(
        &self,
        actor_id: &str,
        other_user_id: &str,
        active_campus_id: Option<Uuid>,
    ) -> Result<TenantContext, ApiError> {
        if let Some(campus_id) = active_campus_id {
            self.require_verified_in_campus(actor_id, campus_id).await?;
            self.require_verified_in_campus(other_user_id, campus_id)
                .await?;
            return Ok(TenantContext {
                user_id: actor_id.to_string(),
                campus_id,
            });
        }

        let campus_id = sqlx::query_scalar::<_, Uuid>(
            "SELECT actor.campus_id
             FROM campus_memberships actor
             JOIN campus_memberships other
               ON other.campus_id = actor.campus_id
              AND other.user_id = $2
              AND other.status = 'verified'
             JOIN campuses c ON c.id = actor.campus_id AND c.status = 'active'
             WHERE actor.user_id = $1 AND actor.status = 'verified'
             ORDER BY actor.verified_at ASC NULLS LAST
             LIMIT 1",
        )
        .bind(actor_id)
        .bind(other_user_id)
        .fetch_optional(&self.db)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?
        .ok_or(ApiError::CampusScopeMismatch)?;
        Ok(TenantContext {
            user_id: actor_id.to_string(),
            campus_id,
        })
    }

    pub async fn request_email_verification(
        &self,
        user_id: &str,
        membership_id: Uuid,
        signing_secret: &str,
    ) -> Result<VerificationRequestResponse, ApiError> {
        let mut tx = self
            .db
            .begin()
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
        let target = sqlx::query_as::<_, VerificationTarget>(
            "SELECT m.id AS membership_id, u.email,
                    m.status AS membership_status, c.email_domains
             FROM campus_memberships m
             JOIN users u ON u.id = m.user_id
             JOIN campuses c ON c.id = m.campus_id
             WHERE m.id = $1 AND m.user_id = $2 AND c.status = 'active'
             FOR UPDATE OF m",
        )
        .bind(membership_id)
        .bind(user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?
        .ok_or(ApiError::NotFound)?;

        if target.membership_status == "verified" {
            return Err(ApiError::Conflict("校园身份已经验证".to_string()));
        }
        if matches!(target.membership_status.as_str(), "suspended" | "revoked") {
            return Err(ApiError::Forbidden);
        }

        let email = target
            .email
            .ok_or_else(|| ApiError::BadRequest("请先设置学校邮箱".to_string()))?;
        let domain = email
            .rsplit_once('@')
            .map(|(_, domain)| domain)
            .ok_or_else(|| ApiError::BadRequest("学校邮箱格式无效".to_string()))?;
        if !target
            .email_domains
            .iter()
            .any(|allowed| allowed.eq_ignore_ascii_case(domain))
        {
            // Naming the domain matters more than it looks. This fires at the
            // single step every student must pass, and someone told only that
            // their address is "not allowed" has to guess the right one — most
            // will just leave instead.
            return Err(ApiError::BadRequest(format!(
                "请使用学校邮箱（{}）",
                target
                    .email_domains
                    .iter()
                    .map(|domain| format!("@{domain}"))
                    .collect::<Vec<_>>()
                    .join(" 或 ")
            )));
        }

        let recent = sqlx::query(
            // The hourly ceiling counts every attempt; the resend cooldown only
            // counts attempts that actually reached the student. Making someone
            // wait out a cooldown for a mail the gateway never delivered turns a
            // flaky mailer into "I cannot register at all" — and it is the one
            // step every single student has to get through.
            "SELECT COUNT(*)::BIGINT AS hourly_count,
                    MAX(requested_at) FILTER (
                        WHERE delivery_status IS DISTINCT FROM 'failed'
                    ) AS last_requested_at
             FROM campus_verification_challenges
             WHERE membership_id = $1
               AND requested_at > NOW() - INTERVAL '1 hour'",
        )
        .bind(target.membership_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
        let hourly_count: i64 = recent.get("hourly_count");
        let last_requested_at: Option<DateTime<Utc>> = recent.get("last_requested_at");
        if hourly_count >= VERIFICATION_HOURLY_LIMIT {
            return Err(ApiError::RateLimitExceeded);
        }
        if last_requested_at.is_some_and(|last| {
            Utc::now().signed_duration_since(last).num_seconds() < VERIFICATION_RESEND_SECONDS
        }) {
            return Err(ApiError::RateLimitExceeded);
        }

        sqlx::query(
            "UPDATE campus_verification_challenges
             SET consumed_at = NOW()
             WHERE membership_id = $1 AND consumed_at IS NULL",
        )
        .bind(target.membership_id)
        .execute(&mut *tx)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;

        let challenge_id = Uuid::new_v4();
        let code = format!("{:06}", rand::rng().random_range(0..1_000_000));
        let code_hash = verification_code_hash(signing_secret, challenge_id, &code)?;
        let expires_at = Utc::now() + chrono::Duration::minutes(VERIFICATION_TTL_MINUTES);
        sqlx::query(
            "INSERT INTO campus_verification_challenges (
                id, membership_id, email, code_hash, expires_at
             ) VALUES ($1, $2, $3, $4, $5)",
        )
        .bind(challenge_id)
        .bind(target.membership_id)
        .bind(&email)
        .bind(code_hash)
        .bind(expires_at)
        .execute(&mut *tx)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
        tx.commit()
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;

        let delivery_result = deliver_verification_code(&email, &code).await;
        let delivery_status = if delivery_result.is_ok() {
            "sent"
        } else {
            "failed"
        };
        sqlx::query("UPDATE campus_verification_challenges SET delivery_status = $1 WHERE id = $2")
            .bind(delivery_status)
            .bind(challenge_id)
            .execute(&self.db)
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
        delivery_result?;

        Ok(VerificationRequestResponse {
            expires_at,
            resend_after_seconds: VERIFICATION_RESEND_SECONDS as u64,
        })
    }

    pub async fn confirm_email_verification(
        &self,
        user_id: &str,
        membership_id: Uuid,
        code: &str,
        signing_secret: &str,
    ) -> Result<CampusMembershipView, ApiError> {
        if code.len() != 6 || !code.bytes().all(|byte| byte.is_ascii_digit()) {
            return Err(ApiError::BadRequest("验证码应为 6 位数字".to_string()));
        }

        let mut tx = self
            .db
            .begin()
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
        let challenge = sqlx::query(
            "SELECT ch.id, ch.code_hash, ch.attempts, ch.expires_at
             FROM campus_verification_challenges ch
             JOIN campus_memberships m ON m.id = ch.membership_id
             WHERE ch.membership_id = $1
               AND m.user_id = $2
               AND ch.consumed_at IS NULL
             ORDER BY ch.requested_at DESC
             LIMIT 1
             FOR UPDATE OF ch",
        )
        .bind(membership_id)
        .bind(user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?
        .ok_or_else(|| ApiError::BadRequest("验证码不存在或已经失效".to_string()))?;

        let challenge_id: Uuid = challenge.get("id");
        let code_hash: String = challenge.get("code_hash");
        let attempts: i32 = challenge.get("attempts");
        let expires_at: DateTime<Utc> = challenge.get("expires_at");
        if expires_at <= Utc::now() || attempts >= VERIFICATION_MAX_ATTEMPTS {
            sqlx::query(
                "UPDATE campus_verification_challenges SET consumed_at = NOW() WHERE id = $1",
            )
            .bind(challenge_id)
            .execute(&mut *tx)
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
            tx.commit()
                .await
                .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
            return Err(ApiError::BadRequest("验证码不存在或已经失效".to_string()));
        }

        if !verification_code_matches(signing_secret, challenge_id, code, &code_hash)? {
            sqlx::query(
                "UPDATE campus_verification_challenges
                 SET attempts = attempts + 1,
                     consumed_at = CASE WHEN attempts + 1 >= $2 THEN NOW() ELSE consumed_at END
                 WHERE id = $1",
            )
            .bind(challenge_id)
            .bind(VERIFICATION_MAX_ATTEMPTS)
            .execute(&mut *tx)
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
            tx.commit()
                .await
                .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
            return Err(ApiError::BadRequest("验证码错误或已经失效".to_string()));
        }

        sqlx::query("UPDATE campus_verification_challenges SET consumed_at = NOW() WHERE id = $1")
            .bind(challenge_id)
            .execute(&mut *tx)
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
        sqlx::query(
            "UPDATE campus_memberships
             SET status = 'verified', verification_method = 'campus_email_otp',
                 verified_at = NOW(), updated_at = NOW()
             WHERE id = $1 AND user_id = $2 AND status = 'pending'",
        )
        .bind(membership_id)
        .bind(user_id)
        .execute(&mut *tx)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
        tx.commit()
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;

        self.list_user_memberships(user_id)
            .await?
            .items
            .into_iter()
            .find(|membership| membership.id == membership_id)
            .ok_or(ApiError::NotFound)
    }
}

#[doc(hidden)]
pub fn verification_code_hash(
    signing_secret: &str,
    challenge_id: Uuid,
    code: &str,
) -> Result<String, ApiError> {
    let mut mac = HmacSha256::new_from_slice(signing_secret.as_bytes())
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("HMAC error: {}", error)))?;
    mac.update(challenge_id.as_bytes());
    mac.update(code.as_bytes());
    Ok(hex::encode(mac.finalize().into_bytes()))
}

fn verification_code_matches(
    signing_secret: &str,
    challenge_id: Uuid,
    code: &str,
    expected_hash: &str,
) -> Result<bool, ApiError> {
    let expected = hex::decode(expected_hash)
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("Hash decode error: {}", error)))?;
    let mut mac = HmacSha256::new_from_slice(signing_secret.as_bytes())
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("HMAC error: {}", error)))?;
    mac.update(challenge_id.as_bytes());
    mac.update(code.as_bytes());
    Ok(mac.verify_slice(&expected).is_ok())
}

/// Well under the 60s router-wide timeout, and deliberately so. If delivery
/// outlasts that layer the whole handler is cancelled mid-flight, which drops
/// the `delivery_status = 'failed'` write — the failure disappears from the one
/// record operations would look at. Better to give up early, record it, and tell
/// the student, than to hang for a minute and leave no trace.
const DELIVERY_TIMEOUT: Duration = Duration::from_secs(10);

/// Built once. A fresh `Client` per send throws away connection pooling and
/// rebuilds TLS for every registration on the busiest hour this system has.
static DELIVERY_CLIENT: OnceLock<reqwest::Client> = OnceLock::new();

fn delivery_client() -> &'static reqwest::Client {
    DELIVERY_CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .timeout(DELIVERY_TIMEOUT)
            .build()
            .unwrap_or_default()
    })
}

async fn deliver_verification_code(email: &str, code: &str) -> Result<(), ApiError> {
    if let Ok(url) = std::env::var("CAMPUS_VERIFICATION_DELIVERY_URL") {
        // The gateway renders the message, but it can only say what it is told.
        // A mail reading "your code is 123456" with no product or campus named
        // is indistinguishable from phishing, and a student who is unsure will
        // not type it in.
        let payload = serde_json::json!({
            "to": email,
            "template": "campus_email_verification",
            "code": code,
            "expires_in_seconds": VERIFICATION_TTL_MINUTES * 60,
            "app_name": "续樟 Goods4ncu",
            "purpose": "校园身份验证",
        });
        let mut request = delivery_client()
            .post(url)
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .body(payload.to_string());
        if let Ok(token) = std::env::var("CAMPUS_VERIFICATION_DELIVERY_TOKEN") {
            request = request.bearer_auth(token);
        }
        let response = request.send().await.map_err(|error| {
            ApiError::Internal(anyhow::anyhow!("Verification delivery failed: {}", error))
        })?;
        if !response.status().is_success() {
            return Err(ApiError::Internal(anyhow::anyhow!(
                "Verification delivery returned {}",
                response.status()
            )));
        }
        return Ok(());
    }

    let production = ["APP_ENV", "ENVIRONMENT", "RUST_ENV"]
        .into_iter()
        .filter_map(|key| std::env::var(key).ok())
        .any(|value| matches!(value.to_ascii_lowercase().as_str(), "production" | "prod"));
    if production {
        return Err(ApiError::Internal(anyhow::anyhow!(
            "CAMPUS_VERIFICATION_DELIVERY_URL is required in production"
        )));
    }

    tracing::warn!(
        email,
        verification_code = code,
        "Development-only campus verification code"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::repositories::{PostgresUserRepository, UserRepository};
    use crate::test_infra::with_test_pool;

    #[tokio::test]
    async fn lists_seeded_campus_and_verified_membership() {
        with_test_pool(|pool| async move {
            let service = CampusService::new(pool.clone());
            let campuses = service.list_active_campuses().await.expect("campuses");
            let ncu = campuses
                .iter()
                .find(|campus| campus.slug == "ncu")
                .expect("NCU seed");
            assert_eq!(ncu.name_zh, "南昌大学");
            assert_eq!(ncu.email_domains, vec!["email.ncu.edu.cn"]);

            let user_id = Uuid::new_v4().to_string();
            sqlx::query(
                "INSERT INTO users (id, username, password_hash)
                 VALUES ($1, $2, 'hash')",
            )
            .bind(&user_id)
            .bind(format!("legacy_{}", Uuid::new_v4()))
            .execute(&pool)
            .await
            .expect("legacy user");
            sqlx::query(
                "INSERT INTO campus_memberships (
                    campus_id, user_id, status, verification_method, verified_at
                 ) VALUES ($1, $2, 'verified', 'legacy_backfill', NOW())",
            )
            .bind(ncu.id)
            .bind(&user_id)
            .execute(&pool)
            .await
            .expect("legacy membership");

            let memberships = service
                .list_user_memberships(&user_id)
                .await
                .expect("legacy memberships");
            assert_eq!(memberships.items.len(), 1);
            assert_eq!(memberships.items[0].status, "verified");
            assert_eq!(
                memberships.items[0].verification_method.as_deref(),
                Some("legacy_backfill")
            );
            assert_eq!(memberships.active_campus_id, Some(ncu.id));
        })
        .await;
    }

    #[tokio::test]
    async fn repository_created_user_starts_pending() {
        with_test_pool(|pool| async move {
            let user_repo = PostgresUserRepository::new(pool.clone());
            let user_id = user_repo
                .create(
                    &format!("campus_pending_{}", Uuid::new_v4()),
                    Some("202600000001@email.ncu.edu.cn"),
                    "hash",
                    "user",
                )
                .await
                .expect("create user");

            let memberships = CampusService::new(pool)
                .list_user_memberships(&user_id)
                .await
                .expect("memberships");
            assert_eq!(memberships.items.len(), 1);
            assert_eq!(memberships.items[0].status, "pending");
            assert_eq!(memberships.active_campus_id, None);
            assert!(memberships.items[0].verified_at.is_none());
        })
        .await;
    }

    #[tokio::test]
    async fn verification_activates_membership_and_email_change_resets_it() {
        with_test_pool(|pool| async move {
            let user_repo = PostgresUserRepository::new(pool.clone());
            let user_id = user_repo
                .create(
                    &format!("verify_{}", Uuid::new_v4()),
                    Some("202600000002@email.ncu.edu.cn"),
                    "hash",
                    "user",
                )
                .await
                .expect("create user");
            let service = CampusService::new(pool.clone());
            assert!(matches!(
                service.require_verified_membership(&user_id).await,
                Err(ApiError::CampusVerificationRequired)
            ));

            let membership_id = service
                .list_user_memberships(&user_id)
                .await
                .expect("memberships")
                .items[0]
                .id;
            let challenge_id = Uuid::new_v4();
            let secret = "test-campus-verification-secret-32";
            let code = "123456";
            let code_hash = verification_code_hash(secret, challenge_id, code).expect("hash");
            sqlx::query(
                "INSERT INTO campus_verification_challenges (
                    id, membership_id, email, code_hash, delivery_status, expires_at
                 ) VALUES ($1, $2, $3, $4, 'sent', NOW() + INTERVAL '5 minutes')",
            )
            .bind(challenge_id)
            .bind(membership_id)
            .bind("202600000002@email.ncu.edu.cn")
            .bind(code_hash)
            .execute(&pool)
            .await
            .expect("challenge");

            assert!(matches!(
                service
                    .confirm_email_verification(&user_id, membership_id, "000000", secret)
                    .await,
                Err(ApiError::BadRequest(_))
            ));
            let attempts: i32 = sqlx::query_scalar(
                "SELECT attempts FROM campus_verification_challenges WHERE id = $1",
            )
            .bind(challenge_id)
            .fetch_one(&pool)
            .await
            .expect("attempts");
            assert_eq!(attempts, 1);

            let verified = service
                .confirm_email_verification(&user_id, membership_id, code, secret)
                .await
                .expect("verify");
            assert_eq!(verified.status, "verified");
            assert_eq!(
                verified.verification_method.as_deref(),
                Some("campus_email_otp")
            );
            assert_eq!(
                service
                    .require_verified_membership(&user_id)
                    .await
                    .expect("active campus"),
                verified.campus_id
            );

            user_repo
                .update_email(&user_id, "202600000003@email.ncu.edu.cn")
                .await
                .expect("change email");
            let reset = service
                .list_user_memberships(&user_id)
                .await
                .expect("memberships after email change");
            assert_eq!(reset.items[0].status, "pending");
            assert!(reset.items[0].verification_method.is_none());
            assert_eq!(reset.active_campus_id, None);
        })
        .await;
    }

    #[tokio::test]
    async fn request_creates_only_a_hashed_short_lived_challenge() {
        with_test_pool(|pool| async move {
            let user_repo = PostgresUserRepository::new(pool.clone());
            let user_id = user_repo
                .create(
                    &format!("request_code_{}", Uuid::new_v4()),
                    Some("202600000004@email.ncu.edu.cn"),
                    "hash",
                    "user",
                )
                .await
                .expect("create user");
            let service = CampusService::new(pool.clone());
            let membership_id = service
                .list_user_memberships(&user_id)
                .await
                .expect("memberships")
                .items[0]
                .id;

            let response = service
                .request_email_verification(
                    &user_id,
                    membership_id,
                    "test-campus-verification-secret-32",
                )
                .await
                .expect("request code");
            assert_eq!(response.resend_after_seconds, 60);
            assert!(response.expires_at > Utc::now());

            let row = sqlx::query(
                "SELECT code_hash, delivery_status,
                        EXTRACT(EPOCH FROM (expires_at - requested_at))::BIGINT AS ttl_seconds
                 FROM campus_verification_challenges
                 WHERE membership_id = $1",
            )
            .bind(membership_id)
            .fetch_one(&pool)
            .await
            .expect("challenge");
            let code_hash: String = row.get("code_hash");
            let delivery_status: String = row.get("delivery_status");
            let ttl_seconds: i64 = row.get("ttl_seconds");
            assert_eq!(code_hash.len(), 64);
            assert_eq!(delivery_status, "sent");
            assert!((295..=300).contains(&ttl_seconds));
        })
        .await;
    }

    #[tokio::test]
    async fn a_mail_that_never_arrived_does_not_cost_the_resend_cooldown() {
        // The gateway going flaky must not read to a student as "you already
        // got a code, wait a minute". They got nothing, and this is the single
        // step every real student has to get through — a cooldown charged for
        // an undelivered mail turns a wobbly mailer into a closed door.
        with_test_pool(|pool| async move {
            let user_repo = PostgresUserRepository::new(pool.clone());
            let user_id = user_repo
                .create(
                    &format!("resend_{}", Uuid::new_v4()),
                    Some("202600000005@email.ncu.edu.cn"),
                    "hash",
                    "user",
                )
                .await
                .expect("create user");
            let service = CampusService::new(pool.clone());
            let membership_id = service
                .list_user_memberships(&user_id)
                .await
                .expect("memberships")
                .items[0]
                .id;
            let secret = "test-campus-verification-secret-32";

            service
                .request_email_verification(&user_id, membership_id, secret)
                .await
                .expect("first request");

            // A second attempt straight away is refused: that one did arrive.
            assert!(matches!(
                service
                    .request_email_verification(&user_id, membership_id, secret)
                    .await,
                Err(ApiError::RateLimitExceeded)
            ));

            // Now say the gateway swallowed it.
            sqlx::query(
                "UPDATE campus_verification_challenges
                 SET delivery_status = 'failed' WHERE membership_id = $1",
            )
            .bind(membership_id)
            .execute(&pool)
            .await
            .expect("mark failed");

            service
                .request_email_verification(&user_id, membership_id, secret)
                .await
                .expect("a failed delivery is retryable at once");
        })
        .await;
    }

    #[tokio::test]
    async fn the_hourly_ceiling_still_counts_failed_deliveries() {
        // Otherwise a gateway erroring on every send becomes an unbounded
        // outbound loop pointed at one address, which is a way to use this
        // system to hammer somebody's inbox.
        with_test_pool(|pool| async move {
            let user_repo = PostgresUserRepository::new(pool.clone());
            let user_id = user_repo
                .create(
                    &format!("ceiling_{}", Uuid::new_v4()),
                    Some("202600000006@email.ncu.edu.cn"),
                    "hash",
                    "user",
                )
                .await
                .expect("create user");
            let service = CampusService::new(pool.clone());
            let membership_id = service
                .list_user_memberships(&user_id)
                .await
                .expect("memberships")
                .items[0]
                .id;
            let secret = "test-campus-verification-secret-32";

            for _ in 0..VERIFICATION_HOURLY_LIMIT {
                service
                    .request_email_verification(&user_id, membership_id, secret)
                    .await
                    .expect("within the ceiling");
                sqlx::query(
                    "UPDATE campus_verification_challenges
                     SET delivery_status = 'failed' WHERE membership_id = $1",
                )
                .bind(membership_id)
                .execute(&pool)
                .await
                .expect("mark failed");
            }

            assert!(
                matches!(
                    service
                        .request_email_verification(&user_id, membership_id, secret)
                        .await,
                    Err(ApiError::RateLimitExceeded)
                ),
                "every attempt counts towards the ceiling, delivered or not",
            );
        })
        .await;
    }
}
