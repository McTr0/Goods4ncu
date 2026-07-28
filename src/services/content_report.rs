use sqlx::{PgPool, Postgres, Transaction};
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::services::moderation_case::create_case_for_content_report;

const MAX_NEW_REPORTS_PER_HOUR: i64 = 10;

#[derive(Clone)]
pub struct ContentReportService {
    pool: PgPool,
}

#[derive(Clone, Copy)]
enum ReportTarget<'a> {
    Listing(&'a str),
    User(&'a str),
}

impl<'a> ReportTarget<'a> {
    fn resource_type(self) -> &'static str {
        match self {
            Self::Listing(_) => "listing",
            Self::User(_) => "user",
        }
    }

    fn resource_id(self) -> &'a str {
        match self {
            Self::Listing(id) | Self::User(id) => id,
        }
    }
}

impl ContentReportService {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn report_listing(
        &self,
        campus_id: Uuid,
        reporter_id: &str,
        listing_id: &str,
        reason: &str,
        details: Option<&str>,
    ) -> Result<Uuid, ApiError> {
        self.submit(
            campus_id,
            reporter_id,
            ReportTarget::Listing(listing_id),
            reason,
            details,
        )
        .await
    }

    pub async fn report_user(
        &self,
        campus_id: Uuid,
        reporter_id: &str,
        user_id: &str,
        reason: &str,
        details: Option<&str>,
    ) -> Result<Uuid, ApiError> {
        self.submit(
            campus_id,
            reporter_id,
            ReportTarget::User(user_id),
            reason,
            details,
        )
        .await
    }

    async fn submit(
        &self,
        campus_id: Uuid,
        reporter_id: &str,
        target: ReportTarget<'_>,
        reason: &str,
        details: Option<&str>,
    ) -> Result<Uuid, ApiError> {
        let (reason, details) = validate_report_text(reason, details)?;
        let mut tx = self.pool.begin().await.map_err(db_error)?;
        let subject_user_id = resolve_target(&mut tx, campus_id, target).await?;

        if subject_user_id == reporter_id {
            return Err(ApiError::BadRequest("不能举报自己或自己的发布".to_string()));
        }

        // Count and insert must be serialized per reporter. Without this lock,
        // concurrent requests can all observe nine reports and each become the
        // tenth. A hash collision only causes harmless extra serialization.
        sqlx::query(
            "SELECT pg_advisory_xact_lock(
                 hashtextextended('content-report:' || $1, 0)
             )",
        )
        .bind(reporter_id)
        .execute(&mut *tx)
        .await
        .map_err(db_error)?;

        let resource_type = target.resource_type();
        let resource_id = target.resource_id();
        let already_exists: bool = sqlx::query_scalar(
            "SELECT EXISTS(
                 SELECT 1 FROM content_reports
                 WHERE campus_id = $1 AND resource_type = $2
                   AND resource_id = $3 AND reporter_id = $4
                   AND status IN ('open', 'reviewing')
             )",
        )
        .bind(campus_id)
        .bind(resource_type)
        .bind(resource_id)
        .bind(reporter_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(db_error)?;

        if !already_exists {
            let recent_count: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM content_reports
                 WHERE reporter_id = $1
                   AND created_at >= NOW() - INTERVAL '1 hour'",
            )
            .bind(reporter_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(db_error)?;
            if recent_count >= MAX_NEW_REPORTS_PER_HOUR {
                return Err(ApiError::RateLimitExceeded);
            }
        }

        let report_id = sqlx::query_scalar::<_, Uuid>(
            "INSERT INTO content_reports (
                 campus_id, resource_type, resource_id, subject_user_id,
                 reporter_id, reason, details
             ) VALUES ($1, $2, $3, $4, $5, $6, $7)
             ON CONFLICT (campus_id, resource_type, resource_id, reporter_id)
                 WHERE status IN ('open', 'reviewing')
             DO UPDATE SET
                 subject_user_id = EXCLUDED.subject_user_id,
                 reason = EXCLUDED.reason,
                 details = EXCLUDED.details,
                 updated_at = NOW()
             RETURNING id",
        )
        .bind(campus_id)
        .bind(resource_type)
        .bind(resource_id)
        .bind(&subject_user_id)
        .bind(reporter_id)
        .bind(&reason)
        .bind(details.as_deref())
        .fetch_one(&mut *tx)
        .await
        .map_err(db_error)?;

        create_case_for_content_report(&mut tx, report_id).await?;
        tx.commit().await.map_err(db_error)?;
        Ok(report_id)
    }
}

async fn resolve_target(
    tx: &mut Transaction<'_, Postgres>,
    campus_id: Uuid,
    target: ReportTarget<'_>,
) -> Result<String, ApiError> {
    let subject_user_id = match target {
        ReportTarget::Listing(listing_id) => sqlx::query_scalar::<_, String>(
            "SELECT owner_id FROM inventory
                 WHERE id = $1 AND campus_id = $2",
        )
        .bind(listing_id)
        .bind(campus_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(db_error)?,
        ReportTarget::User(user_id) => sqlx::query_scalar::<_, String>(
            "SELECT membership.user_id
             FROM campus_memberships membership
             JOIN users user_account ON user_account.id = membership.user_id
             WHERE membership.user_id = $1 AND membership.campus_id = $2
               AND membership.status = 'verified'",
        )
        .bind(user_id)
        .bind(campus_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(db_error)?,
    };

    // A campus mismatch is deliberately indistinguishable from a missing
    // target; this endpoint must not become a cross-campus directory oracle.
    subject_user_id.ok_or(ApiError::NotFound)
}

fn validate_report_text(
    reason: &str,
    details: Option<&str>,
) -> Result<(String, Option<String>), ApiError> {
    let reason = reason.trim();
    if !(1..=80).contains(&reason.chars().count()) {
        return Err(ApiError::BadRequest(
            "举报原因必须为 1 到 80 字".to_string(),
        ));
    }
    let details = details.map(str::trim).filter(|value| !value.is_empty());
    if details.is_some_and(|value| value.chars().count() > 1000) {
        return Err(ApiError::BadRequest("举报说明最多 1000 字".to_string()));
    }
    Ok((reason.to_string(), details.map(str::to_string)))
}

fn db_error(error: sqlx::Error) -> ApiError {
    ApiError::Internal(anyhow::anyhow!("DB error: {}", error))
}
