use sqlx::PgPool;
use std::time::Duration;

use crate::api::ws;
use crate::lifecycle::{tick_or_shutdown, ShutdownSignal};
use crate::services::chat_conversation::ChatConversationService;

pub async fn run_chat_expiry_worker(pool: PgPool, shutdown: ShutdownSignal) {
    let service = ChatConversationService::new(pool);
    let mut interval = tokio::time::interval(Duration::from_secs(30));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    while tick_or_shutdown(&mut interval, &shutdown)
        .await
        .should_continue()
    {
        match service.expire_stale().await {
            Ok(expired) => {
                for (conversation_id, campus_id, initiator_id, recipient_id) in expired {
                    let payload = serde_json::json!({
                        "event": "conversation_state_changed",
                        "conversation_id": conversation_id,
                        "state": "expired",
                    })
                    .to_string();
                    ws::broadcast_to_user_in_campus(&initiator_id, campus_id, &payload);
                    ws::broadcast_to_user_in_campus(&recipient_id, campus_id, &payload);
                }
            }
            Err(error) => tracing::error!(%error, "chat expiry worker failed"),
        }
    }

    tracing::info!("Chat expiry worker stopped");
}
