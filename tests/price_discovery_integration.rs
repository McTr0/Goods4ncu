//! Private-reservation price matching.
//!
//! The reservation is the most sensitive number in this product: a statement of
//! what someone will privately accept, worth more to a counterparty than any
//! listing detail. If it can leak, the mechanism is worse than haggling, because
//! at least haggling is honest about being adversarial.
//!
//! So the leak tests come first and are the reason this file exists. Held to the
//! same standard as the ActionPlan confirmation token: never in a response,
//! never in a log, never in model context.
//!
//! The second property is subtler and easier to lose in a later refactor:
//! **"no deal" must carry no information**. Not how far apart, not who was
//! further, not even whether the other side has answered yet. "You were 20
//! short" is a bargaining position handed to one side, and someone who can
//! learn it by running the mechanism has been given a tool rather than a
//! service.

use goods4ncu::services::moderation_case::ModerationCaseService;
use goods4ncu::services::price_discovery::{
    status, ListingUnavailable, Outcome, PriceDiscoveryService,
};
use goods4ncu::test_infra::with_test_pool;
use uuid::Uuid;

async fn campus(pool: &sqlx::PgPool) -> Uuid {
    sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
        .fetch_one(pool)
        .await
        .expect("ncu campus")
}

async fn member(pool: &sqlx::PgPool, campus_id: Uuid, tag: &str) -> String {
    let id = format!("pd-{tag}-{}", Uuid::new_v4().simple());
    sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
        .bind(&id)
        .bind(format!("pd_{tag}_{}", Uuid::new_v4().simple()))
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

async fn listing(pool: &sqlx::PgPool, campus_id: Uuid, owner: &str) -> String {
    let id = Uuid::new_v4().to_string();
    sqlx::query(
        "INSERT INTO inventory (id, campus_id, title, category, brand, condition_score,
                                suggested_price_cny, defects, owner_id, status)
         VALUES ($1, $2, '显示器', 'electronics', '', 8, 30000, '[]', $3, 'active')",
    )
    .bind(&id)
    .bind(campus_id)
    .bind(owner)
    .execute(pool)
    .await
    .expect("insert listing");
    id
}

async fn restrict_listing(pool: &sqlx::PgPool, listing_id: &str, actor_id: &str) {
    let campus_id = campus(pool).await;
    ModerationCaseService::new(pool.clone())
        .impose_manual_listing_takedown(listing_id, campus_id, actor_id, "测试发布受平台限制", None)
        .await
        .expect("restrict listing");
}

/// Open a session both sides have agreed to.
async fn open_session(
    pool: &sqlx::PgPool,
    campus_id: Uuid,
    listing_id: &str,
    seller: &str,
    buyer: &str,
) -> Uuid {
    let service = PriceDiscoveryService::new(pool.clone());
    let id = service
        .propose(campus_id, listing_id, seller, buyer)
        .await
        .expect("propose");
    assert!(service.accept(id, buyer).await.expect("accept"));
    id
}

#[tokio::test]
async fn neither_side_can_ever_see_the_others_number() {
    // The headline. 280 and 250 meet at 265, and each party learns 265 and
    // nothing else — not the other's limit, not their own relative position.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let seller = member(&pool, campus_id, "seller").await;
        let buyer = member(&pool, campus_id, "buyer").await;
        let item = listing(&pool, campus_id, &seller).await;
        let service = PriceDiscoveryService::new(pool.clone());
        let session = open_session(&pool, campus_id, &item, &seller, &buyer).await;

        assert_eq!(
            service
                .state_limit(session, &buyer, 28_000)
                .await
                .expect("buyer")
                .expect("participant"),
            Outcome::WaitingForOther,
        );
        assert_eq!(
            service
                .state_limit(session, &seller, 25_000)
                .await
                .expect("seller")
                .expect("participant"),
            Outcome::Matched { cents: 26_500 },
        );

        // What each side may see, serialised exactly as the API returns it.
        for viewer in [&seller, &buyer] {
            let view = service
                .view(session, viewer)
                .await
                .expect("view")
                .expect("participant");
            let json = serde_json::to_string(&view).expect("serialise");

            assert_eq!(view.matched_cents, Some(26_500), "the agreement is shared");
            for secret in ["28000", "25000"] {
                assert!(
                    !json.contains(secret),
                    "a reservation must never reach a client: {json}",
                );
            }
        }
    })
    .await;
}

#[tokio::test]
async fn no_deal_reveals_nothing_about_the_gap() {
    // The property most likely to be lost in a later "helpful" change. Telling
    // the buyer they were 10 short hands them the seller's floor, and telling
    // either side who was further does the same more slowly.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let seller = member(&pool, campus_id, "seller").await;
        let buyer = member(&pool, campus_id, "buyer").await;
        let item = listing(&pool, campus_id, &seller).await;
        let service = PriceDiscoveryService::new(pool.clone());
        let session = open_session(&pool, campus_id, &item, &seller, &buyer).await;

        service
            .state_limit(session, &buyer, 20_000)
            .await
            .expect("buyer");
        assert_eq!(
            service
                .state_limit(session, &seller, 30_000)
                .await
                .expect("seller")
                .expect("participant"),
            Outcome::NoDeal,
            "the outcome type has nowhere to put a gap",
        );

        for viewer in [&seller, &buyer] {
            let view = service
                .view(session, viewer)
                .await
                .expect("view")
                .expect("participant");
            assert_eq!(view.status, status::NO_DEAL);
            assert!(view.matched_cents.is_none());
            let json = serde_json::to_string(&view).expect("serialise");
            for revealing in ["20000", "30000", "10000"] {
                assert!(
                    !json.contains(revealing),
                    "no number, including the difference, may appear: {json}",
                );
            }
        }

        // And the gap is not even stored, so a future endpoint cannot expose
        // what a future author assumed was harmless.
        let stored: Option<i64> =
            sqlx::query_scalar("SELECT matched_cents FROM price_discovery_sessions WHERE id = $1")
                .bind(session)
                .fetch_one(&pool)
                .await
                .expect("row");
        assert!(stored.is_none());
    })
    .await;
}

#[tokio::test]
async fn a_viewer_cannot_tell_whether_the_other_side_has_answered() {
    // Knowing they are still deciding is a small advantage — it says they are
    // thinking about it — so the view reports only whether *you* have stated
    // yours.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let seller = member(&pool, campus_id, "seller").await;
        let buyer = member(&pool, campus_id, "buyer").await;
        let item = listing(&pool, campus_id, &seller).await;
        let service = PriceDiscoveryService::new(pool.clone());
        let session = open_session(&pool, campus_id, &item, &seller, &buyer).await;

        service
            .state_limit(session, &buyer, 28_000)
            .await
            .expect("buyer");

        let buyer_view = service
            .view(session, &buyer)
            .await
            .expect("view")
            .expect("participant");
        let seller_view = service
            .view(session, &seller)
            .await
            .expect("view")
            .expect("participant");

        assert!(buyer_view.you_have_stated);
        assert!(!seller_view.you_have_stated);
        // The two views are otherwise identical: nothing distinguishes "they
        // have answered" from "they have not".
        assert_eq!(buyer_view.status, seller_view.status);
        assert_eq!(buyer_view.matched_cents, seller_view.matched_cents);
    })
    .await;
}

#[tokio::test]
async fn both_sides_have_to_opt_in() {
    // A mechanism nobody chose is not a kindness. Until the other side agrees,
    // a stated limit is not accepted at all.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let seller = member(&pool, campus_id, "seller").await;
        let buyer = member(&pool, campus_id, "buyer").await;
        let item = listing(&pool, campus_id, &seller).await;
        let service = PriceDiscoveryService::new(pool.clone());

        let session = service
            .propose(campus_id, &item, &seller, &buyer)
            .await
            .expect("propose");
        assert!(
            service
                .state_limit(session, &buyer, 28_000)
                .await
                .expect("premature")
                .is_none(),
            "a limit stated before both sides agreed must be refused",
        );
        let stored: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM price_reservations WHERE session_id = $1")
                .bind(session)
                .fetch_one(&pool)
                .await
                .expect("count");
        assert_eq!(stored, 0, "and not recorded either");

        // Declining keeps the ordinary negotiation flow available.
        assert!(service.decline(session, &buyer).await.expect("decline"));
        let view = service
            .view(session, &buyer)
            .await
            .expect("view")
            .expect("participant");
        assert_eq!(view.status, status::DECLINED);
    })
    .await;
}

#[tokio::test]
async fn restriction_freezes_existing_sessions_but_still_allows_decline() {
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let seller = member(&pool, campus_id, "restricted-seller").await;
        let buyer = member(&pool, campus_id, "restricted-buyer").await;
        let actor = member(&pool, campus_id, "restricted-admin").await;
        let service = PriceDiscoveryService::new(pool.clone());

        let accept_item = listing(&pool, campus_id, &seller).await;
        let accept_session = service
            .propose(campus_id, &accept_item, &seller, &buyer)
            .await
            .expect("propose before restriction");
        restrict_listing(&pool, &accept_item, &actor).await;
        let accept_err = service
            .accept(accept_session, &buyer)
            .await
            .expect_err("restriction must freeze opt-in");
        assert!(accept_err.downcast_ref::<ListingUnavailable>().is_some());
        let accept_status: String =
            sqlx::query_scalar("SELECT status FROM price_discovery_sessions WHERE id = $1")
                .bind(accept_session)
                .fetch_one(&pool)
                .await
                .expect("accept session status");
        assert_eq!(accept_status, status::PROPOSED);

        let limit_item = listing(&pool, campus_id, &seller).await;
        let limit_session = open_session(&pool, campus_id, &limit_item, &seller, &buyer).await;
        restrict_listing(&pool, &limit_item, &actor).await;
        let limit_err = service
            .state_limit(limit_session, &buyer, 28_000)
            .await
            .expect_err("restriction must freeze reservations");
        assert!(limit_err.downcast_ref::<ListingUnavailable>().is_some());
        let (limit_status, reservations): (String, i64) = sqlx::query_as(
            "SELECT s.status,
                    (SELECT COUNT(*) FROM price_reservations r WHERE r.session_id = s.id)
             FROM price_discovery_sessions s WHERE s.id = $1",
        )
        .bind(limit_session)
        .fetch_one(&pool)
        .await
        .expect("limit side facts");
        assert_eq!(limit_status, status::OPEN);
        assert_eq!(reservations, 0);

        let decline_item = listing(&pool, campus_id, &seller).await;
        let decline_session = service
            .propose(campus_id, &decline_item, &seller, &buyer)
            .await
            .expect("decline session");
        restrict_listing(&pool, &decline_item, &actor).await;
        assert!(service
            .decline(decline_session, &buyer)
            .await
            .expect("decline stays available"));
        let decline_status: String =
            sqlx::query_scalar("SELECT status FROM price_discovery_sessions WHERE id = $1")
                .bind(decline_session)
                .fetch_one(&pool)
                .await
                .expect("decline status");
        assert_eq!(decline_status, status::DECLINED);
    })
    .await;
}

#[tokio::test]
async fn a_stranger_learns_nothing_not_even_that_the_session_exists() {
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let seller = member(&pool, campus_id, "seller").await;
        let buyer = member(&pool, campus_id, "buyer").await;
        let stranger = member(&pool, campus_id, "stranger").await;
        let item = listing(&pool, campus_id, &seller).await;
        let service = PriceDiscoveryService::new(pool.clone());
        let session = open_session(&pool, campus_id, &item, &seller, &buyer).await;

        assert!(
            service
                .view(session, &stranger)
                .await
                .expect("view")
                .is_none(),
            "a non-participant must not learn that two people are negotiating",
        );
        assert!(
            service
                .state_limit(session, &stranger, 1)
                .await
                .expect("state")
                .is_none(),
            "nor be able to inject a limit",
        );
        assert!(
            !service.accept(session, &stranger).await.expect("accept") || {
                // Accept is scoped to participants; if it ever succeeded for a
                // stranger the session would be settled by someone outside it.
                false
            }
        );
    })
    .await;
}

#[tokio::test]
async fn a_limit_cannot_be_changed_to_probe_the_boundary() {
    // Re-submitting until it matches would locate the other side's number
    // exactly. The first statement stands, and a resolved session accepts
    // nothing further.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let seller = member(&pool, campus_id, "seller").await;
        let buyer = member(&pool, campus_id, "buyer").await;
        let item = listing(&pool, campus_id, &seller).await;
        let service = PriceDiscoveryService::new(pool.clone());
        let session = open_session(&pool, campus_id, &item, &seller, &buyer).await;

        service
            .state_limit(session, &buyer, 20_000)
            .await
            .expect("first");
        // A second, higher statement does not replace the first.
        service
            .state_limit(session, &buyer, 40_000)
            .await
            .expect("second");
        let recorded: i64 = sqlx::query_scalar(
            "SELECT cents FROM price_reservations WHERE session_id = $1 AND user_id = $2",
        )
        .bind(session)
        .bind(&buyer)
        .fetch_one(&pool)
        .await
        .expect("recorded");
        assert_eq!(recorded, 20_000, "the first statement stands");

        // Which means this pairing is a no-deal, and re-stating cannot rescue it.
        assert_eq!(
            service
                .state_limit(session, &seller, 30_000)
                .await
                .expect("seller")
                .expect("participant"),
            Outcome::NoDeal,
        );
        assert!(
            service
                .state_limit(session, &buyer, 40_000)
                .await
                .expect("after resolution")
                .is_none(),
            "a resolved session accepts nothing further",
        );
    })
    .await;
}

#[tokio::test]
async fn one_session_per_pair_per_listing() {
    // Repeated runs would let someone binary-search the other side's limit.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let seller = member(&pool, campus_id, "seller").await;
        let buyer = member(&pool, campus_id, "buyer").await;
        let item = listing(&pool, campus_id, &seller).await;
        let service = PriceDiscoveryService::new(pool.clone());

        let first = service
            .propose(campus_id, &item, &seller, &buyer)
            .await
            .expect("first");
        let second = service
            .propose(campus_id, &item, &seller, &buyer)
            .await
            .expect("second");
        assert_eq!(first, second, "proposing twice is the same session");

        let sessions: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM price_discovery_sessions WHERE listing_id = $1",
        )
        .bind(&item)
        .fetch_one(&pool)
        .await
        .expect("count");
        assert_eq!(sessions, 1);
    })
    .await;
}

#[tokio::test]
async fn simultaneous_statements_still_resolve_exactly_once() {
    // Both sides tapping at the same moment must not each see "the other has
    // not answered" and leave a session that never settles.
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let seller = member(&pool, campus_id, "seller").await;
        let buyer = member(&pool, campus_id, "buyer").await;
        let item = listing(&pool, campus_id, &seller).await;
        let session = open_session(&pool, campus_id, &item, &seller, &buyer).await;

        let racing = goods4ncu::test_infra::concurrent_test_pool(4).await;
        let a = {
            let pool = racing.clone();
            let buyer = buyer.clone();
            tokio::spawn(async move {
                PriceDiscoveryService::new(pool)
                    .state_limit(session, &buyer, 28_000)
                    .await
                    .expect("buyer")
            })
        };
        let b = {
            let pool = racing.clone();
            let seller = seller.clone();
            tokio::spawn(async move {
                PriceDiscoveryService::new(pool)
                    .state_limit(session, &seller, 25_000)
                    .await
                    .expect("seller")
            })
        };
        let outcomes = [a.await.expect("join"), b.await.expect("join")];

        let matched = outcomes
            .iter()
            .filter(|o| matches!(o, Some(Outcome::Matched { .. })))
            .count();
        assert_eq!(matched, 1, "exactly one submission settles it");

        let (status_now, price): (String, Option<i64>) = sqlx::query_as(
            "SELECT status, matched_cents FROM price_discovery_sessions WHERE id = $1",
        )
        .bind(session)
        .fetch_one(&pool)
        .await
        .expect("row");
        assert_eq!(status_now, status::MATCHED);
        assert_eq!(price, Some(26_500));
    })
    .await;
}
