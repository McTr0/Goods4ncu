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
    pub campus_id: Uuid,
    pub event_type: String,
    pub title: String,
    pub body: String,
    pub related_order_id: Option<String>,
    pub related_listing_id: Option<String>,
    pub related_conversation_id: Option<String>,
    pub is_read: bool,
    pub created_at: String,
}

#[derive(Debug, Clone, Copy)]
pub struct NewNotification<'a> {
    pub campus_id: Uuid,
    pub user_id: &'a str,
    pub event_type: &'a str,
    pub title: &'a str,
    pub body: &'a str,
    pub related_order_id: Option<&'a str>,
    pub related_listing_id: Option<&'a str>,
    pub related_conversation_id: Option<&'a str>,
}

/// Callback for real-time push. Still used by workers (HITL expiry) that
/// broadcast ephemeral events directly; persisted-notification push now flows
/// through the transactional outbox instead.
pub type NotificationBroadcast = Arc<dyn Fn(String, String) + Send + Sync>;

#[derive(Clone)]
pub struct NotificationService {
    db: PgPool,
}

impl NotificationService {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    /// Create a notification for a user.
    pub async fn create(&self, notification: NewNotification<'_>) -> Result<String> {
        let id = Uuid::new_v4().to_string();

        // Notification row and its push event commit atomically: either both
        // exist or neither does. Delivery itself happens from the outbox
        // worker, so a crash right after this commit cannot lose the push the
        // way the old fire-and-forget in-process broadcast could.
        let mut tx = self.db.begin().await?;
        sqlx::query(
            "INSERT INTO notifications (
                id, campus_id, user_id, event_type, title, body, related_order_id,
                related_listing_id, related_conversation_id
             ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::uuid)",
        )
        .bind(&id)
        .bind(notification.campus_id)
        .bind(notification.user_id)
        .bind(notification.event_type)
        .bind(notification.title)
        .bind(notification.body)
        .bind(notification.related_order_id)
        .bind(notification.related_listing_id)
        .bind(notification.related_conversation_id)
        .execute(&mut *tx)
        .await?;

        let push_payload = serde_json::json!({
            "user_id": notification.user_id,
            "message": {
                "id": id,
                "event_type": notification.event_type,
                "title": notification.title,
                "body": notification.body,
                "related_listing_id": notification.related_listing_id,
                "related_conversation_id": notification.related_conversation_id,
            },
        });
        crate::services::outbox::enqueue_in_tx(
            &mut tx,
            crate::services::outbox::TOPIC_NOTIFICATION_PUSH,
            &push_payload,
        )
        .await
        .map_err(|error| anyhow::anyhow!("enqueue notification push: {error}"))?;
        tx.commit().await?;

        Ok(id)
    }

    /// List all notifications for a user (read + unread, most recent first).
    pub async fn list_all(
        &self,
        user_id: &str,
        campus_id: Uuid,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<Notification>, i64)> {
        let count_row = sqlx::query(
            "SELECT COUNT(*) as cnt FROM notifications WHERE user_id = $1 AND campus_id = $2",
        )
        .bind(user_id)
        .bind(campus_id)
        .fetch_one(&self.db)
        .await?;
        let total: i64 = count_row.try_get("cnt").unwrap_or(0);

        let rows = sqlx::query(
            r#"SELECT id, campus_id, user_id, event_type, title, body, related_order_id,
                      related_listing_id, related_conversation_id, is_read, created_at
               FROM notifications
               WHERE user_id = $1 AND campus_id = $2
               ORDER BY created_at DESC
               LIMIT $3 OFFSET $4"#,
        )
        .bind(user_id)
        .bind(campus_id)
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
                    campus_id: row.get("campus_id"),
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
        campus_id: Uuid,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<Notification>, i64)> {
        let count_row = sqlx::query(
            "SELECT COUNT(*) as cnt FROM notifications
             WHERE user_id = $1 AND campus_id = $2 AND is_read = FALSE",
        )
        .bind(user_id)
        .bind(campus_id)
        .fetch_one(&self.db)
        .await?;
        let total: i64 = count_row.try_get("cnt").unwrap_or(0);

        let rows = sqlx::query(
            r#"SELECT id, campus_id, user_id, event_type, title, body, related_order_id,
                      related_listing_id, related_conversation_id, is_read, created_at
               FROM notifications
               WHERE user_id = $1 AND campus_id = $2 AND is_read = FALSE
               ORDER BY created_at DESC
               LIMIT $3 OFFSET $4"#,
        )
        .bind(user_id)
        .bind(campus_id)
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
                    campus_id: row.get("campus_id"),
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
    pub async fn mark_read(
        &self,
        notification_id: &str,
        user_id: &str,
        campus_id: Uuid,
    ) -> Result<bool> {
        let result = sqlx::query(
            "UPDATE notifications SET is_read = TRUE
             WHERE id = $1 AND user_id = $2 AND campus_id = $3
             RETURNING id",
        )
        .bind(notification_id)
        .bind(user_id)
        .bind(campus_id)
        .fetch_optional(&self.db)
        .await?;
        Ok(result.is_some())
    }

    /// Mark all unread notifications as read for a user.
    pub async fn mark_all_read(&self, user_id: &str, campus_id: Uuid) -> Result<u64> {
        let result = sqlx::query(
            "UPDATE notifications SET is_read = TRUE
             WHERE user_id = $1 AND campus_id = $2 AND is_read = FALSE",
        )
        .bind(user_id)
        .bind(campus_id)
        .execute(&self.db)
        .await?;
        Ok(result.rows_affected())
    }

    /// Count unread notifications for a user.
    pub async fn count_unread(&self, user_id: &str, campus_id: Uuid) -> Result<i64> {
        let row = sqlx::query(
            "SELECT COUNT(*) as cnt FROM notifications
             WHERE user_id = $1 AND campus_id = $2 AND is_read = FALSE",
        )
        .bind(user_id)
        .bind(campus_id)
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
