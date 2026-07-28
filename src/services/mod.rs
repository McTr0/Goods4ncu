use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use tokio::sync::mpsc;

pub mod admin;
pub mod admin_mfa;
pub mod agent_plan;
pub mod aggregation;
pub mod agreement;
pub mod campus;
pub mod chat;
pub mod chat_conversation;
pub mod chat_expire;
pub mod community_health;
pub mod content_report;
pub mod feed;
pub mod hitl_expire;
pub mod intent;
pub mod interruption;
pub mod moderation;
pub mod moderation_case;
pub mod moderation_worker;
pub mod notification;
pub mod order;
pub mod order_worker;
pub mod outbox;
pub mod price_discovery;
pub mod product;
pub mod reputation;
pub mod settlement;
pub mod storage;
pub mod token_denylist;
pub mod totp;
pub mod undo;
pub mod vector;
#[cfg(feature = "redis")]
pub mod ws_fanout;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum BusinessEvent {
    DealReached {
        listing_id: String,
        buyer_id: String,
        seller_id: String,
        final_price: i64,
    },
    ChatMessage {
        conversation_id: String,
        listing_id: String,
        sender: String,
        content: String,
        image_data: Option<String>,
        audio_data: Option<String>,
    },
}

#[allow(dead_code)]
pub struct ServiceManager {
    pub admin: admin::AdminService,
    pub product: product::ProductService,
    pub order: order::OrderService,
    pub chat: chat::ChatService,
    pub notification: notification::NotificationService,
    pub settlement: settlement::SettlementService,
    pub event_tx: mpsc::Sender<BusinessEvent>,
}

/// Bounded channel capacity for event bus — provides backpressure when
/// the event loop is overwhelmed, preventing unbounded memory growth.
const EVENT_BUS_CAPACITY: usize = 2048;

/// API chat endpoints persist directly. Event-driven chat persistence is reserved
/// for internal negotiation transcripts only.
const INTERNAL_EVENT_CHAT_PREFIX: &str = "negotiate:";

fn should_persist_chat_event(conversation_id: &str) -> bool {
    conversation_id.starts_with(INTERNAL_EVENT_CHAT_PREFIX)
}

impl ServiceManager {
    /// Creates ServiceManager from a single PgPool (serves both relational + vector data).
    #[allow(dead_code)]
    pub fn new(db: PgPool) -> (Self, mpsc::Receiver<BusinessEvent>) {
        let (tx, rx) = mpsc::channel(EVENT_BUS_CAPACITY);

        let manager = Self {
            admin: admin::AdminService::new(db.clone()),
            product: product::ProductService::new(db.clone()),
            order: order::OrderService::new(db.clone()),
            chat: chat::ChatService::new(db.clone()),
            notification: notification::NotificationService::new(db.clone()),
            settlement: settlement::SettlementService::new(db),
            event_tx: tx,
        };

        (manager, rx)
    }

    pub async fn run_event_loop(self, mut rx: mpsc::Receiver<BusinessEvent>) {
        tracing::info!("Business Event Loop started.");
        while let Some(event) = rx.recv().await {
            let chat_svc = self.chat.clone();
            let _notification_svc = self.notification.clone();
            let order_svc = self.order.clone();

            tokio::spawn(async move {
                match event {
                    BusinessEvent::DealReached {
                        listing_id,
                        buyer_id,
                        seller_id,
                        final_price,
                    } => {
                        match order_svc
                            .create_order(&listing_id, &buyer_id, &seller_id, final_price)
                            .await
                        {
                            Ok(order_id) => {
                                tracing::info!(
                                    order_id,
                                    listing_id,
                                    buyer_id,
                                    seller_id,
                                    final_price,
                                    "Deal intent created from DealReached event"
                                );
                            }
                            Err(e) => {
                                tracing::error!(%e, listing_id, buyer_id, seller_id, "Failed to create order from DealReached event");
                            }
                        }
                    }
                    BusinessEvent::ChatMessage {
                        conversation_id,
                        listing_id,
                        sender,
                        content,
                        image_data,
                        audio_data,
                    } => {
                        if !should_persist_chat_event(&conversation_id) {
                            tracing::warn!(
                                conversation_id,
                                "Dropped BusinessEvent::ChatMessage for non-internal conversation; API chat endpoints persist directly"
                            );
                            return;
                        }

                        if let Err(e) = chat_svc
                            .log_message(
                                &conversation_id,
                                &listing_id,
                                &sender,
                                None,
                                false, // user message, not agent
                                &content,
                                image_data.as_deref(),
                                audio_data.as_deref(),
                                None,
                                None,
                            )
                            .await
                        {
                            tracing::error!(%e, conversation_id, "Failed to log chat message");
                        }
                    }
                }
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_business_event_deal_reached_serialization() {
        let event = BusinessEvent::DealReached {
            listing_id: "listing-123".to_string(),
            buyer_id: "buyer-456".to_string(),
            seller_id: "seller-789".to_string(),
            final_price: 4999,
        };
        let json = serde_json::to_string(&event).unwrap();
        assert!(json.contains("DealReached"));
        assert!(json.contains("listing-123"));
        assert!(json.contains("buyer-456"));
        assert!(json.contains("seller-789"));
        assert!(json.contains("4999"));
    }

    #[test]
    fn test_business_event_chat_message_serialization() {
        let event = BusinessEvent::ChatMessage {
            conversation_id: "conv-1".to_string(),
            listing_id: "listing-1".to_string(),
            sender: "user-1".to_string(),
            content: "Hello!".to_string(),
            image_data: Some("base64image".to_string()),
            audio_data: None,
        };
        let json = serde_json::to_string(&event).unwrap();
        assert!(json.contains("ChatMessage"));
        assert!(json.contains("conv-1"));
        assert!(json.contains("Hello!"));
        assert!(json.contains("base64image"));
    }

    #[test]
    fn test_business_event_chat_message_without_optional() {
        let event = BusinessEvent::ChatMessage {
            conversation_id: "conv-2".to_string(),
            listing_id: "listing-2".to_string(),
            sender: "user-2".to_string(),
            content: "Hi".to_string(),
            image_data: None,
            audio_data: None,
        };
        let json = serde_json::to_string(&event).unwrap();
        assert!(json.contains("ChatMessage"));
        assert!(json.contains("conv-2"));
    }

    #[test]
    fn test_business_event_deserialization() {
        let json = r#"{
            "DealReached": {
                "listing_id": "listing-x",
                "buyer_id": "buyer-y",
                "seller_id": "seller-z",
                "final_price": 2999
            }
        }"#;
        let event: BusinessEvent = serde_json::from_str(json).unwrap();
        match event {
            BusinessEvent::DealReached {
                listing_id,
                buyer_id,
                seller_id,
                final_price,
            } => {
                assert_eq!(listing_id, "listing-x");
                assert_eq!(buyer_id, "buyer-y");
                assert_eq!(seller_id, "seller-z");
                assert_eq!(final_price, 2999);
            }
            _ => panic!("Expected DealReached variant"),
        }
    }

    #[test]
    fn test_event_bus_capacity_constant() {
        let capacity = EVENT_BUS_CAPACITY;
        assert!((100..=100_000).contains(&capacity));
    }

    #[test]
    fn test_should_persist_chat_event_for_internal_negotiation_conversation() {
        assert!(should_persist_chat_event("negotiate:listing-123"));
    }

    #[test]
    fn test_should_not_persist_chat_event_for_api_chat_conversations() {
        assert!(!should_persist_chat_event("global"));
        assert!(!should_persist_chat_event("__agent__"));
        assert!(!should_persist_chat_event(
            "01234567-89ab-cdef-0123-456789abcdef"
        ));
    }
}
