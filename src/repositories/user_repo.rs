//! PostgreSQL implementation of the UserRepository trait.

use crate::api::error::ApiError;
use crate::repositories::{
    User, UserDiscoverability, UserLookupMethod, UserLookupResult, UserPaymentQr, UserProfile,
    UserRepository,
};
use sqlx::{PgPool, Row};
use uuid::Uuid;

#[derive(Clone)]
#[allow(dead_code)]
pub struct PostgresUserRepository {
    pool: PgPool,
}

impl PostgresUserRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

fn derive_student_id(email: &str) -> Option<String> {
    let lower = email.to_ascii_lowercase();
    let local = lower.strip_suffix("@email.ncu.edu.cn")?;
    if (8..=12).contains(&local.len()) && local.chars().all(|ch| ch.is_ascii_digit()) {
        Some(local.to_string())
    } else {
        None
    }
}

fn db_conflict_or_internal(error: sqlx::Error, message: &str) -> ApiError {
    if let sqlx::Error::Database(db_error) = &error {
        if db_error.code().as_deref() == Some("23505") {
            return ApiError::Conflict(message.to_string());
        }
    }
    ApiError::Internal(anyhow::anyhow!("DB error: {}", error))
}

fn profile_from_row(row: &sqlx::postgres::PgRow, user_id_column: &str) -> UserProfile {
    let created_at: String = row
        .try_get::<sqlx::types::chrono::DateTime<sqlx::types::chrono::Utc>, _>("created_at")
        .map(|dt| dt.to_rfc3339())
        .unwrap_or_else(|_| "unknown".to_string());

    UserProfile {
        user_id: row.get(user_id_column),
        username: row.get("username"),
        email: row.get("email"),
        student_id: row.get("student_id"),
        discoverability: UserDiscoverability {
            username: row.get("discover_by_username"),
            email: row.get("discover_by_email"),
            student_id: row.get("discover_by_student_id"),
        },
        avatar_url: row.get("avatar_url"),
        payment_qr: UserPaymentQr {
            wechat_url: row.get("wechat_pay_qr_url"),
            alipay_url: row.get("alipay_qr_url"),
            show_wechat: row.get("show_wechat_pay_qr"),
            show_alipay: row.get("show_alipay_qr"),
        },
        role: row.get("role"),
        created_at,
    }
}

fn resolve_lookup_method(query: &str, method: UserLookupMethod) -> UserLookupMethod {
    match method {
        UserLookupMethod::Auto if query.contains('@') => UserLookupMethod::Email,
        UserLookupMethod::Auto
            if (8..=12).contains(&query.len()) && query.chars().all(|ch| ch.is_ascii_digit()) =>
        {
            UserLookupMethod::StudentId
        }
        UserLookupMethod::Auto => UserLookupMethod::Username,
        explicit => explicit,
    }
}

fn mask_email(email: &str) -> String {
    let (local, domain) = email.split_once('@').unwrap_or((email, ""));
    let masked_local = match local.chars().count() {
        0..=2 => "***".to_string(),
        3..=5 => format!("{}***", &local[..1]),
        _ => {
            let prefix: String = local.chars().take(2).collect();
            let suffix: String = local
                .chars()
                .rev()
                .take(2)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect();
            format!("{prefix}***{suffix}")
        }
    };
    if domain.is_empty() {
        masked_local
    } else {
        format!("{masked_local}@{domain}")
    }
}

fn mask_student_id(student_id: &str) -> String {
    if student_id.chars().count() <= 4 {
        return "****".to_string();
    }
    let prefix: String = student_id.chars().take(4).collect();
    format!("{prefix}****")
}

impl UserRepository for PostgresUserRepository {
    async fn find_by_id(&self, id: &str) -> Result<Option<User>, ApiError> {
        let row = sqlx::query_as::<_, User>("SELECT * FROM users WHERE id = $1")
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(row)
    }

    async fn find_by_username(&self, username: &str) -> Result<Option<User>, ApiError> {
        let row = sqlx::query_as::<_, User>("SELECT * FROM users WHERE username = $1")
            .bind(username)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(row)
    }

    async fn find_by_email(&self, email: &str) -> Result<Option<User>, ApiError> {
        let row = sqlx::query_as::<_, User>("SELECT * FROM users WHERE email = $1")
            .bind(email)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(row)
    }

    async fn create(
        &self,
        username: &str,
        email: Option<&str>,
        password_hash: &str,
        role: &str,
    ) -> Result<String, ApiError> {
        let user_id = uuid::Uuid::new_v4().to_string();
        let student_id = email.and_then(derive_student_id);
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
        sqlx::query(
            "INSERT INTO users (id, username, email, student_id, password_hash, role)
             VALUES ($1, $2, $3, $4, $5, $6)",
        )
        .bind(&user_id)
        .bind(username)
        .bind(email)
        .bind(student_id.as_deref())
        .bind(password_hash)
        .bind(role)
        .execute(&mut *tx)
        .await
        .map_err(|e| db_conflict_or_internal(e, "用户已存在"))?;

        // Initial membership routes by the registration email's domain: a
        // student registering with campus B's email lands as a pending member
        // of campus B. No email or no matching active campus falls back to
        // the NCU default (compatibility with the single-campus launch).
        let membership = sqlx::query(
            "WITH matched AS (
                SELECT c.id
                FROM campuses c
                WHERE c.status = 'active'
                  AND $2::text IS NOT NULL
                  AND EXISTS (
                      SELECT 1 FROM unnest(c.email_domains) AS d
                      WHERE lower($2) LIKE '%@' || lower(d)
                  )
                ORDER BY (c.slug = 'ncu') DESC, c.created_at ASC
                LIMIT 1
             )
             INSERT INTO campus_memberships (
                campus_id, user_id, status, role, verification_method
             )
             SELECT COALESCE(
                        (SELECT id FROM matched),
                        (SELECT id FROM campuses WHERE slug = 'ncu' AND status = 'active')
                    ),
                    $1, 'pending', 'member', 'repository_create'
             ON CONFLICT (campus_id, user_id) DO NOTHING",
        )
        .bind(&user_id)
        .bind(email)
        .execute(&mut *tx)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
        if membership.rows_affected() != 1 {
            return Err(ApiError::Internal(anyhow::anyhow!(
                "Default campus is missing or inactive"
            )));
        }

        tx.commit()
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
        Ok(user_id)
    }

    async fn get_profile(&self, user_id: &str) -> Result<UserProfile, ApiError> {
        let row = sqlx::query(
            "SELECT id, username, email, student_id, discover_by_username,
                    discover_by_email, discover_by_student_id,
                    avatar_url,
                    wechat_pay_qr_url, alipay_qr_url, show_wechat_pay_qr,
                    show_alipay_qr, role, created_at
             FROM users WHERE id = $1",
        )
        .bind(user_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        .ok_or(ApiError::NotFound)?;

        Ok(profile_from_row(&row, "id"))
    }

    async fn get_user_listings(
        &self,
        user_id: &str,
        campus_id: Uuid,
        limit: i64,
        offset: i64,
        status_filter: &str,
        only_approved_media: bool,
    ) -> Result<(Vec<crate::repositories::Listing>, i64), ApiError> {
        use crate::repositories::Listing;

        let status_clause = if status_filter == "all" {
            String::new()
        } else {
            format!("AND status = '{}'", status_filter.replace('\'', "''"))
        };
        let visibility_clause = if only_approved_media {
            "AND NOT listing_has_active_restriction(id)"
        } else {
            ""
        };

        // Public viewers never see unreviewed media; owners see their own
        // uploads regardless of moderation state.
        let image_column = if only_approved_media {
            "CASE WHEN images_moderation_status = 'approved' THEN image_url ELSE NULL END AS image_url"
        } else {
            "image_url"
        };

        let query = format!(
            "SELECT id, campus_id, content_revision, title, category, brand, direction, condition_score, suggested_price_cny, \
             defects, description, {image_column}, owner_id, status, created_at \
             FROM inventory WHERE owner_id = $1 AND campus_id = $2 {} {} \
             ORDER BY created_at DESC LIMIT {} OFFSET {}",
            status_clause, visibility_clause, limit, offset
        );

        let rows = sqlx::query_as::<_, Listing>(&query)
            .bind(user_id)
            .bind(campus_id)
            .fetch_all(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let count_query = format!(
            "SELECT COUNT(*) FROM inventory WHERE owner_id = $1 AND campus_id = $2 {} {}",
            status_clause, visibility_clause
        );
        let count_row = sqlx::query(&count_query)
            .bind(user_id)
            .bind(campus_id)
            .fetch_one(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let total: i64 = count_row.get(0);
        Ok((rows, total))
    }

    async fn search_users(&self, query: &str, limit: i64) -> Result<Vec<UserProfile>, ApiError> {
        let escaped = query.replace('\'', "''");
        let pattern = format!("%{}%", escaped);

        let rows = sqlx::query(
            "SELECT id, username, email, student_id, discover_by_username,
                    discover_by_email, discover_by_student_id,
                    avatar_url,
                    wechat_pay_qr_url, alipay_qr_url, show_wechat_pay_qr,
                    show_alipay_qr, role, created_at
             FROM users
             WHERE discover_by_username = TRUE
               AND status = 'active'
               AND username ILIKE $1
             LIMIT $2",
        )
        .bind(&pattern)
        .bind(limit)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let profiles = rows.iter().map(|row| profile_from_row(row, "id")).collect();

        Ok(profiles)
    }

    async fn search_users_with_listing_count(
        &self,
        campus_id: Uuid,
        query: Option<&str>,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<(UserProfile, i64)>, i64), ApiError> {
        let (count_row, rows) = if let Some(q) = query {
            let pattern = format!("%{}%", q.replace('\'', "''"));
            let count_row = sqlx::query(
                "SELECT COUNT(*) as cnt
                 FROM users u
                 JOIN campus_memberships membership
                   ON membership.user_id = u.id
                  AND membership.campus_id = $1
                  AND membership.status = 'verified'
                 WHERE u.discover_by_username = TRUE
                   AND u.status = 'active'
                   AND u.username ILIKE $2",
            )
            .bind(campus_id)
            .bind(&pattern)
            .fetch_one(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
            let rows = sqlx::query(
                r#"
                SELECT u.id as user_id, u.username, u.email, u.student_id,
                       u.discover_by_username, u.discover_by_email,
                       u.discover_by_student_id, u.avatar_url,
                       u.wechat_pay_qr_url, u.alipay_qr_url,
                       u.show_wechat_pay_qr, u.show_alipay_qr,
                       u.role, u.created_at,
                       COUNT(i.id) as listing_count
                FROM users u
                JOIN campus_memberships membership
                  ON membership.user_id = u.id
                 AND membership.campus_id = $1
                 AND membership.status = 'verified'
                LEFT JOIN inventory i ON u.id = i.owner_id
                 AND i.status = 'active' AND i.campus_id = $1
                 AND NOT listing_has_active_restriction(i.id)
                WHERE u.discover_by_username = TRUE
                  AND u.status = 'active'
                  AND u.username ILIKE $2
                GROUP BY u.id, u.username, u.email, u.student_id,
                         u.discover_by_username, u.discover_by_email,
                         u.discover_by_student_id, u.avatar_url,
                         u.wechat_pay_qr_url, u.alipay_qr_url,
                         u.show_wechat_pay_qr, u.show_alipay_qr,
                         u.role, u.created_at
                ORDER BY listing_count DESC
                LIMIT $3 OFFSET $4
                "#,
            )
            .bind(campus_id)
            .bind(&pattern)
            .bind(limit)
            .bind(offset)
            .fetch_all(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
            (count_row, rows)
        } else {
            let count_row = sqlx::query(
                "SELECT COUNT(*) as cnt
                 FROM users u
                 JOIN campus_memberships membership
                   ON membership.user_id = u.id
                  AND membership.campus_id = $1
                  AND membership.status = 'verified'
                 WHERE u.discover_by_username = TRUE
                   AND u.status = 'active'",
            )
            .bind(campus_id)
            .fetch_one(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
            let rows = sqlx::query(
                r#"
                SELECT u.id as user_id, u.username, u.email, u.student_id,
                       u.discover_by_username, u.discover_by_email,
                       u.discover_by_student_id, u.avatar_url,
                       u.wechat_pay_qr_url, u.alipay_qr_url,
                       u.show_wechat_pay_qr, u.show_alipay_qr,
                       u.role, u.created_at,
                       COUNT(i.id) as listing_count
                FROM users u
                JOIN campus_memberships membership
                  ON membership.user_id = u.id
                 AND membership.campus_id = $1
                 AND membership.status = 'verified'
                LEFT JOIN inventory i ON u.id = i.owner_id
                 AND i.status = 'active' AND i.campus_id = $1
                 AND NOT listing_has_active_restriction(i.id)
                WHERE u.discover_by_username = TRUE
                  AND u.status = 'active'
                GROUP BY u.id, u.username, u.email, u.student_id,
                         u.discover_by_username, u.discover_by_email,
                         u.discover_by_student_id, u.avatar_url,
                         u.wechat_pay_qr_url, u.alipay_qr_url,
                         u.show_wechat_pay_qr, u.show_alipay_qr,
                         u.role, u.created_at
                ORDER BY listing_count DESC
                LIMIT $2 OFFSET $3
                "#,
            )
            .bind(campus_id)
            .bind(limit)
            .bind(offset)
            .fetch_all(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
            (count_row, rows)
        };

        let total: i64 = count_row.get("cnt");

        let items: Vec<(UserProfile, i64)> = rows
            .iter()
            .map(|row| {
                let profile = profile_from_row(row, "user_id");
                let listing_count: i64 = row.get("listing_count");
                (profile, listing_count)
            })
            .collect();

        Ok((items, total))
    }

    async fn lookup_users(
        &self,
        requester_id: &str,
        campus_id: Uuid,
        query: &str,
        method: UserLookupMethod,
        limit: i64,
    ) -> Result<Vec<UserLookupResult>, ApiError> {
        let resolved = resolve_lookup_method(query, method);
        let limit = limit.clamp(1, 10);
        let rows = match resolved {
            UserLookupMethod::Username | UserLookupMethod::Auto => {
                let pattern = format!("%{}%", query.replace('\'', "''"));
                let prefix = format!("{}%", query.replace('\'', "''"));
                sqlx::query(
                    r#"
                    SELECT u.id AS user_id, u.username, NULL::text AS matched_identifier,
                           COUNT(i.id) AS listing_count
                    FROM users u
                    JOIN campus_memberships membership
                      ON membership.user_id = u.id
                     AND membership.campus_id = $2
                     AND membership.status = 'verified'
                    LEFT JOIN inventory i ON u.id = i.owner_id
                     AND i.status = 'active' AND i.campus_id = $2
                     AND NOT listing_has_active_restriction(i.id)
                    WHERE u.id != $1
                      AND u.status = 'active'
                      AND u.discover_by_username = TRUE
                      AND u.username ILIKE $3
                      AND NOT EXISTS (
                          SELECT 1 FROM chat_blocks block
                          WHERE (block.blocker_id = $1 AND block.blocked_id = u.id)
                             OR (block.blocker_id = u.id AND block.blocked_id = $1)
                      )
                    GROUP BY u.id, u.username
                    ORDER BY
                      CASE
                        WHEN lower(u.username) = lower($5) THEN 0
                        WHEN lower(u.username) LIKE lower($4) THEN 1
                        ELSE 2
                      END,
                      listing_count DESC,
                      u.username ASC
                    LIMIT $6
                    "#,
                )
                .bind(requester_id)
                .bind(campus_id)
                .bind(&pattern)
                .bind(&prefix)
                .bind(query)
                .bind(limit)
                .fetch_all(&self.pool)
                .await
                .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
            }
            UserLookupMethod::Email => sqlx::query(
                r#"
                    SELECT u.id AS user_id, u.username, u.email AS matched_identifier,
                           COUNT(i.id) AS listing_count
                    FROM users u
                    JOIN campus_memberships membership
                      ON membership.user_id = u.id
                     AND membership.campus_id = $2
                     AND membership.status = 'verified'
                    LEFT JOIN inventory i ON u.id = i.owner_id
                     AND i.status = 'active' AND i.campus_id = $2
                     AND NOT listing_has_active_restriction(i.id)
                    WHERE u.id != $1
                      AND u.status = 'active'
                      AND u.discover_by_email = TRUE
                      AND lower(u.email) = lower($3)
                      AND NOT EXISTS (
                          SELECT 1 FROM chat_blocks block
                          WHERE (block.blocker_id = $1 AND block.blocked_id = u.id)
                             OR (block.blocker_id = u.id AND block.blocked_id = $1)
                      )
                    GROUP BY u.id, u.username, u.email
                    LIMIT $4
                    "#,
            )
            .bind(requester_id)
            .bind(campus_id)
            .bind(query)
            .bind(limit)
            .fetch_all(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?,
            UserLookupMethod::StudentId => sqlx::query(
                r#"
                    SELECT u.id AS user_id, u.username, u.student_id AS matched_identifier,
                           COUNT(i.id) AS listing_count
                    FROM users u
                    JOIN campus_memberships membership
                      ON membership.user_id = u.id
                     AND membership.campus_id = $2
                     AND membership.status = 'verified'
                    LEFT JOIN inventory i ON u.id = i.owner_id
                     AND i.status = 'active' AND i.campus_id = $2
                     AND NOT listing_has_active_restriction(i.id)
                    WHERE u.id != $1
                      AND u.status = 'active'
                      AND u.discover_by_student_id = TRUE
                      AND u.student_id = $3
                      AND NOT EXISTS (
                          SELECT 1 FROM chat_blocks block
                          WHERE (block.blocker_id = $1 AND block.blocked_id = u.id)
                             OR (block.blocker_id = u.id AND block.blocked_id = $1)
                      )
                    GROUP BY u.id, u.username, u.student_id
                    LIMIT $4
                    "#,
            )
            .bind(requester_id)
            .bind(campus_id)
            .bind(query)
            .bind(limit)
            .fetch_all(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?,
        };

        let matched_by = match resolved {
            UserLookupMethod::Auto | UserLookupMethod::Username => "username",
            UserLookupMethod::Email => "email",
            UserLookupMethod::StudentId => "student_id",
        };
        let items = rows
            .iter()
            .map(|row| {
                let raw_identifier: Option<String> = row.get("matched_identifier");
                let masked_identifier = match resolved {
                    UserLookupMethod::Email => raw_identifier.as_deref().map(mask_email),
                    UserLookupMethod::StudentId => raw_identifier.as_deref().map(mask_student_id),
                    UserLookupMethod::Auto | UserLookupMethod::Username => None,
                };
                UserLookupResult {
                    user_id: row.get("user_id"),
                    username: row.get("username"),
                    matched_by: matched_by.to_string(),
                    masked_identifier,
                    listing_count: row.get("listing_count"),
                    can_start_conversation: true,
                }
            })
            .collect();

        Ok(items)
    }

    async fn ban_user(&self, user_id: &str) -> Result<(), ApiError> {
        sqlx::query("UPDATE users SET status = 'banned' WHERE id = $1")
            .bind(user_id)
            .execute(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(())
    }

    async fn unban_user(&self, user_id: &str) -> Result<(), ApiError> {
        sqlx::query("UPDATE users SET status = 'active' WHERE id = $1")
            .bind(user_id)
            .execute(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(())
    }

    async fn update_role(&self, user_id: &str, role: &str) -> Result<(), ApiError> {
        sqlx::query("UPDATE users SET role = $1 WHERE id = $2")
            .bind(role)
            .bind(user_id)
            .execute(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(())
    }

    async fn update_username(&self, user_id: &str, new_username: &str) -> Result<(), ApiError> {
        // Check if username is already taken by another user
        let existing = sqlx::query("SELECT id FROM users WHERE username = $1 AND id != $2")
            .bind(new_username)
            .bind(user_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        if existing.is_some() {
            return Err(ApiError::Conflict("用户名已被使用".to_string()));
        }

        sqlx::query("UPDATE users SET username = $1 WHERE id = $2")
            .bind(new_username)
            .bind(user_id)
            .execute(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(())
    }

    async fn update_avatar(&self, user_id: &str, avatar_url: &str) -> Result<(), ApiError> {
        sqlx::query("UPDATE users SET avatar_url = $1 WHERE id = $2")
            .bind(avatar_url)
            .bind(user_id)
            .execute(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(())
    }

    async fn update_email(&self, user_id: &str, new_email: &str) -> Result<(), ApiError> {
        // Check if email is already taken by another user
        let existing = sqlx::query("SELECT id FROM users WHERE email = $1 AND id != $2")
            .bind(new_email)
            .bind(user_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        if existing.is_some() {
            return Err(ApiError::Conflict("邮箱已被使用".to_string()));
        }

        let student_id = derive_student_id(new_email);
        if let Some(student_id) = &student_id {
            let existing_student =
                sqlx::query("SELECT id FROM users WHERE student_id = $1 AND id != $2")
                    .bind(student_id)
                    .bind(user_id)
                    .fetch_optional(&self.pool)
                    .await
                    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

            if existing_student.is_some() {
                return Err(ApiError::Conflict("学号已被使用".to_string()));
            }
        }

        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
        let current_email = sqlx::query_scalar::<_, Option<String>>(
            "SELECT email FROM users WHERE id = $1 FOR UPDATE",
        )
        .bind(user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?
        .ok_or(ApiError::NotFound)?;

        sqlx::query("UPDATE users SET email = $1, student_id = $2 WHERE id = $3")
            .bind(new_email)
            .bind(student_id.as_deref())
            .bind(user_id)
            .execute(&mut *tx)
            .await
            .map_err(|e| db_conflict_or_internal(e, "邮箱或学号已被使用"))?;

        if current_email.as_deref() != Some(new_email) {
            sqlx::query(
                "UPDATE campus_memberships
                 SET status = 'pending', verification_method = NULL,
                     verified_at = NULL, updated_at = NOW()
                 WHERE user_id = $1 AND status = 'verified'",
            )
            .bind(user_id)
            .execute(&mut *tx)
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
        }

        tx.commit()
            .await
            .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;

        Ok(())
    }

    async fn update_discoverability(
        &self,
        user_id: &str,
        username: Option<bool>,
        email: Option<bool>,
        student_id: Option<bool>,
    ) -> Result<(), ApiError> {
        sqlx::query(
            "UPDATE users
             SET discover_by_username = COALESCE($1, discover_by_username),
                 discover_by_email = COALESCE($2, discover_by_email),
                 discover_by_student_id = COALESCE($3, discover_by_student_id)
             WHERE id = $4",
        )
        .bind(username)
        .bind(email)
        .bind(student_id)
        .bind(user_id)
        .execute(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(())
    }

    async fn update_payment_qr(
        &self,
        user_id: &str,
        wechat_url: Option<&str>,
        alipay_url: Option<&str>,
        show_wechat: Option<bool>,
        show_alipay: Option<bool>,
    ) -> Result<(), ApiError> {
        sqlx::query(
            "UPDATE users
             SET wechat_pay_qr_url = CASE
                     WHEN $1::TEXT IS NULL THEN wechat_pay_qr_url
                     ELSE NULLIF($1, '')
                 END,
                 alipay_qr_url = CASE
                     WHEN $2::TEXT IS NULL THEN alipay_qr_url
                     ELSE NULLIF($2, '')
                 END,
                 show_wechat_pay_qr = COALESCE($3, show_wechat_pay_qr),
                 show_alipay_qr = COALESCE($4, show_alipay_qr)
             WHERE id = $5",
        )
        .bind(wechat_url)
        .bind(alipay_url)
        .bind(show_wechat)
        .bind(show_alipay)
        .bind(user_id)
        .execute(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(())
    }

    async fn update_password_hash(
        &self,
        user_id: &str,
        password_hash: &str,
    ) -> Result<(), ApiError> {
        sqlx::query("UPDATE users SET password_hash = $1 WHERE id = $2")
            .bind(password_hash)
            .bind(user_id)
            .execute(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(())
    }

    async fn count_users(&self) -> Result<i64, ApiError> {
        let row = sqlx::query("SELECT COUNT(*) FROM users")
            .fetch_one(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(row.get(0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_infra::with_test_pool;

    #[tokio::test]
    async fn create_user_persists_standard_user_record() {
        with_test_pool(|pool| async move {
            let repo = PostgresUserRepository::new(pool.clone());

            let user_id = repo
                .create(
                    "shadow_profile_user",
                    Some("profile@example.com"),
                    "hash",
                    "user",
                )
                .await
                .expect("create user");
            assert!(Uuid::parse_str(&user_id).is_ok());

            let row = sqlx::query("SELECT id, username, email, role FROM users WHERE id = $1")
                .bind(&user_id)
                .fetch_one(&pool)
                .await
                .expect("select user");

            assert_eq!(row.get::<String, _>("id"), user_id);
            assert_eq!(row.get::<String, _>("username"), "shadow_profile_user");
            assert_eq!(
                row.get::<Option<String>, _>("email").as_deref(),
                Some("profile@example.com")
            );
            assert_eq!(row.get::<String, _>("role"), "user");
        })
        .await;
    }

    #[test]
    fn derives_student_id_only_from_numeric_school_email() {
        assert_eq!(
            derive_student_id("2024123456@email.ncu.edu.cn").as_deref(),
            Some("2024123456")
        );
        assert_eq!(derive_student_id("student@email.ncu.edu.cn"), None);
        assert_eq!(derive_student_id("2024123456@example.com"), None);
    }

    #[tokio::test]
    async fn create_sets_student_id_and_private_discovery_defaults() {
        with_test_pool(|pool| async move {
            let repo = PostgresUserRepository::new(pool.clone());

            let user_id = repo
                .create(
                    "discoverable_defaults_user",
                    Some("2024123456@email.ncu.edu.cn"),
                    "hash",
                    "user",
                )
                .await
                .expect("create user");

            let profile = repo.get_profile(&user_id).await.expect("profile");
            assert_eq!(profile.student_id.as_deref(), Some("2024123456"));
            assert!(profile.discoverability.username);
            assert!(!profile.discoverability.email);
            assert!(!profile.discoverability.student_id);
        })
        .await;
    }

    #[tokio::test]
    async fn lookup_users_respects_discovery_and_blocks() {
        with_test_pool(|pool| async move {
            let repo = PostgresUserRepository::new(pool.clone());
            let requester_id = repo
                .create("lookup_requester", None, "hash", "user")
                .await
                .expect("create requester");
            let target_id = repo
                .create(
                    "lookup_target",
                    Some("2024987654@email.ncu.edu.cn"),
                    "hash",
                    "user",
                )
                .await
                .expect("create target");
            let campus_id: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
                .fetch_one(&pool)
                .await
                .expect("NCU campus");
            sqlx::query(
                "UPDATE campus_memberships
                 SET status = 'verified', verification_method = 'test_fixture', verified_at = NOW()
                 WHERE user_id IN ($1, $2) AND campus_id = $3",
            )
            .bind(&requester_id)
            .bind(&target_id)
            .bind(campus_id)
            .execute(&pool)
            .await
            .expect("verify memberships");

            let by_username = repo
                .lookup_users(
                    &requester_id,
                    campus_id,
                    "lookup_target",
                    UserLookupMethod::Username,
                    10,
                )
                .await
                .expect("lookup username");
            assert_eq!(by_username.len(), 1);
            assert_eq!(by_username[0].user_id, target_id);
            assert_eq!(by_username[0].matched_by, "username");

            let by_email_private = repo
                .lookup_users(
                    &requester_id,
                    campus_id,
                    "2024987654@email.ncu.edu.cn",
                    UserLookupMethod::Email,
                    10,
                )
                .await
                .expect("private email lookup");
            assert!(by_email_private.is_empty());

            repo.update_discoverability(&target_id, Some(false), Some(true), Some(true))
                .await
                .expect("enable private identifiers and hide username");

            let by_username_hidden = repo
                .lookup_users(
                    &requester_id,
                    campus_id,
                    "lookup_target",
                    UserLookupMethod::Username,
                    10,
                )
                .await
                .expect("hidden username lookup");
            assert!(by_username_hidden.is_empty());

            let by_email = repo
                .lookup_users(
                    &requester_id,
                    campus_id,
                    "2024987654@email.ncu.edu.cn",
                    UserLookupMethod::Email,
                    10,
                )
                .await
                .expect("email lookup");
            assert_eq!(by_email.len(), 1);
            assert_eq!(by_email[0].matched_by, "email");
            assert_eq!(
                by_email[0].masked_identifier.as_deref(),
                Some("20***54@email.ncu.edu.cn")
            );

            let by_student_id = repo
                .lookup_users(
                    &requester_id,
                    campus_id,
                    "2024987654",
                    UserLookupMethod::Auto,
                    10,
                )
                .await
                .expect("student lookup");
            assert_eq!(by_student_id.len(), 1);
            assert_eq!(by_student_id[0].matched_by, "student_id");
            assert_eq!(
                by_student_id[0].masked_identifier.as_deref(),
                Some("2024****")
            );

            sqlx::query("INSERT INTO chat_blocks (blocker_id, blocked_id) VALUES ($1, $2)")
                .bind(&target_id)
                .bind(&requester_id)
                .execute(&pool)
                .await
                .expect("insert block");

            let blocked = repo
                .lookup_users(
                    &requester_id,
                    campus_id,
                    "2024987654",
                    UserLookupMethod::StudentId,
                    10,
                )
                .await
                .expect("blocked lookup");
            assert!(blocked.is_empty());
        })
        .await;
    }

    #[tokio::test]
    async fn update_password_hash_persists_new_hash() {
        with_test_pool(|pool| async move {
            let repo = PostgresUserRepository::new(pool.clone());
            let user_id = repo
                .create("password_repo_user", None, "old-hash", "user")
                .await
                .expect("create user");

            repo.update_password_hash(&user_id, "new-hash")
                .await
                .expect("update password hash");

            let password_hash: String =
                sqlx::query_scalar("SELECT password_hash FROM users WHERE id = $1")
                    .bind(&user_id)
                    .fetch_one(&pool)
                    .await
                    .expect("select password hash");
            assert_eq!(password_hash, "new-hash");
        })
        .await;
    }
}
