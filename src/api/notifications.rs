use axum::{
    extract::{Path, Query, State},
    Json,
};
use serde::{Deserialize, Serialize};

use crate::api::error::ApiError;
use crate::api::session::Session;
use crate::api::AppState;
use crate::services::campus::CampusService;

#[derive(Deserialize)]
pub struct NotificationQuery {
    pub limit: Option<i64>,
    pub offset: Option<i64>,
    /// If true, returns all notifications (read + unread). Defaults to false (unread only).
    pub include_read: Option<bool>,
}

#[derive(Serialize)]
pub struct NotificationItem {
    pub id: String,
    pub campus_id: uuid::Uuid,
    pub event_type: String,
    pub title: String,
    pub body: String,
    pub related_order_id: Option<String>,
    pub related_listing_id: Option<String>,
    pub is_read: bool,
    pub created_at: String,
}

#[derive(Serialize)]
pub struct NotificationResponse {
    pub items: Vec<NotificationItem>,
    pub total: i64,
    pub unread_count: i64,
    pub limit: i64,
    pub offset: i64,
}

/// GET /api/notifications — list notifications for the authenticated user.
/// By default returns only unread. Use ?include_read=true to get all history.
pub async fn get_notifications(
    State(state): State<AppState>,
    Session(session): Session,
    Query(query): Query<NotificationQuery>,
) -> Result<Json<NotificationResponse>, ApiError> {
    let campus_id = CampusService::new(state.infra.db.clone())
        .resolve_session_campus(&session.user_id, session.campus_id)
        .await?;

    let limit = query.limit.unwrap_or(20).min(100);
    let offset = query.offset.unwrap_or(0);
    let include_read = query.include_read.unwrap_or(false);

    let unread_count = state
        .infra
        .notification
        .count_unread(&session.user_id, campus_id)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    let (notifications, total) = if include_read {
        state
            .infra
            .notification
            .list_all(&session.user_id, campus_id, limit, offset)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
    } else {
        state
            .infra
            .notification
            .list_unread(&session.user_id, campus_id, limit, offset)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?
    };

    let items: Vec<NotificationItem> = notifications
        .into_iter()
        .map(|n| NotificationItem {
            id: n.id,
            campus_id: n.campus_id,
            event_type: n.event_type,
            title: n.title,
            body: n.body,
            related_order_id: n.related_order_id,
            related_listing_id: n.related_listing_id,
            is_read: n.is_read,
            created_at: n.created_at,
        })
        .collect();

    Ok(Json(NotificationResponse {
        items,
        total,
        unread_count,
        limit,
        offset,
    }))
}

/// POST /api/notifications/{id}/read — mark a single notification as read.
pub async fn mark_notification_read(
    State(state): State<AppState>,
    Session(session): Session,
    Path(notification_id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let campus_id = CampusService::new(state.infra.db.clone())
        .resolve_session_campus(&session.user_id, session.campus_id)
        .await?;

    let marked = state
        .infra
        .notification
        .mark_read(&notification_id, &session.user_id, campus_id)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    if !marked {
        return Err(ApiError::NotFound);
    }

    Ok(Json(serde_json::json!({ "ok": true })))
}

/// POST /api/notifications/read-all — mark all unread notifications as read.
pub async fn mark_all_notifications_read(
    State(state): State<AppState>,
    Session(session): Session,
) -> Result<Json<serde_json::Value>, ApiError> {
    let campus_id = CampusService::new(state.infra.db.clone())
        .resolve_session_campus(&session.user_id, session.campus_id)
        .await?;

    let count = state
        .infra
        .notification
        .mark_all_read(&session.user_id, campus_id)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("DB error: {}", e)))?;

    Ok(Json(
        serde_json::json!({ "ok": true, "marked_count": count }),
    ))
}
