//! The intent layer.
//!
//! Two claims are under test, and they are the reason this layer exists rather
//! than another form.
//!
//! **Vagueness is admissible.** Someone clearing a dorm room says "whatever
//! you'll give me" and means it. If the system needs a number, the number gets
//! invented and the listing becomes a lie about what its owner wants. So an
//! intent with almost nothing pinned down must be storable, matchable, and
//! never excluded for what it declined to say.
//!
//! **Goods, people and events are one mechanism.** A thing to sell, a partner
//! to find and a favour to ask travel the same table, the same pool and the
//! same API. If a special case creeps in for one kind, the unification was
//! decorative.
//!
//! Plus the safety property that makes inference tolerable: anything the system
//! read out of a photo or a sentence stays a draft until its author agrees, so
//! a bad decomposition costs one dismissal instead of putting rubbish in front
//! of the campus.

use goods4ncu::services::intent::slots::{PriceSlot, Slots, TimeSlot};
use goods4ncu::services::intent::{kinds, status, IntentService, NewIntent};
use goods4ncu::test_infra::with_test_pool;
use uuid::Uuid;

async fn campus(pool: &sqlx::PgPool) -> Uuid {
    sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
        .fetch_one(pool)
        .await
        .expect("ncu campus")
}

async fn member(pool: &sqlx::PgPool, campus_id: Uuid, tag: &str) -> String {
    let id = format!("intent-{tag}-{}", Uuid::new_v4().simple());
    sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
        .bind(&id)
        .bind(format!("intent_{tag}_{}", Uuid::new_v4().simple()))
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

fn stated<'a>(
    campus_id: Uuid,
    author: &'a str,
    kind: &'a str,
    raw: &'a str,
    slots: Slots,
) -> NewIntent<'a> {
    NewIntent {
        campus_id,
        author_id: author,
        kind,
        raw_input: raw,
        slots,
        confidence: 1.0,
        status: status::ACTIVE,
        visibility: "campus",
        valid_until: None,
    }
}

#[tokio::test]
async fn an_intent_with_no_price_at_all_is_valid_and_matchable() {
    // The headline claim. A listing form cannot accept this; the intent layer
    // must, and the result must still reach someone who is looking.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let seller = member(&pool, campus_id, "seller").await;
        let buyer = member(&pool, campus_id, "buyer").await;
        let service = IntentService::new(pool.clone());

        service
            .create(stated(
                campus_id,
                &seller,
                kinds::GOODS_OFFER,
                "宿舍要清空了，小冰箱能卖多少卖多少",
                Slots {
                    subject: Some("小冰箱".to_string()),
                    price: Some(PriceSlot::Whatever {
                        hint: Some("能卖就行".to_string()),
                    }),
                    ..Default::default()
                },
            ))
            .await
            .expect("an intent without a price must be storable");

        // A buyer with a firm budget still sees it: not naming a price cannot
        // exclude you from someone's search.
        let looking = Slots {
            price: Some(PriceSlot::Range {
                min_cents: None,
                max_cents: Some(20_000),
            }),
            ..Default::default()
        };
        let offers = service
            .pool(campus_id, kinds::GOODS_OFFER, &buyer, 50)
            .await
            .expect("pool");
        let visible: Vec<_> = offers
            .iter()
            .filter(|o| looking.compatible_with(&o.slots))
            .collect();
        assert_eq!(
            visible.len(),
            1,
            "an unpriced offer must not be filtered out"
        );

        // The author's own words survived, rather than being replaced by a
        // number they never said.
        assert_eq!(
            visible[0].slots.price,
            Some(PriceSlot::Whatever {
                hint: Some("能卖就行".to_string())
            }),
        );
    })
    .await;
}

#[tokio::test]
async fn a_stated_budget_still_excludes_what_it_excludes() {
    // The other half. Permissive about silence, strict about statements —
    // quietly relaxing someone's limit is how people stop trusting matches.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let seller = member(&pool, campus_id, "seller").await;
        let buyer = member(&pool, campus_id, "buyer").await;
        let service = IntentService::new(pool.clone());

        for (title, cents) in [("便宜的", 15_000_i64), ("太贵的", 90_000)] {
            service
                .create(stated(
                    campus_id,
                    &seller,
                    kinds::GOODS_OFFER,
                    title,
                    Slots {
                        subject: Some(title.to_string()),
                        price: Some(PriceSlot::Exact { cents }),
                        ..Default::default()
                    },
                ))
                .await
                .expect("create offer");
        }

        let budget = Slots {
            price: Some(PriceSlot::Range {
                min_cents: None,
                max_cents: Some(20_000),
            }),
            ..Default::default()
        };
        let matched: Vec<_> = service
            .pool(campus_id, kinds::GOODS_OFFER, &buyer, 50)
            .await
            .expect("pool")
            .into_iter()
            .filter(|o| budget.compatible_with(&o.slots))
            .collect();

        assert_eq!(matched.len(), 1);
        assert_eq!(matched[0].slots.subject.as_deref(), Some("便宜的"));
    })
    .await;
}

#[tokio::test]
async fn people_and_events_travel_the_same_machinery_as_goods() {
    // If any kind needed its own table, pool or code path, the "one intent
    // engine" claim would be decoration.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let author = member(&pool, campus_id, "author").await;
        let other = member(&pool, campus_id, "other").await;
        let service = IntentService::new(pool.clone());

        let cases = [
            (kinds::GOODS_OFFER, "宿舍冰箱想出掉"),
            (kinds::GOODS_SEEK, "想收个二手显示器"),
            (kinds::COMPANION, "找个羽毛球搭子"),
            (kinds::HELP, "有人会修自行车吗"),
            (kinds::ACTIVITY, "周末想爬梅岭，有人去吗"),
        ];
        for (kind, raw) in cases {
            service
                .create(stated(campus_id, &author, kind, raw, Slots::default()))
                .await
                .unwrap_or_else(|e| panic!("{kind} must use the same API: {e}"));
        }

        // Each kind has its own pool, reached the same way.
        for (kind, raw) in cases {
            let pool_items = service
                .pool(campus_id, kind, &other, 50)
                .await
                .unwrap_or_else(|e| panic!("{kind} pool: {e}"));
            assert_eq!(pool_items.len(), 1, "{kind}");
            assert_eq!(pool_items[0].raw_input, raw);
        }

        // And they are all one list to their author.
        let mine = service.list_mine(&author, 50).await.expect("list mine");
        assert_eq!(mine.len(), cases.len());
    })
    .await;
}

#[tokio::test]
async fn two_people_wanting_a_partner_are_each_others_match() {
    // Companion intents pair with their own kind. Crossing them the way goods
    // cross would look for a "supplier of badminton partners", which is not a
    // thing that exists.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let a = member(&pool, campus_id, "a").await;
        let b = member(&pool, campus_id, "b").await;
        let service = IntentService::new(pool.clone());

        for author in [&a, &b] {
            service
                .create(stated(
                    campus_id,
                    author,
                    kinds::COMPANION,
                    "找个羽毛球搭子，晚上都行",
                    Slots {
                        subject: Some("羽毛球".to_string()),
                        time: Some(TimeSlot::Flexible {
                            hint: Some("晚上都行".to_string()),
                        }),
                        ..Default::default()
                    },
                ))
                .await
                .expect("create companion intent");
        }

        // Each sees the other, and neither sees themselves.
        for (mine, theirs) in [(&a, &b), (&b, &a)] {
            let candidates = service
                .pool(campus_id, kinds::COMPANION, mine, 50)
                .await
                .expect("companion pool");
            assert_eq!(candidates.len(), 1, "should see exactly the other person");
            assert_ne!(mine, theirs, "sanity");
        }
    })
    .await;
}

#[tokio::test]
async fn inferred_intents_wait_for_their_author_before_being_matchable() {
    // The property that makes decomposition safe. Reading a photo as six items
    // will sometimes be wrong; that should cost the author a dismissal, not put
    // rubbish in front of the campus.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let author = member(&pool, campus_id, "author").await;
        let onlooker = member(&pool, campus_id, "onlooker").await;
        let service = IntentService::new(pool.clone());

        let drafts = service
            .create_draft_batch(
                campus_id,
                &author,
                "（一张宿舍照片）",
                kinds::GOODS_OFFER,
                vec![
                    (
                        Slots {
                            subject: Some("台灯".to_string()),
                            ..Default::default()
                        },
                        0.9,
                    ),
                    (
                        Slots {
                            subject: Some("小冰箱".to_string()),
                            ..Default::default()
                        },
                        0.8,
                    ),
                    (
                        Slots {
                            subject: Some("看不清的东西".to_string()),
                            ..Default::default()
                        },
                        0.3,
                    ),
                ],
            )
            .await
            .expect("draft batch");
        assert_eq!(drafts.len(), 3);

        // Nothing is matchable yet.
        assert!(
            service
                .pool(campus_id, kinds::GOODS_OFFER, &onlooker, 50)
                .await
                .expect("pool")
                .is_empty(),
            "drafts must never enter the matching pool",
        );

        // The author keeps two and drops the misread one.
        assert!(service.confirm(&author, drafts[0]).await.expect("confirm"));
        assert!(service.confirm(&author, drafts[1]).await.expect("confirm"));
        assert!(service
            .withdraw(&author, drafts[2])
            .await
            .expect("withdraw"));

        let live = service
            .pool(campus_id, kinds::GOODS_OFFER, &onlooker, 50)
            .await
            .expect("pool after confirm");
        assert_eq!(live.len(), 2);

        // Confirming twice is not a way to resurrect something withdrawn.
        assert!(
            !service
                .confirm(&author, drafts[2])
                .await
                .expect("re-confirm"),
            "a withdrawn intent must stay withdrawn",
        );
    })
    .await;
}

#[tokio::test]
async fn only_the_author_can_confirm_or_withdraw() {
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let author = member(&pool, campus_id, "author").await;
        let stranger = member(&pool, campus_id, "stranger").await;
        let service = IntentService::new(pool.clone());

        let drafts = service
            .create_draft_batch(
                campus_id,
                &author,
                "一句话",
                kinds::GOODS_OFFER,
                vec![(Slots::default(), 0.9)],
            )
            .await
            .expect("draft");

        assert!(!service
            .confirm(&stranger, drafts[0])
            .await
            .expect("cross-user confirm"));
        assert!(!service
            .withdraw(&stranger, drafts[0])
            .await
            .expect("cross-user withdraw"));
        assert!(service
            .get(&stranger, drafts[0])
            .await
            .expect("cross-user get")
            .is_none());

        // Still a draft, so still invisible.
        assert!(service
            .pool(campus_id, kinds::GOODS_OFFER, &stranger, 50)
            .await
            .expect("pool")
            .is_empty());
    })
    .await;
}

#[tokio::test]
async fn an_intent_whose_moment_has_passed_leaves_the_pool() {
    // "This weekend" is genuinely over on Monday. Keeping it alive produces
    // matches nobody wants and quietly degrades everyone else's results.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let author = member(&pool, campus_id, "author").await;
        let other = member(&pool, campus_id, "other").await;
        let service = IntentService::new(pool.clone());

        let id = service
            .create(NewIntent {
                valid_until: Some(chrono::Utc::now() + chrono::Duration::hours(1)),
                ..stated(
                    campus_id,
                    &author,
                    kinds::ACTIVITY,
                    "周末爬梅岭",
                    Slots::default(),
                )
            })
            .await
            .expect("create");

        assert_eq!(
            service
                .pool(campus_id, kinds::ACTIVITY, &other, 50)
                .await
                .expect("pool")
                .len(),
            1
        );

        sqlx::query("UPDATE intents SET valid_until = NOW() - interval '1 minute' WHERE id = $1")
            .bind(id)
            .execute(&pool)
            .await
            .expect("age it");

        // The pool filters on the deadline directly, so it is correct even
        // before the sweep runs.
        assert!(
            service
                .pool(campus_id, kinds::ACTIVITY, &other, 50)
                .await
                .expect("pool after deadline")
                .is_empty(),
            "a passed deadline takes effect immediately, not at the next sweep",
        );

        assert_eq!(service.expire_due().await.expect("sweep"), 1);
        let status: String = sqlx::query_scalar("SELECT status FROM intents WHERE id = $1")
            .bind(id)
            .fetch_one(&pool)
            .await
            .expect("status");
        assert_eq!(status, status::EXPIRED);

        // The sweep is idempotent — a second pass finds nothing left to do.
        assert_eq!(service.expire_due().await.expect("second sweep"), 0);
    })
    .await;
}

#[tokio::test]
async fn private_intents_are_recorded_but_never_pooled() {
    // Somewhere to put a wish you are not ready to broadcast, without losing it.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let author = member(&pool, campus_id, "author").await;
        let other = member(&pool, campus_id, "other").await;
        let service = IntentService::new(pool.clone());

        service
            .create(NewIntent {
                visibility: "private",
                ..stated(
                    campus_id,
                    &author,
                    kinds::GOODS_SEEK,
                    "想找个便宜的平板，先不公开",
                    Slots::default(),
                )
            })
            .await
            .expect("create private");

        assert!(service
            .pool(campus_id, kinds::GOODS_SEEK, &other, 50)
            .await
            .expect("pool")
            .is_empty());
        assert_eq!(
            service.list_mine(&author, 50).await.expect("mine").len(),
            1,
            "it is still the author's own record",
        );
    })
    .await;
}

#[tokio::test]
async fn intents_do_not_cross_campuses() {
    with_test_pool(|pool| async move {
        let ncu = campus(&pool).await;
        let other_campus: Uuid = sqlx::query_scalar(
            "INSERT INTO campuses (id, slug, name_zh, name_en, email_domains, status)
             VALUES (gen_random_uuid(), $1, '隔离测试校区', 'Isolation Test Campus',
                     ARRAY[$2], 'active')
             RETURNING id",
        )
        .bind(format!("intent-other-{}", Uuid::new_v4().simple()))
        .bind(format!("stu.intent-{}.test", Uuid::new_v4().simple()))
        .fetch_one(&pool)
        .await
        .expect("insert campus");

        let author = member(&pool, ncu, "author").await;
        let outsider = member(&pool, other_campus, "outsider").await;
        let service = IntentService::new(pool.clone());

        service
            .create(stated(
                ncu,
                &author,
                kinds::GOODS_OFFER,
                "本校的东西",
                Slots::default(),
            ))
            .await
            .expect("create");

        assert!(service
            .pool(other_campus, kinds::GOODS_OFFER, &outsider, 50)
            .await
            .expect("other campus pool")
            .is_empty());
    })
    .await;
}

#[tokio::test]
async fn an_unknown_kind_is_refused_rather_than_stored() {
    // The kinds are a closed set; a typo should fail loudly instead of creating
    // an intent nothing will ever look for.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let author = member(&pool, campus_id, "author").await;
        let service = IntentService::new(pool.clone());

        let error = service
            .create(stated(
                campus_id,
                &author,
                "gossip",
                "闲聊",
                Slots::default(),
            ))
            .await
            .expect_err("unknown kinds must be refused");
        assert!(error.to_string().contains("gossip"), "error: {error}");

        // And an intent with no words is not an intent.
        let blank = service
            .create(stated(
                campus_id,
                &author,
                kinds::GOODS_OFFER,
                "   ",
                Slots::default(),
            ))
            .await
            .expect_err("blank input must be refused");
        assert!(blank.to_string().contains("words"), "error: {blank}");
    })
    .await;
}

#[tokio::test]
async fn an_unpriced_intent_is_not_forced_into_the_listing_grid() {
    // The refusal that keeps the whole design honest. `inventory` requires a
    // price; an intent is allowed not to have one. Mirroring "whatever you'll
    // give me" into a grid would mean printing a figure the owner never said —
    // ¥0.00, or a guess — and misrepresenting them to every buyer who looked.
    //
    // So it stays intent-only: still pooled, still matchable, just absent from
    // a surface that cannot show it truthfully.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let seller = member(&pool, campus_id, "seller").await;
        let buyer = member(&pool, campus_id, "buyer").await;
        let service = IntentService::new(pool.clone());

        let priced = service
            .create(stated(
                campus_id,
                &seller,
                kinds::GOODS_OFFER,
                "台灯，30 块",
                Slots {
                    subject: Some("台灯".to_string()),
                    price: Some(PriceSlot::Exact { cents: 3_000 }),
                    ..Default::default()
                },
            ))
            .await
            .expect("create priced");

        let unpriced = service
            .create(stated(
                campus_id,
                &seller,
                kinds::GOODS_OFFER,
                "小冰箱，能卖多少卖多少",
                Slots {
                    subject: Some("小冰箱".to_string()),
                    price: Some(PriceSlot::Whatever {
                        hint: Some("能卖就行".to_string()),
                    }),
                    ..Default::default()
                },
            ))
            .await
            .expect("create unpriced");

        let priced_listing = service
            .project_to_listing(priced)
            .await
            .expect("project priced");
        assert!(
            priced_listing.is_some(),
            "a stated price can be shown as-is"
        );

        assert!(
            service
                .project_to_listing(unpriced)
                .await
                .expect("project unpriced")
                .is_none(),
            "an unpriced intent must not be given an invented price",
        );

        // And crucially, it is still findable through the intent pool.
        let pooled = service
            .pool(campus_id, kinds::GOODS_OFFER, &buyer, 50)
            .await
            .expect("pool");
        assert_eq!(pooled.len(), 2, "both intents remain matchable");

        // The projected one carries a truthful figure.
        let cents: i64 =
            sqlx::query_scalar("SELECT suggested_price_cny FROM inventory WHERE id = $1")
                .bind(priced_listing.as_ref().unwrap())
                .fetch_one(&pool)
                .await
                .expect("listing price");
        assert_eq!(cents, 3_000);
    })
    .await;
}

#[tokio::test]
async fn projection_is_idempotent_and_only_for_offers() {
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let author = member(&pool, campus_id, "author").await;
        let service = IntentService::new(pool.clone());

        let offer = service
            .create(stated(
                campus_id,
                &author,
                kinds::GOODS_OFFER,
                "台灯 30 块",
                Slots {
                    subject: Some("台灯".to_string()),
                    price: Some(PriceSlot::Exact { cents: 3_000 }),
                    ..Default::default()
                },
            ))
            .await
            .expect("create");

        let first = service.project_to_listing(offer).await.expect("first");
        let second = service.project_to_listing(offer).await.expect("second");
        assert_eq!(first, second, "re-projecting must not fork the mirror");
        let listings: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM inventory WHERE owner_id = $1")
                .bind(&author)
                .fetch_one(&pool)
                .await
                .expect("count");
        assert_eq!(listings, 1);

        // A wanted item, a badminton partner and a favour are not listings.
        for kind in [
            kinds::GOODS_SEEK,
            kinds::COMPANION,
            kinds::HELP,
            kinds::ACTIVITY,
        ] {
            let id = service
                .create(stated(
                    campus_id,
                    &author,
                    kind,
                    "不该出现在商品栅格里",
                    Slots {
                        price: Some(PriceSlot::Exact { cents: 1_000 }),
                        ..Default::default()
                    },
                ))
                .await
                .expect("create");
            assert!(
                service
                    .project_to_listing(id)
                    .await
                    .expect("project")
                    .is_none(),
                "{kind} must not be projected into a shopping grid",
            );
        }
    })
    .await;
}

#[tokio::test]
async fn fulfilled_is_kept_distinct_from_withdrawn() {
    // "Someone helped me" and "never mind" are opposite outcomes that look
    // identical in an activity log. The health metrics need them apart to tell
    // a community where nothing gets answered from one where people simply
    // change their minds.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let author = member(&pool, campus_id, "author").await;
        let service = IntentService::new(pool.clone());

        let worked = service
            .create(stated(
                campus_id,
                &author,
                kinds::HELP,
                "有人会修自行车吗",
                Slots::default(),
            ))
            .await
            .expect("create");
        let abandoned = service
            .create(stated(
                campus_id,
                &author,
                kinds::HELP,
                "算了不修了",
                Slots::default(),
            ))
            .await
            .expect("create");

        assert!(service.fulfil(&author, worked).await.expect("fulfil"));
        assert!(service
            .withdraw(&author, abandoned)
            .await
            .expect("withdraw"));

        let statuses: Vec<(Uuid, String)> = sqlx::query_as(
            "SELECT id, status FROM intents WHERE author_id = $1 ORDER BY created_at",
        )
        .bind(&author)
        .fetch_all(&pool)
        .await
        .expect("statuses");
        let by_id: std::collections::HashMap<_, _> = statuses.into_iter().collect();
        assert_eq!(by_id[&worked], status::FULFILLED);
        assert_eq!(by_id[&abandoned], status::WITHDRAWN);

        // Neither is still live, and fulfilling twice is not a way to reopen it.
        assert!(!service.fulfil(&author, worked).await.expect("re-fulfil"));
        assert!(!service
            .fulfil(&author, abandoned)
            .await
            .expect("fulfil withdrawn"));
        assert!(service
            .list_mine(&author, 50)
            .await
            .expect("mine")
            .is_empty());
    })
    .await;
}

#[tokio::test]
async fn the_campus_feed_is_visible_without_posting_anything_first() {
    // Without this, you have to say something before you can see anything: a
    // new student opens the app, has posted nothing, and finds an empty room.
    // That is the unanswered-post problem from the other side — the demand
    // exists and nobody can see it in order to answer it.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let asker = member(&pool, campus_id, "asker").await;
        let newcomer = member(&pool, campus_id, "newcomer").await;
        let service = IntentService::new(pool.clone());

        for (kind, raw) in [
            (kinds::GOODS_SEEK, "想收个二手显示器"),
            (kinds::COMPANION, "找个羽毛球搭子"),
            (kinds::HELP, "有人会修自行车吗"),
        ] {
            service
                .create(stated(campus_id, &asker, kind, raw, Slots::default()))
                .await
                .expect("create");
        }

        // The newcomer has said nothing, and still sees everything.
        let feed = service
            .campus_feed(campus_id, &newcomer, None, 30)
            .await
            .expect("feed");
        assert_eq!(feed.len(), 3, "every kind is interleaved, newest first");

        // Filtering works, and nobody sees their own intents echoed back.
        let only_help = service
            .campus_feed(campus_id, &asker, Some(kinds::HELP), 30)
            .await
            .expect("filtered feed");
        assert!(
            only_help.is_empty(),
            "the author's own intents are not news to them",
        );
    })
    .await;
}

#[tokio::test]
async fn the_feed_never_carries_an_author_identity() {
    // Answering is a server-side action precisely so this surface cannot be
    // scraped into a directory of who wants what. If author ids ever appear in
    // the serialised form, that protection is gone.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let asker = member(&pool, campus_id, "asker").await;
        let viewer = member(&pool, campus_id, "viewer").await;
        let service = IntentService::new(pool.clone());

        service
            .create(stated(
                campus_id,
                &asker,
                kinds::GOODS_SEEK,
                "想收个显示器",
                Slots::default(),
            ))
            .await
            .expect("create");

        let feed = service
            .campus_feed(campus_id, &viewer, None, 30)
            .await
            .expect("feed");
        let json = serde_json::to_string(&feed).expect("serialise");
        assert!(
            !json.contains(&asker),
            "the author id must not reach the client: {json}",
        );
        // It is still available internally, which is how responding works.
        assert_eq!(feed[0].author_id.as_deref(), Some(asker.as_str()));
    })
    .await;
}

#[tokio::test]
async fn only_a_live_visible_intent_can_be_answered() {
    // One answer for every reason an intent is unanswerable — withdrawn,
    // fulfilled, expired, private, another campus's — so this cannot be used to
    // probe what exists.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let asker = member(&pool, campus_id, "asker").await;
        let service = IntentService::new(pool.clone());

        let live = service
            .create(stated(
                campus_id,
                &asker,
                kinds::GOODS_SEEK,
                "想收个显示器",
                Slots::default(),
            ))
            .await
            .expect("create");
        assert!(service
            .answerable_author(campus_id, live)
            .await
            .expect("live")
            .is_some());

        // Withdrawn.
        let withdrawn = service
            .create(stated(
                campus_id,
                &asker,
                kinds::HELP,
                "算了",
                Slots::default(),
            ))
            .await
            .expect("create");
        service.withdraw(&asker, withdrawn).await.expect("withdraw");
        assert!(service
            .answerable_author(campus_id, withdrawn)
            .await
            .expect("withdrawn")
            .is_none());

        // Fulfilled.
        let done = service
            .create(stated(
                campus_id,
                &asker,
                kinds::HELP,
                "修好了",
                Slots::default(),
            ))
            .await
            .expect("create");
        service.fulfil(&asker, done).await.expect("fulfil");
        assert!(service
            .answerable_author(campus_id, done)
            .await
            .expect("fulfilled")
            .is_none());

        // Private.
        let private = service
            .create(NewIntent {
                visibility: "private",
                ..stated(
                    campus_id,
                    &asker,
                    kinds::GOODS_SEEK,
                    "先不公开",
                    Slots::default(),
                )
            })
            .await
            .expect("create");
        assert!(service
            .answerable_author(campus_id, private)
            .await
            .expect("private")
            .is_none());

        // Unknown.
        assert!(service
            .answerable_author(campus_id, Uuid::new_v4())
            .await
            .expect("unknown")
            .is_none());
    })
    .await;
}
