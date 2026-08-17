use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sqlx::{PgPool, Postgres, Row, Transaction};
use std::collections::{BTreeMap, HashSet};
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
const APPEARANCE_KEYS: &[&str] = &["palette", "silhouette", "accessory", "outfit", "character"];
const PALETTES: &[&str] = &["teal", "plum", "sun", "slate"];
const SILHOUETTES: &[&str] = &["soft", "round", "sharp"];
const ACCESSORIES: &[&str] = &["none", "glasses", "headphones", "leaf"];
const OUTFITS: &[&str] = &["campus", "workwear", "casual", "lab"];
const CHARACTERS: &[&str] = &["classic", "ncu_gugugaga", "ncu_doro"];

/// The only persona choices exposed to clients.  These values are deliberately
/// compiled into the server contract: a client can select a catalog token, but
/// it cannot upload a role/skin, provide an arbitrary URL, or submit a prompt
/// that becomes a public identity asset.
#[derive(Debug, Clone, Serialize)]
pub struct SocialPersonaCatalogView {
    pub style_version: String,
    pub representation_modes: Vec<String>,
    pub appearance: BTreeMap<String, Vec<String>>,
    pub self_descriptions: Vec<String>,
    pub contact_postures: Vec<String>,
}

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
    pub selected_asset_id: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize)]
#[allow(dead_code)]
pub struct SocialPersonaAssetView {
    pub id: String,
    pub persona_id: String,
    pub asset_type: String,
    pub declared_mime_type: String,
    pub declared_size_bytes: i64,
    pub uploaded_size_bytes: Option<i64>,
    pub uploaded_mime_type: Option<String>,
    pub storage_verified_at: Option<String>,
    pub moderation_status: String,
    pub status: String,
    pub reject_reason: Option<String>,
    /// Present only in the owner's private response while the client uploads.
    pub upload_key: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[allow(dead_code)]
pub struct PublicSocialPersonaAssetView {
    pub id: String,
    pub asset_type: String,
    #[serde(default)]
    pub url: Option<String>,
    /// Internal projection field. It is populated by the SQL read and removed
    /// by serde before a public response is serialized. The API decorates it
    /// into a short-lived platform URL when storage is configured.
    #[serde(skip_serializing)]
    pub storage_key: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PublicSocialPersonaView {
    pub representation_mode: String,
    pub style_version: String,
    pub appearance_config: Value,
    pub self_descriptions: Vec<String>,
    pub contact_posture: String,
    pub published_at: String,
    pub asset: Option<PublicSocialPersonaAssetView>,
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

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct CreateSocialPersonaAssetInput {
    pub asset_type: String,
    pub declared_mime_type: String,
    pub declared_size_bytes: i64,
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct CompleteSocialPersonaAssetInput {
    pub uploaded_size_bytes: i64,
    pub uploaded_mime_type: String,
    pub moderation_required: bool,
}

#[derive(Clone)]
pub struct SocialPersonaService {
    pool: PgPool,
}

#[allow(dead_code)]
impl SocialPersonaService {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Return the server-owned catalog used by the persona editor.  Keeping
    /// the catalog beside the validator makes the UI discoverable while the
    /// write path remains authoritative when an older client sends a value.
    pub fn catalog() -> SocialPersonaCatalogView {
        let mut appearance = BTreeMap::new();
        appearance.insert(
            "palette".to_string(),
            PALETTES.iter().map(|value| (*value).to_string()).collect(),
        );
        appearance.insert(
            "silhouette".to_string(),
            SILHOUETTES
                .iter()
                .map(|value| (*value).to_string())
                .collect(),
        );
        appearance.insert(
            "accessory".to_string(),
            ACCESSORIES
                .iter()
                .map(|value| (*value).to_string())
                .collect(),
        );
        appearance.insert(
            "outfit".to_string(),
            OUTFITS.iter().map(|value| (*value).to_string()).collect(),
        );
        appearance.insert(
            "character".to_string(),
            CHARACTERS
                .iter()
                .map(|value| (*value).to_string())
                .collect(),
        );
        SocialPersonaCatalogView {
            style_version: SOCIAL_PERSONA_STYLE_VERSION.to_string(),
            representation_modes: REPRESENTATION_MODES
                .iter()
                .map(|value| (*value).to_string())
                .collect(),
            appearance,
            self_descriptions: SELF_DESCRIPTION_CODES
                .iter()
                .map(|value| (*value).to_string())
                .collect(),
            contact_postures: CONTACT_POSTURES
                .iter()
                .map(|value| (*value).to_string())
                .collect(),
        }
    }

    pub async fn get_for_user(
        &self,
        user_id: &str,
        campus_id: Uuid,
    ) -> Result<Option<SocialPersonaView>, ApiError> {
        let row = self.load_row(user_id, campus_id).await?;
        Ok(row.map(|row| row_to_view(&row)))
    }

    pub async fn list_assets(
        &self,
        user_id: &str,
        campus_id: Uuid,
    ) -> Result<Vec<SocialPersonaAssetView>, ApiError> {
        let rows = sqlx::query(
            r#"
            SELECT id, persona_id, asset_type, declared_mime_type,
                   declared_size_bytes, uploaded_size_bytes, uploaded_mime_type,
                   storage_verified_at, moderation_status, status, reject_reason,
                   storage_key, created_at, updated_at
            FROM social_persona_assets
            WHERE user_id = $1 AND campus_id = $2
            ORDER BY created_at DESC, id DESC
            LIMIT 20
            "#,
        )
        .bind(user_id)
        .bind(campus_id)
        .fetch_all(&self.pool)
        .await
        .map_err(db_error)?;
        Ok(rows.into_iter().map(asset_row_to_view).collect())
    }

    pub async fn get_asset(
        &self,
        user_id: &str,
        campus_id: Uuid,
        asset_id: Uuid,
    ) -> Result<SocialPersonaAssetView, ApiError> {
        let row = sqlx::query(
            r#"
            SELECT id, persona_id, asset_type, declared_mime_type,
                   declared_size_bytes, uploaded_size_bytes, uploaded_mime_type,
                   storage_verified_at, moderation_status, status, reject_reason,
                   storage_key, created_at, updated_at
            FROM social_persona_assets
            WHERE id = $1 AND user_id = $2 AND campus_id = $3
            "#,
        )
        .bind(asset_id)
        .bind(user_id)
        .bind(campus_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::NotFound)?;
        Ok(asset_row_to_view(row))
    }

    pub async fn create_asset(
        &self,
        user_id: &str,
        campus_id: Uuid,
        input: CreateSocialPersonaAssetInput,
    ) -> Result<SocialPersonaAssetView, ApiError> {
        let asset_type = normalize_asset_type(&input.asset_type)?;
        let mime_type = normalize_asset_mime_type(&input.declared_mime_type)?;
        validate_asset_size(input.declared_size_bytes)?;

        let mut tx = self.pool.begin().await.map_err(db_error)?;
        let persona_id = sqlx::query_scalar::<_, Uuid>(
            "SELECT id FROM social_personas
             WHERE user_id = $1 AND campus_id = $2 FOR UPDATE",
        )
        .bind(user_id)
        .bind(campus_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::NotFound)?;
        let asset_id = Uuid::new_v4();
        let storage_key = format!("persona/{campus_id}/{persona_id}/{asset_id}");
        let row = sqlx::query(
            r#"
            INSERT INTO social_persona_assets (
                id, persona_id, user_id, campus_id, asset_type, storage_key,
                declared_mime_type, declared_size_bytes
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
            RETURNING id, persona_id, asset_type, declared_mime_type,
                      declared_size_bytes, uploaded_size_bytes, uploaded_mime_type,
                      storage_verified_at, moderation_status, status, reject_reason,
                      storage_key, created_at, updated_at
            "#,
        )
        .bind(asset_id)
        .bind(persona_id)
        .bind(user_id)
        .bind(campus_id)
        .bind(asset_type)
        .bind(&storage_key)
        .bind(mime_type)
        .bind(input.declared_size_bytes)
        .fetch_one(&mut *tx)
        .await
        .map_err(db_error)?;
        insert_asset_audit(
            &mut tx,
            persona_id,
            user_id,
            campus_id,
            "asset_created",
            &row,
        )
        .await?;
        tx.commit().await.map_err(db_error)?;
        Ok(asset_row_to_view(row))
    }

    pub async fn complete_asset(
        &self,
        user_id: &str,
        campus_id: Uuid,
        asset_id: Uuid,
        input: CompleteSocialPersonaAssetInput,
    ) -> Result<SocialPersonaAssetView, ApiError> {
        validate_asset_size(input.uploaded_size_bytes)?;
        let uploaded_mime_type = normalize_asset_mime_type(&input.uploaded_mime_type)?;
        let mut tx = self.pool.begin().await.map_err(db_error)?;
        let row = sqlx::query(
            r#"
            SELECT id, persona_id, asset_type, declared_mime_type,
                   declared_size_bytes, uploaded_size_bytes, uploaded_mime_type,
                   storage_verified_at, moderation_status, status, reject_reason,
                   storage_key, created_at, updated_at
            FROM social_persona_assets
            WHERE id = $1 AND user_id = $2 AND campus_id = $3
            FOR UPDATE
            "#,
        )
        .bind(asset_id)
        .bind(user_id)
        .bind(campus_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::NotFound)?;
        let current = asset_row_to_view(row);
        if current.status == "active" || current.status == "pending_review" {
            // A completion retry is idempotent once the server has recorded a
            // verified object. Do not re-probe or regress an in-flight review.
            if current.storage_verified_at.is_some() {
                tx.commit().await.map_err(db_error)?;
                return Ok(current);
            }
        }
        if current.status != "pending_upload" {
            return Err(ApiError::Conflict("角色图片当前不可完成上传".to_string()));
        }
        if current.declared_size_bytes != input.uploaded_size_bytes {
            return Err(ApiError::CodedConflict {
                code: "persona_asset_size_mismatch",
                message: "上传图片大小与声明不一致".to_string(),
            });
        }
        if current.declared_mime_type != uploaded_mime_type {
            return Err(ApiError::CodedConflict {
                code: "persona_asset_mime_mismatch",
                message: "上传图片类型与声明不一致".to_string(),
            });
        }
        let (status, moderation_status) = if input.moderation_required {
            ("pending_review", "pending")
        } else {
            ("active", "not_required")
        };
        let row = sqlx::query(
            r#"
            UPDATE social_persona_assets
            SET uploaded_size_bytes = $1,
                uploaded_mime_type = $2,
                storage_verified_at = NOW(),
                moderation_status = $3,
                status = $4,
                updated_at = NOW()
            WHERE id = $5 AND user_id = $6 AND campus_id = $7
            RETURNING id, persona_id, asset_type, declared_mime_type,
                      declared_size_bytes, uploaded_size_bytes, uploaded_mime_type,
                      storage_verified_at, moderation_status, status, reject_reason,
                      storage_key, created_at, updated_at
            "#,
        )
        .bind(input.uploaded_size_bytes)
        .bind(&uploaded_mime_type)
        .bind(moderation_status)
        .bind(status)
        .bind(asset_id)
        .bind(user_id)
        .bind(campus_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(db_error)?;
        tx.commit().await.map_err(db_error)?;
        Ok(asset_row_to_view(row))
    }

    pub async fn select_asset(
        &self,
        user_id: &str,
        campus_id: Uuid,
        asset_id: Uuid,
    ) -> Result<SocialPersonaView, ApiError> {
        let mut tx = self.pool.begin().await.map_err(db_error)?;
        let asset = sqlx::query(
            "SELECT persona_id, status, moderation_status, storage_verified_at
             FROM social_persona_assets
             WHERE id = $1 AND user_id = $2 AND campus_id = $3
             FOR UPDATE",
        )
        .bind(asset_id)
        .bind(user_id)
        .bind(campus_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::NotFound)?;
        let persona_id: Uuid = asset.get("persona_id");
        let status: String = asset.get("status");
        let moderation_status: String = asset.get("moderation_status");
        let verified: Option<DateTime<Utc>> = asset.get("storage_verified_at");
        if status != "active"
            || !matches!(moderation_status.as_str(), "approved" | "not_required")
            || verified.is_none()
        {
            return Err(ApiError::Conflict("角色图片尚未通过审核".to_string()));
        }
        let row = sqlx::query(
            r#"
            UPDATE social_personas
            SET selected_asset_id = $1,
                status = CASE WHEN status = 'published' THEN 'draft' ELSE status END,
                published_at = CASE WHEN status = 'published' THEN NULL ELSE published_at END,
                updated_at = NOW()
            WHERE id = $2 AND user_id = $3 AND campus_id = $4
            RETURNING id, user_id, campus_id, representation_mode, style_version,
                      appearance_config, self_descriptions, contact_posture,
                      status, published_at, selected_asset_id, created_at, updated_at
            "#,
        )
        .bind(asset_id)
        .bind(persona_id)
        .bind(user_id)
        .bind(campus_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::NotFound)?;
        let view = row_to_view(&row);
        insert_audit(&mut tx, &view, "edited").await?;
        tx.commit().await.map_err(db_error)?;
        Ok(view)
    }

    pub async fn revoke_asset(
        &self,
        user_id: &str,
        campus_id: Uuid,
        asset_id: Uuid,
    ) -> Result<SocialPersonaAssetView, ApiError> {
        let mut tx = self.pool.begin().await.map_err(db_error)?;
        let row = sqlx::query(
            r#"
            UPDATE social_persona_assets
            SET status = CASE WHEN status = 'deleted' THEN status ELSE 'revoked' END,
                revoked_at = COALESCE(revoked_at, NOW()),
                cleanup_requested_at = COALESCE(cleanup_requested_at, NOW()),
                cleanup_next_attempt_at = NULL,
                updated_at = NOW()
            WHERE id = $1 AND user_id = $2 AND campus_id = $3
            RETURNING id, persona_id, asset_type, declared_mime_type,
                      declared_size_bytes, uploaded_size_bytes, uploaded_mime_type,
                      storage_verified_at, moderation_status, status, reject_reason,
                      storage_key, created_at, updated_at
            "#,
        )
        .bind(asset_id)
        .bind(user_id)
        .bind(campus_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(db_error)?
        .ok_or(ApiError::NotFound)?;
        let persona_id: Uuid = row.get("persona_id");
        insert_asset_audit(
            &mut tx,
            persona_id,
            user_id,
            campus_id,
            "asset_revoked",
            &row,
        )
        .await?;
        let view = asset_row_to_view(row);
        sqlx::query(
            "UPDATE social_personas
             SET selected_asset_id = NULL,
                 status = CASE WHEN status = 'published' THEN 'draft' ELSE status END,
                 published_at = CASE WHEN status = 'published' THEN NULL ELSE published_at END,
                 updated_at = NOW()
             WHERE id = $1 AND user_id = $2 AND campus_id = $3
               AND selected_asset_id = $4",
        )
        .bind(
            Uuid::parse_str(&view.persona_id)
                .map_err(|_| ApiError::Internal(anyhow::anyhow!("invalid persona id")))?,
        )
        .bind(user_id)
        .bind(campus_id)
        .bind(asset_id)
        .execute(&mut *tx)
        .await
        .map_err(db_error)?;
        tx.commit().await.map_err(db_error)?;
        Ok(view)
    }

    pub async fn get_published_for_user(
        &self,
        user_id: &str,
        campus_id: Uuid,
    ) -> Result<Option<PublicSocialPersonaView>, ApiError> {
        let row = sqlx::query(
            r#"
            SELECT p.representation_mode, p.style_version, p.appearance_config,
                   p.self_descriptions, p.contact_posture, p.published_at,
                   NULL::json AS asset
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
            asset: row
                .try_get::<Option<Value>, _>("asset")
                .ok()
                .flatten()
                .and_then(|value| serde_json::from_value(value).ok()),
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
                selected_asset_id = NULL,
                status = 'draft',
                published_at = NULL,
                updated_at = NOW()
            RETURNING id, user_id, campus_id, representation_mode, style_version,
                      appearance_config, self_descriptions, contact_posture,
                      status, published_at, selected_asset_id, created_at, updated_at
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
            SET status = 'published',
                selected_asset_id = NULL,
                published_at = NOW(),
                updated_at = NOW()
            WHERE user_id = $1 AND campus_id = $2
            RETURNING id, user_id, campus_id, representation_mode, style_version,
                      appearance_config, self_descriptions, contact_posture,
                      status, published_at, selected_asset_id, created_at, updated_at
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
            SET status = 'archived',
                selected_asset_id = NULL,
                published_at = NULL,
                updated_at = NOW()
            WHERE user_id = $1 AND campus_id = $2
            RETURNING id, user_id, campus_id, representation_mode, style_version,
                      appearance_config, self_descriptions, contact_posture,
                      status, published_at, selected_asset_id, created_at, updated_at
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
                    status, published_at, selected_asset_id, created_at, updated_at
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

#[allow(dead_code)]
async fn insert_asset_audit(
    tx: &mut Transaction<'_, Postgres>,
    persona_id: Uuid,
    user_id: &str,
    campus_id: Uuid,
    action: &str,
    row: &sqlx::postgres::PgRow,
) -> Result<(), ApiError> {
    let snapshot = serde_json::json!({
        "asset_id": row.get::<Uuid, _>("id"),
        "asset_type": row.get::<String, _>("asset_type"),
        "status": row.get::<String, _>("status"),
        "moderation_status": row.get::<String, _>("moderation_status"),
    });
    sqlx::query(
        "INSERT INTO social_persona_audits
            (persona_id, user_id, campus_id, action, snapshot)
         VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(persona_id)
    .bind(user_id)
    .bind(campus_id)
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
        selected_asset_id: row
            .try_get::<Option<Uuid>, _>("selected_asset_id")
            .ok()
            .flatten()
            .map(|id| id.to_string()),
        created_at: format_timestamp(row.get("created_at")),
        updated_at: format_timestamp(row.get("updated_at")),
    }
}

#[allow(dead_code)]
fn asset_row_to_view(row: sqlx::postgres::PgRow) -> SocialPersonaAssetView {
    SocialPersonaAssetView {
        id: row.get::<Uuid, _>("id").to_string(),
        persona_id: row.get::<Uuid, _>("persona_id").to_string(),
        asset_type: row.get("asset_type"),
        declared_mime_type: row.get("declared_mime_type"),
        declared_size_bytes: row.get("declared_size_bytes"),
        uploaded_size_bytes: row.get("uploaded_size_bytes"),
        uploaded_mime_type: row.get("uploaded_mime_type"),
        storage_verified_at: format_optional_timestamp(row.get("storage_verified_at")),
        moderation_status: row.get("moderation_status"),
        status: row.get("status"),
        reject_reason: row.get("reject_reason"),
        upload_key: Some(row.get("storage_key")),
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

#[allow(dead_code)]
fn normalize_asset_type(value: &str) -> Result<String, ApiError> {
    let value = value.trim();
    if matches!(value, "illustration" | "photo_stylized") {
        Ok(value.to_string())
    } else {
        Err(ApiError::BadRequest("不支持的角色图片类型".to_string()))
    }
}

#[allow(dead_code)]
fn normalize_asset_mime_type(value: &str) -> Result<String, ApiError> {
    let value = value.trim().to_ascii_lowercase();
    if matches!(value.as_str(), "image/png" | "image/jpeg" | "image/webp") {
        Ok(value)
    } else {
        Err(ApiError::BadRequest(
            "角色图片类型必须是 PNG、JPEG 或 WebP".to_string(),
        ))
    }
}

/// Validate the small, non-ambiguous magic headers used by the supported
/// persona image formats. MIME metadata alone is not authoritative because a
/// direct object upload can lie about Content-Type.
#[allow(dead_code)]
pub fn image_header_matches(mime_type: &str, prefix: &[u8]) -> bool {
    match mime_type.trim().to_ascii_lowercase().as_str() {
        "image/png" => prefix.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]),
        "image/jpeg" => prefix.starts_with(&[0xFF, 0xD8, 0xFF]),
        "image/webp" => prefix.len() >= 12 && &prefix[0..4] == b"RIFF" && &prefix[8..12] == b"WEBP",
        _ => false,
    }
}

#[allow(dead_code)]
fn validate_asset_size(size_bytes: i64) -> Result<(), ApiError> {
    if (1..=10 * 1024 * 1024).contains(&size_bytes) {
        Ok(())
    } else {
        Err(ApiError::BadRequest(
            "角色图片大小必须在 1B 到 10MiB 之间".to_string(),
        ))
    }
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
    output.insert(
        "character".to_string(),
        Value::String(read_token(&input, "character", CHARACTERS, "classic")?),
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
        assert_eq!(normalized.appearance_config["character"], "classic");
    }

    #[test]
    fn catalog_is_system_owned_and_matches_the_write_allowlist() {
        let catalog = SocialPersonaService::catalog();
        assert_eq!(catalog.style_version, "v1");
        assert_eq!(
            catalog.representation_modes,
            vec!["trait_mapped".to_string(), "role_character".to_string()]
        );
        assert_eq!(
            catalog.appearance["palette"],
            vec![
                "teal".to_string(),
                "plum".to_string(),
                "sun".to_string(),
                "slate".to_string()
            ]
        );
        assert_eq!(
            catalog.appearance["outfit"],
            vec![
                "campus".to_string(),
                "workwear".to_string(),
                "casual".to_string(),
                "lab".to_string()
            ]
        );
        assert_eq!(
            catalog.appearance["character"],
            vec![
                "classic".to_string(),
                "ncu_gugugaga".to_string(),
                "ncu_doro".to_string()
            ]
        );
        assert!(!catalog.appearance.contains_key("image_url"));
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

        let mut invalid = input();
        invalid.appearance_config = json!({"character": "external_url"});
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

    #[test]
    fn image_headers_must_match_declared_mime() {
        assert!(image_header_matches(
            "image/png",
            &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]
        ));
        assert!(image_header_matches(
            "image/jpeg",
            &[0xFF, 0xD8, 0xFF, 0xE0]
        ));
        assert!(image_header_matches("image/webp", b"RIFF0000WEBPVP8 "));
        assert!(!image_header_matches("image/png", b"not an image"));
        assert!(!image_header_matches(
            "image/jpeg",
            &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]
        ));
    }
}
