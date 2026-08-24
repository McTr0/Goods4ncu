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
use crate::services::agent_memory::{AgentMemoryService, AgentSkillRow};

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

/// Hard caps so imported skills can never blow up the per-turn prompt:
/// at most this many skills per user...
pub const MAX_SKILLS_PER_USER: usize = 20;
/// ...and at most this many characters of *enabled* instructions in total.
pub const MAX_ENABLED_PROMPT_CHARS: usize = 10_000;

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

fn validate_instructions(raw: &str) -> Result<String, ApiError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(ApiError::BadRequest("技能指令不能为空".into()));
    }
    if trimmed.chars().count() > 4000 {
        return Err(ApiError::BadRequest("技能指令过长（≤4000 字）".into()));
    }
    Ok(trimmed.to_string())
}

/// Projected enabled-instruction chars after applying a PATCH: current total,
/// minus the row being edited, plus its new content when it stays enabled.
fn projected_enabled_chars(skills: &[AgentSkillRow], edited_id: Uuid, new_chars: usize) -> usize {
    skills
        .iter()
        .filter(|s| s.enabled && s.id != edited_id)
        .map(|s| s.instructions.chars().count())
        .sum::<usize>()
        + new_chars
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
    let existing = service
        .list_skills(&tenant.session.user_id)
        .await
        .map_err(ApiError::Internal)?;
    let is_new = !existing.iter().any(|s| s.name == input.name);
    if is_new {
        if existing.len() >= MAX_SKILLS_PER_USER {
            return Err(ApiError::BadRequest(format!(
                "技能数量已达上限（≤{MAX_SKILLS_PER_USER} 个）"
            )));
        }
        if input.enabled {
            let current: usize = existing
                .iter()
                .filter(|s| s.enabled)
                .map(|s| s.instructions.chars().count())
                .sum();
            if current + input.instructions.chars().count() > MAX_ENABLED_PROMPT_CHARS {
                return Err(ApiError::BadRequest(format!(
                    "启用技能总字数超限（≤{MAX_ENABLED_PROMPT_CHARS} 字），请精简或停用部分技能"
                )));
            }
        }
    }
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
    Json(mut input): Json<PatchSkillRequest>,
) -> Result<Response, ApiError> {
    if let Some(instructions) = input.instructions.as_deref() {
        let normalized = validate_instructions(instructions)?;
        input.instructions = Some(normalized);
    }
    if let Some(chip) = input.chip_label.as_mut() {
        *chip = chip
            .as_deref()
            .map(str::trim)
            .filter(|c| !c.is_empty())
            .map(str::to_string);
    }
    let service = AgentMemoryService::new(state.infra.db.clone());
    let all = service
        .list_skills(&tenant.session.user_id)
        .await
        .map_err(ApiError::Internal)?;
    let current = all.iter().find(|s| s.id == id).ok_or(ApiError::NotFound)?;
    let instructions = input
        .instructions
        .clone()
        .unwrap_or_else(|| current.instructions.clone());
    let enabled = input.enabled.unwrap_or(current.enabled);
    if enabled
        && projected_enabled_chars(&all, id, instructions.chars().count())
            > MAX_ENABLED_PROMPT_CHARS
    {
        return Err(ApiError::BadRequest(format!(
            "启用技能总字数超限（≤{MAX_ENABLED_PROMPT_CHARS} 字），请精简或停用部分技能"
        )));
    }
    let skill = service
        .patch_skill(&tenant.session.user_id, id, &input)
        .await
        .map_err(ApiError::Internal)?
        .ok_or(ApiError::NotFound)?;
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
