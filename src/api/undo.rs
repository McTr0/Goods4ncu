//! Undo endpoints for immediately-executed (L2) agent actions.
//!
//! The counterpart to [`agent_plans`](crate::api::agent_plans): where that
//! module gates money and identity behind an up-front confirmation, this one
//! lets ordinary writes happen at once and stay recoverable. Authorisation is
//! the caller's own session — an action is undoable only by the person who
//! took it — so there is no undo secret to mint, hand out, or leak into model
//! context, and no agent tool can reach these routes.

use axum::{
    extract::{Path, State},
    Json,
};
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::api::session::Session;
use crate::api::AppState;
use crate::services::undo::{UndoOutcome, UndoService};

/// GET /api/actions/undoable — actions the caller can still undo.
pub async fn list_undoable(
    State(state): State<AppState>,
    Session(session): Session,
) -> Result<Json<serde_json::Value>, ApiError> {
    let items = UndoService::new(state.infra.db.clone())
        .list_undoable(&session.user_id)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(serde_json::json!({ "items": items })))
}

/// POST /api/actions/{id}/undo — revert an action inside its window.
pub async fn undo_action(
    State(state): State<AppState>,
    Session(session): Session,
    Path(action_id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let outcome = UndoService::new(state.infra.db.clone())
        .undo(&session.user_id, action_id)
        .await
        .map_err(ApiError::Internal)?;

    match outcome {
        UndoOutcome::Undone(result) => Ok(Json(serde_json::json!({
            "status": "undone",
            "result": result,
        }))),
        // Repeat undos answer identically to the first: the caller pressed the
        // button twice, which is not an error condition.
        UndoOutcome::AlreadyUndone(result) => Ok(Json(serde_json::json!({
            "status": "undone",
            "result": result,
        }))),
        UndoOutcome::Expired => Err(ApiError::Conflict(
            "撤销时限已过，这个操作不能再撤销了".to_string(),
        )),
        // Not an error the user caused — the world moved on. Say what happened
        // rather than overwriting whatever changed.
        UndoOutcome::Conflict(reason) => Err(ApiError::Conflict(reason)),
        UndoOutcome::Failed(message) => Err(ApiError::Conflict(format!("撤销失败：{}", message))),
        UndoOutcome::NotFound => Err(ApiError::NotFound),
    }
}
