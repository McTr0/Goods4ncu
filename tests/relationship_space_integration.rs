//! Relationship Space projections must remain derived from existing messages
//! while explicit Pin actions stay idempotent, reversible, and campus-scoped.

use goods4ncu::services::chat_conversation::ChatConversationService;
use goods4ncu::test_infra::with_test_pool;
use sqlx::Row;
use uuid::Uuid;

async fn campus(pool: &sqlx::PgPool) -> Uuid {
    sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
        .fetch_one(pool)
        .await
        .expect("ncu campus")
}

async fn user(pool: &sqlx::PgPool, tag: &str) -> String {
    let id = format!("space-{tag}-{}", Uuid::new_v4().simple());
    sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
        .bind(&id)
        .bind(format!("space_{tag}_{}", Uuid::new_v4().simple()))
        .execute(pool)
        .await
        .expect("insert user");
    id
}

#[tokio::test]
async fn pins_are_idempotent_reversible_and_quotes_are_derived() {
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let alice = user(&pool, "alice").await;
        let bob = user(&pool, "bob").await;
        let conversation_id = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO chat_conversations (
                 id, client_request_id, campus_id, mode, state,
                 initiator_id, recipient_id, subject
             ) VALUES ($1, $2, $3, 'mail', 'open', $4, $5, '空间投影测试')",
        )
        .bind(conversation_id)
        .bind(Uuid::new_v4())
        .bind(campus_id)
        .bind(&alice)
        .bind(&bob)
        .execute(&pool)
        .await
        .expect("insert conversation");
        for member in [&alice, &bob] {
            sqlx::query(
                "INSERT INTO chat_conversation_members (conversation_id, user_id)
                 VALUES ($1, $2)",
            )
            .bind(conversation_id)
            .bind(member)
            .execute(&pool)
            .await
            .expect("insert member");
        }
        let message_id: i64 = sqlx::query(
            "INSERT INTO chat_messages (
                 conversation_id, direct_conversation_id, client_message_id,
                 listing_id, sender, receiver, content, kind, status,
                 quote_kind, quote_ref_id, quote_snapshot
             ) VALUES ($1::text, $2, $3, '', $4, $5, '教材在这里', 'message', 'sent',
                       'listing', 'listing-1', '{\"title\":\"数据库教材\"}'::jsonb)
             RETURNING id",
        )
        .bind(conversation_id.to_string())
        .bind(conversation_id)
        .bind(Uuid::new_v4())
        .bind(&alice)
        .bind(&bob)
        .fetch_one(&pool)
        .await
        .expect("insert message")
        .get("id");

        let service = ChatConversationService::new(pool.clone());
        let first = service.pin_message(message_id, &bob).await.expect("pin");
        let second = service
            .pin_message(message_id, &bob)
            .await
            .expect("idempotent pin");
        assert_eq!(first.id, second.id);

        let space = service
            .get_relationship_space(&alice, &bob, Some(campus_id), None, 50)
            .await
            .expect("space");
        assert_eq!(space.pins.len(), 1);
        assert_eq!(space.pins[0].actor_id, bob);
        assert_eq!(space.shared_objects.len(), 1);
        assert_eq!(space.shared_objects[0].key, "listing:listing-1");

        let removed = service
            .unpin_message(message_id, &bob)
            .await
            .expect("unpin")
            .expect("removed marker");
        assert_eq!(removed.id, first.id);
        assert!(service
            .unpin_message(message_id, &bob)
            .await
            .expect("idempotent unpin")
            .is_none());

        // Hiding the source invalidates the quote/pin projection for that
        // device; it does not create a server-side read or attention marker.
        service.pin_message(message_id, &bob).await.expect("repin");
        service
            .hide_message(message_id, &alice)
            .await
            .expect("hide source");
        let hidden_space = service
            .get_relationship_space(&alice, &bob, Some(campus_id), None, 50)
            .await
            .expect("hidden space");
        assert!(hidden_space.pins.is_empty());
        assert!(hidden_space.shared_objects.is_empty());

        assert!(service
            .get_relationship_space(&alice, &bob, Some(Uuid::new_v4()), None, 50)
            .await
            .is_err());
    })
    .await;
}

#[tokio::test]
async fn pending_realtime_is_not_projected_as_connected() {
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let alice = user(&pool, "pending-alice").await;
        let bob = user(&pool, "pending-bob").await;
        let conversation_id = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO chat_conversations (
                 id, client_request_id, campus_id, mode, state,
                 initiator_id, recipient_id
             ) VALUES ($1, $2, $3, 'realtime', 'syn_sent', $4, $5)",
        )
        .bind(conversation_id)
        .bind(Uuid::new_v4())
        .bind(campus_id)
        .bind(&alice)
        .bind(&bob)
        .execute(&pool)
        .await
        .expect("insert pending conversation");
        for member in [&alice, &bob] {
            sqlx::query(
                "INSERT INTO chat_conversation_members (conversation_id, user_id)
                 VALUES ($1, $2)",
            )
            .bind(conversation_id)
            .bind(member)
            .execute(&pool)
            .await
            .expect("insert pending member");
        }

        let service = ChatConversationService::new(pool.clone());
        let pending = service
            .list_threads_for_campus(&alice, campus_id, None, 50)
            .await
            .expect("list pending thread")
            .into_iter()
            .find(|thread| thread.peer_user_id == bob)
            .expect("pending thread");
        assert_eq!(pending.pending_count, 0);
        assert!(!pending.has_active_realtime);
        let pending_recipient = service
            .list_threads_for_campus(&bob, campus_id, None, 50)
            .await
            .expect("list recipient thread")
            .into_iter()
            .find(|thread| thread.peer_user_id == alice)
            .expect("recipient thread");
        assert_eq!(pending_recipient.pending_count, 1);
        assert!(!pending_recipient.has_active_realtime);

        sqlx::query(
            "UPDATE chat_conversations
             SET state = 'active', established_at = now()
             WHERE id = $1",
        )
        .bind(conversation_id)
        .execute(&pool)
        .await
        .expect("activate conversation");
        let active = service
            .list_threads_for_campus(&alice, campus_id, None, 50)
            .await
            .expect("list active thread")
            .into_iter()
            .find(|thread| thread.peer_user_id == bob)
            .expect("active thread");
        assert!(active.has_active_realtime);
    })
    .await;
}
