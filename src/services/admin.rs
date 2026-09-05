//! Admin service for platform-wide management.

use anyhow::Result;
use sqlx::{PgPool, Postgres, Row, Transaction};
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
        let mut tx = self.db.begin().await?;
        Self::log_action_in_tx(&mut tx, entry).await?;
        tx.commit().await?;
        Ok(())
    }

    /// Persist an audit record in the caller's business transaction. Sensitive
    /// enforcement must never commit while its audit record silently fails.
    pub async fn log_action_in_tx(
        tx: &mut Transaction<'_, Postgres>,
        entry: NewAuditLog<'_>,
    ) -> Result<String> {
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
        .execute(&mut **tx)
        .await?;

        Ok(audit_id)
    }

    /// Get admin stats for the given campus.
    pub async fn get_admin_stats(&self, campus_id: Uuid) -> Result<AdminStatsData> {
        let row = sqlx::query(
            "SELECT
                (SELECT COUNT(*) FROM inventory WHERE campus_id = $1) AS total_listings,
                (SELECT COUNT(*) FROM inventory WHERE campus_id = $1 AND status = 'active'
                    AND NOT listing_has_active_restriction(id)) AS active_listings,
                (SELECT COUNT(*) FROM campus_memberships WHERE campus_id = $1 AND status <> 'revoked') AS total_users,
                (SELECT COUNT(*) FROM orders WHERE campus_id = $1) AS total_orders,
                (SELECT COUNT(*) FROM campus_memberships membership
                 JOIN users u ON u.id = membership.user_id
                 WHERE membership.campus_id = $1 AND membership.status <> 'revoked'
                   AND (membership.role IN ('operator', 'admin') OR u.role = 'admin')) AS admin_users",
        )
        .bind(campus_id)
        .fetch_one(&self.db)
        .await?;

        let categories = sqlx::query(
            "SELECT category, COUNT(*) AS count
             FROM inventory WHERE campus_id = $1
             GROUP BY category ORDER BY count DESC, category ASC",
        )
        .bind(campus_id)
        .fetch_all(&self.db)
        .await?
        .into_iter()
        .map(|category| AdminCategoryCountData {
            category: category.get("category"),
            count: category.get("count"),
        })
        .collect();

        Ok(AdminStatsData {
            total_listings: row.get("total_listings"),
            active_listings: row.get("active_listings"),
            total_users: row.get("total_users"),
            total_orders: row.get("total_orders"),
            admin_users: row.get("admin_users"),
            categories,
        })
    }

    /// List users belonging to the given campus with total count.
    pub async fn get_admin_users(
        &self,
        campus_id: Uuid,
        search_term: Option<&str>,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<AdminUserData>, i64)> {
        let users = sqlx::query(
            "SELECT u.id, u.username, u.role, u.status, u.created_at,
                    membership.role AS membership_role,
                    membership.status AS membership_status,
                    COUNT(i.id) AS listing_count
             FROM campus_memberships membership
             JOIN users u ON u.id = membership.user_id
             LEFT JOIN inventory i ON i.owner_id = u.id AND i.campus_id = membership.campus_id
             WHERE membership.campus_id = $1 AND membership.status <> 'revoked'
               AND ($2::TEXT IS NULL
                    OR STRPOS(LOWER(u.username), LOWER($2)) > 0
                    OR STRPOS(LOWER(u.id), LOWER($2)) > 0)
             GROUP BY u.id, u.username, u.role, u.status, u.created_at,
                      membership.role, membership.status
             ORDER BY u.created_at DESC
             LIMIT $3 OFFSET $4",
        )
        .bind(campus_id)
        .bind(search_term)
        .bind(limit)
        .bind(offset)
        .fetch_all(&self.db)
        .await?;

        let total: i64 = sqlx::query_scalar(
            "SELECT COUNT(*)
             FROM campus_memberships membership
             JOIN users u ON u.id = membership.user_id
             WHERE membership.campus_id = $1 AND membership.status <> 'revoked'
               AND ($2::TEXT IS NULL
                    OR STRPOS(LOWER(u.username), LOWER($2)) > 0
                    OR STRPOS(LOWER(u.id), LOWER($2)) > 0)",
        )
        .bind(campus_id)
        .bind(search_term)
        .fetch_one(&self.db)
        .await?;

        let list = users
            .into_iter()
            .map(|row| AdminUserData {
                id: row.get("id"),
                username: row.get("username"),
                role: row.get("role"),
                membership_role: row.get("membership_role"),
                membership_status: row.get("membership_status"),
                status: row.get("status"),
                created_at: row.get("created_at"),
                listing_count: row.get("listing_count"),
            })
            .collect();

        Ok((list, total))
    }

    /// List listings for admin with total count.
    pub async fn get_admin_listings(
        &self,
        campus_id: Uuid,
        status: Option<&str>,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<AdminListingRowData>, i64)> {
        let listings = sqlx::query(
            "SELECT id, title, category, COALESCE(brand, '') AS brand, direction, condition_score,
                    suggested_price_cny, description, status, owner_id, created_at,
                    (SELECT COUNT(*) FROM listing_restriction_effects effect
                     WHERE effect.listing_id = inventory.id
                       AND effect.released_at IS NULL) AS active_restriction_count,
                    EXISTS(
                        SELECT 1 FROM listing_restriction_effects effect
                        WHERE effect.listing_id = inventory.id
                          AND effect.released_at IS NULL
                          AND effect.source_kind IN ('admin_takedown', 'legacy_admin_takedown')
                    ) AS has_admin_restriction,
                    latest_effect.case_id AS restriction_case_id,
                    latest_effect.imposed_at AS restricted_at,
                    latest_effect.public_reason AS restriction_public_reason,
                    latest_effect.can_appeal AS restriction_can_appeal
             FROM inventory
             LEFT JOIN LATERAL (
                 SELECT effect.case_id, effect.imposed_at,
                        moderation_case.public_reason,
                        moderation_case.status IN ('actioned', 'resolved')
                            AND moderation_case.resolution = 'content_restricted'
                            AND NOT EXISTS (
                                SELECT 1 FROM moderation_appeals appeal
                                WHERE appeal.case_id = moderation_case.id
                                  AND appeal.appellant_id = moderation_case.subject_user_id
                            ) AS can_appeal
                 FROM listing_restriction_effects effect
                 JOIN moderation_cases moderation_case ON moderation_case.id = effect.case_id
                 WHERE effect.listing_id = inventory.id AND effect.released_at IS NULL
                 ORDER BY effect.imposed_at DESC
                 LIMIT 1
             ) latest_effect ON TRUE
             WHERE campus_id = $1 AND ($2::text IS NULL OR status = $2)
             ORDER BY created_at DESC LIMIT $3 OFFSET $4",
        )
        .bind(campus_id)
        .bind(status)
        .bind(limit)
        .bind(offset)
        .fetch_all(&self.db)
        .await?;

        let total: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM inventory
             WHERE campus_id = $1 AND ($2::text IS NULL OR status = $2)",
        )
        .bind(campus_id)
        .bind(status)
        .fetch_one(&self.db)
        .await?;

        let list = listings
            .into_iter()
            .map(|row| AdminListingRowData {
                id: row.get("id"),
                title: row.get("title"),
                category: row.get("category"),
                brand: row.get("brand"),
                direction: row.get("direction"),
                condition_score: row.get("condition_score"),
                suggested_price_cny: row.get("suggested_price_cny"),
                description: row.get("description"),
                status: row.get("status"),
                owner_id: row.get("owner_id"),
                created_at: row.get("created_at"),
                active_restriction_count: row.get("active_restriction_count"),
                has_admin_restriction: row.get("has_admin_restriction"),
                restriction_case_id: row.get("restriction_case_id"),
                restricted_at: row.get("restricted_at"),
                restriction_public_reason: row.get("restriction_public_reason"),
                restriction_can_appeal: row.get("restriction_can_appeal"),
            })
            .collect();

        Ok((list, total))
    }

    /// List moderation jobs for admin with total count.
    pub async fn get_moderation_jobs(
        &self,
        campus_id: Uuid,
        status: Option<&str>,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<AdminModerationJobData>, i64)> {
        let jobs = sqlx::query_as::<_, AdminModerationJobData>(
            "SELECT id, campus_id, resource_type, resource_id, image_url, storage_key, status,
                    reject_reason, retry_count, created_at, processed_at
             FROM moderation_jobs
             WHERE campus_id = $1 AND ($2::text IS NULL OR status = $2)
             ORDER BY created_at DESC LIMIT $3 OFFSET $4",
        )
        .bind(campus_id)
        .bind(status)
        .bind(limit)
        .bind(offset)
        .fetch_all(&self.db)
        .await?;

        let total: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM moderation_jobs
             WHERE campus_id = $1 AND ($2::text IS NULL OR status = $2)",
        )
        .bind(campus_id)
        .bind(status)
        .fetch_one(&self.db)
        .await?;

        Ok((jobs, total))
    }
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct AdminStatsData {
    pub total_listings: i64,
    pub active_listings: i64,
    pub total_users: i64,
    pub total_orders: i64,
    pub admin_users: i64,
    pub categories: Vec<AdminCategoryCountData>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct AdminCategoryCountData {
    pub category: String,
    pub count: i64,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct AdminUserData {
    pub id: String,
    pub username: String,
    pub role: String,
    pub membership_role: String,
    pub membership_status: String,
    pub status: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub listing_count: i64,
}

#[derive(Debug, Clone)]
pub struct AdminListingRowData {
    pub id: String,
    pub title: String,
    pub category: String,
    pub brand: String,
    pub direction: String,
    pub condition_score: i32,
    pub suggested_price_cny: i64,
    pub description: Option<String>,
    pub status: String,
    pub owner_id: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub active_restriction_count: i64,
    pub has_admin_restriction: bool,
    pub restriction_case_id: Option<Uuid>,
    pub restricted_at: Option<chrono::DateTime<chrono::Utc>>,
    pub restriction_public_reason: Option<String>,
    pub restriction_can_appeal: Option<bool>,
}

#[derive(Debug, Clone, serde::Serialize, sqlx::FromRow)]
pub struct AdminModerationJobData {
    pub id: String,
    pub campus_id: Uuid,
    pub resource_type: String,
    pub resource_id: String,
    pub image_url: String,
    #[serde(skip_serializing)]
    pub storage_key: Option<String>,
    pub status: String,
    pub reject_reason: Option<String>,
    pub retry_count: i32,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub processed_at: Option<chrono::DateTime<chrono::Utc>>,
}
