//! Admin service for platform-wide management.

use anyhow::Result;
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Clone)]
pub struct AdminService {
    db: PgPool,
}

#[derive(serde::Serialize, sqlx::FromRow)]
pub struct AuditLogEntry {
    pub id: String,
    pub campus_id: Uuid,
    pub admin_id: String,
    pub action: String,
    pub target_id: Option<String>,
    pub old_value: Option<String>,
    pub new_value: Option<String>,
    pub memo: Option<String>,
    pub scope_reason: Option<String>,
    pub created_at: Option<chrono::DateTime<chrono::Utc>>,
}

pub struct NewAuditLog<'a> {
    pub campus_id: Uuid,
    pub admin_id: &'a str,
    pub action: &'a str,
    pub target_id: Option<&'a str>,
    pub old_value: Option<&'a str>,
    pub new_value: Option<&'a str>,
    pub memo: Option<&'a str>,
    pub scope_reason: Option<&'a str>,
}

impl AdminService {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    /// List audit logs with pagination.
    pub async fn list_audit_logs(
        &self,
        campus_id: Uuid,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<AuditLogEntry>, i64)> {
        let total: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM admin_audit_logs WHERE campus_id = $1")
                .bind(campus_id)
                .fetch_one(&self.db)
                .await?;

        let rows = sqlx::query_as::<_, AuditLogEntry>(
            r#"
            SELECT id, campus_id, admin_id, action, target_id, old_value, new_value,
                   memo, scope_reason, created_at
            FROM admin_audit_logs
            WHERE campus_id = $1
            ORDER BY created_at DESC
            LIMIT $2 OFFSET $3
            "#,
        )
        .bind(campus_id)
        .bind(limit)
        .bind(offset)
        .fetch_all(&self.db)
        .await?;

        Ok((rows, total))
    }

    /// Log an administrative action to the audit trail.
    pub async fn log_action(&self, entry: NewAuditLog<'_>) -> Result<()> {
        let audit_id = Uuid::new_v4().to_string();
        sqlx::query(
            r#"
            INSERT INTO admin_audit_logs (
                id, campus_id, admin_id, action, target_id, old_value,
                new_value, memo, scope_reason
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
            "#,
        )
        .bind(&audit_id)
        .bind(entry.campus_id)
        .bind(entry.admin_id)
        .bind(entry.action)
        .bind(entry.target_id)
        .bind(entry.old_value)
        .bind(entry.new_value)
        .bind(entry.memo)
        .bind(entry.scope_reason)
        .execute(&self.db)
        .await?;

        Ok(())
    }
}
