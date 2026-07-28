use serde::{Deserialize, Serialize};
use sqlx::{PgPool, Row};
use uuid::Uuid;

use crate::api::error::ApiError;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum FeedResourceType {
    Listing,
    Intent,
}

impl FeedResourceType {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Listing => "listing",
            Self::Intent => "intent",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum FeedFeedbackAction {
    Hide,
    LessLikeThis,
    NotRelevant,
}

impl FeedFeedbackAction {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Hide => "hide",
            Self::LessLikeThis => "less_like_this",
            Self::NotRelevant => "not_relevant",
        }
    }
}

#[derive(Debug, Serialize)]
pub struct FeedFeedbackReceipt {
    pub feedback_id: Uuid,
    pub resource_type: FeedResourceType,
    pub resource_id: String,
    pub action: FeedFeedbackAction,
}

#[derive(Debug, Serialize)]
pub struct FeedPreferences {
    pub personalization_enabled: bool,
    pub signals_reset_at: Option<chrono::DateTime<chrono::Utc>>,
}

#[derive(Clone)]
pub struct FeedService {
    pool: PgPool,
}

impl FeedService {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn submit_feedback(
        &self,
        campus_id: Uuid,
        user_id: &str,
        resource_type: FeedResourceType,
        resource_id: &str,
        action: FeedFeedbackAction,
    ) -> Result<FeedFeedbackReceipt, ApiError> {
        let resource_id = resource_id.trim();
        if resource_id.is_empty() || resource_id.chars().count() > 255 {
            return Err(ApiError::NotFound);
        }

        // Owner and campus checks live in the same target lookup. Missing,
        // cross-campus and self-owned resources all return the same answer so
        // this write endpoint cannot be used as a directory oracle.
        let (canonical_id, signal_key) = match resource_type {
            FeedResourceType::Listing => {
                let row = sqlx::query(
                    "SELECT id, category
                     FROM inventory
                     WHERE id = $1 AND campus_id = $2 AND owner_id <> $3
                       AND status = 'active'",
                )
                .bind(resource_id)
                .bind(campus_id)
                .bind(user_id)
                .fetch_optional(&self.pool)
                .await
                .map_err(db_error)?
                .ok_or(ApiError::NotFound)?;
                let id: String = row.get("id");
                let category: String = row.get("category");
                (
                    id,
                    format!("listing:category:{}", normalized_signal(&category)),
                )
            }
            FeedResourceType::Intent => {
                let intent_id = Uuid::parse_str(resource_id).map_err(|_| ApiError::NotFound)?;
                let row = sqlx::query(
                    "SELECT id, kind
                     FROM intents
                     WHERE id = $1 AND campus_id = $2 AND author_id <> $3
                       AND status = 'active' AND visibility = 'campus'
                       AND (valid_until IS NULL OR valid_until > NOW())",
                )
                .bind(intent_id)
                .bind(campus_id)
                .bind(user_id)
                .fetch_optional(&self.pool)
                .await
                .map_err(db_error)?
                .ok_or(ApiError::NotFound)?;
                let id: Uuid = row.get("id");
                let kind: String = row.get("kind");
                (
                    id.to_string(),
                    format!("intent:kind:{}", normalized_signal(&kind)),
                )
            }
        };

        let feedback_id: Uuid = sqlx::query_scalar(
            "INSERT INTO feed_feedback (
                 campus_id, user_id, resource_type, resource_id, action, signal_key
             ) VALUES ($1, $2, $3, $4, $5, $6)
             ON CONFLICT (user_id, campus_id, resource_type, resource_id)
             DO UPDATE SET action = EXCLUDED.action,
                           signal_key = EXCLUDED.signal_key,
                           updated_at = NOW()
             RETURNING id",
        )
        .bind(campus_id)
        .bind(user_id)
        .bind(resource_type.as_str())
        .bind(&canonical_id)
        .bind(action.as_str())
        .bind(signal_key)
        .fetch_one(&self.pool)
        .await
        .map_err(db_error)?;

        Ok(FeedFeedbackReceipt {
            feedback_id,
            resource_type,
            resource_id: canonical_id,
            action,
        })
    }

    pub async fn preferences(
        &self,
        campus_id: Uuid,
        user_id: &str,
    ) -> Result<FeedPreferences, ApiError> {
        let row = sqlx::query(
            "SELECT personalization_enabled, signals_reset_at
             FROM feed_preferences WHERE campus_id = $1 AND user_id = $2",
        )
        .bind(campus_id)
        .bind(user_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(db_error)?;

        Ok(row.map_or(
            FeedPreferences {
                personalization_enabled: true,
                signals_reset_at: None,
            },
            |row| FeedPreferences {
                personalization_enabled: row.get("personalization_enabled"),
                signals_reset_at: row.get("signals_reset_at"),
            },
        ))
    }

    pub async fn update_preferences(
        &self,
        campus_id: Uuid,
        user_id: &str,
        personalization_enabled: bool,
    ) -> Result<FeedPreferences, ApiError> {
        let row = sqlx::query(
            "INSERT INTO feed_preferences (campus_id, user_id, personalization_enabled)
             VALUES ($1, $2, $3)
             ON CONFLICT (campus_id, user_id)
             DO UPDATE SET personalization_enabled = EXCLUDED.personalization_enabled,
                           updated_at = NOW()
             RETURNING personalization_enabled, signals_reset_at",
        )
        .bind(campus_id)
        .bind(user_id)
        .bind(personalization_enabled)
        .fetch_one(&self.pool)
        .await
        .map_err(db_error)?;

        Ok(FeedPreferences {
            personalization_enabled: row.get("personalization_enabled"),
            signals_reset_at: row.get("signals_reset_at"),
        })
    }

    pub async fn clear_personalization(
        &self,
        campus_id: Uuid,
        user_id: &str,
    ) -> Result<FeedPreferences, ApiError> {
        let row = sqlx::query(
            "INSERT INTO feed_preferences (campus_id, user_id, signals_reset_at)
             VALUES ($1, $2, NOW())
             ON CONFLICT (campus_id, user_id)
             DO UPDATE SET signals_reset_at = NOW(), updated_at = NOW()
             RETURNING personalization_enabled, signals_reset_at",
        )
        .bind(campus_id)
        .bind(user_id)
        .fetch_one(&self.pool)
        .await
        .map_err(db_error)?;

        Ok(FeedPreferences {
            personalization_enabled: row.get("personalization_enabled"),
            signals_reset_at: row.get("signals_reset_at"),
        })
    }
}

fn normalized_signal(value: &str) -> String {
    value.trim().to_lowercase()
}

fn db_error(error: sqlx::Error) -> ApiError {
    ApiError::Internal(anyhow::anyhow!("DB error: {error}"))
}
