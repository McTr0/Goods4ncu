use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::{Map, Value};
use sqlx::{PgPool, Postgres, Row, Transaction};
use std::collections::HashSet;
use uuid::Uuid;

use crate::api::error::ApiError;

pub const SOCIAL_PERSONA_STYLE_VERSION: &str = "v1";

const REPRESENTATION_MODES: &[&str] = &["trait_mapped", "role_character"];
const CONTACT_POSTURES: &[&str] = &["leave_message", "connection_allowed", "busy", "later"];
const SELF_DESCRIPTION_CODES: &[&str] = &[
    "slow_to_warm",
    "business_only",
    "meetup_friendly",
    "casual_chat",
    "reply_later",
    "tech_enthusiast",
];
const APPEARANCE_KEYS: &[&str] = &["palette", "silhouette", "accessory", "outfit"];
const PALETTES: &[&str] = &["teal", "plum", "sun", "slate"];
const SILHOUETTES: &[&str] = &["soft", "round", "sharp"];
const ACCESSORIES: &[&str] = &["none", "glasses", "headphones", "leaf"];
const OUTFITS: &[&str] = &["campus", "workwear", "casual", "lab"];

#[derive(Debug, Clone, Serialize)]
pub struct SocialPersonaView {
    pub id: String,
    pub user_id: String,
    pub campus_id: Uuid,
    pub representation_mode: String,
    pub style_version: String,
    pub appearance_config: Value,
    pub self_descriptions: Vec<String>,
    pub contact_posture: String,
    pub status: String,
    pub published_at: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct PublicSocialPersonaView {
    pub representation_mode: String,
    pub style_version: String,
    pub appearance_config: Value,
    pub self_descriptions: Vec<String>,
    pub contact_posture: String,
    pub published_at: String,
}

#[derive(Debug, Clone)]
pub struct SocialPersonaInput {
    pub representation_mode: String,
    pub style_version: Option<String>,
    pub appearance_config: Value,
    pub self_descriptions: Vec<String>,
    pub contact_posture: String,
}

#[derive(Debug, Clone)]
struct NormalizedPersonaInput {
    representation_mode: String,
    style_version: String,
    appearance_config: Value,
    self_descriptions: Vec<String>,
    contact_posture: String,
}

#[derive(Clone)]
pub struct SocialPersonaService {
    pool: PgPool,
}

impl SocialPersonaService {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn get_for_user(
        &self,
        user_id: &str,
        campus_id: Uuid,
    ) -> Result<Option<SocialPersonaView>, ApiError> {
        let row = self.load_row(user_id, campus_id).await?;
        Ok(row.map(|row| row_to_view(&row)))
    }

    pub async fn get_published_for_user(
        &self,
        user_id: &str,
        campus_id: Uuid,
    ) -> Result<Option<PublicSocialPersonaView>, ApiError> {
        let row = sqlx::query(
            r#"
            SELECT p.representation_mode, p.style_version, p.appearance_config,
                   p.self_descriptions, p.contact_posture, p.published_at
            FROM social_personas p
            JOIN users user_account
              ON user_account.id = p.user_id
             AND user_account.status = 'active'
            JOIN campus_memberships membership
              ON membership.user_id = p.user_id
             AND membership.campus_id = p.campus_id
             AND membership.status = 'verified'
            JOIN campuses campus
              ON campus.id = p.campus_id AND campus.status = 'active'
            WHERE p.user_id = $1 AND p.campus_id = $2 AND p.status = 'published'
            "#,
        )
        .bind(user_id)
        .bind(campus_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(db_error)?;

        Ok(row.map(|row| PublicSocialPersonaView {
            representation_mode: row.get("representation_mode"),
            style_version: row.get("style_version"),
            appearance_config: row.get("appearance_config"),
            self_descriptions: parse_descriptions(row.get("self_descriptions")),
            contact_posture: row.get("contact_posture"),
            published_at: format_optional_timestamp(row.get("published_at")).unwrap_or_default(),
        }))
    }

    pub async fn upsert_draft(
        &self,
        user_id: &str,
        campus_id: Uuid,
        input: SocialPersonaInput,
    ) -> Result<SocialPersonaView, ApiError> {
        let input = normalize_input(input)?;
        let mut tx = self.pool.begin().await.map_err(db_error)?;
        let existing = sqlx::query_scalar::<_, Uuid>(
            "SELECT id FROM social_personas WHERE user_id = $1 AND campus_id = $2 FOR UPDATE",
        )
        .bind(user_id)
        .bind(campus_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(db_error)?;
        let action = if existing.is_some() {
            "edited"
        } else {
            "created"
        };
        let row = sqlx::query(
            r#"
            INSERT INTO social_personas (
                user_id, campus_id, representation_mode, style_version,
                appearance_config, self_descriptions, contact_posture,
                status, published_at, updated_at
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, 'draft', NULL, NOW())
            ON CONFLICT (user_id, campus_id) DO UPDATE SET
                representation_mode = EXCLUDED.representation_mode,
                style_version = EXCLUDED.style_version,
                appearance_config = EXCLUDED.appearance_config,
                self_descriptions = EXCLUDED.self_descriptions,
                contact_posture = EXCLUDED.contact_posture,
                status = 'draft',
                published_at = NULL,
                updated_at = NOW()
            RETURNING id, user_id, campus_id, representation_mode, style_version,
                      appearance_config, self_descriptions, contact_posture,
                      status, published_at, created_at, updated_at
            "#,
        )
        .bind(user_id)
        .bind(campus_id)
        .bind(&input.representation_mode)
        .bind(&input.style_version)
        .bind(&input.appearance_config)
        .bind(serde_json::to_value(&input.self_descriptions).map_err(json_error)?)
        .bind(&input.contact_posture)
        .fetch_one(&mut *tx)
        .await
        .map_err(db_error)?;
        let view = row_to_view(&row);
        insert_audit(&mut tx, &view, action).await?;
        tx.commit().await.map_err(db_error)?;
        Ok(view)
    }

    pub async fn publish(
        &self,
        user_id: &str,
        campus_id: Uuid,
    ) -> Result<SocialPersonaView, ApiError> {
        let mut tx = self.pool.begin().await.map_err(db_error)?;
        let row = sqlx::query(
            r#"
            UPDATE social_personas
            SET status = 'published', published_at = NOW(), updated_at = NOW()
            WHERE user_id = $1 AND campus_id = $2
            RETURNING id, user_id, campus_id, representation_mode, style_version,
                      appearance_config, self_descriptions, contact_posture,
                      status, published_at, created_at, updated_at
            "#,
        )
        .bind(user_id)
        .bind(campus_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::NotFound)?;
        let view = row_to_view(&row);
        insert_audit(&mut tx, &view, "published").await?;
        tx.commit().await.map_err(db_error)?;
        Ok(view)
    }

    pub async fn archive(
        &self,
        user_id: &str,
        campus_id: Uuid,
    ) -> Result<SocialPersonaView, ApiError> {
        let mut tx = self.pool.begin().await.map_err(db_error)?;
        let row = sqlx::query(
            r#"
            UPDATE social_personas
            SET status = 'archived', published_at = NULL, updated_at = NOW()
            WHERE user_id = $1 AND campus_id = $2
            RETURNING id, user_id, campus_id, representation_mode, style_version,
                      appearance_config, self_descriptions, contact_posture,
                      status, published_at, created_at, updated_at
            "#,
        )
        .bind(user_id)
        .bind(campus_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::NotFound)?;
        let view = row_to_view(&row);
        insert_audit(&mut tx, &view, "archived").await?;
        tx.commit().await.map_err(db_error)?;
        Ok(view)
    }

    async fn load_row(
        &self,
        user_id: &str,
        campus_id: Uuid,
    ) -> Result<Option<sqlx::postgres::PgRow>, ApiError> {
        sqlx::query(
            "SELECT id, user_id, campus_id, representation_mode, style_version,
                    appearance_config, self_descriptions, contact_posture,
                    status, published_at, created_at, updated_at
             FROM social_personas
             WHERE user_id = $1 AND campus_id = $2",
        )
        .bind(user_id)
        .bind(campus_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(db_error)
    }
}

async fn insert_audit(
    tx: &mut Transaction<'_, Postgres>,
    view: &SocialPersonaView,
    action: &str,
) -> Result<(), ApiError> {
    let snapshot = serde_json::to_value(view).map_err(json_error)?;
    sqlx::query(
        "INSERT INTO social_persona_audits
            (persona_id, user_id, campus_id, action, snapshot)
         VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(
        Uuid::parse_str(&view.id)
            .map_err(|_| ApiError::Internal(anyhow::anyhow!("invalid persona id")))?,
    )
    .bind(&view.user_id)
    .bind(view.campus_id)
    .bind(action)
    .bind(snapshot)
    .execute(&mut **tx)
    .await
    .map_err(db_error)?;
    Ok(())
}

fn row_to_view(row: &sqlx::postgres::PgRow) -> SocialPersonaView {
    SocialPersonaView {
        id: row.get::<Uuid, _>("id").to_string(),
        user_id: row.get("user_id"),
        campus_id: row.get("campus_id"),
        representation_mode: row.get("representation_mode"),
        style_version: row.get("style_version"),
        appearance_config: row.get("appearance_config"),
        self_descriptions: parse_descriptions(row.get("self_descriptions")),
        contact_posture: row.get("contact_posture"),
        status: row.get("status"),
        published_at: format_optional_timestamp(row.get("published_at")),
        created_at: format_timestamp(row.get("created_at")),
        updated_at: format_timestamp(row.get("updated_at")),
    }
}

fn parse_descriptions(value: Value) -> Vec<String> {
    serde_json::from_value(value).unwrap_or_default()
}

fn format_optional_timestamp(value: Option<DateTime<Utc>>) -> Option<String> {
    value.map(|date| date.to_rfc3339())
}

fn format_timestamp(value: DateTime<Utc>) -> String {
    value.to_rfc3339()
}

fn normalize_input(input: SocialPersonaInput) -> Result<NormalizedPersonaInput, ApiError> {
    let representation_mode = input.representation_mode.trim().to_string();
    if !REPRESENTATION_MODES.contains(&representation_mode.as_str()) {
        return Err(ApiError::BadRequest("不支持的角色呈现模式".to_string()));
    }
    let style_version = input
        .style_version
        .unwrap_or_else(|| SOCIAL_PERSONA_STYLE_VERSION.to_string());
    if style_version != SOCIAL_PERSONA_STYLE_VERSION {
        return Err(ApiError::BadRequest("不支持的角色风格版本".to_string()));
    }
    let contact_posture = input.contact_posture.trim().to_string();
    if !CONTACT_POSTURES.contains(&contact_posture.as_str()) {
        return Err(ApiError::BadRequest("不支持的公开接近方式".to_string()));
    }
    if input.self_descriptions.len() > 3 {
        return Err(ApiError::BadRequest("最多选择三个自我描述标签".to_string()));
    }
    let mut seen = HashSet::new();
    let mut self_descriptions = Vec::with_capacity(input.self_descriptions.len());
    for description in input.self_descriptions {
        let description = description.trim().to_string();
        if !SELF_DESCRIPTION_CODES.contains(&description.as_str())
            || !seen.insert(description.clone())
        {
            return Err(ApiError::BadRequest("自我描述标签无效或重复".to_string()));
        }
        self_descriptions.push(description);
    }

    Ok(NormalizedPersonaInput {
        representation_mode,
        style_version,
        appearance_config: normalize_appearance(input.appearance_config)?,
        self_descriptions,
        contact_posture,
    })
}

fn normalize_appearance(value: Value) -> Result<Value, ApiError> {
    let Value::Object(input) = value else {
        return Err(ApiError::BadRequest("角色外观配置必须是对象".to_string()));
    };
    if input
        .keys()
        .any(|key| !APPEARANCE_KEYS.contains(&key.as_str()))
    {
        return Err(ApiError::BadRequest("角色外观包含不支持的字段".to_string()));
    }
    let mut output = Map::new();
    output.insert(
        "palette".to_string(),
        Value::String(read_token(&input, "palette", PALETTES, "teal")?),
    );
    output.insert(
        "silhouette".to_string(),
        Value::String(read_token(&input, "silhouette", SILHOUETTES, "soft")?),
    );
    output.insert(
        "accessory".to_string(),
        Value::String(read_token(&input, "accessory", ACCESSORIES, "none")?),
    );
    output.insert(
        "outfit".to_string(),
        Value::String(read_token(&input, "outfit", OUTFITS, "campus")?),
    );
    Ok(Value::Object(output))
}

fn read_token(
    input: &Map<String, Value>,
    key: &str,
    allowed: &[&str],
    default: &str,
) -> Result<String, ApiError> {
    let value = match input.get(key) {
        None => default.to_string(),
        Some(Value::String(value)) => value.trim().to_string(),
        Some(_) => return Err(ApiError::BadRequest(format!("角色外观字段 {key} 无效"))),
    };
    if allowed.contains(&value.as_str()) {
        Ok(value)
    } else {
        Err(ApiError::BadRequest(format!("角色外观字段 {key} 无效")))
    }
}

fn json_error(error: serde_json::Error) -> ApiError {
    ApiError::Internal(anyhow::anyhow!("social persona JSON error: {error}"))
}

fn db_error(error: sqlx::Error) -> ApiError {
    ApiError::Internal(anyhow::anyhow!("social persona database error: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn input() -> SocialPersonaInput {
        SocialPersonaInput {
            representation_mode: "role_character".to_string(),
            style_version: None,
            appearance_config: json!({"palette":"teal", "accessory":"leaf"}),
            self_descriptions: vec!["slow_to_warm".to_string(), "meetup_friendly".to_string()],
            contact_posture: "leave_message".to_string(),
        }
    }

    #[test]
    fn normalizes_missing_appearance_tokens_to_v1_defaults() {
        let normalized = normalize_input(input()).unwrap();
        assert_eq!(normalized.style_version, "v1");
        assert_eq!(normalized.appearance_config["silhouette"], "soft");
        assert_eq!(normalized.appearance_config["outfit"], "campus");
    }

    #[test]
    fn rejects_free_form_or_inferred_persona_values() {
        let mut invalid = input();
        invalid.self_descriptions = vec!["kind".to_string()];
        assert!(normalize_input(invalid).is_err());

        let mut invalid = input();
        invalid.appearance_config = json!({"online":"true"});
        assert!(normalize_input(invalid).is_err());

        let mut invalid = input();
        invalid.appearance_config = json!({"palette": 1});
        assert!(normalize_input(invalid).is_err());
    }

    #[test]
    fn rejects_duplicate_and_overlong_label_selection() {
        let mut duplicate = input();
        duplicate.self_descriptions = vec!["slow_to_warm".to_string(); 2];
        assert!(normalize_input(duplicate).is_err());

        let mut too_many = input();
        too_many.self_descriptions = vec![
            "slow_to_warm".to_string(),
            "business_only".to_string(),
            "meetup_friendly".to_string(),
            "casual_chat".to_string(),
        ];
        assert!(normalize_input(too_many).is_err());
    }
}
