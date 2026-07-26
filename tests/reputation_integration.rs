//! Trust built from what actually happened.
//!
//! The properties under test are all about what this refuses to do. A
//! reputation system on a campus can do real damage — the people it describes
//! will see each other for years — so the interesting assertions are the
//! absences: no revising your account after a falling-out, no answering about
//! an arrangement you were not part of, no penalty for being new, and no way to
//! see what the other person said before you say yours.

use goods4ncu::services::agreement::{slots, AgreementService};
use goods4ncu::services::reputation::{ReputationService, MIN_FOR_A_TRACK_RECORD};
use goods4ncu::test_infra::with_test_pool;
use uuid::Uuid;

async fn campus(pool: &sqlx::PgPool) -> Uuid {
    sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
        .fetch_one(pool)
        .await
        .expect("ncu campus")
}

async fn member(pool: &sqlx::PgPool, campus_id: Uuid, tag: &str) -> String {
    let id = format!("rep-{tag}-{}", Uuid::new_v4().simple());
    sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
        .bind(&id)
        .bind(format!("rep_{tag}_{}", Uuid::new_v4().simple()))
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

/// A settled arrangement between two people — the precondition for confirming.
///
/// Each one gets its own listing. Two people may only have one live realtime
/// thread about the same thing, which is correct product behaviour, so several
/// arrangements between the same pair have to be about several items.
async fn settled_arrangement(pool: &sqlx::PgPool, campus_id: Uuid, a: &str, b: &str) -> Uuid {
    let listing_id = Uuid::new_v4().to_string();
    sqlx::query(
        "INSERT INTO inventory (id, campus_id, title, category, brand, condition_score,
                                suggested_price_cny, defects, owner_id, status)
         VALUES ($1, $2, '台灯', 'misc', '', 8, 3000, '[]', $3, 'active')",
    )
    .bind(&listing_id)
    .bind(campus_id)
    .bind(a)
    .execute(pool)
    .await
    .expect("listing");

    let convo: Uuid = sqlx::query_scalar(
        "INSERT INTO chat_conversations (campus_id, client_request_id, mode, state,
                                         initiator_id, recipient_id, listing_id,
                                         created_at, last_activity_at)
         VALUES ($1, $2, 'realtime', 'active', $3, $4, $5, NOW(), NOW())
         RETURNING id",
    )
    .bind(campus_id)
    .bind(Uuid::new_v4())
    .bind(a)
    .bind(b)
    .bind(&listing_id)
    .fetch_one(pool)
    .await
    .expect("conversation");

    let service = AgreementService::new(pool.clone());
    let agreement = service
        .ensure_for_conversation(campus_id, convo, "deal")
        .await
        .expect("agreement");
    service
        .set_term(agreement, slots::ITEM, "台灯", None, a, None)
        .await
        .expect("term");
    service
        .adopt_term(agreement, slots::ITEM, b, "台灯")
        .await
        .expect("adopt");
    assert!(service.settle(agreement, a).await.expect("settle"));
    agreement
}

#[tokio::test]
async fn a_record_is_two_facts_and_no_opinion() {
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let seller = member(&pool, campus_id, "seller").await;
        let buyer = member(&pool, campus_id, "buyer").await;
        let service = ReputationService::new(pool.clone());

        for _ in 0..MIN_FOR_A_TRACK_RECORD {
            let agreement = settled_arrangement(&pool, campus_id, &seller, &buyer).await;
            assert!(service
                .confirm(agreement, &buyer, true, Some(true))
                .await
                .expect("confirm"));
        }

        let record = service.of(campus_id, &seller).await.expect("reputation");
        assert_eq!(record.completed, MIN_FOR_A_TRACK_RECORD);
        assert_eq!(record.on_time, MIN_FOR_A_TRACK_RECORD);
        assert_eq!(record.missed, 0);
        assert!(record.has_track_record);
        assert_eq!(record.matching_weight(), 1.0);
    })
    .await;
}

#[tokio::test]
async fn a_newcomer_is_unmeasured_rather_than_untrusted() {
    // Having no history is the normal state of a first-year in September. A
    // system that reads it as risk makes the community impossible to join.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let fresh = member(&pool, campus_id, "fresh").await;

        let record = ReputationService::new(pool.clone())
            .of(campus_id, &fresh)
            .await
            .expect("reputation");
        assert_eq!(record.completed, 0);
        assert!(!record.has_track_record);
        assert_eq!(
            record.matching_weight(),
            0.5,
            "neutral, not bottom of the list",
        );
    })
    .await;
}

#[tokio::test]
async fn nobody_can_revise_their_account_after_the_fact() {
    // The failure this prevents: a falling-out later, and one party goes back
    // to change what they said happened.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let seller = member(&pool, campus_id, "seller").await;
        let buyer = member(&pool, campus_id, "buyer").await;
        let service = ReputationService::new(pool.clone());
        let agreement = settled_arrangement(&pool, campus_id, &seller, &buyer).await;

        assert!(service
            .confirm(agreement, &buyer, true, Some(true))
            .await
            .expect("first"));
        assert!(
            !service
                .confirm(agreement, &buyer, false, None)
                .await
                .expect("second"),
            "a second answer is refused, not applied",
        );

        let record = service.of(campus_id, &seller).await.expect("reputation");
        assert_eq!(record.completed, 1);
        assert_eq!(record.missed, 0, "the original answer stands");
    })
    .await;
}

#[tokio::test]
async fn only_a_participant_in_a_settled_arrangement_may_answer() {
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let seller = member(&pool, campus_id, "seller").await;
        let buyer = member(&pool, campus_id, "buyer").await;
        let stranger = member(&pool, campus_id, "stranger").await;
        let service = ReputationService::new(pool.clone());
        let agreement = settled_arrangement(&pool, campus_id, &seller, &buyer).await;

        assert!(
            !service
                .confirm(agreement, &stranger, false, None)
                .await
                .expect("stranger"),
            "someone outside the arrangement cannot report on it",
        );
        assert_eq!(service.of(campus_id, &seller).await.expect("rep").missed, 0,);
    })
    .await;
}

#[tokio::test]
async fn an_arrangement_nobody_agreed_to_cannot_be_confirmed() {
    // Otherwise a handoff could be recorded for something that was never
    // arranged, which is a way to manufacture a record against someone.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let a = member(&pool, campus_id, "a").await;
        let b = member(&pool, campus_id, "b").await;

        let convo: Uuid = sqlx::query_scalar(
            "INSERT INTO chat_conversations (campus_id, client_request_id, mode, state,
                                             initiator_id, recipient_id, created_at,
                                             last_activity_at)
             VALUES ($1, $2, 'realtime', 'active', $3, $4, NOW(), NOW())
             RETURNING id",
        )
        .bind(campus_id)
        .bind(Uuid::new_v4())
        .bind(&a)
        .bind(&b)
        .fetch_one(&pool)
        .await
        .expect("conversation");
        // Created but never settled.
        let agreement = AgreementService::new(pool.clone())
            .ensure_for_conversation(campus_id, convo, "deal")
            .await
            .expect("agreement");

        assert!(
            !ReputationService::new(pool.clone())
                .confirm(agreement, &a, false, None)
                .await
                .expect("unsettled"),
            "there was no arrangement to miss",
        );
    })
    .await;
}

#[tokio::test]
async fn punctuality_is_not_asked_about_a_meeting_that_did_not_happen() {
    // Demanding an answer would manufacture data. And claiming someone was
    // "late" for something that never occurred is not a fact about them.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let seller = member(&pool, campus_id, "seller").await;
        let buyer = member(&pool, campus_id, "buyer").await;
        let service = ReputationService::new(pool.clone());
        let agreement = settled_arrangement(&pool, campus_id, &seller, &buyer).await;

        assert!(service
            .confirm(agreement, &buyer, false, None)
            .await
            .expect("no-show"));

        let stored: Option<bool> =
            sqlx::query_scalar("SELECT on_time FROM handoff_confirmations WHERE agreement_id = $1")
                .bind(agreement)
                .fetch_one(&pool)
                .await
                .expect("row");
        assert!(stored.is_none());

        // And saying it happened without saying whether they were on time is
        // refused rather than silently defaulted.
        let other = settled_arrangement(&pool, campus_id, &seller, &buyer).await;
        assert!(service.confirm(other, &buyer, true, None).await.is_err());
    })
    .await;
}

#[tokio::test]
async fn both_sides_answer_independently() {
    // Neither sees the other's answer, so nobody is answering in reaction — and
    // a record is one person's account of the other, never a mutual score.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let seller = member(&pool, campus_id, "seller").await;
        let buyer = member(&pool, campus_id, "buyer").await;
        let service = ReputationService::new(pool.clone());
        let agreement = settled_arrangement(&pool, campus_id, &seller, &buyer).await;

        assert!(service
            .confirm(agreement, &buyer, true, Some(false))
            .await
            .expect("buyer says late"));
        assert!(service
            .confirm(agreement, &seller, true, Some(true))
            .await
            .expect("seller says on time"));

        // Each answer lands on the other person, not on the answerer.
        let seller_record = service.of(campus_id, &seller).await.expect("seller");
        assert_eq!(seller_record.completed, 1);
        assert_eq!(seller_record.on_time, 0, "the buyer said they were late");

        let buyer_record = service.of(campus_id, &buyer).await.expect("buyer");
        assert_eq!(buyer_record.completed, 1);
        assert_eq!(buyer_record.on_time, 1);
    })
    .await;
}

#[tokio::test]
async fn a_settled_arrangement_prompts_each_side_once() {
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let seller = member(&pool, campus_id, "seller").await;
        let buyer = member(&pool, campus_id, "buyer").await;
        let service = ReputationService::new(pool.clone());
        let agreement = settled_arrangement(&pool, campus_id, &seller, &buyer).await;

        assert_eq!(
            service.awaiting_confirmation(&buyer).await.expect("await"),
            vec![agreement],
        );

        service
            .confirm(agreement, &buyer, true, Some(true))
            .await
            .expect("confirm");
        assert!(
            service
                .awaiting_confirmation(&buyer)
                .await
                .expect("after")
                .is_empty(),
            "answered once is answered; the prompt does not nag",
        );
        // The other side is still owed the question.
        assert_eq!(
            service.awaiting_confirmation(&seller).await.expect("other"),
            vec![agreement],
        );
    })
    .await;
}

#[tokio::test]
async fn reputation_does_not_travel_between_campuses() {
    with_test_pool(|pool| async move {
        let ncu = campus(&pool).await;
        let other: Uuid = sqlx::query_scalar(
            "INSERT INTO campuses (id, slug, name_zh, name_en, email_domains, status)
             VALUES (gen_random_uuid(), $1, '隔离测试校区', 'Isolation', ARRAY[$2], 'active')
             RETURNING id",
        )
        .bind(format!("rep-other-{}", Uuid::new_v4().simple()))
        .bind(format!("stu.rep-{}.test", Uuid::new_v4().simple()))
        .fetch_one(&pool)
        .await
        .expect("campus");

        let seller = member(&pool, ncu, "seller").await;
        let buyer = member(&pool, ncu, "buyer").await;
        let service = ReputationService::new(pool.clone());
        let agreement = settled_arrangement(&pool, ncu, &seller, &buyer).await;
        service
            .confirm(agreement, &buyer, true, Some(true))
            .await
            .expect("confirm");

        assert_eq!(
            service
                .of(other, &seller)
                .await
                .expect("other campus")
                .completed,
            0,
        );
    })
    .await;
}
