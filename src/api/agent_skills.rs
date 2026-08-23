//! User-importable companion skills (小昌技能).
//!
//! A skill is a named instruction module: `{name, instructions, chip_label,
//! enabled}`. Enabled skills are injected into every turn's memory context
//! below custom instructions; `chip_label` optionally surfaces a quick
//! suggestion chip. Import = POST the parsed JSON array.

use axum::extract::{Path, State};
use axum::response::Response;
use axum::Json;
use serde::Deserialize;
use uuid::Uuid;

use crate::api::agent_plans::no_store_json;
use crate::api::error::ApiError;
use crate::api::session::VerifiedTenant;
use crate::api::AppState;
use crate::services::agent_memory::AgentMemoryService;

#[derive(Debug, Deserialize)]
pub struct UpsertSkillRequest {
    pub name: String,
    pub instructions: String,
    pub chip_label: Option<String>,
    #[serde(default = "default_true")]
    pub enabled: bool,
    pub sort_order: Option<i32>,
}

fn default_true() -> bool {
    true
}

impl UpsertSkillRequest {
    fn normalized(mut self) -> Result<Self, ApiError> {
        self.name = self.name.trim().to_string();
        self.instructions = self.instructions.trim().to_string();
        self.chip_label = self
            .chip_label
            .map(|c| c.trim().to_string())
            .filter(|c| !c.is_empty());
        if self.name.is_empty() || self.instructions.is_empty() {
            return Err(ApiError::BadRequest("技能名称与指令均不能为空".into()));
        }
        if self.name.chars().count() > 60 {
            return Err(ApiError::BadRequest("技能名称过长（≤60 字）".into()));
        }
        if self.instructions.chars().count() > 4000 {
            return Err(ApiError::BadRequest("技能指令过长（≤4000 字）".into()));
        }
        Ok(self)
    }
}

/// GET /api/agent/skills — list the caller's skills (creation order).
pub async fn list_skills(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
) -> Result<Response, ApiError> {
    let service = AgentMemoryService::new(state.infra.db.clone());
    let skills = service
        .list_skills(&tenant.session.user_id)
        .await
        .map_err(ApiError::Internal)?;
    Ok(no_store_json(serde_json::json!({ "skills": skills })))
}

/// POST /api/agent/skills — create or update-by-name a single skill.
pub async fn upsert_skill(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Json(input): Json<UpsertSkillRequest>,
) -> Result<Response, ApiError> {
    let input = input.normalized()?;
    let service = AgentMemoryService::new(state.infra.db.clone());
    let skill = service
        .upsert_skill(&tenant.session.user_id, &input)
        .await
        .map_err(ApiError::Internal)?;
    Ok(no_store_json(serde_json::json!({ "skill": skill })))
}

/// PATCH /api/agent/skills/{id} — toggle enabled or edit fields.
#[derive(Debug, Deserialize, Default)]
pub struct PatchSkillRequest {
    pub instructions: Option<String>,
    pub chip_label: Option<Option<String>>,
    pub enabled: Option<bool>,
    pub sort_order: Option<i32>,
}

pub async fn patch_skill(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(id): Path<Uuid>,
    Json(input): Json<PatchSkillRequest>,
) -> Result<Response, ApiError> {
    let service = AgentMemoryService::new(state.infra.db.clone());
    let skill = service
        .patch_skill(&tenant.session.user_id, id, &input)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::NotFound)?;
    Ok(no_store_json(serde_json::json!({ "skill": skill })))
}

/// DELETE /api/agent/skills/{id}
pub async fn delete_skill(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(id): Path<Uuid>,
) -> Result<Response, ApiError> {
    let service = AgentMemoryService::new(state.infra.db.clone());
    let deleted = service
        .delete_skill(&tenant.session.user_id, id)
        .await
        .map_err(ApiError::Internal)?;
    if !deleted {
        return Err(ApiError::NotFound);
    }
    Ok(no_store_json(serde_json::json!({ "deleted": true })))
}

/// DELETE /api/agent/skills — remove every skill for the caller.
pub async fn clear_skills(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
) -> Result<Response, ApiError> {
    let service = AgentMemoryService::new(state.infra.db.clone());
    let cleared = service
        .clear_skills(&tenant.session.user_id)
        .await
        .map_err(ApiError::Internal)?;
    Ok(no_store_json(serde_json::json!({ "cleared": cleared })))
}
