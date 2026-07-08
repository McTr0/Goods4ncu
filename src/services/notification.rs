use anyhow::Result;
use serde::Serialize;
use sqlx::{PgPool, Row};
use std::sync::Arc;
use uuid::Uuid;

/// In-app notification for users (e.g., "a buyer purchased your item").
#[derive(Debug, Clone, Serialize)]
pub struct Notification {
    pub id: String,
    pub user_id: String,
    pub event_type: String,
    pub title: String,
    pub body: String,
    pub related_order_id: Option<String>,
    pub related_listing_id: Option<String>,
    pub related_conversation_id: Option<String>,
    pub is_read: bool,
    pub created_at: String,
}

/// Callback for real-time push after a notification is persisted.
/// Receives (user_id, json_payload). Set at construction time in AppState.
pub type NotificationBroadcast = Arc<dyn Fn(String, String) + Send + Sync>;

#[derive(Clone)]
pub struct NotificationService {
    db: PgPool,
    /// Optional WebSocket broadcast callback. Set by AppState wiring in main.rs.
    broadcast: NotificationBroadcast,
}

impl NotificationService {
    pub fn new(db: PgPool) -> Self {
        Self {
            db,
            broadcast: Arc::new(|_, _| {}),
        }
    }

    /// Set the WebSocket broadcast callback. Called after each successful insert.
    pub fn with_broadcast(mut self, broadcast: NotificationBroadcast) -> Self {
        self.broadcast = broadcast;
        self
    }

    /// Create a notification for a user.
    pub async fn create(
        &self,
        user_id: &str,
        event_type: &str,
        title: &str,
        body: &str,
        related_order_id: Option<&str>,
        related_listing_id: Option<&str>,
    ) -> Result<String> {
        self.create_internal(
            user_id,
            event_type,
            title,
            body,
            related_order_id,
            related_listing_id,
            None,
        )
        .await
    }

    pub async fn create_for_conversation(
        &self,
        user_id: &str,
        event_type: &str,
        title: &str,
        body: &str,
        related_listing_id: Option<&str>,
        related_conversation_id: &str,
    ) -> Result<String> {
        self.create_internal(
            user_id,
            event_type,
            title,
            body,
            None,
            related_listing_id,
            Some(related_conversation_id),
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    async fn create_internal(
        &self,
        user_id: &str,
        event_type: &str,
        title: &str,
        body: &str,
        related_order_id: Option<&str>,
        related_listing_id: Option<&str>,
        related_conversation_id: Option<&str>,
    ) -> Result<String> {
        let id = Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO notifications (
                id, user_id, event_type, title, body, related_order_id,
                related_listing_id, related_conversation_id
             ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8::uuid)",
        )
        .bind(&id)
        .bind(user_id)
        .bind(event_type)
        .bind(title)
        .bind(body)
        .bind(related_order_id)
        .bind(related_listing_id)
        .bind(related_conversation_id)
        .execute(&self.db)
        .await?;

        // WebSocket push: fire-and-forget, non-blocking.
        let payload = serde_json::json!({
            "id": id,
            "event_type": event_type,
            "title": title,
            "body": body,
            "related_listing_id": related_listing_id,
            "related_conversation_id": related_conversation_id,
        })
        .to_string();
        (self.broadcast)(user_id.to_string(), payload);

        Ok(id)
    }

    /// List all notifications for a user (read + unread, most recent first).
    pub async fn list_all(
        &self,
        user_id: &str,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<Notification>, i64)> {
        let count_row = sqlx::query("SELECT COUNT(*) as cnt FROM notifications WHERE user_id = $1")
            .bind(user_id)
            .fetch_one(&self.db)
            .await?;
        let total: i64 = count_row.try_get("cnt").unwrap_or(0);

        let rows = sqlx::query(
            r#"SELECT id, user_id, event_type, title, body, related_order_id,
                      related_listing_id, related_conversation_id, is_read, created_at
               FROM notifications
               WHERE user_id = $1
               ORDER BY created_at DESC
               LIMIT $2 OFFSET $3"#,
        )
        .bind(user_id)
        .bind(limit)
        .bind(offset)
        .fetch_all(&self.db)
        .await?;

        let notifications = rows
            .into_iter()
            .map(|row| {
                let created_at: String = row
                    .try_get::<sqlx::types::chrono::DateTime<sqlx::types::chrono::Utc>, _>(
                        "created_at",
                    )
                    .map(|dt| dt.to_rfc3339())
                    .unwrap_or_default();
                Notification {
                    id: row.get("id"),
                    user_id: row.get("user_id"),
                    event_type: row.get("event_type"),
                    title: row.get("title"),
                    body: row.get("body"),
                    related_order_id: row.try_get("related_order_id").ok(),
                    related_listing_id: row.try_get("related_listing_id").ok(),
                    related_conversation_id: row
                        .try_get::<Option<uuid::Uuid>, _>("related_conversation_id")
                        .ok()
                        .flatten()
                        .map(|value| value.to_string()),
                    is_read: row.get("is_read"),
                    created_at,
                }
            })
            .collect();

        Ok((notifications, total))
    }

    /// List unread notifications for a user (most recent first).
    pub async fn list_unread(
        &self,
        user_id: &str,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<Notification>, i64)> {
        let count_row = sqlx::query(
            "SELECT COUNT(*) as cnt FROM notifications WHERE user_id = $1 AND is_read = FALSE",
        )
        .bind(user_id)
        .fetch_one(&self.db)
        .await?;
        let total: i64 = count_row.try_get("cnt").unwrap_or(0);

        let rows = sqlx::query(
            r#"SELECT id, user_id, event_type, title, body, related_order_id,
                      related_listing_id, related_conversation_id, is_read, created_at
               FROM notifications
               WHERE user_id = $1 AND is_read = FALSE
               ORDER BY created_at DESC
               LIMIT $2 OFFSET $3"#,
        )
        .bind(user_id)
        .bind(limit)
        .bind(offset)
        .fetch_all(&self.db)
        .await?;

        let notifications = rows
            .into_iter()
            .map(|row| {
                let created_at: String = row
                    .try_get::<sqlx::types::chrono::DateTime<sqlx::types::chrono::Utc>, _>(
                        "created_at",
                    )
                    .map(|dt| dt.to_rfc3339())
                    .unwrap_or_default();
                Notification {
                    id: row.get("id"),
                    user_id: row.get("user_id"),
                    event_type: row.get("event_type"),
                    title: row.get("title"),
                    body: row.get("body"),
                    related_order_id: row.try_get("related_order_id").ok(),
                    related_listing_id: row.try_get("related_listing_id").ok(),
                    related_conversation_id: row
                        .try_get::<Option<uuid::Uuid>, _>("related_conversation_id")
                        .ok()
                        .flatten()
                        .map(|value| value.to_string()),
                    is_read: row.get("is_read"),
                    created_at,
                }
            })
            .collect();

        Ok((notifications, total))
    }

    /// Mark a notification as read (only if it belongs to the user).
    pub async fn mark_read(&self, notification_id: &str, user_id: &str) -> Result<bool> {
        let result = sqlx::query(
            "UPDATE notifications SET is_read = TRUE WHERE id = $1 AND user_id = $2 RETURNING id",
        )
        .bind(notification_id)
        .bind(user_id)
        .fetch_optional(&self.db)
        .await?;
        Ok(result.is_some())
    }

    /// Mark all unread notifications as read for a user.
    pub async fn mark_all_read(&self, user_id: &str) -> Result<u64> {
        let result = sqlx::query(
            "UPDATE notifications SET is_read = TRUE WHERE user_id = $1 AND is_read = FALSE",
        )
        .bind(user_id)
        .execute(&self.db)
        .await?;
        Ok(result.rows_affected())
    }

    /// Count unread notifications for a user.
    pub async fn count_unread(&self, user_id: &str) -> Result<i64> {
        let row = sqlx::query(
            "SELECT COUNT(*) as cnt FROM notifications WHERE user_id = $1 AND is_read = FALSE",
        )
        .bind(user_id)
        .fetch_one(&self.db)
        .await?;
        Ok(row.try_get("cnt").unwrap_or(0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_notification_service_clone() {
        fn assert_clone<T: Clone>() {}
        assert_clone::<NotificationService>();
    }
}
