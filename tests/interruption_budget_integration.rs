//! Interruption budget.
//!
//! What these tests are defending. A community that matches people and forms
//! groups can always find something else to tell you about, so the limit on
//! proactive outreach has to be structural — enforceable, not merely intended.
//! These assert the two things that make it structural: the budget cannot be
//! walked around by taking the unbudgeted door, and running out of budget
//! silences the push without losing the message.

use goods4ncu::services::interruption::{
    topics, Decision, InterruptionRequest, InterruptionService, Preferences, Suppressed,
};
use goods4ncu::services::notification::{NewNotification, NotificationService};
use goods4ncu::test_infra::with_test_pool;
use uuid::Uuid;

async fn seed_user(pool: &sqlx::PgPool, user_id: &str) -> Uuid {
    sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
        .bind(user_id)
        .bind(format!("intr_user_{}", Uuid::new_v4()))
        .execute(pool)
        .await
        .expect("insert user");
    sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
        .fetch_one(pool)
        .await
        .expect("ncu campus")
}

fn request<'a>(
    campus_id: Uuid,
    user_id: &'a str,
    topic: &'a str,
    value: f32,
) -> InterruptionRequest<'a> {
    InterruptionRequest {
        campus_id,
        user_id,
        channel: "in_app",
        topic,
        reason: "测试用途：这条是为了验证打扰预算",
        expected_value: value,
    }
}

#[tokio::test]
async fn budget_caps_deliveries_and_records_every_attempt() {
    with_test_pool(|pool| async move {
        let user_id = format!("intr-budget-{}", Uuid::new_v4().simple());
        let campus_id = seed_user(&pool, &user_id).await;
        let service = InterruptionService::new(pool.clone());

        // Default budget is 3.
        for i in 0..3 {
            let decision = service
                .request(request(campus_id, &user_id, topics::MATCH_FOUND, 0.9))
                .await
                .expect("request");
            assert!(
                matches!(decision, Decision::Granted(_)),
                "attempt {i} should be granted, got {decision:?}"
            );
        }

        let decision = service
            .request(request(campus_id, &user_id, topics::MATCH_FOUND, 0.9))
            .await
            .expect("fourth request");
        assert!(
            matches!(
                decision,
                Decision::Withheld {
                    reason: Suppressed::Budget,
                    ..
                }
            ),
            "the fourth must be withheld, got {decision:?}"
        );

        assert_eq!(
            service.remaining_budget(&user_id).await.expect("remaining"),
            0
        );

        // All four are on the record — a suppression nobody can see is
        // indistinguishable from having nothing to say.
        let history = service.recent(&user_id, 50).await.expect("history");
        assert_eq!(history.len(), 4);
        assert_eq!(
            history.iter().filter(|e| e.decision == "delivered").count(),
            3
        );
        assert_eq!(
            history
                .iter()
                .filter(|e| e.decision == "suppressed_budget")
                .count(),
            1
        );
        // Every entry can answer "why am I seeing this".
        assert!(history.iter().all(|e| !e.reason.is_empty()));
    })
    .await;
}

#[tokio::test]
async fn a_budgeted_topic_cannot_take_the_unbudgeted_door() {
    // The type system stops a caller pushing without a grant; this is the
    // other half — the plain notification path refuses budgeted topics rather
    // than trusting call sites to remember which door to use.
    with_test_pool(|pool| async move {
        let user_id = format!("intr-door-{}", Uuid::new_v4().simple());
        let campus_id = seed_user(&pool, &user_id).await;

        let error = NotificationService::new(pool.clone())
            .create(NewNotification {
                campus_id,
                user_id: &user_id,
                event_type: topics::MATCH_FOUND,
                title: "sneaking past the budget",
                body: "should not be possible",
                related_order_id: None,
                related_listing_id: None,
                related_conversation_id: None,
                related_space_id: None,
            })
            .await
            .expect_err("budgeted topics must be refused on the unbudgeted path");
        assert!(
            error.to_string().contains("budgeted"),
            "error should explain: {error}"
        );

        let stored: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM notifications WHERE user_id = $1")
                .bind(&user_id)
                .fetch_one(&pool)
                .await
                .expect("count");
        assert_eq!(stored, 0, "the refused notification must not be written");

        // Directed topics still go through untouched.
        NotificationService::new(pool.clone())
            .create(NewNotification {
                campus_id,
                user_id: &user_id,
                event_type: "negotiation_request",
                title: "someone wants to negotiate",
                body: "this is about your own listing",
                related_order_id: None,
                related_listing_id: None,
                related_conversation_id: None,
                related_space_id: None,
            })
            .await
            .expect("directed notifications are never budgeted");
    })
    .await;
}

#[tokio::test]
async fn over_budget_silences_the_push_but_keeps_the_message() {
    // Running out of budget must not look like losing data. The notification
    // still lands in the inbox; only the push is withheld.
    with_test_pool(|pool| async move {
        let user_id = format!("intr-inbox-{}", Uuid::new_v4().simple());
        let campus_id = seed_user(&pool, &user_id).await;
        let interruptions = InterruptionService::new(pool.clone());
        let notifications = NotificationService::new(pool.clone());

        // Spend the budget down to nothing.
        interruptions
            .set_preferences(
                &user_id,
                &Preferences {
                    daily_budget: 0,
                    ..Preferences::default()
                },
            )
            .await
            .expect("set budget to zero");

        let decision = interruptions
            .request(request(campus_id, &user_id, topics::WANTED_RESPONSE, 0.9))
            .await
            .expect("request");
        assert!(matches!(
            decision,
            Decision::Withheld {
                reason: Suppressed::Budget,
                ..
            }
        ));

        let outbox_before: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM outbox_events")
            .fetch_one(&pool)
            .await
            .expect("count outbox");

        notifications
            .create_budgeted(
                &decision,
                NewNotification {
                    campus_id,
                    user_id: &user_id,
                    event_type: topics::WANTED_RESPONSE,
                    title: "有人给你的收物需求推荐了商品",
                    body: "held back from push, still in the inbox",
                    related_order_id: None,
                    related_listing_id: None,
                    related_conversation_id: None,
                    related_space_id: None,
                },
            )
            .await
            .expect("create budgeted");

        // In the inbox…
        let (items, total) = notifications
            .list_all(&user_id, campus_id, 20, 0)
            .await
            .expect("list");
        assert_eq!(total, 1, "the message must survive being over budget");
        // …linked back to the ledger so the user can still accept or dismiss it.
        assert_eq!(items[0].interruption_id, decision.ledger_id());

        // …but nothing was pushed.
        let outbox_after: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM outbox_events")
            .fetch_one(&pool)
            .await
            .expect("count outbox again");
        assert_eq!(
            outbox_after, outbox_before,
            "a withheld interruption must enqueue no push"
        );
    })
    .await;
}

#[tokio::test]
async fn muting_and_quiet_hours_withhold_with_their_own_reasons() {
    with_test_pool(|pool| async move {
        let user_id = format!("intr-mute-{}", Uuid::new_v4().simple());
        let campus_id = seed_user(&pool, &user_id).await;
        let service = InterruptionService::new(pool.clone());

        service
            .set_preferences(
                &user_id,
                &Preferences {
                    muted_topics: vec![topics::MATCH_FOUND.to_string()],
                    ..Preferences::default()
                },
            )
            .await
            .expect("mute topic");

        let decision = service
            .request(request(campus_id, &user_id, topics::MATCH_FOUND, 0.9))
            .await
            .expect("muted request");
        assert!(matches!(
            decision,
            Decision::Withheld {
                reason: Suppressed::Muted,
                ..
            }
        ));

        // A muted topic must not consume budget — otherwise muting one thing
        // would quietly starve everything else.
        let other = service
            .request(request(campus_id, &user_id, topics::SPACE_FORMED, 0.9))
            .await
            .expect("unmuted request");
        assert!(matches!(other, Decision::Granted(_)), "{other:?}");

        // Quiet hours outrank everything.
        service
            .set_preferences(
                &user_id,
                &Preferences {
                    quiet_until: Some(chrono::Utc::now() + chrono::Duration::hours(2)),
                    ..Preferences::default()
                },
            )
            .await
            .expect("set quiet");
        let decision = service
            .request(request(campus_id, &user_id, topics::SPACE_FORMED, 1.0))
            .await
            .expect("quiet request");
        assert!(matches!(
            decision,
            Decision::Withheld {
                reason: Suppressed::Quiet,
                ..
            }
        ));
    })
    .await;
}

#[tokio::test]
async fn a_repeatedly_dismissed_topic_raises_its_own_bar() {
    // A category the user keeps waving away should fade without them having to
    // find a settings screen.
    with_test_pool(|pool| async move {
        let user_id = format!("intr-decay-{}", Uuid::new_v4().simple());
        let campus_id = seed_user(&pool, &user_id).await;
        let service = InterruptionService::new(pool.clone());
        service
            .set_preferences(
                &user_id,
                &Preferences {
                    daily_budget: 20,
                    ..Preferences::default()
                },
            )
            .await
            .expect("raise budget out of the way");

        // A middling-value interruption gets through while the topic is new.
        let first = service
            .request(request(campus_id, &user_id, topics::SPACE_FORMED, 0.5))
            .await
            .expect("first");
        assert!(matches!(first, Decision::Granted(_)), "{first:?}");

        // The user dismisses several in a row.
        for _ in 0..3 {
            let decision = service
                .request(request(campus_id, &user_id, topics::SPACE_FORMED, 0.9))
                .await
                .expect("deliver");
            let ledger_id = decision.ledger_id().expect("recorded");
            assert!(service
                .mark_dismissed(&user_id, ledger_id)
                .await
                .expect("dismiss"));
        }

        // The same middling value no longer clears the bar.
        let later = service
            .request(request(campus_id, &user_id, topics::SPACE_FORMED, 0.5))
            .await
            .expect("later");
        assert!(
            matches!(
                later,
                Decision::Withheld {
                    reason: Suppressed::LowValue,
                    ..
                }
            ),
            "a dismissed topic should raise its bar, got {later:?}"
        );

        // An untouched topic is unaffected — the penalty is per topic, not a
        // blanket punishment.
        let unrelated = service
            .request(request(campus_id, &user_id, topics::MATCH_FOUND, 0.5))
            .await
            .expect("unrelated");
        assert!(matches!(unrelated, Decision::Granted(_)), "{unrelated:?}");
    })
    .await;
}

#[tokio::test]
async fn engagement_receipts_are_scoped_and_single_use() {
    with_test_pool(|pool| async move {
        let user_id = format!("intr-receipt-{}", Uuid::new_v4().simple());
        let other_id = format!("intr-other-{}", Uuid::new_v4().simple());
        let campus_id = seed_user(&pool, &user_id).await;
        seed_user(&pool, &other_id).await;
        let service = InterruptionService::new(pool.clone());

        let decision = service
            .request(request(campus_id, &user_id, topics::MATCH_FOUND, 0.9))
            .await
            .expect("request");
        let ledger_id = decision.ledger_id().expect("recorded");

        // Someone else's receipt does nothing.
        assert!(!service
            .mark_accepted(&other_id, ledger_id)
            .await
            .expect("cross-user accept"));

        assert!(service
            .mark_accepted(&user_id, ledger_id)
            .await
            .expect("accept"));
        // Already answered: a later dismiss must not overwrite the acceptance,
        // or the statistics would follow whichever signal arrived last.
        assert!(!service
            .mark_dismissed(&user_id, ledger_id)
            .await
            .expect("late dismiss"));

        let history = service.recent(&user_id, 10).await.expect("history");
        let entry = history.iter().find(|e| e.id == ledger_id).expect("entry");
        assert!(entry.accepted_at.is_some());
        assert!(entry.dismissed_at.is_none());
    })
    .await;
}

#[tokio::test]
async fn budget_is_not_overspent_by_concurrent_requests() {
    // Two matches found at the same moment must not both see the last unit of
    // budget and both spend it. The preference row lock serialises them.
    with_test_pool(|pool| async move {
        let user_id = format!("intr-race-{}", Uuid::new_v4().simple());
        let campus_id = seed_user(&pool, &user_id).await;
        InterruptionService::new(pool.clone())
            .set_preferences(
                &user_id,
                &Preferences {
                    daily_budget: 1,
                    ..Preferences::default()
                },
            )
            .await
            .expect("budget of one");

        let racing_pool = goods4ncu::test_infra::concurrent_test_pool(4).await;
        let racers: Vec<_> = (0..4)
            .map(|_| {
                let pool = racing_pool.clone();
                let user_id = user_id.clone();
                tokio::spawn(async move {
                    InterruptionService::new(pool)
                        .request(request(campus_id, &user_id, topics::MATCH_FOUND, 0.9))
                        .await
                        .expect("request")
                })
            })
            .collect();

        let mut granted = 0;
        for racer in racers {
            if matches!(racer.await.expect("join"), Decision::Granted(_)) {
                granted += 1;
            }
        }
        assert_eq!(granted, 1, "a budget of one must grant exactly one");
    })
    .await;
}

#[tokio::test]
async fn directed_topics_are_rejected_by_the_budget_path() {
    // The mirror of the door test: asking the budget to account for something
    // that must always be delivered is a programming error, not a silent pass.
    with_test_pool(|pool| async move {
        let user_id = format!("intr-directed-{}", Uuid::new_v4().simple());
        let campus_id = seed_user(&pool, &user_id).await;

        let error = InterruptionService::new(pool.clone())
            .request(request(campus_id, &user_id, "negotiation_request", 0.9))
            .await
            .expect_err("directed topics must not be budgeted");
        assert!(
            error.to_string().contains("not budgeted"),
            "error should explain: {error}"
        );
    })
    .await;
}
