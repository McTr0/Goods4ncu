use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::Value;
use sqlx::{FromRow, PgPool, Postgres, Row, Transaction};
use uuid::Uuid;

use crate::api::error::ApiError;

#[derive(Debug, Clone, Serialize, FromRow)]
pub struct ModerationCaseRecord {
    pub id: Uuid,
    pub campus_id: Uuid,
    pub subject_user_id: Option<String>,
    pub resource_type: String,
    pub resource_id: String,
    pub source_type: String,
    pub source_ref_id: String,
    pub status: String,
    pub reason_category: String,
    pub public_reason: String,
    pub internal_details: Value,
    pub resolution: Option<String>,
    pub opened_by: Option<String>,
    pub assigned_to: Option<String>,
    pub decided_by: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub decided_at: Option<DateTime<Utc>>,
    pub pending_appeal_count: i64,
    pub pending_appeal_id: Option<Uuid>,
}

#[derive(Debug, Clone, Serialize, FromRow)]
pub struct ModerationAppealRecord {
    pub id: Uuid,
    pub case_id: Uuid,
    pub campus_id: Uuid,
    pub appellant_id: String,
    pub reason: String,
    pub status: String,
    pub reviewed_by: Option<String>,
    pub decision_note: Option<String>,
    pub created_at: DateTime<Utc>,
    pub decided_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Copy)]
pub enum CaseReviewAction {
    StartReview,
    Restrict,
    Dismiss,
    Restore,
}

#[derive(Debug, Clone, Copy)]
pub enum AppealDecision {
    Uphold,
    Overturn,
}

#[derive(Clone)]
pub struct ModerationCaseService {
    pool: PgPool,
}

impl ModerationCaseService {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn list_for_subject(
        &self,
        subject_user_id: &str,
        campus_id: Uuid,
        status: Option<&str>,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<ModerationCaseRecord>, i64), ApiError> {
        validate_case_status_filter(status)?;
        let limit = limit.clamp(1, 100);
        let offset = offset.max(0);
        let cases = sqlx::query_as::<_, ModerationCaseRecord>(&format!(
            "{} WHERE moderation_case.subject_user_id = $1
               AND moderation_case.campus_id = $2
               AND ($3::TEXT IS NULL OR moderation_case.status = $3)
             ORDER BY moderation_case.created_at DESC
             LIMIT $4 OFFSET $5",
            case_select_sql()
        ))
        .bind(subject_user_id)
        .bind(campus_id)
        .bind(status)
        .bind(limit)
        .bind(offset)
        .fetch_all(&self.pool)
        .await
        .map_err(db_error)?;
        let total = sqlx::query_scalar(
            "SELECT COUNT(*) FROM moderation_cases
             WHERE subject_user_id = $1 AND campus_id = $2
               AND ($3::TEXT IS NULL OR status = $3)",
        )
        .bind(subject_user_id)
        .bind(campus_id)
        .bind(status)
        .fetch_one(&self.pool)
        .await
        .map_err(db_error)?;
        Ok((cases, total))
    }

    pub async fn get_for_subject(
        &self,
        case_id: Uuid,
        subject_user_id: &str,
        campus_id: Uuid,
    ) -> Result<ModerationCaseRecord, ApiError> {
        sqlx::query_as::<_, ModerationCaseRecord>(&format!(
            "{} WHERE moderation_case.id = $1
               AND moderation_case.subject_user_id = $2
               AND moderation_case.campus_id = $3",
            case_select_sql()
        ))
        .bind(case_id)
        .bind(subject_user_id)
        .bind(campus_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::NotFound)
    }

    pub async fn list_for_admin(
        &self,
        campus_id: Uuid,
        status: Option<&str>,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<ModerationCaseRecord>, i64), ApiError> {
        validate_case_status_filter(status)?;
        let limit = limit.clamp(1, 100);
        let offset = offset.max(0);
        let cases = sqlx::query_as::<_, ModerationCaseRecord>(&format!(
            "{} WHERE moderation_case.campus_id = $1
               AND ($2::TEXT IS NULL OR moderation_case.status = $2)
             ORDER BY
               (moderation_case.status IN ('open', 'appealed')) DESC,
               moderation_case.created_at DESC
             LIMIT $3 OFFSET $4",
            case_select_sql()
        ))
        .bind(campus_id)
        .bind(status)
        .bind(limit)
        .bind(offset)
        .fetch_all(&self.pool)
        .await
        .map_err(db_error)?;
        let total = sqlx::query_scalar(
            "SELECT COUNT(*) FROM moderation_cases
             WHERE campus_id = $1 AND ($2::TEXT IS NULL OR status = $2)",
        )
        .bind(campus_id)
        .bind(status)
        .fetch_one(&self.pool)
        .await
        .map_err(db_error)?;
        Ok((cases, total))
    }

    pub async fn submit_appeal(
        &self,
        case_id: Uuid,
        subject_user_id: &str,
        campus_id: Uuid,
        reason: &str,
    ) -> Result<ModerationAppealRecord, ApiError> {
        let reason = reason.trim();
        if !(10..=2000).contains(&reason.chars().count()) {
            return Err(ApiError::BadRequest(
                "申诉说明必须为 10 到 2000 字".to_string(),
            ));
        }

        let mut tx = self.pool.begin().await.map_err(db_error)?;
        let moderation_case = sqlx::query(
            "SELECT status, resolution, resource_type FROM moderation_cases
             WHERE id = $1 AND subject_user_id = $2 AND campus_id = $3
             FOR UPDATE",
        )
        .bind(case_id)
        .bind(subject_user_id)
        .bind(campus_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::NotFound)?;
        let current_status: String = moderation_case.get("status");
        let resolution: Option<String> = moderation_case.get("resolution");
        let resource_type: String = moderation_case.get("resource_type");
        let can_appeal = matches!(current_status.as_str(), "actioned" | "resolved")
            && matches!(
                resolution.as_deref(),
                Some("content_restricted" | "warning" | "account_action")
            );
        if !can_appeal {
            return Err(ApiError::Conflict("当前案件状态不可申诉".to_string()));
        }
        if matches!(resource_type.as_str(), "listing" | "user") {
            return Err(ApiError::Conflict(
                "该举报类型尚未定义限制或恢复动作".to_string(),
            ));
        }

        let existing = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS(
                SELECT 1 FROM moderation_appeals
                WHERE case_id = $1 AND appellant_id = $2
             )",
        )
        .bind(case_id)
        .bind(subject_user_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(db_error)?;
        if existing {
            return Err(ApiError::Conflict("该案件已提交过申诉".to_string()));
        }

        let appeal = sqlx::query_as::<_, ModerationAppealRecord>(
            "INSERT INTO moderation_appeals (
                case_id, campus_id, appellant_id, reason
             ) VALUES ($1, $2, $3, $4)
             RETURNING id, case_id, campus_id, appellant_id, reason, status,
                       reviewed_by, decision_note, created_at, decided_at",
        )
        .bind(case_id)
        .bind(campus_id)
        .bind(subject_user_id)
        .bind(reason)
        .fetch_one(&mut *tx)
        .await
        .map_err(db_error)?;
        sqlx::query(
            "UPDATE moderation_cases
             SET status = 'appealed', updated_at = NOW()
             WHERE id = $1",
        )
        .bind(case_id)
        .execute(&mut *tx)
        .await
        .map_err(db_error)?;
        insert_event(
            &mut tx,
            case_id,
            Some(subject_user_id),
            "appeal_submitted",
            Some(&current_status),
            Some("appealed"),
            None,
        )
        .await?;
        tx.commit().await.map_err(db_error)?;
        Ok(appeal)
    }

    pub async fn review_case(
        &self,
        case_id: Uuid,
        campus_id: Uuid,
        actor_id: &str,
        action: CaseReviewAction,
        note: Option<&str>,
        public_reason: Option<&str>,
    ) -> Result<ModerationCaseRecord, ApiError> {
        let note = normalize_optional(note, 2000, "处置说明最多 2000 字")?;
        let public_reason = normalize_optional(public_reason, 500, "公开原因最多 500 字")?;
        if public_reason
            .as_ref()
            .is_some_and(|value| value.chars().count() < 3)
        {
            return Err(ApiError::BadRequest("公开原因至少 3 字".to_string()));
        }

        let mut tx = self.pool.begin().await.map_err(db_error)?;
        let row = sqlx::query(
            "SELECT status, subject_user_id, source_type, source_ref_id,
                    resource_type, resource_id
             FROM moderation_cases
             WHERE id = $1 AND campus_id = $2
             FOR UPDATE",
        )
        .bind(case_id)
        .bind(campus_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::NotFound)?;
        let current_status: String = row.get("status");
        let subject_user_id: Option<String> = row.get("subject_user_id");
        if subject_user_id.as_deref() == Some(actor_id) {
            return Err(ApiError::Forbidden);
        }
        let source_type: String = row.get("source_type");
        let source_ref_id: String = row.get("source_ref_id");
        let resource_type: String = row.get("resource_type");
        let resource_id: String = row.get("resource_id");

        // Reporting a listing or account creates a review case, but this
        // feature does not define what a reversible listing takedown or account
        // sanction means. Refuse those transitions instead of marking a case
        // actioned while silently leaving the resource unchanged. Dismissal is
        // safe: it intentionally makes no change to the reported resource.
        if matches!(resource_type.as_str(), "listing" | "user")
            && matches!(
                action,
                CaseReviewAction::Restrict | CaseReviewAction::Restore
            )
        {
            return Err(ApiError::Conflict(
                "该举报类型尚未定义限制或恢复动作".to_string(),
            ));
        }

        let (new_status, resolution, resource_status) = match action {
            CaseReviewAction::StartReview if current_status == "open" => ("reviewing", None, None),
            CaseReviewAction::Restrict
                if matches!(current_status.as_str(), "open" | "reviewing") =>
            {
                ("actioned", Some("content_restricted"), Some("rejected"))
            }
            CaseReviewAction::Dismiss
                if matches!(current_status.as_str(), "open" | "reviewing") =>
            {
                ("dismissed", Some("no_violation"), Some("approved"))
            }
            CaseReviewAction::Restore
                if matches!(current_status.as_str(), "actioned" | "appealed") =>
            {
                ("resolved", Some("restored"), Some("approved"))
            }
            _ => {
                return Err(ApiError::Conflict(
                    "案件状态已变化，请刷新后重试".to_string(),
                ));
            }
        };

        if matches!(action, CaseReviewAction::StartReview) {
            sqlx::query(
                "UPDATE moderation_cases
                 SET status = 'reviewing', assigned_to = $2, updated_at = NOW()
                 WHERE id = $1",
            )
            .bind(case_id)
            .bind(actor_id)
            .execute(&mut *tx)
            .await
            .map_err(db_error)?;
        } else {
            sqlx::query(
                "UPDATE moderation_cases
                 SET status = $2, resolution = $3,
                     public_reason = COALESCE($4, public_reason),
                     assigned_to = COALESCE(assigned_to, $5),
                     decided_by = $5, decided_at = NOW(), updated_at = NOW()
                 WHERE id = $1",
            )
            .bind(case_id)
            .bind(new_status)
            .bind(resolution)
            .bind(public_reason.as_deref())
            .bind(actor_id)
            .execute(&mut *tx)
            .await
            .map_err(db_error)?;
        }

        if let Some(status) = resource_status {
            update_resource_status(&mut tx, &resource_type, &resource_id, status).await?;
        }
        sync_report_status(
            &mut tx,
            &source_type,
            &source_ref_id,
            new_status,
            resolution,
        )
        .await?;
        insert_event(
            &mut tx,
            case_id,
            Some(actor_id),
            review_event_type(action),
            Some(&current_status),
            Some(new_status),
            note.as_deref(),
        )
        .await?;
        tx.commit().await.map_err(db_error)?;
        self.get_for_admin(case_id, campus_id).await
    }

    pub async fn review_appeal(
        &self,
        appeal_id: Uuid,
        campus_id: Uuid,
        actor_id: &str,
        decision: AppealDecision,
        note: &str,
    ) -> Result<ModerationAppealRecord, ApiError> {
        let note = note.trim();
        if !(3..=2000).contains(&note.chars().count()) {
            return Err(ApiError::BadRequest(
                "复核说明必须为 3 到 2000 字".to_string(),
            ));
        }
        let mut tx = self.pool.begin().await.map_err(db_error)?;
        let row = sqlx::query(
            "SELECT appeal.case_id, appeal.appellant_id, appeal.status,
                    moderation_case.status AS case_status,
                    moderation_case.decided_by, moderation_case.resource_type,
                    moderation_case.resource_id, moderation_case.source_type,
                    moderation_case.source_ref_id
             FROM moderation_appeals appeal
             JOIN moderation_cases moderation_case ON moderation_case.id = appeal.case_id
             WHERE appeal.id = $1 AND appeal.campus_id = $2
             FOR UPDATE OF appeal, moderation_case",
        )
        .bind(appeal_id)
        .bind(campus_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::NotFound)?;
        let appeal_status: String = row.get("status");
        if appeal_status != "pending" {
            return Err(ApiError::Conflict("该申诉已经处理".to_string()));
        }
        let appellant_id: String = row.get("appellant_id");
        let original_decider: Option<String> = row.get("decided_by");
        if appellant_id == actor_id || original_decider.as_deref() == Some(actor_id) {
            return Err(ApiError::Forbidden);
        }
        let case_id: Uuid = row.get("case_id");
        let case_status: String = row.get("case_status");
        if case_status != "appealed" {
            return Err(ApiError::Conflict("案件不在申诉复核状态".to_string()));
        }
        let resource_type: String = row.get("resource_type");
        let resource_id: String = row.get("resource_id");
        let source_type: String = row.get("source_type");
        let source_ref_id: String = row.get("source_ref_id");
        if matches!(resource_type.as_str(), "listing" | "user") {
            return Err(ApiError::Conflict(
                "该举报类型尚未定义限制或恢复动作".to_string(),
            ));
        }
        let (appeal_status, resolution, resource_status, event_type) = match decision {
            AppealDecision::Uphold => (
                "upheld",
                "content_restricted",
                Some("rejected"),
                "appeal_upheld",
            ),
            AppealDecision::Overturn => (
                "overturned",
                "restored",
                Some("approved"),
                "appeal_overturned",
            ),
        };
        sqlx::query(
            "UPDATE moderation_appeals
             SET status = $2, reviewed_by = $3, decision_note = $4, decided_at = NOW()
             WHERE id = $1",
        )
        .bind(appeal_id)
        .bind(appeal_status)
        .bind(actor_id)
        .bind(note)
        .execute(&mut *tx)
        .await
        .map_err(db_error)?;
        sqlx::query(
            "UPDATE moderation_cases
             SET status = 'resolved', resolution = $2, decided_by = $3,
                 decided_at = NOW(), updated_at = NOW()
             WHERE id = $1",
        )
        .bind(case_id)
        .bind(resolution)
        .bind(actor_id)
        .execute(&mut *tx)
        .await
        .map_err(db_error)?;
        if let Some(status) = resource_status {
            update_resource_status(&mut tx, &resource_type, &resource_id, status).await?;
        }
        sync_report_status(
            &mut tx,
            &source_type,
            &source_ref_id,
            "resolved",
            Some(resolution),
        )
        .await?;
        insert_event(
            &mut tx,
            case_id,
            Some(actor_id),
            event_type,
            Some("appealed"),
            Some("resolved"),
            Some(note),
        )
        .await?;
        let appeal = sqlx::query_as::<_, ModerationAppealRecord>(
            "SELECT id, case_id, campus_id, appellant_id, reason, status,
                    reviewed_by, decision_note, created_at, decided_at
             FROM moderation_appeals WHERE id = $1",
        )
        .bind(appeal_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(db_error)?;
        tx.commit().await.map_err(db_error)?;
        Ok(appeal)
    }

    pub async fn get_appeal_for_subject(
        &self,
        appeal_id: Uuid,
        subject_user_id: &str,
        campus_id: Uuid,
    ) -> Result<ModerationAppealRecord, ApiError> {
        sqlx::query_as::<_, ModerationAppealRecord>(
            "SELECT appeal.id, appeal.case_id, appeal.campus_id,
                    appeal.appellant_id, appeal.reason, appeal.status,
                    appeal.reviewed_by, appeal.decision_note,
                    appeal.created_at, appeal.decided_at
             FROM moderation_appeals appeal
             JOIN moderation_cases moderation_case ON moderation_case.id = appeal.case_id
             WHERE appeal.id = $1 AND appeal.appellant_id = $2
               AND moderation_case.subject_user_id = $2
               AND appeal.campus_id = $3",
        )
        .bind(appeal_id)
        .bind(subject_user_id)
        .bind(campus_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::NotFound)
    }

    async fn get_for_admin(
        &self,
        case_id: Uuid,
        campus_id: Uuid,
    ) -> Result<ModerationCaseRecord, ApiError> {
        sqlx::query_as::<_, ModerationCaseRecord>(&format!(
            "{} WHERE moderation_case.id = $1 AND moderation_case.campus_id = $2",
            case_select_sql()
        ))
        .bind(case_id)
        .bind(campus_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::NotFound)
    }
}

pub async fn create_case_for_report(
    tx: &mut Transaction<'_, Postgres>,
    report_id: Uuid,
) -> Result<Uuid, ApiError> {
    let case_id = sqlx::query_scalar::<_, Uuid>(
        "WITH upserted_case AS (
            INSERT INTO moderation_cases (
                campus_id, subject_user_id, resource_type, resource_id,
                source_type, source_ref_id, status, reason_category,
                public_reason, internal_details, opened_by
            )
            SELECT conversation.campus_id, message.sender, 'chat_message',
                   report.message_id::text, 'user_report', report.id::text,
                   'open', 'message_report',
                   '一条聊天消息已进入内容审核流程',
                   jsonb_build_object(
                       'reported_reason', report.reason,
                       'details', report.details,
                       'report_id', report.id
                   ),
                   report.reporter_id
            FROM chat_message_reports report
            JOIN chat_messages message ON message.id = report.message_id
            JOIN chat_conversations conversation
              ON conversation.id = message.direct_conversation_id
            WHERE report.id = $1
            ON CONFLICT (source_type, source_ref_id) DO UPDATE
            SET internal_details = EXCLUDED.internal_details,
                updated_at = NOW()
            RETURNING id
         ), linked_report AS (
            UPDATE chat_message_reports report
            SET case_id = upserted_case.id
            FROM upserted_case
            WHERE report.id = $1
            RETURNING upserted_case.id
         )
         SELECT id FROM linked_report",
    )
    .bind(report_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(db_error)?
    .ok_or_else(|| ApiError::Internal(anyhow::anyhow!("unable to create report case")))?;
    sqlx::query(
        "INSERT INTO moderation_case_events (
            case_id, actor_id, event_type, from_status, to_status
         )
         SELECT moderation_case.id, moderation_case.opened_by,
                'case_created', NULL, moderation_case.status
         FROM moderation_cases moderation_case
         WHERE moderation_case.id = $1
           AND NOT EXISTS (
               SELECT 1 FROM moderation_case_events event
               WHERE event.case_id = moderation_case.id
                 AND event.event_type = 'case_created'
           )",
    )
    .bind(case_id)
    .execute(&mut **tx)
    .await
    .map_err(db_error)?;
    Ok(case_id)
}

/// Link a listing/user report to the shared moderation queue.
///
/// Content reports use a prefixed source reference. Chat report ids are UUIDs
/// too, and `moderation_cases` de-duplicates on `(source_type, source_ref_id)`;
/// a bare id in both tables would make an otherwise unlikely UUID collision
/// attach one person's report to an unrelated case.
pub async fn create_case_for_content_report(
    tx: &mut Transaction<'_, Postgres>,
    report_id: Uuid,
) -> Result<Uuid, ApiError> {
    let case_id = sqlx::query_scalar::<_, Uuid>(
        "WITH upserted_case AS (
            INSERT INTO moderation_cases (
                campus_id, subject_user_id, resource_type, resource_id,
                source_type, source_ref_id, status, reason_category,
                public_reason, internal_details, opened_by
            )
            SELECT report.campus_id, report.subject_user_id,
                   report.resource_type, report.resource_id,
                   'user_report', 'content_report:' || report.id::text,
                   'open',
                   CASE report.resource_type
                       WHEN 'listing' THEN 'listing_report'
                       ELSE 'user_report'
                   END,
                   CASE report.resource_type
                       WHEN 'listing' THEN '一条发布已进入内容审核流程'
                       ELSE '一个账号已进入安全审核流程'
                   END,
                   jsonb_build_object(
                       'reported_reason', report.reason,
                       'details', report.details,
                       'content_report_id', report.id,
                       'reported_resource_type', report.resource_type
                   ),
                   report.reporter_id
            FROM content_reports report
            WHERE report.id = $1
            ON CONFLICT (source_type, source_ref_id) DO UPDATE
            SET subject_user_id = EXCLUDED.subject_user_id,
                resource_type = EXCLUDED.resource_type,
                resource_id = EXCLUDED.resource_id,
                reason_category = EXCLUDED.reason_category,
                public_reason = EXCLUDED.public_reason,
                internal_details = EXCLUDED.internal_details,
                updated_at = NOW()
            RETURNING id
         ), linked_report AS (
            UPDATE content_reports report
            SET case_id = upserted_case.id, updated_at = NOW()
            FROM upserted_case
            WHERE report.id = $1
            RETURNING upserted_case.id
         )
         SELECT id FROM linked_report",
    )
    .bind(report_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(db_error)?
    .ok_or_else(|| ApiError::Internal(anyhow::anyhow!("unable to create content report case")))?;

    sqlx::query(
        "INSERT INTO moderation_case_events (
            case_id, actor_id, event_type, from_status, to_status
         )
         SELECT moderation_case.id, moderation_case.opened_by,
                'case_created', NULL, moderation_case.status
         FROM moderation_cases moderation_case
         WHERE moderation_case.id = $1
           AND NOT EXISTS (
               SELECT 1 FROM moderation_case_events event
               WHERE event.case_id = moderation_case.id
                 AND event.event_type = 'case_created'
           )",
    )
    .bind(case_id)
    .execute(&mut **tx)
    .await
    .map_err(db_error)?;
    Ok(case_id)
}

pub async fn create_case_for_rejected_job(
    tx: &mut Transaction<'_, Postgres>,
    job_id: &str,
) -> Result<Uuid, ApiError> {
    let case_id = sqlx::query_scalar::<_, Uuid>(
        "WITH upserted_case AS (
            INSERT INTO moderation_cases (
                campus_id, subject_user_id, resource_type, resource_id,
                source_type, source_ref_id, status, reason_category,
                public_reason, internal_details, resolution, decided_at
            )
            SELECT job.campus_id,
                   CASE
                       WHEN job.resource_type = 'listing_image' THEN listing.owner_id
                       WHEN job.resource_type = 'chat_image' THEN message.sender
                       WHEN job.resource_type = 'avatar' THEN job.resource_id
                       ELSE NULL
                   END,
                   job.resource_type, job.resource_id, 'machine', job.id,
                   'actioned', 'image_policy',
                   COALESCE(NULLIF(btrim(job.reject_reason), ''),
                            '图片未通过内容安全审核'),
                   jsonb_build_object('moderation_job_id', job.id),
                   'content_restricted', job.processed_at
            FROM moderation_jobs job
            LEFT JOIN inventory listing
              ON job.resource_type = 'listing_image' AND listing.id = job.resource_id
            LEFT JOIN chat_messages message
              ON job.resource_type = 'chat_image' AND message.id::text = job.resource_id
            WHERE job.id = $1 AND job.status = 'rejected'
            ON CONFLICT (source_type, source_ref_id) DO UPDATE
            SET public_reason = EXCLUDED.public_reason,
                internal_details = EXCLUDED.internal_details,
                updated_at = NOW()
            RETURNING id
         ), linked_job AS (
            UPDATE moderation_jobs job
            SET case_id = upserted_case.id
            FROM upserted_case
            WHERE job.id = $1
            RETURNING upserted_case.id
         )
         SELECT id FROM linked_job",
    )
    .bind(job_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(db_error)?
    .ok_or_else(|| ApiError::Internal(anyhow::anyhow!("unable to create moderation case")))?;
    sqlx::query(
        "INSERT INTO moderation_case_events (
            case_id, actor_id, event_type, from_status, to_status
         )
         SELECT id, NULL, 'case_created', NULL, status
         FROM moderation_cases moderation_case
         WHERE id = $1
           AND NOT EXISTS (
               SELECT 1 FROM moderation_case_events event
               WHERE event.case_id = moderation_case.id
                 AND event.event_type = 'case_created'
           )",
    )
    .bind(case_id)
    .execute(&mut **tx)
    .await
    .map_err(db_error)?;
    Ok(case_id)
}

async fn insert_event(
    tx: &mut Transaction<'_, Postgres>,
    case_id: Uuid,
    actor_id: Option<&str>,
    event_type: &str,
    from_status: Option<&str>,
    to_status: Option<&str>,
    note: Option<&str>,
) -> Result<(), ApiError> {
    sqlx::query(
        "INSERT INTO moderation_case_events (
            case_id, actor_id, event_type, from_status, to_status, note
         ) VALUES ($1, $2, $3, $4, $5, $6)",
    )
    .bind(case_id)
    .bind(actor_id)
    .bind(event_type)
    .bind(from_status)
    .bind(to_status)
    .bind(note)
    .execute(&mut **tx)
    .await
    .map_err(db_error)?;
    Ok(())
}

async fn update_resource_status(
    tx: &mut Transaction<'_, Postgres>,
    resource_type: &str,
    resource_id: &str,
    status: &str,
) -> Result<(), ApiError> {
    match resource_type {
        "listing_image" => {
            sqlx::query("UPDATE inventory SET images_moderation_status = $1 WHERE id = $2")
                .bind(status)
                .bind(resource_id)
                .execute(&mut **tx)
                .await
                .map_err(db_error)?;
        }
        "chat_image" | "chat_message" => {
            let message_id = resource_id.parse::<i64>().map_err(|_| {
                ApiError::Internal(anyhow::anyhow!("invalid chat message resource id"))
            })?;
            sqlx::query("UPDATE chat_messages SET moderation_status = $1 WHERE id = $2")
                .bind(status)
                .bind(message_id)
                .execute(&mut **tx)
                .await
                .map_err(db_error)?;
        }
        "avatar" => {
            sqlx::query("UPDATE users SET avatar_moderation_status = $1 WHERE id = $2")
                .bind(status)
                .bind(resource_id)
                .execute(&mut **tx)
                .await
                .map_err(db_error)?;
        }
        _ => {}
    }
    Ok(())
}

async fn sync_report_status(
    tx: &mut Transaction<'_, Postgres>,
    source_type: &str,
    source_ref_id: &str,
    case_status: &str,
    resolution: Option<&str>,
) -> Result<(), ApiError> {
    if source_type != "user_report" {
        return Ok(());
    }
    let report_status = match case_status {
        "reviewing" => "reviewing",
        "dismissed" => "dismissed",
        "actioned" => "resolved",
        "resolved" if matches!(resolution, Some("no_violation" | "restored")) => "dismissed",
        "resolved" => "resolved",
        _ => return Ok(()),
    };

    if let Some(content_report_id) = source_ref_id.strip_prefix("content_report:") {
        sqlx::query(
            "UPDATE content_reports
             SET status = $2, updated_at = NOW()
             WHERE id::text = $1",
        )
        .bind(content_report_id)
        .bind(report_status)
        .execute(&mut **tx)
        .await
        .map_err(db_error)?;
        return Ok(());
    }

    sqlx::query("UPDATE chat_message_reports SET status = $2 WHERE id::text = $1")
        .bind(source_ref_id)
        .bind(report_status)
        .execute(&mut **tx)
        .await
        .map_err(db_error)?;
    Ok(())
}

fn case_select_sql() -> &'static str {
    "SELECT moderation_case.id, moderation_case.campus_id,
            moderation_case.subject_user_id, moderation_case.resource_type,
            moderation_case.resource_id, moderation_case.source_type,
            moderation_case.source_ref_id, moderation_case.status,
            moderation_case.reason_category, moderation_case.public_reason,
            moderation_case.internal_details, moderation_case.resolution,
            moderation_case.opened_by, moderation_case.assigned_to,
            moderation_case.decided_by, moderation_case.created_at,
            moderation_case.updated_at, moderation_case.decided_at,
            (SELECT COUNT(*) FROM moderation_appeals appeal
             WHERE appeal.case_id = moderation_case.id
               AND appeal.status = 'pending') AS pending_appeal_count,
            (SELECT appeal.id FROM moderation_appeals appeal
             WHERE appeal.case_id = moderation_case.id
               AND appeal.status = 'pending'
             ORDER BY appeal.created_at ASC LIMIT 1) AS pending_appeal_id
     FROM moderation_cases moderation_case"
}

fn validate_case_status_filter(status: Option<&str>) -> Result<(), ApiError> {
    if status.is_some_and(|value| {
        !matches!(
            value,
            "open" | "reviewing" | "actioned" | "dismissed" | "appealed" | "resolved"
        )
    }) {
        return Err(ApiError::BadRequest("无效的案件状态".to_string()));
    }
    Ok(())
}

fn normalize_optional(
    value: Option<&str>,
    max_len: usize,
    error: &str,
) -> Result<Option<String>, ApiError> {
    let value = value.map(str::trim).filter(|value| !value.is_empty());
    if value.is_some_and(|value| value.chars().count() > max_len) {
        return Err(ApiError::BadRequest(error.to_string()));
    }
    Ok(value.map(str::to_string))
}

fn review_event_type(action: CaseReviewAction) -> &'static str {
    match action {
        CaseReviewAction::StartReview => "review_started",
        CaseReviewAction::Restrict => "content_restricted",
        CaseReviewAction::Dismiss => "case_dismissed",
        CaseReviewAction::Restore => "content_restored",
    }
}

fn db_error(error: sqlx::Error) -> ApiError {
    ApiError::Internal(anyhow::anyhow!("DB error: {}", error))
}
