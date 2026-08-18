//! API endpoints for User Agent Profile and Hierarchical Memory management.
//!
//! Provides transparent, user-controlled memory and personalization endpoints:
//! - GET  /api/agent/profile     — retrieve user's agent settings & preferences
//! - PUT  /api/agent/profile     — update user's agent settings & preferences
//! - GET  /api/agent/memories    — list stored episodic memories
//! - POST /api/agent/memories    — manually add a preference or memory note
//! - DELETE /api/agent/memories/:id — delete a specific memory item
//! - DELETE /api/agent/memories     — clear all stored memories

use axum::extract::{Path, Query, State};
use axum::response::Response;
use axum::Json;
use serde::Deserialize;
use uuid::Uuid;

use crate::api::agent_plans::no_store_json;
use crate::api::error::ApiError;
use crate::api::session::VerifiedTenant;
use crate::api::AppState;
use crate::services::agent_memory::{AgentMemoryService, UpdateProfileInput};

#[derive(Debug, Deserialize)]
pub struct MemoryListQuery {
    pub memory_type: Option<String>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

#[derive(Debug, Deserialize)]
pub struct CreateMemoryRequest {
    pub memory_type: Option<String>,
    pub content: String,
}

/// GET /api/agent/profile — get user's assistant profile & preferences
pub async fn get_profile(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
) -> Result<Response, ApiError> {
    let service = AgentMemoryService::new(state.infra.db.clone());
    let profile = service
        .get_or_create_profile(&tenant.session.user_id, tenant.campus_id)
        .await
        .map_err(ApiError::Internal)?;

    Ok(no_store_json(serde_json::json!({ "profile": profile })))
}

/// PUT /api/agent/profile — update user's assistant profile & preferences
pub async fn update_profile(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Json(input): Json<UpdateProfileInput>,
) -> Result<Response, ApiError> {
    let service = AgentMemoryService::new(state.infra.db.clone());
    let profile = service
        .update_profile(&tenant.session.user_id, tenant.campus_id, input)
        .await
        .map_err(ApiError::Internal)?;

    Ok(no_store_json(serde_json::json!({ "profile": profile })))
}

/// GET /api/agent/memories — list user's memories
pub async fn list_memories(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Query(query): Query<MemoryListQuery>,
) -> Result<Response, ApiError> {
    let service = AgentMemoryService::new(state.infra.db.clone());
    let limit = query.limit.unwrap_or(20).clamp(1, 100);
    let offset = query.offset.unwrap_or(0).max(0);

    let (memories, total) = service
        .list_memories(
            &tenant.session.user_id,
            query.memory_type.as_deref(),
            limit,
            offset,
        )
        .await
        .map_err(ApiError::Internal)?;

    Ok(no_store_json(serde_json::json!({
        "memories": memories,
        "total": total,
        "limit": limit,
        "offset": offset
    })))
}

/// POST /api/agent/memories — add a custom memory note
pub async fn create_memory(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Json(req): Json<CreateMemoryRequest>,
) -> Result<Response, ApiError> {
    let content = req.content.trim();
    if content.is_empty() {
        return Err(ApiError::BadRequest(
            "Memory content cannot be empty".into(),
        ));
    }

    let service = AgentMemoryService::new(state.infra.db.clone());
    let memory_type = req.memory_type.as_deref().unwrap_or("custom_note");

    let embedder = state.agents.llm_provider.clone().embedding_generator();

    let memory = service
        .add_memory(
            crate::services::agent_memory::CreateMemoryInput {
                user_id: &tenant.session.user_id,
                campus_id: tenant.campus_id,
                memory_type,
                content,
                source_ref: Some("manual_user_entry"),
                confidence: 1.0,
            },
            Some(&embedder),
        )
        .await
        .map_err(ApiError::Internal)?;

    Ok(no_store_json(serde_json::json!({ "memory": memory })))
}

/// DELETE /api/agent/memories/:id — delete a specific memory item
pub async fn delete_memory(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
    Path(memory_id): Path<Uuid>,
) -> Result<Response, ApiError> {
    let service = AgentMemoryService::new(state.infra.db.clone());
    let deleted = service
        .delete_memory(&tenant.session.user_id, memory_id)
        .await
        .map_err(ApiError::Internal)?;

    if !deleted {
        return Err(ApiError::NotFound);
    }

    Ok(no_store_json(serde_json::json!({ "deleted": true })))
}

/// DELETE /api/agent/memories — clear all memories for the user
pub async fn clear_memories(
    State(state): State<AppState>,
    tenant: VerifiedTenant,
) -> Result<Response, ApiError> {
    let service = AgentMemoryService::new(state.infra.db.clone());
    let count = service
        .clear_all_memories(&tenant.session.user_id)
        .await
        .map_err(ApiError::Internal)?;

    Ok(no_store_json(serde_json::json!({
        "cleared": true,
        "count": count
    })))
}
