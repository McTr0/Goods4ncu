//! The living state of an arrangement.
//!
//! Two properties are under test, and both are about what the assistant is *not*
//! allowed to do.
//!
//! **An extraction is not the plan.** A term the model read out of the
//! conversation lands with nobody having agreed to it. If that ever changes, a
//! misread "周三下午" silently becomes the arrangement and somebody turns up on the
//! wrong day — which is worse than the scrolling this feature replaces.
//!
//! **Changing a term withdraws agreement to it.** Consent was to the old value.
//! Carrying it forward would let one party edit the price under the other's
//! existing yes, which is the most damaging thing this data model could do.

use goods4ncu::services::agreement::{slots, AgreementService, ASSISTANT};
use goods4ncu::test_infra::with_test_pool;
use uuid::Uuid;

async fn campus(pool: &sqlx::PgPool) -> Uuid {
    sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
        .fetch_one(pool)
        .await
        .expect("ncu campus")
}

async fn member(pool: &sqlx::PgPool, campus_id: Uuid, tag: &str) -> String {
    let id = format!("ag-{tag}-{}", Uuid::new_v4().simple());
    sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
        .bind(&id)
        .bind(format!("ag_{tag}_{}", Uuid::new_v4().simple()))
        .execute(pool)
        .await
        .expect("insert user");
    sqlx::query(
        "INSERT INTO campus_memberships (campus_id, user_id, status, verification_method,
                                         verified_at)
         VALUES ($1, $2, 'verified', 'test_fixture', NOW())",
    )
    .bind(campus_id)
    .bind(&id)
    .execute(pool)
    .await
    .expect("insert membership");
    id
}

async fn conversation(pool: &sqlx::PgPool, campus_id: Uuid, a: &str, b: &str) -> Uuid {
    sqlx::query_scalar(
        "INSERT INTO chat_conversations (campus_id, client_request_id, mode, state,
                                         initiator_id, recipient_id, created_at,
                                         last_activity_at)
         VALUES ($1, $2, 'realtime', 'active', $3, $4, NOW(), NOW())
         RETURNING id",
    )
    .bind(campus_id)
    .bind(Uuid::new_v4())
    .bind(a)
    .bind(b)
    .fetch_one(pool)
    .await
    .expect("insert conversation")
}

#[tokio::test]
async fn an_assistant_extraction_waits_for_a_person() {
    // The safety property. The model may read "周三下午三点" out of the thread and
    // put it on the card, but it is a suggestion until somebody says yes.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let seller = member(&pool, campus_id, "seller").await;
        let buyer = member(&pool, campus_id, "buyer").await;
        let convo = conversation(&pool, campus_id, &seller, &buyer).await;
        let service = AgreementService::new(pool.clone());

        let agreement = service
            .ensure_for_conversation(campus_id, convo, "deal")
            .await
            .expect("ensure");

        assert!(service
            .set_term(
                agreement,
                slots::TIME,
                "周三下午三点",
                None,
                ASSISTANT,
                Some(42)
            )
            .await
            .expect("assistant proposes"));

        let view = service
            .view(agreement, &buyer)
            .await
            .expect("view")
            .expect("participant");
        let term = view.terms.iter().find(|t| t.slot == slots::TIME).unwrap();

        assert!(
            term.agreed_by.is_empty(),
            "nobody has agreed to an extraction"
        );
        assert!(term.suggestion);
        assert!(!view.is_fully_agreed());
        // Traceable back to the message it came from, so a member can check the
        // assistant's work rather than take it on faith.
        assert_eq!(term.source_message_id, Some(42));

        // Adopting is what makes it real, and only for whoever adopted.
        assert!(service
            .adopt_term(agreement, slots::TIME, &buyer, "周三下午三点")
            .await
            .expect("adopt"));
        let view = service
            .view(agreement, &buyer)
            .await
            .expect("view")
            .expect("participant");
        let term = view.terms.iter().find(|t| t.slot == slots::TIME).unwrap();
        assert_eq!(term.agreed_by, vec![buyer.clone()]);
        assert!(!term.is_settled(&view.participants), "the seller has not");
    })
    .await;
}

#[tokio::test]
async fn changing_a_term_withdraws_the_agreement_to_it() {
    // The most damaging thing this model could do is let one side edit the price
    // under the other's existing yes. Consent was to the old value.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let seller = member(&pool, campus_id, "seller").await;
        let buyer = member(&pool, campus_id, "buyer").await;
        let convo = conversation(&pool, campus_id, &seller, &buyer).await;
        let service = AgreementService::new(pool.clone());
        let agreement = service
            .ensure_for_conversation(campus_id, convo, "deal")
            .await
            .expect("ensure");

        // 300, agreed by both.
        service
            .set_term(
                agreement,
                slots::PRICE,
                "300 元",
                Some(30_000),
                &seller,
                None,
            )
            .await
            .expect("seller states");
        service
            .adopt_term(agreement, slots::PRICE, &buyer, "300 元")
            .await
            .expect("buyer agrees");
        let view = service.view(agreement, &buyer).await.expect("v").unwrap();
        assert!(view.terms[0].is_settled(&view.participants));

        // The seller changes it to 350.
        service
            .set_term(
                agreement,
                slots::PRICE,
                "350 元",
                Some(35_000),
                &seller,
                None,
            )
            .await
            .expect("seller changes");

        let view = service.view(agreement, &buyer).await.expect("v").unwrap();
        let term = &view.terms[0];
        assert_eq!(term.value, "350 元");
        assert_eq!(
            term.agreed_by,
            vec![seller.clone()],
            "the buyer's yes was to 300 and does not carry over",
        );
        assert!(!term.is_settled(&view.participants));
    })
    .await;
}

#[tokio::test]
async fn adopting_cannot_land_on_a_value_that_changed_underneath() {
    // "I agreed to 300 and it says 350." The expected value is checked, so a card
    // edited while it was on screen cannot capture a stale tap.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let seller = member(&pool, campus_id, "seller").await;
        let buyer = member(&pool, campus_id, "buyer").await;
        let convo = conversation(&pool, campus_id, &seller, &buyer).await;
        let service = AgreementService::new(pool.clone());
        let agreement = service
            .ensure_for_conversation(campus_id, convo, "deal")
            .await
            .expect("ensure");

        service
            .set_term(
                agreement,
                slots::PRICE,
                "300 元",
                Some(30_000),
                &seller,
                None,
            )
            .await
            .expect("stated");
        // It changes before the buyer's tap arrives.
        service
            .set_term(
                agreement,
                slots::PRICE,
                "350 元",
                Some(35_000),
                &seller,
                None,
            )
            .await
            .expect("changed");

        assert!(
            !service
                .adopt_term(agreement, slots::PRICE, &buyer, "300 元")
                .await
                .expect("stale adopt"),
            "a tap on the old value must not agree to the new one",
        );
        let view = service.view(agreement, &buyer).await.expect("v").unwrap();
        assert!(!view.terms[0].agreed_by.contains(&buyer));
    })
    .await;
}

#[tokio::test]
async fn one_card_per_conversation() {
    // Two cards would recreate the problem this replaces: a second place to look
    // for the answer.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let a = member(&pool, campus_id, "a").await;
        let b = member(&pool, campus_id, "b").await;
        let convo = conversation(&pool, campus_id, &a, &b).await;
        let service = AgreementService::new(pool.clone());

        let first = service
            .ensure_for_conversation(campus_id, convo, "deal")
            .await
            .expect("first");
        let second = service
            .ensure_for_conversation(campus_id, convo, "deal")
            .await
            .expect("second");
        assert_eq!(first, second);

        let count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM agreements WHERE conversation_id = $1")
                .bind(convo)
                .fetch_one(&pool)
                .await
                .expect("count");
        assert_eq!(count, 1);
    })
    .await;
}

#[tokio::test]
async fn a_meetup_has_no_price_to_state() {
    // Pricing a game of badminton is a category error, and a slot that accepts it
    // invites it.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let a = member(&pool, campus_id, "a").await;
        let b = member(&pool, campus_id, "b").await;
        let convo = conversation(&pool, campus_id, &a, &b).await;
        let service = AgreementService::new(pool.clone());
        let agreement = service
            .ensure_for_conversation(campus_id, convo, "meetup")
            .await
            .expect("ensure");

        let error = service
            .set_term(agreement, slots::PRICE, "300 元", Some(30_000), &a, None)
            .await
            .expect_err("a meetup has no price");
        assert!(error.to_string().contains("price"), "error: {error}");

        // The slots it does have work.
        assert!(service
            .set_term(agreement, slots::BRING, "带球拍", None, &a, None)
            .await
            .expect("bring"));
    })
    .await;
}

#[tokio::test]
async fn settling_requires_everyone_to_have_agreed_to_everything() {
    // "Settled" must not be able to mean "one of us decided".
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let seller = member(&pool, campus_id, "seller").await;
        let buyer = member(&pool, campus_id, "buyer").await;
        let convo = conversation(&pool, campus_id, &seller, &buyer).await;
        let service = AgreementService::new(pool.clone());
        let agreement = service
            .ensure_for_conversation(campus_id, convo, "deal")
            .await
            .expect("ensure");

        service
            .set_term(agreement, slots::ITEM, "台灯", None, &seller, None)
            .await
            .expect("item");
        service
            .set_term(agreement, slots::PRICE, "30 元", Some(3_000), &seller, None)
            .await
            .expect("price");

        assert!(
            !service.settle(agreement, &seller).await.expect("premature"),
            "the buyer has agreed to nothing yet",
        );

        service
            .adopt_term(agreement, slots::ITEM, &buyer, "台灯")
            .await
            .expect("adopt item");
        assert!(
            !service.settle(agreement, &seller).await.expect("partial"),
            "one term short is still short",
        );

        service
            .adopt_term(agreement, slots::PRICE, &buyer, "30 元")
            .await
            .expect("adopt price");
        assert!(service.settle(agreement, &seller).await.expect("settle"));

        let status: String = sqlx::query_scalar("SELECT status FROM agreements WHERE id = $1")
            .bind(agreement)
            .fetch_one(&pool)
            .await
            .expect("status");
        assert_eq!(status, "settled");

        // Settling twice is not an error the caller has to handle, but it does
        // not happen twice either.
        assert!(!service.settle(agreement, &seller).await.expect("again"));
    })
    .await;
}

#[tokio::test]
async fn the_card_shows_the_words_they_actually_used() {
    // A normalised value would lose "周三下午图书馆东门那边" and gain nothing. The
    // point of the card is that both people recognise their own arrangement in
    // it.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let a = member(&pool, campus_id, "a").await;
        let b = member(&pool, campus_id, "b").await;
        let convo = conversation(&pool, campus_id, &a, &b).await;
        let service = AgreementService::new(pool.clone());
        let agreement = service
            .ensure_for_conversation(campus_id, convo, "meetup")
            .await
            .expect("ensure");

        service
            .set_term(
                agreement,
                slots::PLACE,
                "图书馆东门那边的台阶",
                None,
                &a,
                None,
            )
            .await
            .expect("place");

        let view = service.view(agreement, &b).await.expect("v").unwrap();
        assert_eq!(view.terms[0].value, "图书馆东门那边的台阶");
    })
    .await;
}

#[tokio::test]
async fn someone_outside_the_conversation_sees_nothing() {
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let a = member(&pool, campus_id, "a").await;
        let b = member(&pool, campus_id, "b").await;
        let outsider = member(&pool, campus_id, "outsider").await;
        let convo = conversation(&pool, campus_id, &a, &b).await;
        let service = AgreementService::new(pool.clone());
        let agreement = service
            .ensure_for_conversation(campus_id, convo, "deal")
            .await
            .expect("ensure");
        service
            .set_term(agreement, slots::PRICE, "300 元", Some(30_000), &a, None)
            .await
            .expect("price");

        assert!(
            service
                .view(agreement, &outsider)
                .await
                .expect("view")
                .is_none(),
            "an arrangement is between its participants",
        );
        assert!(!service.settle(agreement, &outsider).await.expect("settle"));
    })
    .await;
}
