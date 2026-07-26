//! Community health metrics, checked against hand-built scenarios.
//!
//! These numbers exist to answer "is this place working for the people on it",
//! and their entire value is being right. A dashboard that quietly
//! miscalculates is worse than none: it produces confident decisions from
//! wrong evidence. So each test constructs a situation whose answer is known
//! by hand and asserts the arithmetic lands on it.
//!
//! They also pin the *definitions*, which is where metrics usually rot. That
//! completion is measured over answered posts and not all posts, that a
//! relationship needs a second interaction to count, that an ignored
//! notification is not a rejection — those are judgements, and a later change
//! that quietly redefines one would make the series incomparable while still
//! looking healthy.

use goods4ncu::services::community_health::CommunityHealthService;
use goods4ncu::services::interruption::{
    topics, Decision, InterruptionRequest, InterruptionService, Preferences,
};
use goods4ncu::test_infra::with_test_pool;
use uuid::Uuid;

async fn ncu(pool: &sqlx::PgPool) -> Uuid {
    sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
        .fetch_one(pool)
        .await
        .expect("ncu campus")
}

/// A member of the campus, created `age_days` ago.
async fn member(pool: &sqlx::PgPool, campus_id: Uuid, tag: &str, age_days: i64) -> String {
    let id = format!("health-{tag}-{}", Uuid::new_v4().simple());
    sqlx::query(
        "INSERT INTO users (id, username, password_hash, created_at)
         VALUES ($1, $2, 'hash', NOW() - make_interval(days => $3::int))",
    )
    .bind(&id)
    .bind(format!("health_{tag}_{}", Uuid::new_v4().simple()))
    .bind(age_days as i32)
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

async fn listing(
    pool: &sqlx::PgPool,
    campus_id: Uuid,
    owner: &str,
    title: &str,
    hours_ago: i64,
) -> String {
    let id = Uuid::new_v4().to_string();
    sqlx::query(
        "INSERT INTO inventory (id, campus_id, title, category, brand, condition_score,
                                suggested_price_cny, defects, owner_id, status, created_at)
         VALUES ($1, $2, $3, 'misc', 'Brand', 8, 3000, '[]', $4, 'active',
                 NOW() - make_interval(hours => $5::int))",
    )
    .bind(&id)
    .bind(campus_id)
    .bind(title)
    .bind(owner)
    .bind(hours_ago as i32)
    .execute(pool)
    .await
    .expect("insert listing");
    id
}

/// A conversation opened about a listing, `hours_ago` hours back.
async fn conversation(
    pool: &sqlx::PgPool,
    campus_id: Uuid,
    listing_id: &str,
    initiator: &str,
    recipient: &str,
    hours_ago: i64,
) -> Uuid {
    sqlx::query_scalar(
        "INSERT INTO chat_conversations (campus_id, client_request_id, mode, state,
                                         initiator_id, recipient_id, listing_id,
                                         created_at, last_activity_at)
         VALUES ($1, $6, 'realtime', 'active', $2, $3, $4,
                 NOW() - make_interval(hours => $5::int),
                 NOW() - make_interval(hours => $5::int))
         RETURNING id",
    )
    .bind(campus_id)
    .bind(initiator)
    .bind(recipient)
    .bind(listing_id)
    .bind(hours_ago as i32)
    .bind(Uuid::new_v4())
    .fetch_one(pool)
    .await
    .expect("insert conversation")
}

async fn message(
    pool: &sqlx::PgPool,
    conversation_id: Uuid,
    listing_id: &str,
    sender: &str,
    hours_ago: i64,
) {
    // `id` is a bigint identity column, left to the database. `conversation_id`
    // is the legacy per-listing thread key and is still NOT NULL, distinct from
    // `direct_conversation_id`, which is the row the metrics join on.
    sqlx::query(
        "INSERT INTO chat_messages (conversation_id, direct_conversation_id, listing_id,
                                    sender, content, timestamp)
         VALUES ($1::text, $2, $3, $4, 'hi', NOW() - make_interval(hours => $5::int))",
    )
    .bind(conversation_id.to_string())
    .bind(conversation_id)
    .bind(listing_id)
    .bind(sender)
    .bind(hours_ago as i32)
    .execute(pool)
    .await
    .expect("insert message");
}

async fn confirmed_order(
    pool: &sqlx::PgPool,
    campus_id: Uuid,
    listing_id: &str,
    buyer: &str,
    seller: &str,
    hours_ago: i64,
) {
    sqlx::query(
        "INSERT INTO orders (id, campus_id, listing_id, buyer_id, seller_id, final_price,
                             status, created_at, confirmed_at, updated_at)
         VALUES ($1, $2, $3, $4, $5, 3000, 'confirmed',
                 NOW() - make_interval(hours => $6::int),
                 NOW() - make_interval(hours => $6::int),
                 NOW() - make_interval(hours => $6::int))",
    )
    .bind(Uuid::new_v4().to_string())
    .bind(campus_id)
    .bind(listing_id)
    .bind(buyer)
    .bind(seller)
    .bind(hours_ago as i32)
    .execute(pool)
    .await
    .expect("insert order");
}

#[tokio::test]
async fn answer_rate_counts_posts_nobody_replied_to() {
    // The metric that matters most, because it is the one an activity count
    // hides: an ignored post and a useful one are both "one post".
    with_test_pool(|pool| async move {
        let campus = ncu(&pool).await;
        let seller = member(&pool, campus, "seller", 30).await;
        let buyer = member(&pool, campus, "buyer", 30).await;

        // Three posts; two get a reply, one is ignored.
        let answered_a = listing(&pool, campus, &seller, "回应A", 10).await;
        let answered_b = listing(&pool, campus, &seller, "回应B", 8).await;
        let _ignored = listing(&pool, campus, &seller, "无人理", 6).await;

        // Replied two hours after posting.
        conversation(&pool, campus, &answered_a, &buyer, &seller, 8).await;
        conversation(&pool, campus, &answered_b, &buyer, &seller, 6).await;

        let health = CommunityHealthService::new(pool.clone())
            .measure(campus, 30)
            .await
            .expect("measure");

        assert_eq!(health.intent.posted, 3);
        assert_eq!(health.intent.answered, 2);
        assert!((health.intent.answer_rate - 2.0 / 3.0).abs() < 1e-9);

        // Both waited two hours, so the median is 120 minutes.
        let p50 = health.intent.first_answer_p50_minutes.expect("median");
        assert!((p50 - 120.0).abs() < 1.0, "p50 was {p50}");
    })
    .await;
}

#[tokio::test]
async fn completion_is_measured_over_answered_posts_not_all_posts() {
    // A definition worth pinning. Dividing by every post would fold the answer
    // rate into completion, so a community with lots of ignored posts would
    // look like one that is bad at closing deals — two different diseases with
    // different cures.
    with_test_pool(|pool| async move {
        let campus = ncu(&pool).await;
        let seller = member(&pool, campus, "seller", 30).await;
        let buyer = member(&pool, campus, "buyer", 30).await;

        let closed = listing(&pool, campus, &seller, "成交了", 10).await;
        let stalled = listing(&pool, campus, &seller, "聊了没成", 10).await;
        let _ignored = listing(&pool, campus, &seller, "没人理", 10).await;

        conversation(&pool, campus, &closed, &buyer, &seller, 9).await;
        conversation(&pool, campus, &stalled, &buyer, &seller, 9).await;
        confirmed_order(&pool, campus, &closed, &buyer, &seller, 8).await;

        let health = CommunityHealthService::new(pool.clone())
            .measure(campus, 30)
            .await
            .expect("measure");

        assert_eq!(
            health.agreement.answered, 2,
            "denominator is answered posts"
        );
        assert_eq!(health.agreement.confirmed, 1);
        assert!((health.agreement.completion_rate - 0.5).abs() < 1e-9);
    })
    .await;
}

#[tokio::test]
async fn messages_to_agreement_counts_only_what_came_before_the_deal() {
    // This is the number that tests the assistant's actual claim: that settling
    // what/when/where takes less back-and-forth here. Messages after the
    // handshake are not part of reaching it.
    with_test_pool(|pool| async move {
        let campus = ncu(&pool).await;
        let seller = member(&pool, campus, "seller", 30).await;
        let buyer = member(&pool, campus, "buyer", 30).await;
        let item = listing(&pool, campus, &seller, "台灯", 20).await;
        let convo = conversation(&pool, campus, &item, &buyer, &seller, 19).await;

        // Four messages settling it, then the deal, then two more afterwards.
        for hours in [18, 17, 16, 15] {
            message(&pool, convo, &item, &buyer, hours).await;
        }
        confirmed_order(&pool, campus, &item, &buyer, &seller, 14).await;
        for hours in [13, 12] {
            message(&pool, convo, &item, &seller, hours).await;
        }

        let health = CommunityHealthService::new(pool.clone())
            .measure(campus, 30)
            .await
            .expect("measure");

        let p50 = health
            .agreement
            .messages_to_agreement_p50
            .expect("median messages");
        assert!(
            (p50 - 4.0).abs() < 1e-9,
            "only pre-agreement messages count, got {p50}",
        );
    })
    .await;
}

#[tokio::test]
async fn a_relationship_needs_a_second_interaction_to_count() {
    // "People met" is cheap; "people came back to each other" is the community
    // actually working. One exchange and silence is not a relationship.
    with_test_pool(|pool| async move {
        let campus = ncu(&pool).await;
        let a = member(&pool, campus, "a", 30).await;
        let b = member(&pool, campus, "b", 30).await;
        let c = member(&pool, campus, "c", 30).await;

        // a↔b interact twice, through two different channels.
        let item1 = listing(&pool, campus, &a, "第一件", 20).await;
        conversation(&pool, campus, &item1, &b, &a, 19).await;
        confirmed_order(&pool, campus, &item1, &b, &a, 18).await;

        // a↔c interact once and never again.
        let item2 = listing(&pool, campus, &a, "第二件", 20).await;
        conversation(&pool, campus, &item2, &c, &a, 19).await;

        let health = CommunityHealthService::new(pool.clone())
            .measure(campus, 30)
            .await
            .expect("measure");

        assert_eq!(health.relationships.first_met, 2, "two pairs met");
        assert_eq!(
            health.relationships.interacted_again, 1,
            "only a↔b came back",
        );
        assert!((health.relationships.stickiness - 0.5).abs() < 1e-9);
    })
    .await;
}

#[tokio::test]
async fn a_pair_is_unordered_so_direction_does_not_double_count() {
    // Without normalising the pair, A contacting B and B contacting A would
    // read as two relationships that each interacted once — inflating "met"
    // and erasing the stickiness that actually happened.
    with_test_pool(|pool| async move {
        let campus = ncu(&pool).await;
        let a = member(&pool, campus, "a", 30).await;
        let b = member(&pool, campus, "b", 30).await;

        let a_item = listing(&pool, campus, &a, "A 的东西", 20).await;
        let b_item = listing(&pool, campus, &b, "B 的东西", 20).await;
        conversation(&pool, campus, &a_item, &b, &a, 19).await;
        conversation(&pool, campus, &b_item, &a, &b, 18).await;

        let health = CommunityHealthService::new(pool.clone())
            .measure(campus, 30)
            .await
            .expect("measure");

        assert_eq!(
            health.relationships.first_met, 1,
            "one relationship, not two"
        );
        assert_eq!(health.relationships.interacted_again, 1);
    })
    .await;
}

#[tokio::test]
async fn newcomer_retention_excludes_accounts_too_young_to_judge() {
    // Counting a two-day-old account as churned would make retention drop
    // every time the community grew, which is exactly backwards.
    with_test_pool(|pool| async move {
        let campus = ncu(&pool).await;

        // Old enough to judge: stayed.
        let stayed = member(&pool, campus, "stayed", 20).await;
        // Old enough to judge: drifted away after signing up.
        let _drifted = member(&pool, campus, "drifted", 20).await;
        // Too young for the question to be answerable.
        let fresh = member(&pool, campus, "fresh", 2).await;

        // Activity on day 10, well past the one-week mark.
        listing(&pool, campus, &stayed, "还在用", 10 * 24).await;
        // The newest member is busy, but it is too early to count them.
        listing(&pool, campus, &fresh, "刚来", 1).await;

        let health = CommunityHealthService::new(pool.clone())
            .measure(campus, 30)
            .await
            .expect("measure");

        assert_eq!(
            health.newcomers.cohort, 2,
            "the 2-day-old is not judged yet"
        );
        assert_eq!(health.newcomers.still_active_after_a_week, 1);
        assert!((health.newcomers.day7_retention - 0.5).abs() < 1e-9);
    })
    .await;
}

#[tokio::test]
async fn an_ignored_notification_is_not_counted_as_a_rejection() {
    // Acceptance is measured over *decided* interruptions. Treating silence as
    // rejection would push the system to interrupt less than the evidence
    // warrants — and not every notification asks for an answer.
    with_test_pool(|pool| async move {
        let campus = ncu(&pool).await;
        let user = member(&pool, campus, "reader", 30).await;
        let interruptions = InterruptionService::new(pool.clone());
        interruptions
            .set_preferences(
                &user,
                &Preferences {
                    daily_budget: 10,
                    ..Preferences::default()
                },
            )
            .await
            .expect("raise budget");

        let mut ledger_ids = Vec::new();
        for _ in 0..3 {
            let decision = interruptions
                .request(InterruptionRequest {
                    campus_id: campus,
                    user_id: &user,
                    channel: "in_app",
                    topic: topics::MATCH_FOUND,
                    reason: "测试：健康度统计",
                    expected_value: 0.9,
                })
                .await
                .expect("request");
            assert!(matches!(decision, Decision::Granted(_)));
            ledger_ids.push(decision.ledger_id().expect("recorded"));
        }

        // One accepted, one dismissed, one left alone.
        interruptions
            .mark_accepted(&user, ledger_ids[0])
            .await
            .expect("accept");
        interruptions
            .mark_dismissed(&user, ledger_ids[1])
            .await
            .expect("dismiss");

        let health = CommunityHealthService::new(pool.clone())
            .measure(campus, 30)
            .await
            .expect("measure");

        assert_eq!(health.interruptions.delivered, 3);
        assert_eq!(health.interruptions.accepted, 1);
        assert_eq!(health.interruptions.dismissed, 1);
        let rate = health.interruptions.acceptance_rate.expect("rate");
        assert!(
            (rate - 0.5).abs() < 1e-9,
            "1 of 2 decided, not 1 of 3 delivered; got {rate}",
        );
    })
    .await;
}

#[tokio::test]
async fn metrics_do_not_leak_across_campuses() {
    // Every figure is a per-campus judgement. One campus's silence must not be
    // hidden by another's activity.
    with_test_pool(|pool| async move {
        let ncu_id = ncu(&pool).await;
        let other_id: Uuid = sqlx::query_scalar(
            "INSERT INTO campuses (id, slug, name_zh, name_en, email_domains, status)
             VALUES (gen_random_uuid(), $1, '隔离测试校区', 'Isolation Test Campus',
                     ARRAY[$2], 'active')
             RETURNING id",
        )
        .bind(format!("health-other-{}", Uuid::new_v4().simple()))
        .bind(format!("stu.health-{}.test", Uuid::new_v4().simple()))
        .fetch_one(&pool)
        .await
        .expect("insert campus");

        let seller = member(&pool, ncu_id, "seller", 30).await;
        let buyer = member(&pool, ncu_id, "buyer", 30).await;
        let item = listing(&pool, ncu_id, &seller, "本校商品", 10).await;
        conversation(&pool, ncu_id, &item, &buyer, &seller, 9).await;

        let health = CommunityHealthService::new(pool.clone())
            .measure(other_id, 30)
            .await
            .expect("measure other campus");

        assert_eq!(health.intent.posted, 0);
        assert_eq!(health.relationships.first_met, 0);
        assert_eq!(health.newcomers.cohort, 0);
        // An empty campus reports zero, not a division by nothing.
        assert_eq!(health.intent.answer_rate, 0.0);
    })
    .await;
}

#[tokio::test]
async fn the_window_bounds_what_is_measured() {
    with_test_pool(|pool| async move {
        let campus = ncu(&pool).await;
        let seller = member(&pool, campus, "seller", 60).await;

        // Posted 40 days ago — outside a 30-day window, inside a 90-day one.
        listing(&pool, campus, &seller, "很久以前", 40 * 24).await;

        let service = CommunityHealthService::new(pool.clone());
        assert_eq!(
            service
                .measure(campus, 30)
                .await
                .expect("30d")
                .intent
                .posted,
            0
        );
        assert_eq!(
            service
                .measure(campus, 90)
                .await
                .expect("90d")
                .intent
                .posted,
            1
        );

        // Absurd windows are clamped rather than trusted.
        assert_eq!(
            service
                .measure(campus, 10_000)
                .await
                .expect("huge")
                .window_days,
            365
        );
        assert_eq!(
            service.measure(campus, 0).await.expect("zero").window_days,
            1
        );
    })
    .await;
}
