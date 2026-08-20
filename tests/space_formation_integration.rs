//! Spaces that form from need and archive when the need is spent.
//!
//! This is aimed at the number the health metrics actually reported: 0% of
//! posts answered. Preset boards cannot fix that, because they assume rooms
//! first and people later, and at one campus's scale every niche room shows a
//! last message from three weeks ago.
//!
//! Three properties are under test, and one of them is a safety property rather
//! than a feature.
//!
//! * A group forms only when there are enough people for it to be worth
//!   joining, and is capped before it becomes a crowd.
//! * It archives itself when the thing it was for is over — a dead room is
//!   worse than no room, because it teaches people the place is empty.
//! * **It refuses to keep handing the same people to each other.**
//!   Similarity-based grouping naturally produces cliques, and on a campus that
//!   hardens divisions that already exist. The roadmap calls this a hard metric,
//!   so it is asserted like one.

use goods4ncu::services::aggregation::{
    AggregationService, Declined, MAX_MEMBERS, MAX_REPEAT_PAIRINGS, MIN_MEMBERS,
};
use goods4ncu::services::intent::{kinds, slots::Slots, status, IntentService, NewIntent};
use goods4ncu::test_infra::with_test_pool;
use uuid::Uuid;

async fn campus(pool: &sqlx::PgPool) -> Uuid {
    sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
        .fetch_one(pool)
        .await
        .expect("ncu campus")
}

async fn member(pool: &sqlx::PgPool, campus_id: Uuid, tag: &str) -> String {
    let id = format!("agg-{tag}-{}", Uuid::new_v4().simple());
    sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
        .bind(&id)
        .bind(format!("agg_{tag}_{}", Uuid::new_v4().simple()))
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

#[tokio::test]
async fn three_people_wanting_the_same_thing_get_a_room() {
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let service = AggregationService::new(pool.clone());
        let intents = IntentService::new(pool.clone());

        let mut people = Vec::new();
        for i in 0..MIN_MEMBERS {
            let person = member(&pool, campus_id, &format!("p{i}")).await;
            let raw = "想找人一起打羽毛球".to_string();
            intents
                .create(NewIntent {
                    campus_id,
                    author_id: &person,
                    kind: kinds::COMPANION,
                    raw_input: &raw,
                    slots: Slots {
                        subject: Some("羽毛球".to_string()),
                        ..Default::default()
                    },
                    confidence: 1.0,
                    status: status::ACTIVE,
                    visibility: "campus",
                    valid_until: None,
                })
                .await
                .expect("create intent");
            people.push(person);
        }

        let (formed, declined) = service
            .form_spaces(campus_id, kinds::COMPANION)
            .await
            .expect("form");
        assert!(declined.is_empty(), "{declined:?}");
        assert_eq!(formed.len(), 1);

        let space = &formed[0];
        assert_eq!(space.members.len(), MIN_MEMBERS);
        assert!(space.name.contains("羽毛球"), "name: {}", space.name);

        // Every member can be told why they are here. Being added to a room
        // with no stated reason is how group chats become noise.
        for person in &people {
            let reason = service
                .explain(person, space.space_id)
                .await
                .expect("explain")
                .expect("a member must be able to see why");
            assert!(reason.contains("羽毛球"), "reason: {reason}");
        }

        // A second sweep does not build the same room again: the intents it was
        // made from are now spoken for.
        let (again, _) = service
            .form_spaces(campus_id, kinds::COMPANION)
            .await
            .expect("second sweep");
        assert!(again.is_empty(), "formation must not repeat itself");
    })
    .await;
}

#[tokio::test]
async fn two_people_are_not_put_in_a_room_together() {
    // One or two people in a room named after their interest is a rejection
    // with extra steps. Better to keep waiting.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let intents = IntentService::new(pool.clone());

        for i in 0..(MIN_MEMBERS - 1) {
            let person = member(&pool, campus_id, &format!("p{i}")).await;
            let raw = "有人一起爬梅岭吗".to_string();
            intents
                .create(NewIntent {
                    campus_id,
                    author_id: &person,
                    kind: kinds::ACTIVITY,
                    raw_input: &raw,
                    slots: Slots {
                        subject: Some("爬梅岭".to_string()),
                        ..Default::default()
                    },
                    confidence: 1.0,
                    status: status::ACTIVE,
                    visibility: "campus",
                    valid_until: None,
                })
                .await
                .expect("create intent");
        }

        let (formed, declined) = AggregationService::new(pool.clone())
            .form_spaces(campus_id, kinds::ACTIVITY)
            .await
            .expect("form");
        assert!(formed.is_empty());
        assert_eq!(
            declined,
            vec![Declined::TooFew {
                found: MIN_MEMBERS - 1
            }],
            "the refusal is recorded, not silently dropped",
        );
    })
    .await;
}

#[tokio::test]
async fn a_crowd_is_capped_rather_than_admitted_whole() {
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let intents = IntentService::new(pool.clone());

        for i in 0..(MAX_MEMBERS + 5) {
            let person = member(&pool, campus_id, &format!("p{i}")).await;
            let raw = "考研数学互助".to_string();
            intents
                .create(NewIntent {
                    campus_id,
                    author_id: &person,
                    kind: kinds::COMPANION,
                    raw_input: &raw,
                    slots: Slots {
                        subject: Some("考研数学".to_string()),
                        ..Default::default()
                    },
                    confidence: 1.0,
                    status: status::ACTIVE,
                    visibility: "campus",
                    valid_until: None,
                })
                .await
                .expect("create intent");
        }

        let (formed, _) = AggregationService::new(pool.clone())
            .form_spaces(campus_id, kinds::COMPANION)
            .await
            .expect("form");
        assert_eq!(formed.len(), 1);
        assert_eq!(
            formed[0].members.len(),
            MAX_MEMBERS,
            "past a dozen nobody feels responsible for turning up",
        );
    })
    .await;
}

#[tokio::test]
async fn formation_refuses_to_keep_rebuilding_the_same_clique() {
    // The safety property. Grouping by similarity hands the same people to each
    // other, and on a campus that deepens divisions that already exist. This is
    // the assertion that makes "we watch for filter bubbles" a fact rather than
    // an intention.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let service = AggregationService::new(pool.clone());
        let intents = IntentService::new(pool.clone());

        let clique: Vec<String> = {
            let mut people = Vec::new();
            for i in 0..MIN_MEMBERS {
                people.push(member(&pool, campus_id, &format!("clique{i}")).await);
            }
            people
        };

        // They have already been grouped together often enough that the
        // connection has been made.
        for (index, a) in clique.iter().enumerate() {
            for b in clique.iter().skip(index + 1) {
                let (lo, hi) = if a < b { (a, b) } else { (b, a) };
                sqlx::query(
                    "INSERT INTO space_formation_pairs (campus_id, lo_user, hi_user, times)
                     VALUES ($1, $2, $3, $4)",
                )
                .bind(campus_id)
                .bind(lo)
                .bind(hi)
                .bind(MAX_REPEAT_PAIRINGS)
                .execute(&pool)
                .await
                .expect("seed pairing history");
            }
        }

        for person in &clique {
            let raw = "又想打球了".to_string();
            intents
                .create(NewIntent {
                    campus_id,
                    author_id: person,
                    kind: kinds::COMPANION,
                    raw_input: &raw,
                    slots: Slots {
                        subject: Some("乒乓球".to_string()),
                        ..Default::default()
                    },
                    confidence: 1.0,
                    status: status::ACTIVE,
                    visibility: "campus",
                    valid_until: None,
                })
                .await
                .expect("create intent");
        }

        let (formed, declined) = service
            .form_spaces(campus_id, kinds::COMPANION)
            .await
            .expect("form");
        assert!(
            formed.is_empty(),
            "a group that is entirely old acquaintances must not be re-formed",
        );
        assert!(
            matches!(declined.as_slice(), [Declined::TooFamiliar { .. }]),
            "and the reason must say so: {declined:?}",
        );

        // A newcomer changes the picture: most pairs are now fresh, so the
        // group is worth forming. The rule blocks re-running a clique, not
        // people who happen to know each other.
        let newcomers = {
            let mut fresh = Vec::new();
            for i in 0..3 {
                fresh.push(member(&pool, campus_id, &format!("fresh{i}")).await);
            }
            fresh
        };
        for person in &newcomers {
            let raw = "也想打乒乓球".to_string();
            intents
                .create(NewIntent {
                    campus_id,
                    author_id: person,
                    kind: kinds::COMPANION,
                    raw_input: &raw,
                    slots: Slots {
                        subject: Some("乒乓球".to_string()),
                        ..Default::default()
                    },
                    confidence: 1.0,
                    status: status::ACTIVE,
                    visibility: "campus",
                    valid_until: None,
                })
                .await
                .expect("create intent");
        }

        let (formed, _) = service
            .form_spaces(campus_id, kinds::COMPANION)
            .await
            .expect("form with newcomers");
        assert_eq!(
            formed.len(),
            1,
            "introducing new people is what unblocks it, which is the point",
        );
    })
    .await;
}

#[tokio::test]
async fn a_space_archives_itself_once_its_reason_is_spent() {
    // A dead room is worse than no room: it teaches whoever looks in that the
    // place is empty. When every intent behind a space is done, the space is
    // done.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let service = AggregationService::new(pool.clone());
        let intents = IntentService::new(pool.clone());

        let mut people = Vec::new();
        let mut intent_ids = Vec::new();
        for i in 0..MIN_MEMBERS {
            let person = member(&pool, campus_id, &format!("p{i}")).await;
            let raw = "周末爬梅岭".to_string();
            intent_ids.push(
                intents
                    .create(NewIntent {
                        campus_id,
                        author_id: &person,
                        kind: kinds::ACTIVITY,
                        raw_input: &raw,
                        slots: Slots {
                            subject: Some("爬梅岭".to_string()),
                            ..Default::default()
                        },
                        confidence: 1.0,
                        status: status::ACTIVE,
                        visibility: "campus",
                        valid_until: None,
                    })
                    .await
                    .expect("create intent"),
            );
            people.push(person);
        }

        let (formed, _) = service
            .form_spaces(campus_id, kinds::ACTIVITY)
            .await
            .expect("form");
        let space_id = formed[0].space_id;

        // Still live while anyone still wants it.
        for (person, intent_id) in people.iter().zip(&intent_ids).take(MIN_MEMBERS - 1) {
            assert!(intents.fulfil(person, *intent_id).await.expect("fulfil"));
        }
        assert_eq!(
            service.archive_spent().await.expect("sweep"),
            0,
            "one member still waiting keeps the room open",
        );

        // The last one is satisfied: the outing happened, the room has no job.
        assert!(intents
            .fulfil(&people[MIN_MEMBERS - 1], intent_ids[MIN_MEMBERS - 1])
            .await
            .expect("fulfil last"));
        assert_eq!(service.archive_spent().await.expect("sweep"), 1);

        let (status, reason): (String, Option<String>) =
            sqlx::query_as("SELECT status, archive_reason FROM chat_spaces WHERE id = $1")
                .bind(space_id)
                .fetch_one(&pool)
                .await
                .expect("space row");
        assert_eq!(status, "archived");
        assert_eq!(reason.as_deref(), Some("purpose_served"));

        // The sweep is idempotent.
        assert_eq!(service.archive_spent().await.expect("second sweep"), 0);
    })
    .await;
}

#[tokio::test]
async fn a_space_nobody_kept_alive_expires() {
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let service = AggregationService::new(pool.clone());
        let intents = IntentService::new(pool.clone());

        for i in 0..MIN_MEMBERS {
            let person = member(&pool, campus_id, &format!("p{i}")).await;
            let raw = "想找人练口语".to_string();
            intents
                .create(NewIntent {
                    campus_id,
                    author_id: &person,
                    kind: kinds::COMPANION,
                    raw_input: &raw,
                    slots: Slots {
                        subject: Some("练口语".to_string()),
                        ..Default::default()
                    },
                    confidence: 1.0,
                    status: status::ACTIVE,
                    visibility: "campus",
                    valid_until: None,
                })
                .await
                .expect("create intent");
        }
        let (formed, _) = service
            .form_spaces(campus_id, kinds::COMPANION)
            .await
            .expect("form");
        let space_id = formed[0].space_id;

        sqlx::query("UPDATE chat_spaces SET expires_at = NOW() - interval '1 day' WHERE id = $1")
            .bind(space_id)
            .execute(&pool)
            .await
            .expect("age it");

        assert_eq!(service.archive_spent().await.expect("sweep"), 1);
        let reason: Option<String> =
            sqlx::query_scalar("SELECT archive_reason FROM chat_spaces WHERE id = $1")
                .bind(space_id)
                .fetch_one(&pool)
                .await
                .expect("reason");
        assert_eq!(reason.as_deref(), Some("lifespan_elapsed"));
    })
    .await;
}

#[tokio::test]
async fn hand_made_spaces_are_left_alone() {
    // These archive rules exist to clean up after automated guesses. Someone who
    // created a group on purpose did not ask for it to be tidied away.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let owner = member(&pool, campus_id, "owner").await;

        let space_id: Uuid = sqlx::query_scalar(
            "INSERT INTO chat_spaces (campus_id, kind, name, owner_id, status, origin,
                                      expires_at)
             VALUES ($1, 'group', '手工建的群', $2, 'active', 'manual',
                     NOW() - interval '1 day')
             RETURNING id",
        )
        .bind(campus_id)
        .bind(&owner)
        .fetch_one(&pool)
        .await
        .expect("insert manual space");

        assert_eq!(
            AggregationService::new(pool.clone())
                .archive_spent()
                .await
                .expect("sweep"),
            0,
        );
        let status: String = sqlx::query_scalar("SELECT status FROM chat_spaces WHERE id = $1")
            .bind(space_id)
            .fetch_one(&pool)
            .await
            .expect("status");
        assert_eq!(status, "active");
    })
    .await;
}

#[tokio::test]
async fn incompatible_needs_do_not_share_a_room() {
    // Same subject is not the same occasion. Saturday morning and Sunday night
    // are different plans, and putting them together produces a room where
    // nobody can agree on anything.
    with_test_pool(|pool| async move {
        use goods4ncu::services::intent::slots::TimeSlot;

        let campus_id = campus(&pool).await;
        let intents = IntentService::new(pool.clone());

        let saturday = chrono::Utc::now() + chrono::Duration::days(2);
        let next_month = chrono::Utc::now() + chrono::Duration::days(30);

        for (i, when) in [saturday, saturday, next_month].into_iter().enumerate() {
            let person = member(&pool, campus_id, &format!("p{i}")).await;
            let raw = "打球".to_string();
            intents
                .create(NewIntent {
                    campus_id,
                    author_id: &person,
                    kind: kinds::COMPANION,
                    raw_input: &raw,
                    slots: Slots {
                        subject: Some("篮球".to_string()),
                        time: Some(TimeSlot::Exact { at: when }),
                        ..Default::default()
                    },
                    confidence: 1.0,
                    status: status::ACTIVE,
                    visibility: "campus",
                    valid_until: None,
                })
                .await
                .expect("create intent");
        }

        // Only two share a time, which is below the floor, so nothing forms —
        // correctly. Three people who cannot meet on the same day are not a
        // group.
        let (formed, declined) = AggregationService::new(pool.clone())
            .form_spaces(campus_id, kinds::COMPANION)
            .await
            .expect("form");
        assert!(formed.is_empty(), "{formed:?}");
        assert!(
            matches!(declined.as_slice(), [Declined::TooFew { found: 2 }]),
            "the clash should reduce the group, not be papered over: {declined:?}",
        );
    })
    .await;
}

#[tokio::test]
async fn formation_does_not_reach_across_campuses() {
    with_test_pool(|pool| async move {
        let ncu = campus(&pool).await;
        let other: Uuid = sqlx::query_scalar(
            "INSERT INTO campuses (id, slug, name_zh, name_en, email_domains, status)
             VALUES (gen_random_uuid(), $1, '隔离测试校区', 'Isolation', ARRAY[$2], 'active')
             RETURNING id",
        )
        .bind(format!("agg-other-{}", Uuid::new_v4().simple()))
        .bind(format!("stu.agg-{}.test", Uuid::new_v4().simple()))
        .fetch_one(&pool)
        .await
        .expect("insert campus");

        let intents = IntentService::new(pool.clone());
        for i in 0..MIN_MEMBERS {
            let person = member(&pool, ncu, &format!("p{i}")).await;
            let raw = "打羽毛球".to_string();
            intents
                .create(NewIntent {
                    campus_id: ncu,
                    author_id: &person,
                    kind: kinds::COMPANION,
                    raw_input: &raw,
                    slots: Slots {
                        subject: Some("羽毛球".to_string()),
                        ..Default::default()
                    },
                    confidence: 1.0,
                    status: status::ACTIVE,
                    visibility: "campus",
                    valid_until: None,
                })
                .await
                .expect("create intent");
        }

        let (formed, _) = AggregationService::new(pool.clone())
            .form_spaces(other, kinds::COMPANION)
            .await
            .expect("form on the other campus");
        assert!(formed.is_empty());
    })
    .await;
}

#[tokio::test]
async fn drafts_and_private_intents_never_pull_anyone_into_a_room() {
    // An unconfirmed reading of someone's words must not put them in a room with
    // strangers, and neither must an intent they deliberately kept private.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let intents = IntentService::new(pool.clone());

        for i in 0..MIN_MEMBERS {
            let person = member(&pool, campus_id, &format!("draft{i}")).await;
            intents
                .create_draft_batch(
                    campus_id,
                    &person,
                    "（一段语音）",
                    kinds::COMPANION,
                    vec![(
                        Slots {
                            subject: Some("羽毛球".to_string()),
                            ..Default::default()
                        },
                        0.7,
                    )],
                )
                .await
                .expect("draft");
        }
        for i in 0..MIN_MEMBERS {
            let person = member(&pool, campus_id, &format!("private{i}")).await;
            let raw = "先不公开".to_string();
            intents
                .create(NewIntent {
                    campus_id,
                    author_id: &person,
                    kind: kinds::COMPANION,
                    raw_input: &raw,
                    slots: Slots {
                        subject: Some("羽毛球".to_string()),
                        ..Default::default()
                    },
                    confidence: 1.0,
                    status: status::ACTIVE,
                    visibility: "private",
                    valid_until: None,
                })
                .await
                .expect("create private");
        }

        let (formed, _) = AggregationService::new(pool.clone())
            .form_spaces(campus_id, kinds::COMPANION)
            .await
            .expect("form");
        assert!(
            formed.is_empty(),
            "neither drafts nor private intents may form a space",
        );
    })
    .await;
}

#[tokio::test]
async fn one_person_asking_twice_is_still_one_person() {
    // Found by running this against the live deployment: three intents produced
    // a group of two, because one of them was the same person asking again.
    // That is the right answer — someone who wants a badminton game twice is
    // still one player — and it is load-bearing, because counting intents
    // instead of people would let a single enthusiast conjure a room out of
    // nothing and then sit in it alone.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let intents = IntentService::new(pool.clone());

        let keen = member(&pool, campus_id, "keen").await;
        let other = member(&pool, campus_id, "other").await;

        // The keen one asks three times; the other once.
        for author in [&keen, &keen, &keen, &other] {
            let raw = "想打羽毛球".to_string();
            intents
                .create(NewIntent {
                    campus_id,
                    author_id: author,
                    kind: kinds::COMPANION,
                    raw_input: &raw,
                    slots: Slots {
                        subject: Some("羽毛球".to_string()),
                        ..Default::default()
                    },
                    confidence: 1.0,
                    status: status::ACTIVE,
                    visibility: "campus",
                    valid_until: None,
                })
                .await
                .expect("create intent");
        }

        let (formed, declined) = AggregationService::new(pool.clone())
            .form_spaces(campus_id, kinds::COMPANION)
            .await
            .expect("form");
        assert!(formed.is_empty(), "four intents, two people, no room");
        assert_eq!(
            declined,
            vec![Declined::TooFew { found: 2 }],
            "the count is people, not intents",
        );
    })
    .await;
}

#[tokio::test]
async fn a_formed_space_tells_its_members_why_through_the_budget() {
    // Forming a room and not telling anyone is the same as not forming it. The
    // notice is budgeted, because formation runs hourly across every kind and is
    // exactly the sort of thing that becomes a nuisance if it can notify freely
    // — but over budget it must still reach the inbox, so nobody ends up in a
    // room they were never told about.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let intents = IntentService::new(pool.clone());
        let mut people = Vec::new();

        for i in 0..MIN_MEMBERS {
            let person = member(&pool, campus_id, &format!("p{i}")).await;
            let raw = "想找人练口语".to_string();
            intents
                .create(NewIntent {
                    campus_id,
                    author_id: &person,
                    kind: kinds::COMPANION,
                    raw_input: &raw,
                    slots: Slots {
                        subject: Some("练口语".to_string()),
                        ..Default::default()
                    },
                    confidence: 1.0,
                    status: status::ACTIVE,
                    visibility: "campus",
                    valid_until: None,
                })
                .await
                .expect("create intent");
            people.push(person);
        }

        // One member has already spent their budget, so their notice must land
        // in the inbox unpushed rather than vanish.
        goods4ncu::services::interruption::InterruptionService::new(pool.clone())
            .set_preferences(
                &people[0],
                &goods4ncu::services::interruption::Preferences {
                    daily_budget: 0,
                    ..Default::default()
                },
            )
            .await
            .expect("zero budget");

        let service = AggregationService::new(pool.clone());
        let (formed, _) = service
            .form_spaces(campus_id, kinds::COMPANION)
            .await
            .expect("form");
        assert_eq!(formed.len(), 1);
        goods4ncu::services::aggregation::notify_members(&pool, campus_id, &formed[0]).await;

        for person in &people {
            let notices: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM notifications
                 WHERE user_id = $1 AND event_type = 'space_formed'",
            )
            .bind(person)
            .fetch_one(&pool)
            .await
            .expect("count notices");
            assert_eq!(notices, 1, "every member is told, budget or not");
        }

        // And the one over budget got no push.
        let pushed: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM interruption_ledger
             WHERE user_id = $1 AND topic = 'space_formed' AND delivered_at IS NOT NULL",
        )
        .bind(&people[0])
        .fetch_one(&pool)
        .await
        .expect("count pushes");
        assert_eq!(pushed, 0, "over budget silences the push, not the message");
    })
    .await;
}
