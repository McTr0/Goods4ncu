//! Shared command boundary for listing writes.
//!
//! HTTP forms and Agent tools are different input surfaces, but they must
//! produce the same normalized listing facts, pass the same moderation gate,
//! and use the same transactional repository operations. This service owns
//! that boundary; callers still own the surrounding transaction when an
//! ActionPlan needs to commit its plan row and listing change together.

use crate::api::error::ApiError;
use crate::categories::{normalize_category, valid_category_message};
use crate::repositories::{
    CreateListingInput, DeleteOwnedResult, PostgresListingRepository, UpdateListingInput,
    UpdateOwnedResult,
};
use crate::services::moderation::ModerationService;
use sha2::{Digest, Sha256};
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

const MAX_TITLE_CHARS: usize = 200;
const MAX_BRAND_CHARS: usize = 100;
const MAX_PRICE_CNY: f64 = 10_000_000.0;
const MAX_PRICE_CENTS: i64 = 1_000_000_000;

#[derive(Clone)]
pub struct ListingCommandService {
    pool: sqlx::PgPool,
    moderation: ModerationService,
}

#[derive(Debug, Clone)]
pub struct CreateListingDraft {
    pub campus_id: Uuid,
    pub owner_id: String,
    pub title: String,
    pub category: String,
    pub brand: String,
    pub direction: Option<String>,
    pub condition_score: i32,
    pub suggested_price_cny: f64,
    pub defects: Vec<String>,
    pub description: Option<String>,
    pub image_url: Option<String>,
}

#[derive(Debug, Clone)]
pub struct UpdateListingDraft {
    pub title: Option<String>,
    pub category: Option<String>,
    pub brand: Option<String>,
    pub condition_score: Option<i32>,
    pub suggested_price_cny: Option<f64>,
    pub defects: Option<Vec<String>>,
    pub description: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreateListingCommandResult {
    pub id: String,
    pub direction: String,
    pub replayed: bool,
}

impl ListingCommandService {
    pub fn new(pool: sqlx::PgPool, moderation: ModerationService) -> Self {
        Self { pool, moderation }
    }

    /// Normalize and validate a create draft without touching the database.
    pub fn normalize_create(
        &self,
        draft: CreateListingDraft,
    ) -> Result<CreateListingInput, ApiError> {
        let title = normalize_required_text(draft.title, "title", MAX_TITLE_CHARS)?;
        let direction = normalize_direction(draft.direction.as_deref(), "offer")?;
        if direction == "all" {
            return Err(ApiError::BadRequest(
                "direction 创建时只能为 offer 或 wanted".to_string(),
            ));
        }

        let brand = draft.brand.trim().to_string();
        let brand = if direction == "wanted" && brand.is_empty() {
            "不限".to_string()
        } else {
            normalize_required_text(brand, "brand", MAX_BRAND_CHARS)?
        };
        let category = normalize_category(draft.category.trim())
            .ok_or_else(|| ApiError::BadRequest(valid_category_message()))?
            .to_string();
        validate_condition(draft.condition_score)?;
        let price = normalize_price(draft.suggested_price_cny)?;
        let defects = normalize_defects(draft.defects);
        let description = draft.description.unwrap_or_default().trim().to_string();
        let image_url = normalize_image_url(draft.image_url)?;

        self.ensure_text_allowed(&title, &brand, &description, &defects)?;

        Ok(CreateListingInput {
            campus_id: draft.campus_id,
            title,
            category,
            brand: Some(brand),
            direction,
            condition_score: draft.condition_score,
            suggested_price_cny: price,
            defects,
            description,
            image_url,
            owner_id: draft.owner_id,
        })
    }

    /// Normalize and validate a partial update without touching the database.
    pub fn normalize_update(
        &self,
        draft: UpdateListingDraft,
    ) -> Result<UpdateListingInput, ApiError> {
        if draft.title.is_none()
            && draft.category.is_none()
            && draft.brand.is_none()
            && draft.condition_score.is_none()
            && draft.suggested_price_cny.is_none()
            && draft.defects.is_none()
            && draft.description.is_none()
        {
            return Err(ApiError::BadRequest("没有要更新的字段".to_string()));
        }

        let title = draft
            .title
            .map(|value| normalize_required_text(value, "title", MAX_TITLE_CHARS))
            .transpose()?;
        let category = draft
            .category
            .map(|value| {
                normalize_category(value.trim())
                    .map(str::to_string)
                    .ok_or_else(|| ApiError::BadRequest(valid_category_message()))
            })
            .transpose()?;
        let brand = draft
            .brand
            .map(|value| normalize_required_text(value, "brand", MAX_BRAND_CHARS))
            .transpose()?;
        if let Some(score) = draft.condition_score {
            validate_condition(score)?;
        }
        let suggested_price_cny = draft.suggested_price_cny.map(normalize_price).transpose()?;
        let defects = draft.defects.map(normalize_defects);
        let description = draft.description.map(|value| value.trim().to_string());
        let empty_defects: &[String] = &[];

        self.ensure_text_allowed(
            title.as_deref().unwrap_or_default(),
            brand.as_deref().unwrap_or_default(),
            description.as_deref().unwrap_or_default(),
            defects.as_deref().unwrap_or(empty_defects),
        )?;
        Ok(UpdateListingInput {
            title,
            category,
            brand,
            condition_score: draft.condition_score,
            suggested_price_cny,
            defects,
            description,
            status: None,
        })
    }

    pub async fn create_in_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        draft: CreateListingDraft,
        idempotency_key: Option<&str>,
    ) -> Result<CreateListingCommandResult, ApiError> {
        let input = self.normalize_create(draft)?;
        let direction = input.direction.clone();
        let campus_id = input.campus_id;
        let image_url = input.image_url.clone();
        let request_hash = idempotency_key
            .map(|_| create_listing_request_hash(&input))
            .transpose()?;
        let result = PostgresListingRepository::new(self.pool.clone())
            .create_idempotent_in_tx(tx, input, idempotency_key, request_hash.as_deref())
            .await?;

        if !result.replayed {
            if let Some(image_url) = image_url {
                self.moderation
                    .submit_image_job_in_tx(tx, campus_id, &result.id, &image_url, "listing_image")
                    .await
                    .map_err(|error| ApiError::Internal(anyhow::anyhow!("DB error: {}", error)))?;
            }
        }

        Ok(CreateListingCommandResult {
            id: result.id,
            direction,
            replayed: result.replayed,
        })
    }

    #[allow(dead_code)]
    pub async fn update_in_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        id: &str,
        owner_id: &str,
        campus_id: Uuid,
        draft: UpdateListingDraft,
    ) -> Result<bool, ApiError> {
        Ok(matches!(
            self.update_with_state_in_tx(tx, id, owner_id, campus_id, draft)
                .await?,
            UpdateOwnedResult::Updated
        ))
    }

    #[allow(dead_code)]
    pub async fn update_with_state_in_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        id: &str,
        owner_id: &str,
        campus_id: Uuid,
        draft: UpdateListingDraft,
    ) -> Result<UpdateOwnedResult, ApiError> {
        self.update_with_state_and_revision_in_tx(tx, id, owner_id, campus_id, draft, None)
            .await
    }

    pub async fn update_with_state_and_revision_in_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        id: &str,
        owner_id: &str,
        campus_id: Uuid,
        draft: UpdateListingDraft,
        expected_content_revision: Option<i64>,
    ) -> Result<UpdateOwnedResult, ApiError> {
        let input = self.normalize_update(draft)?;
        PostgresListingRepository::new(self.pool.clone())
            .update_owned_active_with_state_in_tx(
                tx,
                id,
                owner_id,
                campus_id,
                &input,
                expected_content_revision,
            )
            .await
    }

    #[allow(dead_code)]
    pub async fn delete_in_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        id: &str,
        owner_id: &str,
        campus_id: Uuid,
    ) -> Result<DeleteOwnedResult, ApiError> {
        self.delete_with_revision_in_tx(tx, id, owner_id, campus_id, None)
            .await
    }

    pub async fn delete_with_revision_in_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        id: &str,
        owner_id: &str,
        campus_id: Uuid,
        expected_content_revision: Option<i64>,
    ) -> Result<DeleteOwnedResult, ApiError> {
        PostgresListingRepository::new(self.pool.clone())
            .delete_owned_with_revision_in_tx(
                tx,
                id,
                owner_id,
                campus_id,
                expected_content_revision,
            )
            .await
    }

    fn ensure_text_allowed(
        &self,
        title: &str,
        brand: &str,
        description: &str,
        defects: &[String],
    ) -> Result<(), ApiError> {
        let full_text = format!(
            "{}\n{}\n{}\n{}",
            title,
            brand,
            description,
            defects.join(" ")
        );
        let result = self.moderation.check_text(&full_text);
        if result.passed {
            Ok(())
        } else {
            Err(ApiError::ContentViolation(
                result.reason.unwrap_or_default(),
            ))
        }
    }
}

fn normalize_direction(value: Option<&str>, default: &str) -> Result<String, ApiError> {
    let direction = value.unwrap_or(default).trim();
    match direction {
        "offer" | "wanted" | "all" => Ok(direction.to_string()),
        _ => Err(ApiError::BadRequest(
            "无效的 direction 参数，可选值：offer, wanted, all".to_string(),
        )),
    }
}

fn normalize_required_text(
    value: String,
    field: &str,
    max_chars: usize,
) -> Result<String, ApiError> {
    let value = value.trim().to_string();
    if value.is_empty() {
        return Err(ApiError::BadRequest(format!("{} is required", field)));
    }
    if value.chars().count() > max_chars {
        return Err(ApiError::BadRequest(format!(
            "{} must be {} characters or fewer",
            field, max_chars
        )));
    }
    Ok(value)
}

fn normalize_price(value: f64) -> Result<f64, ApiError> {
    if !value.is_finite() || value <= 0.0 || value > MAX_PRICE_CNY {
        return Err(ApiError::BadRequest(
            "suggested_price_cny 必须大于 0 且在 10,000,000 元以内".to_string(),
        ));
    }
    let cents = (value * 100.0).round();
    if !cents.is_finite() || cents > MAX_PRICE_CENTS as f64 {
        return Err(ApiError::BadRequest(
            "suggested_price_cny 超出可保存的金额范围".to_string(),
        ));
    }
    Ok(cents / 100.0)
}

fn validate_condition(score: i32) -> Result<(), ApiError> {
    if (1..=10).contains(&score) {
        Ok(())
    } else {
        Err(ApiError::BadRequest(
            "condition_score must be between 1 and 10".to_string(),
        ))
    }
}

fn normalize_defects(defects: Vec<String>) -> Vec<String> {
    defects
        .into_iter()
        .map(|defect| defect.trim().to_string())
        .filter(|defect| !defect.is_empty())
        .collect()
}

fn normalize_image_url(value: Option<String>) -> Result<Option<String>, ApiError> {
    value
        .map(|url| {
            let url = url.trim().to_string();
            if url.starts_with("http://") || url.starts_with("https://") {
                Ok(url)
            } else {
                Err(ApiError::BadRequest("image_url格式无效".to_string()))
            }
        })
        .transpose()
}

pub fn create_listing_request_hash(input: &CreateListingInput) -> Result<String, ApiError> {
    let canonical = serde_json::to_vec(input).map_err(|error| {
        ApiError::Internal(anyhow::anyhow!(
            "Failed to serialize normalized listing input: {}",
            error
        ))
    })?;
    Ok(hex::encode(Sha256::digest(canonical)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn service() -> ListingCommandService {
        ListingCommandService::new(
            sqlx::PgPool::connect_lazy("postgres://localhost/test").expect("lazy pool"),
            ModerationService::new_for_test(false),
        )
    }

    #[tokio::test]
    async fn normalizes_http_and_agent_create_shapes_to_the_same_input() {
        let service = service();
        let base = CreateListingDraft {
            campus_id: Uuid::nil(),
            owner_id: "owner".to_string(),
            title: "  Textbook  ".to_string(),
            category: "书籍".to_string(),
            brand: "  Brand ".to_string(),
            direction: Some("offer".to_string()),
            condition_score: 8,
            suggested_price_cny: 19.999,
            defects: vec![" scratch ".to_string(), " ".to_string()],
            description: Some("  good  ".to_string()),
            image_url: None,
        };
        let normalized = service.normalize_create(base).expect("normalize");
        assert_eq!(normalized.title, "Textbook");
        assert_eq!(normalized.category, "books");
        assert_eq!(normalized.suggested_price_cny, 20.0);
        assert_eq!(normalized.defects, vec!["scratch"]);
        assert_eq!(normalized.description, "good");
    }

    #[tokio::test]
    async fn wanted_create_uses_the_same_default_brand_as_http() {
        let service = service();
        let normalized = service
            .normalize_create(CreateListingDraft {
                campus_id: Uuid::nil(),
                owner_id: "owner".to_string(),
                title: "Need notes".to_string(),
                category: "other".to_string(),
                brand: "   ".to_string(),
                direction: Some("wanted".to_string()),
                condition_score: 5,
                suggested_price_cny: 0.0,
                defects: vec![],
                description: None,
                image_url: None,
            })
            .expect("normalize wanted");
        assert_eq!(normalized.brand.as_deref(), Some("不限"));
        assert_eq!(normalized.direction, "wanted");
    }

    #[tokio::test]
    async fn rejects_invalid_values_and_moderated_update_text_before_database() {
        let service = service();
        let invalid = service.normalize_create(CreateListingDraft {
            campus_id: Uuid::nil(),
            owner_id: "owner".to_string(),
            title: "  ".to_string(),
            category: "other".to_string(),
            brand: "Brand".to_string(),
            direction: Some("offer".to_string()),
            condition_score: 11,
            suggested_price_cny: -1.0,
            defects: vec![],
            description: None,
            image_url: None,
        });
        assert!(matches!(invalid, Err(ApiError::BadRequest(_))));

        let moderated = service.normalize_update(UpdateListingDraft {
            title: None,
            category: None,
            brand: None,
            condition_score: None,
            suggested_price_cny: None,
            defects: Some(vec!["联系电话：13812345678".to_string()]),
            description: None,
        });
        assert!(matches!(moderated, Err(ApiError::ContentViolation(_))));
    }
}
