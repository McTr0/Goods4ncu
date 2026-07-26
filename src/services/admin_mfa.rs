//! Persistence and enforcement for platform-admin TOTP MFA.
//!
//! Enrollment is two-phase: `begin_enrollment` stores a secret without
//! `confirmed_at`, and only `confirm_enrollment` — which requires a valid code
//! from the authenticator — activates enforcement. Enforcing on the unconfirmed
//! secret would let a typo in the QR scan lock an admin out permanently.

use sqlx::PgPool;

use crate::services::totp;

/// MFA state for one user, as needed by the auth handlers.
#[derive(Debug, Clone)]
pub struct TotpStatus {
    pub secret_base32: String,
    pub confirmed: bool,
    pub last_used_step: i64,
}

pub struct AdminMfaService {
    db: PgPool,
}

/// Why a TOTP verification attempt failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TotpRejection {
    /// Code did not match any acceptable time step.
    InvalidCode,
    /// Code was valid but its time step was already consumed (replay).
    Replayed,
}

impl AdminMfaService {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    pub async fn status(&self, user_id: &str) -> anyhow::Result<Option<TotpStatus>> {
        let row = sqlx::query_as::<_, (String, Option<chrono::DateTime<chrono::Utc>>, i64)>(
            "SELECT secret_base32, confirmed_at, last_used_step
             FROM admin_totp_secrets WHERE user_id = $1",
        )
        .bind(user_id)
        .fetch_optional(&self.db)
        .await?;
        Ok(
            row.map(|(secret_base32, confirmed_at, last_used_step)| TotpStatus {
                secret_base32,
                confirmed: confirmed_at.is_some(),
                last_used_step,
            }),
        )
    }

    /// Store a fresh pending secret. Refuses to overwrite a confirmed
    /// enrollment: silently replacing an active factor would let a session
    /// hijacker rotate MFA to an authenticator they control.
    pub async fn begin_enrollment(&self, user_id: &str) -> anyhow::Result<Option<String>> {
        let secret = totp::generate_secret();
        let inserted = sqlx::query(
            "INSERT INTO admin_totp_secrets (user_id, secret_base32)
             VALUES ($1, $2)
             ON CONFLICT (user_id) DO UPDATE
                SET secret_base32 = EXCLUDED.secret_base32,
                    last_used_step = 0,
                    updated_at = NOW()
                WHERE admin_totp_secrets.confirmed_at IS NULL",
        )
        .bind(user_id)
        .bind(&secret)
        .execute(&self.db)
        .await?;
        if inserted.rows_affected() == 0 {
            return Ok(None); // already confirmed — refuse
        }
        Ok(Some(secret))
    }

    /// Activate enforcement after the admin proves possession of the
    /// authenticator by submitting one valid code.
    pub async fn confirm_enrollment(
        &self,
        user_id: &str,
        code: &str,
        unix_time: i64,
    ) -> anyhow::Result<Result<(), TotpRejection>> {
        let Some(status) = self.status(user_id).await? else {
            return Ok(Err(TotpRejection::InvalidCode));
        };
        if status.confirmed {
            // Confirming twice is harmless but the code must still be fresh.
        }
        let Some(step) = totp::verify(
            &status.secret_base32,
            code,
            unix_time,
            status.last_used_step,
        ) else {
            return Ok(Err(TotpRejection::InvalidCode));
        };
        let updated = sqlx::query(
            "UPDATE admin_totp_secrets
             SET confirmed_at = COALESCE(confirmed_at, NOW()),
                 last_used_step = $2,
                 updated_at = NOW()
             WHERE user_id = $1 AND last_used_step < $2",
        )
        .bind(user_id)
        .bind(step)
        .execute(&self.db)
        .await?;
        if updated.rows_affected() == 0 {
            return Ok(Err(TotpRejection::Replayed));
        }
        Ok(Ok(()))
    }

    /// Verify a code against a *confirmed* enrollment and consume its time
    /// step. The `last_used_step < $2` guard in the UPDATE is what makes the
    /// consumption atomic under concurrent requests: two requests presenting
    /// the same code race on the row update, and exactly one wins.
    pub async fn verify_and_consume(
        &self,
        user_id: &str,
        code: &str,
        unix_time: i64,
    ) -> anyhow::Result<Result<(), TotpRejection>> {
        let Some(status) = self.status(user_id).await? else {
            return Ok(Err(TotpRejection::InvalidCode));
        };
        if !status.confirmed {
            return Ok(Err(TotpRejection::InvalidCode));
        }
        let Some(step) = totp::verify(
            &status.secret_base32,
            code,
            unix_time,
            status.last_used_step,
        ) else {
            return Ok(Err(TotpRejection::InvalidCode));
        };
        let updated = sqlx::query(
            "UPDATE admin_totp_secrets
             SET last_used_step = $2, updated_at = NOW()
             WHERE user_id = $1 AND last_used_step < $2 AND confirmed_at IS NOT NULL",
        )
        .bind(user_id)
        .bind(step)
        .execute(&self.db)
        .await?;
        if updated.rows_affected() == 0 {
            return Ok(Err(TotpRejection::Replayed));
        }
        Ok(Ok(()))
    }

    /// Whether this user has an active (confirmed) TOTP factor.
    pub async fn is_enforced(&self, user_id: &str) -> anyhow::Result<bool> {
        Ok(self
            .status(user_id)
            .await?
            .map(|s| s.confirmed)
            .unwrap_or(false))
    }
}
