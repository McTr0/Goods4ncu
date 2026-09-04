//! Service for wanted listing responses and wanted fulfillment workflows.

use anyhow::Result;
use chrono::{DateTime, Utc};
use sqlx::{PgPool, Row};
use uuid::Uuid;

use crate::api::error::ApiError;

#[derive(Debug, Clone)]
pub struct WantedResponseRow {
    pub id: Uuid,
    pub wanted_listing_id: String,
    pub wanted_title: String,
    pub wanted_status: String,
    pub wanted_restricted: bool,
    pub current_lifecycle_epoch: i64,
    pub offer_listing_id: String,
    pub offer_title: String,
    pub offer_status: String,
    pub offer_restricted: bool,
    pub responder_id: String,
    pub requester_id: String,
    pub message: Option<String>,
    pub status: String,
    pub created_at: DateTime<Utc>,
    pub responded_at: Option<DateTime<Utc>>,
    pub lifecycle_epoch: Option<i64>,
}

#[derive(Debug, Clone)]
pub struct ActionOutcome {
    pub counterpart_id: String,
    pub offer_title: String,
    pub wanted_listing_id: String,
}

#[derive(Debug, Clone)]
pub struct CreateWantedResponseResult {
    pub id: String,
    pub message: String,
    pub replayed: bool,
    pub wanted_owner_id: String,
    pub wanted_title: String,
    pub offer_title: String,
}

#[derive(Debug, Clone)]
pub struct FulfillWantedResult {
    pub title: String,
    pub pending_responders: Vec<String>,
    pub lifecycle_epoch: i64,
}

pub struct ListWantedResponsesParams<'a> {
    pub column: &'a str,
    pub user_id: &'a str,
    pub campus_id: Uuid,
    pub status: Option<&'a str>,
    pub wanted_listing_id: Option<&'a str>,
    pub limit: i64,
    pub offset: i64,
}

pub struct ActionWantedResponseParams<'a> {
    pub user_id: &'a str,
    pub campus_id: Uuid,
    pub response_id: Uuid,
    pub actor_column: &'a str,
    pub to_status: &'a str,
    pub require_offer_active: bool,
    pub notify_column: &'a str,
}

pub struct CreateWantedResponseParams<'a> {
    pub user_id: &'a str,
    pub campus_id: Uuid,
    pub wanted_id: &'a str,
    pub offer_listing_id: &'a str,
    pub message: Option<&'a str>,
    pub idempotency_key: Option<&'a str>,
    pub request_hash: Option<&'a str>,
}

#[derive(Clone)]
pub struct WantedResponseService {
    db: PgPool,
}

impl WantedResponseService {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    pub async fn list_responses(
        &self,
        params: ListWantedResponsesParams<'_>,
    ) -> Result<(Vec<WantedResponseRow>, i64), ApiError> {
        let ListWantedResponsesParams {
            column,
            user_id,
            campus_id,
            status,
            wanted_listing_id,
            limit,
            offset,
        } = params;

        if column != "requester_id" && column != "responder_id" {
            return Err(ApiError::BadRequest("无效的查询主体".to_string()));
        }

        let filter = format!(
            "FROM wanted_responses r
             WHERE r.{column} = $1
               AND r.campus_id = $2
               AND ($3::text IS NULL OR r.status = $3)
               AND ($4::text IS NULL OR r.wanted_listing_id = $4)"
        );
        let total: i64 = sqlx::query_scalar(&format!("SELECT COUNT(*) {filter}"))
            .bind(user_id)
            .bind(campus_id)
            .bind(status)
            .bind(wanted_listing_id)
            .fetch_one(&self.db)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let rows = sqlx::query(&format!(
            "SELECT r.id, r.wanted_listing_id, r.offer_listing_id, r.responder_id, r.requester_id,
                    r.message, r.status, r.created_at, r.responded_at, r.lifecycle_epoch,
                    w.title AS wanted_title, w.status AS wanted_status,
                    w.lifecycle_epoch AS current_lifecycle_epoch,
                    listing_has_active_restriction(w.id) AS wanted_restricted,
                    o.title AS offer_title, o.status AS offer_status,
                    listing_has_active_restriction(o.id) AS offer_restricted
             FROM wanted_responses r
             JOIN inventory w ON w.id = r.wanted_listing_id
             JOIN inventory o ON o.id = r.offer_listing_id
             WHERE r.{column} = $1
               AND r.campus_id = $2
               AND ($3::text IS NULL OR r.status = $3)
               AND ($4::text IS NULL OR r.wanted_listing_id = $4)
             ORDER BY r.created_at DESC
             LIMIT $5 OFFSET $6"
        ))
        .bind(user_id)
        .bind(campus_id)
        .bind(status)
        .bind(wanted_listing_id)
        .bind(limit)
        .bind(offset)
        .fetch_all(&self.db)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let items = rows
            .into_iter()
            .map(|r| WantedResponseRow {
                id: r.get("id"),
                wanted_listing_id: r.get("wanted_listing_id"),
                wanted_title: r.get("wanted_title"),
                wanted_status: r.get("wanted_status"),
                wanted_restricted: r.get("wanted_restricted"),
                current_lifecycle_epoch: r.get("current_lifecycle_epoch"),
                offer_listing_id: r.get("offer_listing_id"),
                offer_title: r.get("offer_title"),
                offer_status: r.get("offer_status"),
                offer_restricted: r.get("offer_restricted"),
                responder_id: r.get("responder_id"),
                requester_id: r.get("requester_id"),
                message: r.get("message"),
                status: r.get("status"),
                created_at: r.get("created_at"),
                responded_at: r.get("responded_at"),
                lifecycle_epoch: r.get("lifecycle_epoch"),
            })
            .collect();

        Ok((items, total))
    }

    pub async fn action_response(
        &self,
        params: ActionWantedResponseParams<'_>,
    ) -> Result<ActionOutcome, ApiError> {
        let ActionWantedResponseParams {
            user_id,
            campus_id,
            response_id,
            actor_column,
            to_status,
            require_offer_active,
            notify_column,
        } = params;
        if actor_column != "requester_id" && actor_column != "responder_id" {
            return Err(ApiError::BadRequest("无效的操作主体".to_string()));
        }
        if notify_column != "requester_id" && notify_column != "responder_id" {
            return Err(ApiError::BadRequest("无效的通知主体".to_string()));
        }

        let mut tx = self
            .db
            .begin()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let link = sqlx::query(&format!(
            "SELECT wanted_listing_id, offer_listing_id
             FROM wanted_responses
             WHERE id = $1 AND campus_id = $2 AND {} = $3",
            actor_column
        ))
        .bind(response_id)
        .bind(campus_id)
        .bind(user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        .ok_or(ApiError::NotFound)?;
        let wanted_listing_id: String = link.get("wanted_listing_id");
        let offer_listing_id: String = link.get("offer_listing_id");

        let wanted = sqlx::query(
            "SELECT status, lifecycle_epoch
             FROM inventory
             WHERE id = $1 AND campus_id = $2
             FOR UPDATE",
        )
        .bind(&wanted_listing_id)
        .bind(campus_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        .ok_or(ApiError::NotFound)?;
        let wanted_status: String = wanted.get("status");
        let current_lifecycle_epoch: i64 = wanted.get("lifecycle_epoch");
        let wanted_restricted: bool =
            sqlx::query_scalar("SELECT listing_has_active_restriction($1)")
                .bind(&wanted_listing_id)
                .fetch_one(&mut *tx)
                .await
                .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let offer = sqlx::query(
            "SELECT status, title
             FROM inventory
             WHERE id = $1 AND campus_id = $2
             FOR UPDATE",
        )
        .bind(&offer_listing_id)
        .bind(campus_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        .ok_or(ApiError::NotFound)?;
        let offer_status: String = offer.get("status");
        let offer_title: String = offer.get("title");
        let offer_restricted: bool =
            sqlx::query_scalar("SELECT listing_has_active_restriction($1)")
                .bind(&offer_listing_id)
                .fetch_one(&mut *tx)
                .await
                .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let row = sqlx::query(&format!(
            "SELECT responder_id, requester_id, status, lifecycle_epoch,
                    wanted_listing_id, offer_listing_id
             FROM wanted_responses
             WHERE id = $1 AND campus_id = $2 AND {} = $3
             FOR UPDATE",
            actor_column
        ))
        .bind(response_id)
        .bind(campus_id)
        .bind(user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        .ok_or(ApiError::NotFound)?;

        let status: String = row.get("status");
        let lifecycle_epoch: Option<i64> = row.get("lifecycle_epoch");
        let locked_wanted_listing_id: String = row.get("wanted_listing_id");
        let locked_offer_listing_id: String = row.get("offer_listing_id");
        if locked_wanted_listing_id != wanted_listing_id
            || locked_offer_listing_id != offer_listing_id
        {
            return Err(ApiError::Conflict(
                "该推荐关联的商品已发生变化，请刷新后重试".to_string(),
            ));
        }

        let ineligible_reason = if status != "pending" {
            Some(ApiError::Conflict(format!(
                "该推荐当前状态为 {status}，无法操作"
            )))
        } else if lifecycle_epoch != Some(current_lifecycle_epoch)
            || wanted_status != "active"
            || wanted_restricted
        {
            Some(ApiError::CodedConflict {
                code: "wanted_response_round_closed",
                message: "该推荐属于已结束的收物轮次，请刷新后查看历史".to_string(),
            })
        } else if offer_restricted && to_status != "dismissed" {
            Some(ApiError::CodedConflict {
                code: "listing_restricted",
                message: "推荐商品已受平台限制，无法操作".to_string(),
            })
        } else if require_offer_active && offer_status != "active" {
            Some(ApiError::Conflict(format!(
                "推荐商品当前状态为 {offer_status}，无法操作"
            )))
        } else {
            None
        };
        if let Some(error) = ineligible_reason {
            return Err(error);
        }

        let updated = sqlx::query(&format!(
            "UPDATE wanted_responses AS r
             SET status = $2, responded_at = NOW()
             WHERE r.id = $1
               AND r.status = 'pending'
               AND r.{} = $3
               AND r.campus_id = $4
               AND r.lifecycle_epoch = $5
               AND EXISTS (
                   SELECT 1
                   FROM inventory AS w
                   WHERE w.id = r.wanted_listing_id
                     AND w.campus_id = r.campus_id
                     AND w.status = 'active'
                     AND NOT listing_has_active_restriction(w.id)
                     AND w.lifecycle_epoch = r.lifecycle_epoch
               )
               AND (
                   NOT $6::boolean
                   OR EXISTS (
                       SELECT 1
                       FROM inventory AS o
                       WHERE o.id = r.offer_listing_id
                         AND o.campus_id = r.campus_id
                         AND o.status = 'active'
                         AND NOT listing_has_active_restriction(o.id)
                   )
               )",
            actor_column
        ))
        .bind(response_id)
        .bind(to_status)
        .bind(user_id)
        .bind(campus_id)
        .bind(lifecycle_epoch)
        .bind(require_offer_active)
        .execute(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        if updated.rows_affected() == 0 {
            return Err(ApiError::Conflict(
                "该推荐状态已发生变化，无法操作".to_string(),
            ));
        }
        tx.commit()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let counterpart_id: String = row.get(notify_column);
        Ok(ActionOutcome {
            counterpart_id,
            offer_title,
            wanted_listing_id,
        })
    }

    pub async fn create_wanted_response(
        &self,
        params: CreateWantedResponseParams<'_>,
    ) -> Result<CreateWantedResponseResult, ApiError> {
        let CreateWantedResponseParams {
            user_id,
            campus_id,
            wanted_id,
            offer_listing_id,
            message,
            idempotency_key,
            request_hash,
        } = params;
        let mut tx = self
            .db
            .begin()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        if let Some(key) = idempotency_key {
            if let Some((existing_id, existing_hash)) = sqlx::query_as::<_, (Uuid, Option<String>)>(
                "SELECT id, idempotency_hash
                     FROM wanted_responses
                     WHERE campus_id = $1 AND responder_id = $2 AND idempotency_key = $3",
            )
            .bind(campus_id)
            .bind(user_id)
            .bind(key)
            .fetch_optional(&mut *tx)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
            {
                if existing_hash.as_deref() != request_hash {
                    return Err(ApiError::Conflict(
                        "Idempotency-Key 已用于不同的推荐内容".to_string(),
                    ));
                }
                tx.commit()
                    .await
                    .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
                return Ok(CreateWantedResponseResult {
                    id: existing_id.to_string(),
                    message: "已推荐给需求方".to_string(),
                    replayed: true,
                    wanted_owner_id: String::new(),
                    wanted_title: String::new(),
                    offer_title: String::new(),
                });
            }
        }

        let wanted = sqlx::query(
            "SELECT id, title, owner_id, status, direction, lifecycle_epoch
             FROM inventory
             WHERE id = $1 AND campus_id = $2
             FOR UPDATE",
        )
        .bind(wanted_id)
        .bind(campus_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        .ok_or(ApiError::NotFound)?;
        let wanted_id_val: String = wanted.get("id");
        let wanted_title: String = wanted.get("title");
        let wanted_owner_id: String = wanted.get("owner_id");
        let wanted_status: String = wanted.get("status");
        let wanted_direction: String = wanted.get("direction");
        let lifecycle_epoch: i64 = wanted.get("lifecycle_epoch");
        let wanted_restricted: bool =
            sqlx::query_scalar("SELECT listing_has_active_restriction($1)")
                .bind(&wanted_id_val)
                .fetch_one(&mut *tx)
                .await
                .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        if wanted_restricted {
            return Err(ApiError::CodedConflict {
                code: "wanted_response_round_closed",
                message: "该收物需求已受平台限制，当前轮次不可响应".to_string(),
            });
        }
        if wanted_direction != "wanted" || wanted_status != "active" {
            return Err(ApiError::BadRequest("这不是可响应的收物需求".to_string()));
        }
        if wanted_owner_id == user_id {
            return Err(ApiError::BadRequest("不能给自己的需求推荐商品".to_string()));
        }

        let requester_is_verified: bool = sqlx::query_scalar(
            "SELECT EXISTS(
                SELECT 1
                FROM campus_memberships AS membership
                JOIN campuses AS campus
                  ON campus.id = membership.campus_id AND campus.status = 'active'
                WHERE membership.campus_id = $1
                  AND membership.user_id = $2
                  AND membership.status = 'verified'
             )",
        )
        .bind(campus_id)
        .bind(&wanted_owner_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        if !requester_is_verified {
            return Err(ApiError::CampusScopeMismatch);
        }

        let offer = sqlx::query(
            "SELECT id, title, owner_id, status, direction
             FROM inventory
             WHERE id = $1 AND campus_id = $2
             FOR UPDATE",
        )
        .bind(offer_listing_id.trim())
        .bind(campus_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        .ok_or(ApiError::NotFound)?;
        let offer_id: String = offer.get("id");
        let offer_title: String = offer.get("title");
        let offer_owner_id: String = offer.get("owner_id");
        let offer_status: String = offer.get("status");
        let offer_direction: String = offer.get("direction");
        let offer_restricted: bool =
            sqlx::query_scalar("SELECT listing_has_active_restriction($1)")
                .bind(&offer_id)
                .fetch_one(&mut *tx)
                .await
                .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        if offer_restricted {
            return Err(ApiError::CodedConflict {
                code: "listing_restricted",
                message: "推荐商品已受平台限制".to_string(),
            });
        }
        if offer_direction != "offer" || offer_status != "active" {
            return Err(ApiError::BadRequest("只能推荐正在出的商品".to_string()));
        }
        if offer_owner_id != user_id {
            return Err(ApiError::Forbidden);
        }

        let inserted = sqlx::query_scalar::<_, Uuid>(
            r#"
            INSERT INTO wanted_responses (
                campus_id, wanted_listing_id, offer_listing_id, responder_id,
                requester_id, message, lifecycle_epoch,
                idempotency_key, idempotency_hash
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
            ON CONFLICT DO NOTHING
            RETURNING id
            "#,
        )
        .bind(campus_id)
        .bind(&wanted_id_val)
        .bind(&offer_id)
        .bind(user_id)
        .bind(&wanted_owner_id)
        .bind(message)
        .bind(lifecycle_epoch)
        .bind(idempotency_key)
        .bind(request_hash)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let (response_id, replayed) = if let Some(response_id) = inserted {
            (response_id, false)
        } else if let Some(key) = idempotency_key {
            match sqlx::query_as::<_, (Uuid, Option<String>)>(
                "SELECT id, idempotency_hash
                 FROM wanted_responses
                 WHERE campus_id = $1 AND responder_id = $2 AND idempotency_key = $3",
            )
            .bind(campus_id)
            .bind(user_id)
            .bind(key)
            .fetch_optional(&mut *tx)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
            {
                Some((existing_id, existing_hash)) => {
                    if existing_hash.as_deref() != request_hash {
                        return Err(ApiError::Conflict(
                            "Idempotency-Key 已用于不同的推荐内容".to_string(),
                        ));
                    }
                    (existing_id, true)
                }
                None => return Err(ApiError::BadRequest("本轮已经推荐过这件商品".to_string())),
            }
        } else {
            return Err(ApiError::BadRequest("本轮已经推荐过这件商品".to_string()));
        };

        tx.commit()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(CreateWantedResponseResult {
            id: response_id.to_string(),
            message: "已推荐给需求方".to_string(),
            replayed,
            wanted_owner_id,
            wanted_title,
            offer_title,
        })
    }

    pub async fn fulfill_wanted(
        &self,
        user_id: &str,
        campus_id: Uuid,
        listing_id: &str,
    ) -> Result<FulfillWantedResult, ApiError> {
        let mut tx = self
            .db
            .begin()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        let listing = sqlx::query(
            "SELECT owner_id, title, status, direction, lifecycle_epoch
             FROM inventory
             WHERE id = $1 AND campus_id = $2
             FOR UPDATE",
        )
        .bind(listing_id)
        .bind(campus_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
        .ok_or(ApiError::NotFound)?;

        let owner_id: String = listing.get("owner_id");
        let title: String = listing.get("title");
        let status: String = listing.get("status");
        let direction: String = listing.get("direction");
        let lifecycle_epoch: i64 = listing.get("lifecycle_epoch");
        let restricted: bool = sqlx::query_scalar("SELECT listing_has_active_restriction($1)")
            .bind(listing_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        if owner_id != user_id {
            return Err(ApiError::Forbidden);
        }
        if direction != "wanted" {
            return Err(ApiError::BadRequest(
                "只有收物需求可以标记为已完成".to_string(),
            ));
        }
        if restricted {
            return Err(ApiError::CodedConflict {
                code: "listing_restricted",
                message: "该发布受平台限制，不能标记完成".to_string(),
            });
        }
        if status != "active" {
            return Err(ApiError::Conflict(format!(
                "当前状态为'{}'，无法标记完成",
                status
            )));
        }

        let updated = sqlx::query(
            "UPDATE inventory SET status = 'fulfilled'
             WHERE id = $1
               AND campus_id = $2
               AND owner_id = $3
               AND direction = 'wanted'
               AND status = 'active'
               AND lifecycle_epoch = $4",
        )
        .bind(listing_id)
        .bind(campus_id)
        .bind(user_id)
        .bind(lifecycle_epoch)
        .execute(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;
        if updated.rows_affected() == 0 {
            return Err(ApiError::Conflict(
                "收物需求状态已发生变化，无法标记完成".to_string(),
            ));
        }

        let pending_responders: Vec<String> = sqlx::query_scalar(
            "SELECT DISTINCT responder_id FROM wanted_responses
             WHERE wanted_listing_id = $1
               AND campus_id = $2
               AND lifecycle_epoch = $3
               AND status = 'pending'",
        )
        .bind(listing_id)
        .bind(campus_id)
        .bind(lifecycle_epoch)
        .fetch_all(&mut *tx)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        tx.commit()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

        Ok(FulfillWantedResult {
            title,
            pending_responders,
            lifecycle_epoch,
        })
    }
}
