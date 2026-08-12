//! Integration tests for the direct chat conversation state machine.

use goods4ncu::api::error::ApiError;
use goods4ncu::services::chat_conversation::{
    AcknowledgementKind, ChatConversationService, ConversationDecision, ConversationMode,
    ConversationState, CreateConversationInput, SendConversationMessageInput, StructuredQuoteInput,
    StructuredQuoteKind,
};
use goods4ncu::test_infra::with_test_pool;
use sqlx::Row;
use uuid::Uuid;

async fn insert_user(pool: &sqlx::PgPool, id: &str, username: &str) {
    sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
        .bind(id)
        .bind(username)
        .execute(pool)
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO campus_memberships (
            campus_id, user_id, status, verification_method, verified_at
         ) SELECT id, $1, 'verified', 'test_fixture', NOW()
           FROM campuses WHERE slug = 'ncu'",
    )
    .bind(id)
    .execute(pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO chat_connection_preferences (user_id, allow_strangers)
         VALUES ($1, TRUE)
         ON CONFLICT (user_id) DO UPDATE SET allow_strangers = TRUE",
    )
    .bind(id)
    .execute(pool)
    .await
    .unwrap();
}

fn realtime_input(
    initiator_id: &str,
    recipient_id: &str,
    content: &str,
) -> CreateConversationInput {
    CreateConversationInput {
        client_request_id: Uuid::new_v4(),
        campus_id: Uuid::parse_str("c0000000-0000-0000-0000-000000000001").unwrap(),
        initiator_id: initiator_id.to_string(),
        recipient_id: recipient_id.to_string(),
        listing_id: None,
        mode: ConversationMode::Realtime,
        subject: None,
        content: content.to_string(),
    }
}

fn mail_input(
    initiator_id: &str,
    recipient_id: &str,
    subject: &str,
    content: &str,
) -> CreateConversationInput {
    CreateConversationInput {
        client_request_id: Uuid::new_v4(),
        campus_id: Uuid::parse_str("c0000000-0000-0000-0000-000000000001").unwrap(),
        initiator_id: initiator_id.to_string(),
        recipient_id: recipient_id.to_string(),
        listing_id: None,
        mode: ConversationMode::Mail,
        subject: Some(subject.to_string()),
        content: content.to_string(),
    }
}

fn send_input(
    conversation_id: Uuid,
    sender_id: &str,
    content: &str,
) -> SendConversationMessageInput {
    SendConversationMessageInput {
        client_message_id: Uuid::new_v4(),
        conversation_id,
        sender_id: sender_id.to_string(),
        content: content.to_string(),
        reply_to_message_id: None,
        quote: None,
        image_data: None,
        audio_data: None,
        image_url: None,
        audio_url: None,
    }
}

async fn insert_listing(pool: &sqlx::PgPool, id: &str, owner_id: &str, title: &str) {
    sqlx::query(
        "INSERT INTO inventory
         (id, title, category, brand, condition_score, suggested_price_cny, defects, owner_id, status)
         VALUES ($1, $2, 'electronics', 'brand', 8, 12345, 'none', $3, 'active')",
    )
    .bind(id)
    .bind(title)
    .bind(owner_id)
    .execute(pool)
    .await
    .unwrap();
}

async fn create_active_realtime(
    service: &ChatConversationService,
    initiator_id: &str,
    recipient_id: &str,
) -> Uuid {
    let created = service
        .create_conversation(realtime_input(
            initiator_id,
            recipient_id,
            "你好，想聊聊这个商品",
        ))
        .await
        .unwrap();
    let conversation_id = Uuid::parse_str(&created.conversation.id).unwrap();
    service
        .respond(conversation_id, recipient_id, ConversationDecision::Accept)
        .await
        .unwrap();
    service
        .acknowledge(conversation_id, initiator_id)
        .await
        .unwrap();
    conversation_id
}

#[tokio::test]
async fn threads_group_multiple_conversations_by_peer_without_merging_history() {
    with_test_pool(|pool| async move {
        insert_user(&pool, "user-a", "alice").await;
        insert_user(&pool, "user-b", "bob").await;
        sqlx::query(
            "INSERT INTO social_personas (
                 user_id, campus_id, representation_mode, style_version,
                 appearance_config, self_descriptions, contact_posture,
                 status, published_at
             ) VALUES (
                 'user-a',
                 'c0000000-0000-0000-0000-000000000001',
                 'role_character', 'v1',
                 '{\"palette\":\"plum\",\"silhouette\":\"round\",\"accessory\":\"leaf\",\"outfit\":\"campus\"}',
                 '[\"slow_to_warm\"]', 'leave_message',
                 'published', NOW()
             )",
        )
        .execute(&pool)
        .await
        .unwrap();
        let service = ChatConversationService::new(pool.clone());

        let realtime_id = create_active_realtime(&service, "user-a", "user-b").await;
        service.close(realtime_id, "user-a").await.unwrap();
        service
            .create_conversation(mail_input("user-a", "user-b", "取货时间", "今晚七点可以吗"))
            .await
            .unwrap();

        let threads = service.list_threads("user-b", None, 20).await.unwrap();
        assert_eq!(threads.len(), 1);
        let thread = &threads[0];
        assert_eq!(
            thread.relationship_key,
            "relationship:v1:legacy:user-a:user-b"
        );
        assert_eq!(thread.peer_user_id, "user-a");
        assert_eq!(thread.peer_username, "alice");
        assert_eq!(thread.conversation_count, 2);
        assert_eq!(thread.realtime_count, 1);
        assert_eq!(thread.mail_count, 1);
        assert_eq!(thread.latest_preview.as_deref(), Some("今晚七点可以吗"));

        let detail = service.get_thread("user-b", "user-a", None).await.unwrap();
        assert_eq!(detail.thread.peer_user_id, "user-a");
        assert_eq!(detail.conversations.len(), 2);
        assert!(detail
            .conversations
            .iter()
            .any(|conversation| conversation.mode == ConversationMode::Realtime));
        assert!(detail
            .conversations
            .iter()
            .any(|conversation| conversation.mode == ConversationMode::Mail));

        let mail_threads = service
            .list_threads("user-b", Some(ConversationMode::Mail), 20)
            .await
            .unwrap();
        assert_eq!(mail_threads.len(), 1);
        assert_eq!(mail_threads[0].conversation_count, 1);

        let ncu = Uuid::parse_str("c0000000-0000-0000-0000-000000000001").unwrap();
        let other_campus = Uuid::parse_str("c0000000-0000-0000-0000-000000000099").unwrap();
        assert_eq!(
            service
                .list_threads_for_campus("user-b", ncu, None, 20)
                .await
                .unwrap()
                .len(),
            1
        );
        let campus_thread = service
            .list_threads_for_campus("user-b", ncu, None, 20)
            .await
            .unwrap()
            .pop()
            .unwrap();
        let persona = campus_thread.persona.expect("published peer persona");
        assert_eq!(persona.representation_mode, "role_character");
        assert_eq!(persona.contact_posture, "leave_message");
        assert!(service
            .list_threads("user-b", None, 20)
            .await
            .unwrap()
            .first()
            .unwrap()
            .persona
            .is_none());
        assert_eq!(
            campus_thread.relationship_key,
            "relationship:v1:c0000000-0000-0000-0000-000000000001:user-a:user-b"
        );
        assert!(service
            .list_threads_for_campus("user-b", other_campus, None, 20)
            .await
            .unwrap()
            .is_empty());
        assert!(service
            .list_conversations_for_campus("user-b", other_campus, None, None, 20)
            .await
            .unwrap()
            .0
            .is_empty());
        assert!(matches!(
            service
                .get_relationship_space("user-b", "user-a", Some(other_campus), None, 50)
                .await,
            Err(ApiError::NotFound)
        ));

        let space = service
            .get_relationship_space("user-b", "user-a", None, None, 50)
            .await
            .unwrap();
        assert_eq!(
            space.relationship_key,
            "relationship:v1:legacy:user-a:user-b"
        );
        assert!(space
            .events
            .iter()
            .any(|event| event.event_type == "message.opening"));
        assert!(space
            .events
            .iter()
            .any(|event| event.event_type == "conversation.created"));
        let first_cursor = space.next_cursor.clone();
        if let Some(cursor) = first_cursor {
            let cursor_time = cursor.split('|').next().unwrap().to_string();
            let next_page = service
                .get_relationship_space("user-b", "user-a", None, Some(&cursor), 50)
                .await
                .unwrap();
            assert!(next_page
                .events
                .iter()
                .all(|event| event.occurred_at.as_str() <= cursor_time.as_str()));
        }
    })
    .await;
}

#[tokio::test]
async fn message_reply_reaction_hide_and_report_are_member_scoped() {
    with_test_pool(|pool| async move {
        insert_user(&pool, "user-a", "alice").await;
        insert_user(&pool, "user-b", "bob").await;
        let service = ChatConversationService::new(pool.clone());
        let conversation_id = create_active_realtime(&service, "user-a", "user-b").await;

        let first = service
            .send_message(send_input(conversation_id, "user-a", "这个耳机还能小刀吗"))
            .await
            .unwrap();
        let mut reply_input = send_input(conversation_id, "user-b", "可以小刀一点，但希望今天自提");
        reply_input.reply_to_message_id = Some(first.id);
        let reply = service.send_message(reply_input).await.unwrap();
        assert_eq!(reply.reply_to_message_id, Some(first.id));
        assert_eq!(
            reply.reply_preview.as_ref().map(|preview| preview.id),
            Some(first.id)
        );

        let reacted = service
            .set_reaction(reply.id, "user-a", "👍")
            .await
            .unwrap();
        assert_eq!(reacted.reactions.len(), 1);
        assert_eq!(reacted.reactions[0].emoji, "👍");
        assert!(reacted.reactions[0].reacted_by_me);

        service.hide_message(reply.id, "user-a").await.unwrap();
        let (alice_messages, _) = service
            .get_messages(conversation_id, "user-a", 20, 0)
            .await
            .unwrap();
        assert!(!alice_messages.iter().any(|message| message.id == reply.id));
        let (bob_messages, _) = service
            .get_messages(conversation_id, "user-b", 20, 0)
            .await
            .unwrap();
        assert!(bob_messages.iter().any(|message| message.id == reply.id));

        let report_id = service
            .report_message(first.id, "user-b", "不当内容", Some("测试举报"))
            .await
            .unwrap();
        let duplicate_report_id = service
            .report_message(first.id, "user-b", "不当内容", Some("更新说明"))
            .await
            .unwrap();
        assert_eq!(report_id, duplicate_report_id);

        let report_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM chat_message_reports
             WHERE message_id = $1 AND reporter_id = 'user-b'",
        )
        .bind(first.id)
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(report_count, 1);

        let linked_case = sqlx::query(
            "SELECT report.case_id, moderation_case.campus_id,
                    moderation_case.subject_user_id, moderation_case.status,
                    moderation_case.internal_details->>'details' AS details
             FROM chat_message_reports report
             JOIN moderation_cases moderation_case ON moderation_case.id = report.case_id
             WHERE report.id = $1",
        )
        .bind(report_id)
        .fetch_one(&pool)
        .await
        .unwrap();
        assert!(linked_case.get::<Option<Uuid>, _>("case_id").is_some());
        assert_eq!(
            linked_case.get::<Uuid, _>("campus_id"),
            Uuid::parse_str("c0000000-0000-0000-0000-000000000001").unwrap()
        );
        assert_eq!(
            linked_case.get::<Option<String>, _>("subject_user_id"),
            Some("user-a".to_string())
        );
        assert_eq!(linked_case.get::<String, _>("status"), "open");
        assert_eq!(linked_case.get::<String, _>("details"), "更新说明");

        let case_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM moderation_cases
             WHERE source_type = 'user_report' AND source_ref_id = $1",
        )
        .bind(report_id.to_string())
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(case_count, 1);
    })
    .await;
}

#[tokio::test]
async fn message_acknowledgement_is_recipient_scoped_idempotent_replaceable_and_withdrawable() {
    with_test_pool(|pool| async move {
        insert_user(&pool, "ack-user-a", "ack_alice").await;
        insert_user(&pool, "ack-user-b", "ack_bob").await;
        insert_user(&pool, "ack-user-c", "ack_carol").await;
        let service = ChatConversationService::new(pool.clone());
        let created = service
            .create_conversation(mail_input(
                "ack-user-a",
                "ack-user-b",
                "请确认",
                "请在方便时确认这条留言",
            ))
            .await
            .unwrap();
        let conversation_id = Uuid::parse_str(&created.conversation.id).unwrap();
        let message = service
            .get_messages(conversation_id, "ack-user-b", 20, 0)
            .await
            .unwrap()
            .0
            .pop()
            .unwrap();

        let received = service
            .set_message_acknowledgement(message.id, "ack-user-b", AcknowledgementKind::Received)
            .await
            .unwrap();
        assert_eq!(received.acknowledgements.len(), 1);
        assert_eq!(
            received.acknowledgements[0].kind,
            AcknowledgementKind::Received
        );

        let repeated = service
            .set_message_acknowledgement(message.id, "ack-user-b", AcknowledgementKind::Received)
            .await
            .unwrap();
        assert_eq!(repeated.acknowledgements.len(), 1);

        let replaced = service
            .set_message_acknowledgement(message.id, "ack-user-b", AcknowledgementKind::Completed)
            .await
            .unwrap();
        assert_eq!(
            replaced.acknowledgements[0].kind,
            AcknowledgementKind::Completed
        );

        assert!(matches!(
            service
                .set_message_acknowledgement(
                    message.id,
                    "ack-user-a",
                    AcknowledgementKind::Received,
                )
                .await,
            Err(ApiError::Forbidden)
        ));
        assert!(matches!(
            service
                .set_message_acknowledgement(
                    message.id,
                    "ack-user-c",
                    AcknowledgementKind::Received,
                )
                .await,
            Err(ApiError::Forbidden)
        ));

        let withdrawn = service
            .delete_message_acknowledgement(message.id, "ack-user-b")
            .await
            .unwrap();
        assert!(withdrawn.acknowledgements.is_empty());

        service
            .block_user("ack-user-b", "ack-user-a")
            .await
            .unwrap();
        assert!(matches!(
            service
                .set_message_acknowledgement(
                    message.id,
                    "ack-user-b",
                    AcknowledgementKind::WillReview,
                )
                .await,
            Err(ApiError::Conflict(code)) if code == "conversation_unavailable"
        ));
    })
    .await;
}

#[tokio::test]
async fn realtime_accept_then_sender_message_auto_acknowledges_without_server_read_state() {
    with_test_pool(|pool| async move {
        insert_user(&pool, "user-a", "alice").await;
        insert_user(&pool, "user-b", "bob").await;
        let service = ChatConversationService::new(pool.clone());

        let created = service
            .create_conversation(realtime_input("user-a", "user-b", "你好，我想问下还在吗"))
            .await
            .unwrap();
        assert!(created.created);
        assert_eq!(created.conversation.state, ConversationState::SynSent);
        assert!(created.conversation.capabilities.can_close);

        let conversation_id = Uuid::parse_str(&created.conversation.id).unwrap();
        let receiver_view = service
            .get_conversation(conversation_id, "user-b")
            .await
            .unwrap();
        assert!(receiver_view.capabilities.can_respond);

        let accepted = service
            .respond(conversation_id, "user-b", ConversationDecision::Accept)
            .await
            .unwrap();
        assert_eq!(accepted.state, ConversationState::SynAck);

        let initiator_view = service
            .get_conversation(conversation_id, "user-a")
            .await
            .unwrap();
        assert!(initiator_view.capabilities.can_ack);
        assert!(initiator_view.capabilities.can_send);

        let sent = service
            .send_message(send_input(
                conversation_id,
                "user-a",
                "我现在在线，可以继续聊",
            ))
            .await
            .unwrap();
        assert_eq!(sent.kind, "message");

        let receiver_after = service
            .get_conversation(conversation_id, "user-b")
            .await
            .unwrap();
        assert_eq!(receiver_after.state, ConversationState::Active);

        let ack_events: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM chat_conversation_events
             WHERE conversation_id = $1 AND event_type = 'conversation_acknowledged_by_message'",
        )
        .bind(conversation_id)
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(ack_events, 1);
    })
    .await;
}

#[tokio::test]
async fn mutual_realtime_intent_reuses_single_active_conversation() {
    with_test_pool(|pool| async move {
        insert_user(&pool, "user-a", "alice").await;
        insert_user(&pool, "user-b", "bob").await;
        let service = ChatConversationService::new(pool.clone());

        let first = service
            .create_conversation(realtime_input("user-a", "user-b", "我想聊一下"))
            .await
            .unwrap();
        let first_id = Uuid::parse_str(&first.conversation.id).unwrap();

        let second = service
            .create_conversation(realtime_input("user-b", "user-a", "我也正想联系你"))
            .await
            .unwrap();
        assert!(!second.created);
        assert!(second.mutual_open);
        assert_eq!(second.conversation.id, first_id.to_string());
        assert_eq!(second.conversation.state, ConversationState::Active);

        let message_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM chat_messages WHERE direct_conversation_id = $1",
        )
        .bind(first_id)
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(message_count, 2);

        let user_a_view = service.get_conversation(first_id, "user-a").await.unwrap();
        let user_b_view = service.get_conversation(first_id, "user-b").await.unwrap();
        assert_eq!(user_a_view.state, ConversationState::Active);
        assert_eq!(user_b_view.state, ConversationState::Active);
    })
    .await;
}

#[tokio::test]
async fn stranger_realtime_requests_require_contact_permission_but_mail_is_allowed() {
    with_test_pool(|pool| async move {
        insert_user(&pool, "privacy-a", "privacy_alice").await;
        insert_user(&pool, "privacy-b", "privacy_bob").await;
        sqlx::query(
            "UPDATE chat_connection_preferences
             SET allow_strangers = FALSE WHERE user_id = 'privacy-b'",
        )
        .execute(&pool)
        .await
        .unwrap();
        let service = ChatConversationService::new(pool.clone());

        let error = service
            .create_conversation(realtime_input("privacy-a", "privacy-b", "现在方便接通吗"))
            .await
            .unwrap_err();
        assert!(matches!(
            error,
            ApiError::CodedConflict {
                code: "connection_requires_contact",
                ..
            }
        ));

        let mail = service
            .create_conversation(mail_input(
                "privacy-a",
                "privacy-b",
                "留言",
                "方便时回复就好",
            ))
            .await
            .unwrap();
        assert!(mail.created);

        service
            .set_contact_permission("privacy-b", "privacy-a", true, None)
            .await
            .unwrap();
        let allowed = service
            .create_conversation(realtime_input("privacy-a", "privacy-b", "现在方便接通吗"))
            .await
            .unwrap();
        assert!(allowed.created);
    })
    .await;
}

#[tokio::test]
async fn busy_rejects_realtime_and_contact_mute_suppresses_only_notification() {
    with_test_pool(|pool| async move {
        insert_user(&pool, "busy-a", "busy_alice").await;
        insert_user(&pool, "busy-b", "busy_bob").await;
        let service = ChatConversationService::new(pool.clone());
        service
            .set_connection_preferences(
                "busy-b",
                true,
                Some(chrono::Utc::now() + chrono::Duration::hours(1)),
            )
            .await
            .unwrap();
        let error = service
            .create_conversation(realtime_input("busy-a", "busy-b", "接通请求"))
            .await
            .unwrap_err();
        assert!(matches!(
            error,
            ApiError::CodedConflict {
                code: "recipient_busy",
                ..
            }
        ));

        service
            .set_connection_preferences("busy-b", true, None)
            .await
            .unwrap();
        service
            .set_contact_permission(
                "busy-b",
                "busy-a",
                true,
                Some(chrono::Utc::now() + chrono::Duration::hours(1)),
            )
            .await
            .unwrap();
        let mail = service
            .create_conversation(mail_input("busy-a", "busy-b", "留言", "不打扰，方便时看"))
            .await
            .unwrap();
        assert!(mail.created);
        assert!(!mail.notify_recipient);
    })
    .await;
}

#[tokio::test]
async fn mail_thread_opens_immediately_allows_reply_and_member_archiving() {
    with_test_pool(|pool| async move {
        insert_user(&pool, "user-a", "alice").await;
        insert_user(&pool, "user-b", "bob").await;
        let service = ChatConversationService::new(pool.clone());

        let created = service
            .create_conversation(mail_input(
                "user-a",
                "user-b",
                "想确认取货时间",
                "你好，我不急，你方便时回复就好。",
            ))
            .await
            .unwrap();
        assert_eq!(created.conversation.mode, ConversationMode::Mail);
        assert_eq!(created.conversation.state, ConversationState::Open);
        assert!(created.conversation.capabilities.can_send);

        let conversation_id = Uuid::parse_str(&created.conversation.id).unwrap();
        let receiver_view = service
            .get_conversation(conversation_id, "user-b")
            .await
            .unwrap();
        assert!(receiver_view.capabilities.can_send);

        service
            .send_message(send_input(conversation_id, "user-b", "今晚 7 点后可以"))
            .await
            .unwrap();
        let archived = service
            .set_archived(conversation_id, "user-a", true)
            .await
            .unwrap();
        assert!(archived.archived);

        let (user_a_items, _) = service
            .list_conversations("user-a", None, None, 10)
            .await
            .unwrap();
        assert!(user_a_items.is_empty());

        let (user_b_items, _) = service
            .list_conversations("user-b", None, None, 10)
            .await
            .unwrap();
        assert_eq!(user_b_items.len(), 1);
        assert!(!user_b_items[0].archived);
    })
    .await;
}

#[tokio::test]
async fn server_schema_removes_retired_read_state_after_compatibility_window() {
    with_test_pool(|pool| async move {
        let shadow_columns: i64 = sqlx::query_scalar(
            "SELECT COUNT(*)
             FROM information_schema.columns
             WHERE table_schema = 'public'
                 AND ((table_name = 'chat_messages' AND column_name IN ('read_at', 'read_by'))
                 OR (table_name = 'chat_conversation_members' AND column_name IN ('unread_count', 'last_read_message_id', 'read_receipt_mode'))
                 OR (table_name = 'chat_connections' AND column_name = 'unread_count')
                 OR (table_name = 'users' AND column_name = 'chat_read_receipt_mode'))",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(shadow_columns, 0);
    })
    .await;
}

#[tokio::test]
async fn structured_quotes_are_server_snapshots_and_permission_scoped() {
    with_test_pool(|pool| async move {
        insert_user(&pool, "user-a", "alice").await;
        insert_user(&pool, "user-b", "bob").await;
        insert_user(&pool, "user-c", "carol").await;
        insert_listing(&pool, "listing-quote", "user-b", "引用测试商品").await;

        sqlx::query(
            "INSERT INTO orders (id, listing_id, buyer_id, seller_id, final_price, status)
             VALUES ('order-quote', 'listing-quote', 'user-a', 'user-b', 12000, 'intent_pending')",
        )
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO hitl_requests
             (id, listing_id, buyer_id, seller_id, proposed_price, reason, status, counter_price)
             VALUES ('hitl-quote', 'listing-quote', 'user-a', 'user-b', 11000, '测试', 'countered', 11800)",
        )
        .execute(&pool)
        .await
        .unwrap();

        let service = ChatConversationService::new(pool.clone());
        let conversation_id = create_active_realtime(&service, "user-a", "user-b").await;

        let mut listing_message = send_input(conversation_id, "user-a", "我说的是这件");
        listing_message.quote = Some(StructuredQuoteInput {
            kind: StructuredQuoteKind::Listing,
            ref_id: "listing-quote".to_string(),
        });
        let listing_quote = service.send_message(listing_message).await.unwrap();
        let quote = listing_quote.quote.as_ref().expect("listing quote");
        assert_eq!(quote.kind, "listing");
        assert_eq!(quote.ref_id, "listing-quote");
        assert_eq!(quote.snapshot["title"], "引用测试商品");
        assert_eq!(quote.snapshot["price_cny"], 123.45);

        let mut order_message = send_input(conversation_id, "user-b", "这个成交意向");
        order_message.quote = Some(StructuredQuoteInput {
            kind: StructuredQuoteKind::Order,
            ref_id: "order-quote".to_string(),
        });
        let order_quote = service.send_message(order_message).await.unwrap();
        assert_eq!(
            order_quote
                .quote
                .as_ref()
                .expect("order quote")
                .snapshot["final_price_cny"],
            120.0
        );

        let mut hitl_message = send_input(conversation_id, "user-a", "这次还价");
        hitl_message.quote = Some(StructuredQuoteInput {
            kind: StructuredQuoteKind::HitlOffer,
            ref_id: "hitl-quote".to_string(),
        });
        let hitl_quote = service.send_message(hitl_message).await.unwrap();
        assert_eq!(
            hitl_quote
                .quote
                .as_ref()
                .expect("hitl quote")
                .snapshot["counter_price_cny"],
            118.0
        );

        let other_conversation = create_active_realtime(&service, "user-c", "user-b").await;
        let mut forbidden = send_input(other_conversation, "user-c", "偷看订单");
        forbidden.quote = Some(StructuredQuoteInput {
            kind: StructuredQuoteKind::Order,
            ref_id: "order-quote".to_string(),
        });
        let error = service.send_message(forbidden).await.unwrap_err();
        assert!(matches!(error, ApiError::Forbidden));
    })
    .await;
}

#[tokio::test]
async fn new_listing_quote_rejects_restricted_listing_without_persisting_message() {
    with_test_pool(|pool| async move {
        insert_user(&pool, "quote-restriction-sender", "quote_sender").await;
        insert_user(&pool, "quote-restriction-owner", "quote_owner").await;
        insert_user(&pool, "quote-restriction-admin", "quote_admin").await;
        insert_listing(
            &pool,
            "quote-restricted-listing",
            "quote-restriction-owner",
            "受限制引用商品",
        )
        .await;
        let service = ChatConversationService::new(pool.clone());
        let conversation_id = create_active_realtime(
            &service,
            "quote-restriction-sender",
            "quote-restriction-owner",
        )
        .await;
        goods4ncu::services::moderation_case::ModerationCaseService::new(pool.clone())
            .impose_manual_listing_takedown(
                "quote-restricted-listing",
                Uuid::parse_str("c0000000-0000-0000-0000-000000000001").unwrap(),
                "quote-restriction-admin",
                "结构化引用限制测试",
                None,
            )
            .await
            .expect("restrict listing");
        let before: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM chat_messages WHERE direct_conversation_id = $1",
        )
        .bind(conversation_id)
        .fetch_one(&pool)
        .await
        .expect("message count before");

        let mut message = send_input(
            conversation_id,
            "quote-restriction-sender",
            "尝试引用受限制发布",
        );
        message.quote = Some(StructuredQuoteInput {
            kind: StructuredQuoteKind::Listing,
            ref_id: "quote-restricted-listing".to_string(),
        });
        let error = service
            .send_message(message)
            .await
            .expect_err("restricted listing quote must fail closed");
        assert!(matches!(
            error,
            ApiError::CodedConflict {
                code: "listing_restricted",
                ..
            }
        ));
        let after: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM chat_messages WHERE direct_conversation_id = $1",
        )
        .bind(conversation_id)
        .fetch_one(&pool)
        .await
        .expect("message count after");
        assert_eq!(after, before, "failed quote must not persist a message");
    })
    .await;
}

#[tokio::test]
async fn block_user_closes_live_realtime_and_prevents_new_or_continued_contact() {
    with_test_pool(|pool| async move {
        insert_user(&pool, "user-a", "alice").await;
        insert_user(&pool, "user-b", "bob").await;
        let service = ChatConversationService::new(pool.clone());
        let conversation_id = create_active_realtime(&service, "user-a", "user-b").await;

        service.block_user("user-b", "user-a").await.unwrap();

        let blocked_view = service
            .get_conversation(conversation_id, "user-a")
            .await
            .unwrap();
        assert_eq!(blocked_view.state, ConversationState::Closed);
        assert_eq!(blocked_view.close_reason.as_deref(), Some("blocked"));
        assert!(blocked_view.is_blocked);

        let send_error = service
            .send_message(send_input(conversation_id, "user-a", "还能聊吗"))
            .await
            .unwrap_err();
        assert!(matches!(send_error, ApiError::Conflict(_)));

        let create_error = service
            .create_conversation(realtime_input("user-a", "user-b", "重新联系一下"))
            .await
            .unwrap_err();
        assert!(matches!(create_error, ApiError::Conflict(_)));
    })
    .await;
}

#[tokio::test]
async fn expire_stale_invites_is_idempotent() {
    with_test_pool(|pool| async move {
        insert_user(&pool, "user-a", "alice").await;
        insert_user(&pool, "user-b", "bob").await;
        let service = ChatConversationService::new(pool.clone());

        let created = service
            .create_conversation(realtime_input("user-a", "user-b", "有空时接通一下"))
            .await
            .unwrap();
        let conversation_id = Uuid::parse_str(&created.conversation.id).unwrap();

        sqlx::query(
            "UPDATE chat_conversations
             SET invite_expires_at = NOW() - INTERVAL '1 minute'
             WHERE id = $1",
        )
        .bind(conversation_id)
        .execute(&pool)
        .await
        .unwrap();

        let expired = service.expire_stale().await.unwrap();
        assert_eq!(expired.len(), 1);
        assert_eq!(expired[0].0, conversation_id);

        let expired_again = service.expire_stale().await.unwrap();
        assert!(expired_again.is_empty());

        let view = service
            .get_conversation(conversation_id, "user-a")
            .await
            .unwrap();
        assert_eq!(view.state, ConversationState::Expired);
        assert_eq!(view.close_reason.as_deref(), Some("invite_timeout"));

        let expire_events: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM chat_conversation_events
             WHERE conversation_id = $1 AND event_type = 'conversation_expired'",
        )
        .bind(conversation_id)
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(expire_events, 1);
    })
    .await;
}

#[tokio::test]
async fn direct_conversation_rejects_cross_campus_participants() {
    with_test_pool(|pool| async move {
        insert_user(&pool, "user-a", "alice").await;

        let other_campus_id = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO campuses (id, slug, name_zh, name_en, email_domains)
             VALUES ($1, $2, '测试大学', 'Test University', ARRAY['test.edu.cn'])",
        )
        .bind(other_campus_id)
        .bind(format!("test-{}", &other_campus_id.to_string()[..8]))
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO users (id, username, password_hash)
             VALUES ('user-b', 'bob', 'hash')",
        )
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO campus_memberships (
                campus_id, user_id, status, verification_method, verified_at
             ) VALUES ($1, 'user-b', 'verified', 'test_fixture', NOW())",
        )
        .bind(other_campus_id)
        .execute(&pool)
        .await
        .unwrap();

        let service = ChatConversationService::new(pool.clone());
        let error = service
            .create_conversation(realtime_input("user-a", "user-b", "跨校联系"))
            .await
            .unwrap_err();
        assert!(matches!(error, ApiError::CampusScopeMismatch));

        let count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM chat_conversations
             WHERE initiator_id = 'user-a' AND recipient_id = 'user-b'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(count, 0);
    })
    .await;
}
