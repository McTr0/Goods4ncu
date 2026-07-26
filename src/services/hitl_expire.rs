//! HITL negotiation timeout background worker.
//!
//! Runs every 10 minutes and expires pending hitl_requests where:
//! - status = 'pending' (seller hasn't responded)
//! - expires_at < NOW() (48 hours have passed)
//!
//! On expiration:
//! 1. Updates status to 'expired' in DB
//! 2. Injects a system message into the conversation
//! 3. Notifies the buyer: "卖家超时未回应，本次议价已自动取消"

use crate::lifecycle::{tick_or_shutdown, ShutdownSignal};
use crate::services::notification::NotificationBroadcast;
use sqlx::{PgPool, Row};
use std::time::Duration;
use tokio::time::interval;
use uuid::Uuid;

/// Run the HITL expiration worker.
///
/// Stops between scans on shutdown rather than being aborted, so an in-progress
/// expiration transaction is never cut off partway through.
pub async fn run(db_pool: PgPool, broadcast: NotificationBroadcast, shutdown: ShutdownSignal) {
    tracing::info!("HITL expiration worker started (interval: 10 min)");
    let mut ticker = interval(Duration::from_secs(10 * 60));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    while tick_or_shutdown(&mut ticker, &shutdown)
        .await
        .should_continue()
    {
        if let Err(e) = expire_pending(&db_pool, &broadcast).await {
            tracing::error!(%e, "HITL expiration scan failed");
        }
    }

    tracing::info!("HITL expiration worker stopped");
}

/// Scan for and expire all pending hitl_requests past their expires_at.
/// Returns the number of records expired.
async fn expire_pending(
    db_pool: &PgPool,
    broadcast: &NotificationBroadcast,
) -> anyhow::Result<usize> {
    let mut tx = db_pool.begin().await?;
    let rows = sqlx::query(
        r#"
        WITH candidates AS (
            SELECT id
            FROM hitl_requests
            WHERE status = 'pending' AND expires_at < NOW()
            FOR UPDATE SKIP LOCKED
        )
        UPDATE hitl_requests h
        SET status = 'expired', resolved_at = NOW()
        FROM candidates
        WHERE h.id = candidates.id
        RETURNING h.id, h.campus_id, h.listing_id, h.buyer_id, h.seller_id
        "#,
    )
    .fetch_all(&mut *tx)
    .await?;

    if rows.is_empty() {
        tx.commit().await?;
        return Ok(0);
    }

    tracing::info!(
        count = rows.len(),
        "Found {} expired HITL requests to process",
        rows.len()
    );

    let mut expired = Vec::with_capacity(rows.len());
    for row in &rows {
        let id: String = row.get("id");
        let campus_id: Uuid = row.get("campus_id");
        let listing_id: String = row.get("listing_id");
        let buyer_id: String = row.get("buyer_id");
        let seller_id: String = row.get("seller_id");

        tracing::debug!(%id, "Expired HITL request");

        // Keep the status transition and timeline message in the same commit.
        let conversation_id = format!("negotiate:{}", listing_id);
        let system_content = "系统：卖家超时未回应（48小时内未处理），本次议价已自动取消";
        sqlx::query(
            r#"INSERT INTO chat_messages (conversation_id, sender, receiver, is_agent, content, listing_id)
               VALUES ($1, $2, $3, TRUE, $4, $5)"#,
        )
        .bind(&conversation_id)
        .bind(&seller_id)
        .bind(&buyer_id)
        .bind(system_content)
        .bind(&listing_id)
        .execute(&mut *tx)
        .await?;

        expired.push((id, campus_id, listing_id, buyer_id, seller_id));
    }

    tx.commit().await?;

    for (_id, campus_id, listing_id, buyer_id, seller_id) in &expired {
        // Notify buyer: seller didn't respond in time.
        let notification_id = Uuid::new_v4().to_string();
        let _ = sqlx::query(
            r#"INSERT INTO notifications (
                   id, campus_id, user_id, event_type, title, body, related_listing_id
               ) VALUES ($1, $2, $3, 'negotiation_expired', '议价已超时取消',
                         '卖家超时未回应（48小时内未处理），本次议价已自动取消', $4)"#,
        )
        .bind(&notification_id)
        .bind(campus_id)
        .bind(buyer_id)
        .bind(listing_id)
        .execute(db_pool)
        .await
        .map_err(|e| tracing::warn!(%e, "Failed to notify buyer of expiration"));

        // Push WebSocket notification to buyer immediately.
        let notif_payload = serde_json::json!({
            "id": notification_id,
            "event_type": "negotiation_expired",
            "title": "议价已超时取消",
            "body": "卖家超时未回应（48小时内未处理），本次议价已自动取消",
        });
        broadcast(buyer_id.to_string(), notif_payload.to_string());

        // Notify seller as well — they missed a negotiation request.
        let seller_notif_id = Uuid::new_v4().to_string();
        let _ = sqlx::query(
            r#"INSERT INTO notifications (
                   id, campus_id, user_id, event_type, title, body, related_listing_id
               ) VALUES ($1, $2, $3, 'negotiation_expired_seller', '议价超时未处理',
                         '您有一笔议价请求超时未处理，已自动取消', $4)"#,
        )
        .bind(&seller_notif_id)
        .bind(campus_id)
        .bind(seller_id)
        .bind(listing_id)
        .execute(db_pool)
        .await
        .map_err(|e| tracing::warn!(%e, "Failed to notify seller of expiration"));

        let seller_notif_payload = serde_json::json!({
            "id": seller_notif_id,
            "event_type": "negotiation_expired_seller",
            "title": "议价超时未处理",
            "body": "您有一笔议价请求超时未处理，已自动取消",
        });
        broadcast(seller_id.to_string(), seller_notif_payload.to_string());
    }

    let count = expired.len();
    tracing::info!(count, "Expired {} HITL negotiation requests", count);

    Ok(count)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_infra::with_test_pool;
    use std::sync::{Arc, Mutex};

    async fn insert_user(pool: &PgPool, id: &str, username: &str) {
        sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
            .bind(id)
            .bind(username)
            .execute(pool)
            .await
            .expect("insert user");
    }

    async fn insert_listing(pool: &PgPool, id: &str, owner_id: &str) {
        sqlx::query(
            "INSERT INTO inventory (id, title, category, brand, condition_score, suggested_price_cny, defects, owner_id, status) \
             VALUES ($1, 'Expired HITL Listing', 'misc', 'Brand', 8, 10000, '[]', $2, 'active')",
        )
        .bind(id)
        .bind(owner_id)
        .execute(pool)
        .await
        .expect("insert listing");
    }

    async fn insert_hitl(
        pool: &PgPool,
        id: &str,
        listing_id: &str,
        buyer_id: &str,
        seller_id: &str,
    ) {
        sqlx::query(
            "INSERT INTO hitl_requests (id, listing_id, buyer_id, seller_id, proposed_price, reason, status, expires_at) \
             VALUES ($1, $2, $3, $4, 9000, 'test expiration', 'pending', NOW() - INTERVAL '1 hour')",
        )
        .bind(id)
        .bind(listing_id)
        .bind(buyer_id)
        .bind(seller_id)
        .execute(pool)
        .await
        .expect("insert hitl request");
    }

    #[tokio::test]
    async fn expire_pending_commits_status_message_and_notifications_once() {
        with_test_pool(|pool| async move {
            insert_user(&pool, "expire-seller-1", "expire_seller").await;
            insert_user(&pool, "expire-buyer-1", "expire_buyer").await;
            insert_listing(&pool, "expire-listing-1", "expire-seller-1").await;
            insert_hitl(
                &pool,
                "expire-request-1",
                "expire-listing-1",
                "expire-buyer-1",
                "expire-seller-1",
            )
            .await;

            let broadcasted = Arc::new(Mutex::new(Vec::new()));
            let captured = Arc::clone(&broadcasted);
            let broadcast: NotificationBroadcast = Arc::new(move |user_id, _payload| {
                captured.lock().expect("lock broadcast log").push(user_id);
            });

            let count = expire_pending(&pool, &broadcast)
                .await
                .expect("expire hitl");
            assert_eq!(count, 1);

            let hitl = sqlx::query("SELECT status, resolved_at FROM hitl_requests WHERE id = $1")
                .bind("expire-request-1")
                .fetch_one(&pool)
                .await
                .expect("select hitl request");
            assert_eq!(hitl.get::<String, _>("status"), "expired");
            assert!(hitl
                .get::<Option<chrono::DateTime<chrono::Utc>>, _>("resolved_at")
                .is_some());

            let message_count: i64 =
                sqlx::query_scalar("SELECT COUNT(*) FROM chat_messages WHERE listing_id = $1")
                    .bind("expire-listing-1")
                    .fetch_one(&pool)
                    .await
                    .expect("count chat messages");
            assert_eq!(message_count, 1);

            let notification_count: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM notifications WHERE related_listing_id = $1",
            )
            .bind("expire-listing-1")
            .fetch_one(&pool)
            .await
            .expect("count notifications");
            assert_eq!(notification_count, 2);

            let broadcasted = broadcasted.lock().expect("lock broadcast log").clone();
            assert!(broadcasted.contains(&"expire-buyer-1".to_string()));
            assert!(broadcasted.contains(&"expire-seller-1".to_string()));

            let second_count = expire_pending(&pool, &broadcast)
                .await
                .expect("repeat expiration");
            assert_eq!(second_count, 0);
        })
        .await;
    }
}
