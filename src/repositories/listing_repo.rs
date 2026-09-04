//! PostgreSQL implementation of the ListingRepository trait.

use crate::api::error::ApiError;
use crate::categories::{normalize_category, normalize_category_list, normalize_category_or_other};
use crate::repositories::{CreateListingInput, Listing, ListingRepository, UpdateListingInput};
use sqlx::{PgPool, Postgres, Row, Transaction};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeleteOwnedResult {
    Deleted,
    AlreadyDeleted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UpdateOwnedResult {
    Updated,
    NotFound,
    Inactive,
}

fn version_conflict(expected: i64, actual: i64) -> ApiError {
    ApiError::CodedConflict {
        code: "listing_version_conflict",
        message: format!(
            "发布内容已变化（期望版本 {}, 当前版本 {}），请刷新后重试",
            expected, actual
        ),
    }
}

/// Escape special characters for PostgreSQL LIKE patterns.
///
/// The following characters are escaped:
/// - `\` becomes `\\`
/// - `'` becomes `''`
/// - `%` becomes `\%`
/// - `_` becomes `\_`
///
/// This ensures user search input is treated as literal characters in LIKE queries.
pub fn escape_like_pattern(input: &str) -> String {
    input
        .replace('\\', "\\\\")
        .replace('\'', "''")
        .replace('%', "\\%")
        .replace('_', "\\_")
}

#[derive(Clone)]
#[allow(dead_code)]
pub struct PostgresListingRepository {
    pool: PgPool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IdempotentCreateResult {
    pub id: String,
    pub replayed: bool,
}

impl PostgresListingRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn create_in_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        input: CreateListingInput,
    ) -> Result<String, ApiError> {
        Ok(self
            .create_idempotent_in_tx(tx, input, None, None)
            .await?
            .id)
    }

    pub async fn create_idempotent_in_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        input: CreateListingInput,
        idempotency_key: Option<&str>,
        idempotency_hash: Option<&str>,
    ) -> Result<IdempotentCreateResult, ApiError> {
        if idempotency_key.is_some() != idempotency_hash.is_some() {
            return Err(ApiError::Internal(anyhow::anyhow!(
                "Listing idempotency key and hash must be provided together"
            )));
        }

        let listing_id = uuid::Uuid::new_v4().to_string();
        let price_cents = (input.suggested_price_cny * 100.0).round() as i32;
        let defects_json = serde_json::to_string(&input.defects)
            .map_err(|e| ApiError::BadRequest(format!("invalid defects: {}", e)))?;

        let inserted_id = sqlx::query_scalar::<_, String>(
            r#"
            INSERT INTO inventory (
                id, campus_id,
                title, category, brand, direction, condition_score,
                suggested_price_cny, defects, description, image_url,
                owner_id, status,
                idempotency_key, idempotency_hash
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, 'active', $13, $14)
            ON CONFLICT (owner_id, idempotency_key)
                WHERE idempotency_key IS NOT NULL
                DO NOTHING
            RETURNING id
            "#,
        )
        .bind(&listing_id)
        .bind(input.campus_id)
        .bind(&input.title)
        .bind(&input.category)
        .bind(&input.brand)
        .bind(&input.direction)
        .bind(input.condition_score)
        .bind(price_cents)
        .bind(&defects_json)
        .bind(&input.description)
        .bind(&input.image_url)
        .bind(&input.owner_id)
        .bind(idempotency_key)
        .bind(idempotency_hash)
        .fetch_optional(&mut **tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        if let Some(id) = inserted_id {
            return Ok(IdempotentCreateResult {
                id,
                replayed: false,
            });
        }

        let key = idempotency_key.ok_or_else(|| {
            ApiError::Internal(anyhow::anyhow!(
                "Unkeyed listing insert unexpectedly returned no row"
            ))
        })?;
        let (existing_id, existing_hash) =
            sqlx::query_as::<_, (String, Option<String>)>(
                "SELECT id, idempotency_hash FROM inventory WHERE owner_id = $1 AND idempotency_key = $2",
            )
            .bind(&input.owner_id)
            .bind(key)
            .fetch_optional(&mut **tx)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
            .ok_or_else(|| {
                ApiError::Internal(anyhow::anyhow!(
                    "Idempotent listing conflict row disappeared"
                ))
            })?;

        if existing_hash.as_deref() != idempotency_hash {
            return Err(ApiError::Conflict(
                "Idempotency-Key 已用于不同的发布内容".to_string(),
            ));
        }

        Ok(IdempotentCreateResult {
            id: existing_id,
            replayed: true,
        })
    }

    // Public transaction-owning wrapper retained for repository integration
    // tests; production HTTP flows compose `create_idempotent_in_tx` instead.
    #[allow(dead_code)]
    pub async fn create_idempotent(
        &self,
        input: CreateListingInput,
        idempotency_key: Option<&str>,
        idempotency_hash: Option<&str>,
    ) -> Result<IdempotentCreateResult, ApiError> {
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        let result = self
            .create_idempotent_in_tx(&mut tx, input, idempotency_key, idempotency_hash)
            .await?;
        tx.commit()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(result)
    }

    fn update_query_for_owner(
        input: &UpdateListingInput,
        require_active: bool,
    ) -> Result<String, ApiError> {
        if input.title.is_none()
            && input.category.is_none()
            && input.brand.is_none()
            && input.condition_score.is_none()
            && input.suggested_price_cny.is_none()
            && input.defects.is_none()
            && input.description.is_none()
            && input.status.is_none()
        {
            return Err(ApiError::BadRequest("没有要更新的字段".to_string()));
        }

        let mut set_clauses = Vec::new();
        let mut param_idx = 1;

        if input.title.is_some() {
            set_clauses.push(format!("title = ${}", param_idx));
            param_idx += 1;
        }
        if input.category.is_some() {
            set_clauses.push(format!("category = ${}", param_idx));
            param_idx += 1;
        }
        if input.brand.is_some() {
            set_clauses.push(format!("brand = ${}", param_idx));
            param_idx += 1;
        }
        if input.condition_score.is_some() {
            set_clauses.push(format!("condition_score = ${}", param_idx));
            param_idx += 1;
        }
        if input.suggested_price_cny.is_some() {
            set_clauses.push(format!("suggested_price_cny = ${}", param_idx));
            param_idx += 1;
        }
        if input.defects.is_some() {
            set_clauses.push(format!("defects = ${}", param_idx));
            param_idx += 1;
        }
        if input.description.is_some() {
            set_clauses.push(format!("description = ${}", param_idx));
            param_idx += 1;
        }
        if input.status.is_some() {
            set_clauses.push(format!("status = ${}", param_idx));
            param_idx += 1;
        }

        let mut query = format!(
            "UPDATE inventory SET {} WHERE id = ${} AND owner_id = ${}",
            set_clauses.join(", "),
            param_idx,
            param_idx + 1
        );
        if require_active {
            query.push_str(" AND status = 'active' AND NOT listing_has_active_restriction(id)");
        }

        Ok(query)
    }

    fn bind_update_query<'q>(
        mut query: sqlx::query::Query<'q, Postgres, sqlx::postgres::PgArguments>,
        input: &'q UpdateListingInput,
    ) -> Result<sqlx::query::Query<'q, Postgres, sqlx::postgres::PgArguments>, ApiError> {
        if let Some(ref v) = input.title {
            query = query.bind(v);
        }
        if let Some(ref v) = input.category {
            query = query.bind(v);
        }
        if let Some(ref v) = input.brand {
            query = query.bind(v);
        }
        if let Some(v) = input.condition_score {
            query = query.bind(v);
        }
        if let Some(v) = input.suggested_price_cny {
            query = query.bind((v * 100.0).round() as i32);
        }
        if let Some(ref v) = input.defects {
            let defects_json = serde_json::to_string(v)
                .map_err(|e| ApiError::BadRequest(format!("invalid defects: {}", e)))?;
            query = query.bind(defects_json);
        }
        if let Some(ref v) = input.description {
            query = query.bind(v);
        }
        if let Some(ref v) = input.status {
            query = query.bind(v);
        }

        Ok(query)
    }

    #[allow(dead_code)]
    pub async fn mark_sold_if_active_in_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        id: &str,
    ) -> Result<bool, ApiError> {
        let updated = sqlx::query(
            "UPDATE inventory SET status = 'sold'
             WHERE id = $1 AND status = 'active'
               AND NOT listing_has_active_restriction(id)",
        )
        .bind(id)
        .execute(&mut **tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(updated.rows_affected() > 0)
    }

    #[allow(dead_code)]
    pub async fn relist_if_no_open_orders_in_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        listing_id: &str,
    ) -> Result<bool, ApiError> {
        let _ = sqlx::query("SELECT 1 FROM inventory WHERE id = $1 FOR UPDATE")
            .bind(listing_id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let updated = sqlx::query(
            r#"
            UPDATE inventory
            SET status = 'active'
            WHERE id = $1
              AND status = 'sold'
              AND NOT listing_has_active_restriction(id)
              AND NOT EXISTS (
                SELECT 1
                FROM orders o
                WHERE o.listing_id = $1
                  AND o.status IN ('pending', 'paid', 'shipped')
              )
            "#,
        )
        .bind(listing_id)
        .execute(&mut **tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(updated.rows_affected() > 0)
    }

    pub async fn update_owned_active_in_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        id: &str,
        owner_id: &str,
        campus_id: Uuid,
        input: &UpdateListingInput,
    ) -> Result<bool, ApiError> {
        Ok(matches!(
            self.update_owned_active_with_state_in_tx(tx, id, owner_id, campus_id, input, None)
                .await?,
            UpdateOwnedResult::Updated
        ))
    }

    pub async fn update_owned_active_with_state_in_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        id: &str,
        owner_id: &str,
        campus_id: Uuid,
        input: &UpdateListingInput,
        expected_content_revision: Option<i64>,
    ) -> Result<UpdateOwnedResult, ApiError> {
        let row = sqlx::query_as::<_, (String, i64)>(
            "SELECT status, content_revision FROM inventory
             WHERE id = $1 AND owner_id = $2 AND campus_id = $3
             FOR UPDATE",
        )
        .bind(id)
        .bind(owner_id)
        .bind(campus_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        let Some((status, actual_revision)) = row else {
            return Ok(UpdateOwnedResult::NotFound);
        };
        if let Some(expected) = expected_content_revision {
            if expected <= 0 {
                return Err(ApiError::BadRequest(
                    "expected_content_revision 必须为正整数".to_string(),
                ));
            }
            if expected != actual_revision {
                return Err(version_conflict(expected, actual_revision));
            }
        }
        let restricted: bool = sqlx::query_scalar("SELECT listing_has_active_restriction($1)")
            .bind(id)
            .fetch_one(&mut **tx)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        if restricted {
            return Err(ApiError::CodedConflict {
                code: "listing_restricted",
                message: "该发布受平台限制，不能编辑".to_string(),
            });
        }
        if status != "active" {
            return Ok(UpdateOwnedResult::Inactive);
        }

        let query = Self::update_query_for_owner(input, false)?;
        let result = Self::bind_update_query(sqlx::query(&query), input)?
            .bind(id)
            .bind(owner_id)
            .execute(&mut **tx)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(if result.rows_affected() == 1 {
            UpdateOwnedResult::Updated
        } else {
            UpdateOwnedResult::Inactive
        })
    }

    // Transaction-owning compatibility wrapper retained for direct callers;
    // ActionPlan execution composes `update_owned_active_in_tx` atomically.
    #[allow(dead_code)]
    pub async fn update_owned_active(
        &self,
        id: &str,
        owner_id: &str,
        campus_id: Uuid,
        input: &UpdateListingInput,
    ) -> Result<bool, ApiError> {
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        let updated = self
            .update_owned_active_in_tx(&mut tx, id, owner_id, campus_id, input)
            .await?;
        tx.commit()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(updated)
    }

    #[allow(dead_code)]
    pub async fn update_in_campus(
        &self,
        id: &str,
        owner_id: &str,
        campus_id: Uuid,
        input: UpdateListingInput,
    ) -> Result<(), ApiError> {
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        let status = sqlx::query_scalar::<_, String>(
            "SELECT status FROM inventory
             WHERE id = $1 AND owner_id = $2 AND campus_id = $3
             FOR UPDATE",
        )
        .bind(id)
        .bind(owner_id)
        .bind(campus_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        .ok_or(ApiError::NotFound)?;
        let restricted: bool = sqlx::query_scalar("SELECT listing_has_active_restriction($1)")
            .bind(id)
            .fetch_one(&mut *tx)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        if restricted {
            return Err(ApiError::CodedConflict {
                code: "listing_restricted",
                message: "该发布受平台限制，不能编辑".to_string(),
            });
        }
        if status != "active" {
            return Err(ApiError::CodedConflict {
                code: "listing_action_stale",
                message: "只有正在展示的发布可以编辑".to_string(),
            });
        }

        let query = Self::update_query_for_owner(&input, false)?;
        Self::bind_update_query(sqlx::query(&query), &input)?
            .bind(id)
            .bind(owner_id)
            .execute(&mut *tx)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        tx.commit()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(())
    }

    #[allow(dead_code)]
    pub async fn soft_delete_active_owned_in_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        id: &str,
        owner_id: &str,
        campus_id: Uuid,
    ) -> Result<bool, ApiError> {
        let result = sqlx::query(
            "UPDATE inventory SET status = 'deleted'
             WHERE id = $1 AND owner_id = $2 AND campus_id = $3 AND status = 'active'",
        )
        .bind(id)
        .bind(owner_id)
        .bind(campus_id)
        .execute(&mut **tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(result.rows_affected() > 0)
    }

    pub async fn delete_owned_in_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        id: &str,
        owner_id: &str,
        campus_id: Uuid,
    ) -> Result<DeleteOwnedResult, ApiError> {
        self.delete_owned_with_revision_in_tx(tx, id, owner_id, campus_id, None)
            .await
    }

    pub async fn delete_owned_with_revision_in_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        id: &str,
        owner_id: &str,
        campus_id: Uuid,
        expected_content_revision: Option<i64>,
    ) -> Result<DeleteOwnedResult, ApiError> {
        let row = sqlx::query_as::<_, (String, i64)>(
            "SELECT status, content_revision FROM inventory
             WHERE id = $1 AND owner_id = $2 AND campus_id = $3
             FOR UPDATE",
        )
        .bind(id)
        .bind(owner_id)
        .bind(campus_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        .ok_or(ApiError::NotFound)?;
        let (status, actual_revision) = row;
        if let Some(expected) = expected_content_revision {
            if expected <= 0 {
                return Err(ApiError::BadRequest(
                    "expected_content_revision 必须为正整数".to_string(),
                ));
            }
            if expected != actual_revision {
                return Err(version_conflict(expected, actual_revision));
            }
        }

        if status == "sold" {
            return Err(ApiError::BadRequest("无法删除已售出的商品".to_string()));
        }
        if status == "deleted" {
            return Ok(DeleteOwnedResult::AlreadyDeleted);
        }

        let updated = sqlx::query(
            "UPDATE inventory SET status = 'deleted'
             WHERE id = $1 AND owner_id = $2 AND campus_id = $3 AND status = $4",
        )
        .bind(id)
        .bind(owner_id)
        .bind(campus_id)
        .bind(&status)
        .execute(&mut **tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        if updated.rows_affected() != 1 {
            return Err(ApiError::Conflict(
                "商品状态已发生变化，无法删除".to_string(),
            ));
        }
        Ok(DeleteOwnedResult::Deleted)
    }

    pub async fn ping(&self) -> Result<(), ApiError> {
        sqlx::query("SELECT 1")
            .fetch_one(&self.pool)
            .await
            .map_err(|e| {
                tracing::error!(%e, "Readiness check failed: database unreachable");
                ApiError::ServiceUnavailable("database_unreachable")
            })?;
        Ok(())
    }

    pub async fn get_order_target(
        &self,
        listing_id: &str,
    ) -> Result<Option<ListingOrderTarget>, ApiError> {
        let row = sqlx::query(
            "SELECT owner_id, suggested_price_cny, status, campus_id,
                    listing_has_active_restriction(id) AS restricted
             FROM inventory WHERE id = $1",
        )
        .bind(listing_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| {
            tracing::error!("fetch listing error: {}", e);
            ApiError::Internal(anyhow::anyhow!("Failed to fetch listing"))
        })?;

        Ok(row.map(|r| ListingOrderTarget {
            owner_id: r.get("owner_id"),
            suggested_price_cny: r.get("suggested_price_cny"),
            status: r.get("status"),
            campus_id: r.get("campus_id"),
            restricted: r.get("restricted"),
        }))
    }

    pub async fn find_active_unrestricted_owner(
        &self,
        listing_id: &str,
        campus_id: Uuid,
    ) -> Result<Option<String>, ApiError> {
        let owner: Option<String> = sqlx::query_scalar(
            "SELECT owner_id FROM inventory
             WHERE id = $1 AND campus_id = $2 AND status = 'active'
               AND NOT listing_has_active_restriction(id)",
        )
        .bind(listing_id)
        .bind(campus_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;

        Ok(owner)
    }

    pub async fn get_marketplace_stats(&self) -> Result<MarketplaceStatsData, ApiError> {
        let (total_listings, active_listings, total_users, total_orders) = tokio::try_join!(
            async {
                let row = sqlx::query("SELECT COUNT(*) as cnt FROM inventory")
                    .fetch_one(&self.pool)
                    .await
                    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
                row.try_get::<i64, _>("cnt")
                    .map_err(|_| ApiError::Internal(anyhow::anyhow!("Failed to parse count")))
            },
            async {
                let row = sqlx::query(
                    "SELECT COUNT(*) as cnt FROM inventory WHERE status = 'active'
                       AND NOT listing_has_active_restriction(id)",
                )
                .fetch_one(&self.pool)
                .await
                .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
                row.try_get::<i64, _>("cnt")
                    .map_err(|_| ApiError::Internal(anyhow::anyhow!("Failed to parse count")))
            },
            async {
                let row = sqlx::query("SELECT COUNT(*) as cnt FROM users")
                    .fetch_one(&self.pool)
                    .await
                    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
                row.try_get::<i64, _>("cnt")
                    .map_err(|_| ApiError::Internal(anyhow::anyhow!("Failed to parse count")))
            },
            async {
                let row = sqlx::query("SELECT COUNT(*) as cnt FROM orders")
                    .fetch_one(&self.pool)
                    .await
                    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
                row.try_get::<i64, _>("cnt")
                    .map_err(|_| ApiError::Internal(anyhow::anyhow!("Failed to parse count")))
            },
        )?;

        let category_rows = sqlx::query(
            "SELECT category, COUNT(*) as cnt FROM inventory
             WHERE status = 'active' AND NOT listing_has_active_restriction(id)
             GROUP BY category ORDER BY cnt DESC",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let mut category_counts = Vec::with_capacity(category_rows.len());
        for row in category_rows {
            let category: String = row.get("category");
            let count: i64 = row.get("cnt");
            category_counts.push((category, count));
        }

        Ok(MarketplaceStatsData {
            total_listings,
            active_listings,
            total_users,
            total_orders,
            category_counts,
        })
    }

    pub async fn is_listing_restricted(&self, listing_id: &str) -> Result<bool, ApiError> {
        let restricted: bool = sqlx::query_scalar("SELECT listing_has_active_restriction($1)")
            .bind(listing_id)
            .fetch_one(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(restricted)
    }

    pub async fn get_listing_restriction_details(
        &self,
        listing_id: &str,
        campus_id: Uuid,
    ) -> Result<Option<ListingRestrictionDetails>, ApiError> {
        let restriction = sqlx::query(
            "SELECT COUNT(*) AS count,
                    (ARRAY_AGG(moderation_case.public_reason ORDER BY effect.imposed_at DESC))[1]
                        AS public_reason,
                    (ARRAY_AGG(effect.imposed_at ORDER BY effect.imposed_at DESC))[1]
                        AS restricted_at,
                    (ARRAY_AGG(effect.case_id ORDER BY effect.imposed_at DESC))[1]
                        AS moderation_case_id,
                    (ARRAY_AGG(
                        moderation_case.status IN ('actioned', 'resolved')
                        AND moderation_case.resolution = 'content_restricted'
                        AND NOT EXISTS (
                            SELECT 1 FROM moderation_appeals appeal
                            WHERE appeal.case_id = moderation_case.id
                              AND appeal.appellant_id = moderation_case.subject_user_id
                        )
                        ORDER BY effect.imposed_at DESC
                    ))[1] AS can_appeal
             FROM listing_restriction_effects effect
             JOIN moderation_cases moderation_case ON moderation_case.id = effect.case_id
             WHERE effect.listing_id = $1 AND effect.campus_id = $2
               AND effect.released_at IS NULL",
        )
        .bind(listing_id)
        .bind(campus_id)
        .fetch_one(&self.pool)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;

        let count: i64 = restriction.get("count");
        if count == 0 {
            return Ok(None);
        }

        Ok(Some(ListingRestrictionDetails {
            public_reason: restriction.try_get("public_reason").ok().flatten(),
            restricted_at: restriction.try_get("restricted_at").ok().flatten(),
            moderation_case_id: restriction.try_get("moderation_case_id").ok().flatten(),
            can_appeal: restriction.try_get("can_appeal").ok().flatten(),
        }))
    }

    pub async fn get_active_restrictions_for_listings(
        &self,
        listing_ids: &[String],
        user_id: &str,
    ) -> Result<std::collections::HashMap<String, ActiveRestrictionView>, ApiError> {
        if listing_ids.is_empty() {
            return Ok(std::collections::HashMap::new());
        }

        let restriction_rows = sqlx::query(
            "SELECT DISTINCT ON (effect.listing_id)
                    effect.listing_id, effect.imposed_at, effect.case_id,
                    moderation_case.public_reason,
                    moderation_case.status IN ('actioned', 'resolved')
                        AND moderation_case.resolution = 'content_restricted'
                        AND NOT EXISTS (
                            SELECT 1 FROM moderation_appeals appeal
                            WHERE appeal.case_id = moderation_case.id
                              AND appeal.appellant_id = $2
                        ) AS can_appeal
             FROM listing_restriction_effects effect
             JOIN moderation_cases moderation_case ON moderation_case.id = effect.case_id
             WHERE effect.listing_id = ANY($1::text[])
               AND effect.released_at IS NULL
             ORDER BY effect.listing_id, effect.imposed_at DESC",
        )
        .bind(listing_ids)
        .bind(user_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;

        let restrictions = restriction_rows
            .into_iter()
            .map(|row| {
                (
                    row.get("listing_id"),
                    ActiveRestrictionView {
                        public_reason: row.get("public_reason"),
                        restricted_at: row.get("imposed_at"),
                        moderation_case_id: row.get("case_id"),
                        can_appeal: row.get("can_appeal"),
                    },
                )
            })
            .collect();

        Ok(restrictions)
    }
}

#[derive(Debug, Clone)]
pub struct ListingOrderTarget {
    pub owner_id: String,
    pub suggested_price_cny: i64,
    pub status: String,
    pub campus_id: Uuid,
    pub restricted: bool,
}

#[derive(Debug, Clone)]
pub struct MarketplaceStatsData {
    pub total_listings: i64,
    pub active_listings: i64,
    pub total_users: i64,
    pub total_orders: i64,
    pub category_counts: Vec<(String, i64)>,
}

#[derive(Debug, Clone)]
pub struct ListingRestrictionDetails {
    pub public_reason: Option<String>,
    pub restricted_at: Option<chrono::DateTime<chrono::Utc>>,
    pub moderation_case_id: Option<Uuid>,
    pub can_appeal: Option<bool>,
}

#[derive(Debug, Clone)]
pub struct ActiveRestrictionView {
    pub public_reason: String,
    pub restricted_at: chrono::DateTime<chrono::Utc>,
    pub moderation_case_id: Uuid,
    pub can_appeal: bool,
}

impl ListingRepository for PostgresListingRepository {
    async fn find_listings(
        &self,
        campus_id: Uuid,
        category: Option<&str>,
        categories: Option<&str>,
        search: Option<&str>,
        direction: Option<&str>,
        min_price_cny: Option<f64>,
        max_price_cny: Option<f64>,
        sort: &str,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<Listing>, i64), ApiError> {
        let mut query = format!(
            "SELECT id, campus_id, content_revision, title, category, brand, direction, condition_score, suggested_price_cny, \
             defects, description, CASE WHEN images_moderation_status = 'approved' THEN image_url ELSE NULL END AS image_url, owner_id, status, created_at \
             FROM inventory WHERE status = 'active' AND campus_id = '{}'
               AND NOT listing_has_active_restriction(id)",
            campus_id
        );
        let mut count_query = format!(
            "SELECT COUNT(*) FROM inventory WHERE status = 'active' AND campus_id = '{}'
               AND NOT listing_has_active_restriction(id)",
            campus_id
        );

        if let Some(direction) = direction {
            if direction != "all" {
                query = format!(
                    "{} AND direction = '{}'",
                    query,
                    direction.replace('\'', "''")
                );
                count_query = format!(
                    "{} AND direction = '{}'",
                    count_query,
                    direction.replace('\'', "''")
                );
            }
        }

        // Single category filter (preferred when both are provided)
        if let Some(cat) = category {
            if !cat.is_empty() && cat != "all" && categories.is_none() {
                if let Some(normalized) = normalize_category(cat) {
                    query = format!("{} AND category = '{}'", query, normalized);
                    count_query = format!("{} AND category = '{}'", count_query, normalized);
                } else {
                    query = format!("{} AND FALSE", query);
                    count_query = format!("{} AND FALSE", count_query);
                }
            }
        }

        // Multi-category: comma-separated, e.g. "electronics,books" -> category IN ('electronics','books')
        if let Some(cats) = categories {
            if !cats.is_empty() && category.is_none() {
                let parts: Vec<String> = normalize_category_list(cats)
                    .into_iter()
                    .map(|category| format!("'{}'", category))
                    .collect();
                if parts.is_empty() {
                    query = format!("{} AND FALSE", query);
                    count_query = format!("{} AND FALSE", count_query);
                } else {
                    query = format!("{} AND category IN ({})", query, parts.join(","));
                    count_query = format!("{} AND category IN ({})", count_query, parts.join(","));
                }
            }
        }

        if let Some(s) = search {
            if !s.is_empty() {
                // Escape LIKE wildcards: % matches any sequence, _ matches single char
                let escaped = escape_like_pattern(s);
                query = format!(
                    "{} AND (title ILIKE '%{}%' OR description ILIKE '%{}%')",
                    query, escaped, escaped
                );
                count_query = format!(
                    "{} AND (title ILIKE '%{}%' OR description ILIKE '%{}%')",
                    count_query, escaped, escaped
                );
            }
        }

        // Price range filter
        if let Some(min) = min_price_cny {
            if min > 0.0 {
                let min_cents = (min * 100.0).round() as i32;
                query = format!("{} AND suggested_price_cny >= {}", query, min_cents);
                count_query = format!("{} AND suggested_price_cny >= {}", count_query, min_cents);
            }
        }
        if let Some(max) = max_price_cny {
            if max > 0.0 {
                let max_cents = (max * 100.0).round() as i32;
                query = format!("{} AND suggested_price_cny <= {}", query, max_cents);
                count_query = format!("{} AND suggested_price_cny <= {}", count_query, max_cents);
            }
        }

        // Sorting
        let order_by = match sort {
            "price_asc" => "suggested_price_cny ASC",
            "price_desc" => "suggested_price_cny DESC",
            "condition_desc" => "condition_score DESC",
            _ => "created_at DESC", // default: newest
        };
        query = format!(
            "{} ORDER BY {} LIMIT {} OFFSET {}",
            query, order_by, limit, offset
        );

        let rows = sqlx::query_as::<_, Listing>(&query)
            .fetch_all(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let count_row = sqlx::query(&count_query)
            .fetch_one(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let total: i64 = count_row.get(0);
        Ok((rows, total))
    }

    async fn find_by_id(&self, id: &str) -> Result<Option<Listing>, ApiError> {
        let row = sqlx::query_as::<_, Listing>(
            "SELECT id, campus_id, content_revision, title, category, brand, direction, condition_score, suggested_price_cny, \
             defects, description, CASE WHEN images_moderation_status = 'approved' THEN image_url ELSE NULL END AS image_url, owner_id, status, created_at \
             FROM inventory WHERE id = $1",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(row)
    }

    async fn find_by_id_with_owner(
        &self,
        id: &str,
    ) -> Result<Option<(Listing, Option<String>)>, ApiError> {
        let row = sqlx::query(
            "SELECT i.id, i.campus_id, i.content_revision, i.title, i.category, i.brand, i.direction, i.condition_score, i.suggested_price_cny, \
             i.defects, i.description, \
             CASE WHEN i.images_moderation_status = 'approved' THEN i.image_url ELSE NULL END AS image_url, \
             i.owner_id, i.status, i.created_at, \
             u.username as owner_username \
             FROM inventory i \
             LEFT JOIN users u ON i.owner_id = u.id \
             WHERE i.id = $1",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        match row {
            Some(r) => {
                let listing = Listing {
                    id: r.get("id"),
                    campus_id: r.get("campus_id"),
                    content_revision: r.get("content_revision"),
                    title: r.get("title"),
                    category: r.get("category"),
                    brand: r.get("brand"),
                    direction: r.get("direction"),
                    condition_score: r.get("condition_score"),
                    suggested_price_cny: r.get("suggested_price_cny"),
                    defects: r.get("defects"),
                    description: r.get("description"),
                    image_url: r.get("image_url"),
                    owner_id: r.get("owner_id"),
                    status: r.get("status"),
                    created_at: r.get("created_at"),
                };
                let owner_username: Option<String> = r.get("owner_username");
                Ok(Some((listing, owner_username)))
            }
            None => Ok(None),
        }
    }

    async fn find_by_id_with_owner_in_campus(
        &self,
        id: &str,
        campus_id: Uuid,
    ) -> Result<Option<(Listing, Option<String>)>, ApiError> {
        let result = self.find_by_id_with_owner(id).await?;
        Ok(result.filter(|(listing, _)| listing.campus_id == campus_id))
    }

    async fn create(&self, input: CreateListingInput) -> Result<String, ApiError> {
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        let listing_id = self.create_in_tx(&mut tx, input).await?;
        tx.commit()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(listing_id)
    }

    async fn update(
        &self,
        id: &str,
        owner_id: &str,
        input: UpdateListingInput,
    ) -> Result<(), ApiError> {
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        let row = sqlx::query("SELECT owner_id, status FROM inventory WHERE id = $1 FOR UPDATE")
            .bind(id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
            .ok_or(ApiError::NotFound)?;

        let current_owner: String = row.get("owner_id");
        let current_status: String = row.get("status");
        let restricted: bool = sqlx::query_scalar("SELECT listing_has_active_restriction($1)")
            .bind(id)
            .fetch_one(&mut *tx)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        if current_owner != owner_id {
            return Err(ApiError::Forbidden);
        }
        if current_status == "sold" {
            return Err(ApiError::BadRequest("无法修改已售出的商品".to_string()));
        }
        if restricted {
            return Err(ApiError::CodedConflict {
                code: "listing_restricted",
                message: "该发布受平台限制，不能编辑".to_string(),
            });
        }

        let query = Self::update_query_for_owner(&input, false)?;
        let q = Self::bind_update_query(sqlx::query(&query), &input)?
            .bind(id)
            .bind(owner_id);

        q.execute(&mut *tx)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        tx.commit()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(())
    }

    async fn delete(
        &self,
        id: &str,
        owner_id: &str,
        campus_id: uuid::Uuid,
    ) -> Result<(), ApiError> {
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        self.delete_owned_in_tx(&mut tx, id, owner_id, campus_id)
            .await?;
        tx.commit()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(())
    }

    async fn relist(
        &self,
        id: &str,
        owner_id: &str,
        campus_id: uuid::Uuid,
    ) -> Result<(), ApiError> {
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        let row = sqlx::query(
            "SELECT status, direction
             FROM inventory
             WHERE id = $1 AND owner_id = $2 AND campus_id = $3
             FOR UPDATE",
        )
        .bind(id)
        .bind(owner_id)
        .bind(campus_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        .ok_or(ApiError::NotFound)?;

        let status: String = row.get("status");
        let restricted: bool = sqlx::query_scalar("SELECT listing_has_active_restriction($1)")
            .bind(id)
            .fetch_one(&mut *tx)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        if restricted {
            return Err(ApiError::CodedConflict {
                code: "listing_restricted",
                message: "该发布仍受平台限制，不能重新上架".to_string(),
            });
        }
        // 'fulfilled' is the wanted-side counterpart of 'sold': reopening a
        // fulfilled wanted resumes matching without recreating the item.
        if status != "sold" && status != "deleted" && status != "fulfilled" {
            return Err(ApiError::BadRequest(format!(
                "无法重新上架，当前状态为'{}'，只能重新上架已售出、已删除或已完成的条目",
                status
            )));
        }

        let direction: String = row.get("direction");
        sqlx::query(
            "UPDATE inventory
             SET status = 'active',
                 lifecycle_epoch = lifecycle_epoch
                     + CASE WHEN direction = 'wanted' THEN 1 ELSE 0 END
             WHERE id = $1 AND owner_id = $2 AND campus_id = $3",
        )
        .bind(id)
        .bind(owner_id)
        .bind(campus_id)
        .execute(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        tx.commit()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        tracing::debug!(
            listing_id = %id,
            %direction,
            "listing reopened in a serialized lifecycle transition"
        );
        Ok(())
    }

    async fn mark_sold(&self, id: &str, owner_id: &str) -> Result<(), ApiError> {
        sqlx::query(
            "UPDATE inventory SET status = 'sold'
             WHERE id = $1 AND owner_id = $2 AND status = 'active'
               AND NOT listing_has_active_restriction(id)",
        )
        .bind(id)
        .bind(owner_id)
        .execute(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        Ok(())
    }

    async fn count(&self, status: Option<&str>) -> Result<i64, ApiError> {
        let query = if let Some(s) = status {
            format!(
                "SELECT COUNT(*) FROM inventory WHERE status = '{}'",
                s.replace('\'', "''")
            )
        } else {
            "SELECT COUNT(*) FROM inventory".to_string()
        };

        let row = sqlx::query(&query)
            .fetch_one(&self.pool)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(row.get(0))
    }

    async fn get_category_stats(&self) -> Result<Vec<(String, i64)>, ApiError> {
        let rows = sqlx::query(
            "SELECT COALESCE(category, 'Other') as category, COUNT(*) as cnt \
             FROM inventory GROUP BY category ORDER BY cnt DESC LIMIT 50",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let mut merged = std::collections::BTreeMap::<String, i64>::new();
        for row in rows {
            let category: String = row.get("category");
            let count: i64 = row.get("cnt");
            let normalized = normalize_category_or_other(&category).to_string();
            *merged.entry(normalized).or_default() += count;
        }

        let mut stats: Vec<(String, i64)> = merged.into_iter().collect();
        stats.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));

        Ok(stats)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_infra::with_test_pool;

    #[test]
    fn test_escape_like_pattern_escapes_backslash() {
        assert_eq!(escape_like_pattern(r"a\b"), r"a\\b");
    }

    #[test]
    fn test_escape_like_pattern_escapes_single_quote() {
        assert_eq!(escape_like_pattern("a'b"), "a''b");
    }

    #[test]
    fn test_escape_like_pattern_escapes_percent() {
        assert_eq!(escape_like_pattern("100%"), r"100\%");
    }

    #[test]
    fn test_escape_like_pattern_escapes_underscore() {
        assert_eq!(escape_like_pattern("a_b"), r"a\_b");
    }

    #[test]
    fn test_escape_like_pattern_escapes_all_special_chars() {
        // Input: a%b_c'd\e
        // - ' -> ''
        // - \ -> \\
        // - % -> \%
        // - _ -> \_
        assert_eq!(escape_like_pattern(r#"a%b_c'd\e"#), r#"a\%b\_c''d\\e"#);
    }

    #[test]
    fn test_escape_like_pattern_100_percent() {
        // "100%" should be escaped to "100\%"
        assert_eq!(escape_like_pattern("100%"), r"100\%");
    }

    #[test]
    fn test_escape_like_pattern_a_b() {
        // "a_b" should be escaped to "a\_b"
        assert_eq!(escape_like_pattern("a_b"), r"a\_b");
    }

    #[test]
    fn test_escape_like_pattern_with_backslash() {
        // "test\" should be escaped to "test\\"
        assert_eq!(escape_like_pattern(r"test\"), r"test\\");
    }

    #[test]
    fn test_escape_like_pattern_empty_string() {
        assert_eq!(escape_like_pattern(""), "");
    }

    #[test]
    fn test_escape_like_pattern_plain_text() {
        // Plain text with no special characters should be unchanged
        assert_eq!(escape_like_pattern("hello world"), "hello world");
    }

    #[test]
    fn test_escape_like_pattern_unicode() {
        // Unicode characters should pass through unchanged
        assert_eq!(escape_like_pattern("你好世界"), "你好世界");
    }

    #[test]
    fn test_escape_like_pattern_emoji() {
        // Emojis should pass through unchanged
        assert_eq!(escape_like_pattern("hello 👋"), "hello 👋");
    }

    #[test]
    fn test_escape_like_pattern_multiple_percent_signs() {
        // Input is "100% off %%%" which is: 100 %   off   % % %
        // After escaping: 100\% off\%\%\%
        assert_eq!(escape_like_pattern("100% off %%%"), "100\\% off \\%\\%\\%");
    }

    #[test]
    fn test_escape_like_pattern_sql_injection_attempt() {
        // Simulate SQL injection-like input: ' ; DROP TABLE users ; --
        // The input has a backslash before the semicolon in the test string
        // Actually the input "'; DROP TABLE users; --" has no backslash
        // After escaping: '' ; DROP TABLE users ; --
        assert_eq!(
            escape_like_pattern("'; DROP TABLE users; --"),
            "''; DROP TABLE users; --"
        );
    }

    #[test]
    fn test_escape_like_pattern_multiple_underscores() {
        assert_eq!(escape_like_pattern("a_b_c_d"), r"a\_b\_c\_d");
    }

    #[tokio::test]
    async fn create_listing_persists_standard_columns() {
        with_test_pool(|pool| async move {
            sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
                .bind("listing-owner")
                .bind("owner")
                .execute(&pool)
                .await
                .expect("insert owner");

            let repo = PostgresListingRepository::new(pool.clone());
            let listing_id = repo
                .create(CreateListingInput {
                    campus_id: Uuid::parse_str("c0000000-0000-0000-0000-000000000001").unwrap(),
                    title: "Desk".to_string(),
                    category: "other".to_string(),
                    brand: Some("Brand".to_string()),
                    direction: "offer".to_string(),
                    condition_score: 8,
                    suggested_price_cny: 123.45,
                    defects: vec!["scratch".to_string()],
                    description: "usable".to_string(),
                    image_url: Some("https://cdn.example.com/desk.jpg".to_string()),
                    owner_id: "listing-owner".to_string(),
                })
                .await
                .expect("create listing");
            assert!(Uuid::parse_str(&listing_id).is_ok());

            let row = sqlx::query(
                "SELECT id, owner_id, suggested_price_cny, status FROM inventory WHERE id = $1",
            )
            .bind(&listing_id)
            .fetch_one(&pool)
            .await
            .expect("select listing");

            assert_eq!(row.get::<String, _>("id"), listing_id);
            assert_eq!(row.get::<String, _>("owner_id"), "listing-owner");
            assert_eq!(row.get::<i64, _>("suggested_price_cny"), 12345);
            assert_eq!(row.get::<String, _>("status"), "active");
        })
        .await;
    }

    #[tokio::test]
    async fn idempotent_create_replays_same_request_and_rejects_key_reuse() {
        with_test_pool(|pool| async move {
            sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
                .bind("idempotent-listing-owner")
                .bind("idempotent-owner")
                .execute(&pool)
                .await
                .expect("insert owner");

            let repo = PostgresListingRepository::new(pool.clone());
            let input = CreateListingInput {
                campus_id: Uuid::parse_str("c0000000-0000-0000-0000-000000000001").unwrap(),
                title: "Desk".to_string(),
                category: "other".to_string(),
                brand: Some("Campus".to_string()),
                direction: "offer".to_string(),
                condition_score: 8,
                suggested_price_cny: 123.45,
                defects: vec!["scratch".to_string()],
                description: "usable".to_string(),
                image_url: None,
                owner_id: "idempotent-listing-owner".to_string(),
            };
            let request_hash = "a".repeat(64);

            let first = repo
                .create_idempotent(
                    input.clone(),
                    Some("publish-attempt-1"),
                    Some(&request_hash),
                )
                .await
                .expect("first create");
            let replay = repo
                .create_idempotent(
                    input.clone(),
                    Some("publish-attempt-1"),
                    Some(&request_hash),
                )
                .await
                .expect("replay create");

            assert!(!first.replayed);
            assert!(replay.replayed);
            assert_eq!(first.id, replay.id);

            let count: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM inventory WHERE owner_id = $1 AND idempotency_key = $2",
            )
            .bind("idempotent-listing-owner")
            .bind("publish-attempt-1")
            .fetch_one(&pool)
            .await
            .expect("count listings");
            assert_eq!(count, 1);

            let mut changed = input;
            changed.title = "Different desk".to_string();
            let different_hash = "b".repeat(64);
            let error = repo
                .create_idempotent(changed, Some("publish-attempt-1"), Some(&different_hash))
                .await
                .expect_err("key reuse must fail");
            assert!(matches!(error, ApiError::Conflict(_)));
        })
        .await;
    }

    #[tokio::test]
    async fn stale_listing_revision_cannot_overwrite_or_delete_newer_content() {
        with_test_pool(|pool| async move {
            sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
                .bind("revision-owner")
                .bind("revision-owner")
                .execute(&pool)
                .await
                .expect("insert owner");

            let campus_id = Uuid::parse_str("c0000000-0000-0000-0000-000000000001").unwrap();
            let repo = PostgresListingRepository::new(pool.clone());
            let listing_id = repo
                .create(CreateListingInput {
                    campus_id,
                    title: "Versioned desk".to_string(),
                    category: "other".to_string(),
                    brand: Some("Campus".to_string()),
                    direction: "offer".to_string(),
                    condition_score: 8,
                    suggested_price_cny: 100.0,
                    defects: vec![],
                    description: "first".to_string(),
                    image_url: None,
                    owner_id: "revision-owner".to_string(),
                })
                .await
                .expect("create listing");
            let revision: i64 =
                sqlx::query_scalar("SELECT content_revision FROM inventory WHERE id = $1")
                    .bind(&listing_id)
                    .fetch_one(&pool)
                    .await
                    .expect("initial revision");

            let input = UpdateListingInput {
                title: Some("Updated desk".to_string()),
                category: None,
                brand: None,
                condition_score: None,
                suggested_price_cny: None,
                defects: None,
                description: None,
                status: None,
            };
            let mut tx = pool.begin().await.expect("update transaction");
            assert_eq!(
                repo.update_owned_active_with_state_in_tx(
                    &mut tx,
                    &listing_id,
                    "revision-owner",
                    campus_id,
                    &input,
                    Some(revision),
                )
                .await
                .expect("versioned update"),
                UpdateOwnedResult::Updated
            );
            tx.commit().await.expect("commit update");

            let current_revision: i64 =
                sqlx::query_scalar("SELECT content_revision FROM inventory WHERE id = $1")
                    .bind(&listing_id)
                    .fetch_one(&pool)
                    .await
                    .expect("current revision");
            assert!(current_revision > revision);

            let mut stale_update_tx = pool.begin().await.expect("stale update transaction");
            let stale_update = repo
                .update_owned_active_with_state_in_tx(
                    &mut stale_update_tx,
                    &listing_id,
                    "revision-owner",
                    campus_id,
                    &input,
                    Some(revision),
                )
                .await
                .expect_err("stale update must fail");
            assert!(matches!(
                stale_update,
                ApiError::CodedConflict {
                    code: "listing_version_conflict",
                    ..
                }
            ));
            stale_update_tx
                .rollback()
                .await
                .expect("rollback stale update");

            let mut stale_delete_tx = pool.begin().await.expect("stale delete transaction");
            let stale_delete = repo
                .delete_owned_with_revision_in_tx(
                    &mut stale_delete_tx,
                    &listing_id,
                    "revision-owner",
                    campus_id,
                    Some(revision),
                )
                .await
                .expect_err("stale delete must fail");
            assert!(matches!(
                stale_delete,
                ApiError::CodedConflict {
                    code: "listing_version_conflict",
                    ..
                }
            ));
            stale_delete_tx
                .rollback()
                .await
                .expect("rollback stale delete");

            let (title, status): (String, String) =
                sqlx::query_as("SELECT title, status FROM inventory WHERE id = $1")
                    .bind(&listing_id)
                    .fetch_one(&pool)
                    .await
                    .expect("listing remains live");
            assert_eq!(title, "Updated desk");
            assert_eq!(status, "active");
        })
        .await;
    }
}
