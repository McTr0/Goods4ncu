//! Undo window for immediately-executed (L2) agent actions.
//!
//! What these tests are defending. Replacing an up-front confirmation with an
//! undo window is only a good trade if undo is actually trustworthy: it must
//! never fire twice, never race itself, never revert someone else's action,
//! and — the property that makes it safe at all — never overwrite state that
//! changed after the action. A snapshot restore that ignores the current world
//! would quietly destroy a sale or a later edit, which is strictly worse than
//! the confirmation dialog it replaced.

use goods4ncu::agents::tools::{CreateListingArgs, CreateListingTool, ToolContext};
use goods4ncu::services::notification::NotificationService;
use goods4ncu::services::undo::{UndoOutcome, UndoService};
use goods4ncu::test_infra::with_test_pool;
use rig::tool::Tool;
use uuid::Uuid;

fn tool_ctx(pool: sqlx::PgPool, user_id: &str) -> ToolContext {
    ToolContext {
        db_pool: pool.clone(),
        current_user_id: Some(user_id.to_string()),
        current_campus_id: None,
        moderation: goods4ncu::services::moderation::ModerationService::new_for_test(false),
        notification: NotificationService::new(pool),
    }
}

async fn seed_verified_user(pool: &sqlx::PgPool, user_id: &str) {
    sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
        .bind(user_id)
        .bind(format!("undo_user_{}", Uuid::new_v4()))
        .execute(pool)
        .await
        .expect("insert user");
    sqlx::query(
        "INSERT INTO campus_memberships (campus_id, user_id, status, verification_method, verified_at)
         SELECT id, $1, 'verified', 'test_fixture', NOW() FROM campuses WHERE slug = 'ncu'",
    )
    .bind(user_id)
    .execute(pool)
    .await
    .expect("insert membership");
}

fn create_args(title: &str) -> CreateListingArgs {
    CreateListingArgs {
        title: title.to_string(),
        category: "misc".to_string(),
        brand: "Brand".to_string(),
        condition_score: 8,
        suggested_price_cny: 10_000,
        defects: vec![],
        original_description: "undo flow".to_string(),
    }
}

/// Publish through the tool and return (listing_id, undoable action id).
async fn publish(pool: &sqlx::PgPool, user_id: &str, title: &str) -> (String, Uuid) {
    let tool = CreateListingTool {
        ctx: tool_ctx(pool.clone(), user_id),
    };
    tool.call(create_args(title)).await.expect("publish");

    let listing_id: String = sqlx::query_scalar("SELECT id FROM inventory WHERE title = $1")
        .bind(title)
        .fetch_one(pool)
        .await
        .expect("listing exists");

    let actions = UndoService::new(pool.clone())
        .list_undoable(user_id)
        .await
        .expect("list undoable");
    let action = actions
        .iter()
        .find(|a| a.target_id == listing_id)
        .expect("publish registered an undoable action");
    (listing_id, action.id)
}

async fn status_of(pool: &sqlx::PgPool, listing_id: &str) -> String {
    sqlx::query_scalar("SELECT status FROM inventory WHERE id = $1")
        .bind(listing_id)
        .fetch_one(pool)
        .await
        .expect("listing status")
}

#[tokio::test]
async fn publish_is_registered_undoable_and_undo_retracts_it() {
    with_test_pool(|pool| async move {
        let user_id = format!("undo-actor-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &user_id).await;
        let title = format!("Undo Target {}", Uuid::new_v4().simple());
        let (listing_id, action_id) = publish(&pool, &user_id, &title).await;

        assert_eq!(status_of(&pool, &listing_id).await, "active");

        let outcome = UndoService::new(pool.clone())
            .undo(&user_id, action_id)
            .await
            .expect("undo");
        assert!(matches!(outcome, UndoOutcome::Undone(_)), "{outcome:?}");
        assert_eq!(status_of(&pool, &listing_id).await, "deleted");

        // The embedding goes with it, so retracted listings stop surfacing in
        // retrieval the same way deleted ones do.
        let documents: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM documents WHERE id = $1")
            .bind(&listing_id)
            .fetch_one(&pool)
            .await
            .expect("count documents");
        assert_eq!(documents, 0);

        // Consumed actions leave the undoable list.
        let remaining = UndoService::new(pool.clone())
            .list_undoable(&user_id)
            .await
            .expect("list after undo");
        assert!(!remaining.iter().any(|a| a.id == action_id));
    })
    .await;
}

#[tokio::test]
async fn repeat_undo_is_idempotent() {
    with_test_pool(|pool| async move {
        let user_id = format!("undo-idem-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &user_id).await;
        let title = format!("Undo Idem {}", Uuid::new_v4().simple());
        let (listing_id, action_id) = publish(&pool, &user_id, &title).await;

        let service = UndoService::new(pool.clone());
        let UndoOutcome::Undone(first) = service.undo(&user_id, action_id).await.expect("first")
        else {
            panic!("expected first undo to apply");
        };

        // Someone re-publishes the same listing id out of band. A second undo
        // must NOT reach through and retract it again — the action was already
        // consumed, and it answers with the original result.
        sqlx::query("UPDATE inventory SET status = 'active' WHERE id = $1")
            .bind(&listing_id)
            .execute(&pool)
            .await
            .expect("reactivate");

        let outcome = service.undo(&user_id, action_id).await.expect("second");
        match outcome {
            UndoOutcome::AlreadyUndone(second) => assert_eq!(second, first),
            other => panic!("expected AlreadyUndone, got {other:?}"),
        }
        assert_eq!(
            status_of(&pool, &listing_id).await,
            "active",
            "a consumed undo must not act a second time"
        );
    })
    .await;
}

#[tokio::test]
async fn undo_refuses_when_the_listing_moved_on() {
    // The property that makes the undo window safe: if the world changed after
    // the action, reverting would clobber that change, so undo declines and
    // explains instead.
    with_test_pool(|pool| async move {
        let user_id = format!("undo-conflict-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &user_id).await;
        let title = format!("Undo Conflict {}", Uuid::new_v4().simple());
        let (listing_id, action_id) = publish(&pool, &user_id, &title).await;

        // It sells before the seller presses undo.
        sqlx::query("UPDATE inventory SET status = 'sold' WHERE id = $1")
            .bind(&listing_id)
            .execute(&pool)
            .await
            .expect("sell");

        let outcome = UndoService::new(pool.clone())
            .undo(&user_id, action_id)
            .await
            .expect("undo");
        match outcome {
            UndoOutcome::Conflict(reason) => {
                assert!(reason.contains("撤销"), "reason should explain: {reason}")
            }
            other => panic!("expected Conflict, got {other:?}"),
        }

        // The sale stands, untouched.
        assert_eq!(status_of(&pool, &listing_id).await, "sold");

        // A refused undo is not consumed — it stays available in case the
        // conflict resolves inside the window.
        let still_open = UndoService::new(pool.clone())
            .list_undoable(&user_id)
            .await
            .expect("list");
        assert!(still_open.iter().any(|a| a.id == action_id));
    })
    .await;
}

#[tokio::test]
async fn undo_is_scoped_to_the_actor() {
    with_test_pool(|pool| async move {
        let owner_id = format!("undo-owner-{}", Uuid::new_v4().simple());
        let outsider_id = format!("undo-outsider-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &owner_id).await;
        seed_verified_user(&pool, &outsider_id).await;
        let title = format!("Undo Scoped {}", Uuid::new_v4().simple());
        let (listing_id, action_id) = publish(&pool, &owner_id, &title).await;

        let service = UndoService::new(pool.clone());

        // Indistinguishable from an unknown action — no existence oracle.
        let outcome = service.undo(&outsider_id, action_id).await.expect("undo");
        assert!(matches!(outcome, UndoOutcome::NotFound), "{outcome:?}");
        assert_eq!(status_of(&pool, &listing_id).await, "active");

        // Nor does it show up in their undoable list.
        let theirs = service
            .list_undoable(&outsider_id)
            .await
            .expect("outsider list");
        assert!(!theirs.iter().any(|a| a.id == action_id));

        let unknown = service.undo(&owner_id, Uuid::new_v4()).await.expect("undo");
        assert!(matches!(unknown, UndoOutcome::NotFound));
    })
    .await;
}

#[tokio::test]
async fn undo_expires_with_its_window() {
    with_test_pool(|pool| async move {
        let user_id = format!("undo-expiry-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &user_id).await;
        let title = format!("Undo Expiry {}", Uuid::new_v4().simple());
        let (listing_id, action_id) = publish(&pool, &user_id, &title).await;

        sqlx::query(
            "UPDATE reversible_actions SET undo_deadline = NOW() - interval '1 second'
             WHERE id = $1",
        )
        .bind(action_id)
        .execute(&pool)
        .await
        .expect("expire window");

        let service = UndoService::new(pool.clone());
        let outcome = service.undo(&user_id, action_id).await.expect("undo");
        assert!(matches!(outcome, UndoOutcome::Expired), "{outcome:?}");
        assert_eq!(status_of(&pool, &listing_id).await, "active");

        // Expired actions drop off the list rather than showing a dead button.
        let listed = service.list_undoable(&user_id).await.expect("list");
        assert!(!listed.iter().any(|a| a.id == action_id));
    })
    .await;
}

#[tokio::test]
async fn concurrent_undos_apply_exactly_once() {
    // Two taps on the undo button, or two devices, must not double-apply the
    // inverse. The row lock serialises them; the loser observes the winner's
    // result.
    //
    // The racers run on a separate multi-connection pool. The default test
    // pool caps at one connection, so spawning tasks against it would queue
    // them on that connection and the `FOR UPDATE` lock would never be
    // contended — the test would pass without exercising the thing it names.
    with_test_pool(|pool| async move {
        let user_id = format!("undo-race-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &user_id).await;
        let title = format!("Undo Race {}", Uuid::new_v4().simple());
        let (listing_id, action_id) = publish(&pool, &user_id, &title).await;

        let racing_pool = goods4ncu::test_infra::concurrent_test_pool(4).await;
        let racers: Vec<_> = (0..4)
            .map(|_| {
                let pool = racing_pool.clone();
                let user_id = user_id.clone();
                tokio::spawn(async move {
                    UndoService::new(pool)
                        .undo(&user_id, action_id)
                        .await
                        .expect("undo")
                })
            })
            .collect();

        let mut applied = 0;
        let mut already = 0;
        for racer in racers {
            match racer.await.expect("join") {
                UndoOutcome::Undone(_) => applied += 1,
                UndoOutcome::AlreadyUndone(_) => already += 1,
                other => panic!("unexpected concurrent outcome: {other:?}"),
            }
        }
        assert_eq!(applied, 1, "the inverse must apply exactly once");
        assert_eq!(already, 3);
        assert_eq!(status_of(&pool, &listing_id).await, "deleted");
    })
    .await;
}

#[tokio::test]
async fn model_visible_reply_carries_no_undo_handle() {
    // Undo is authorised by the actor's session, not by a secret, and it is
    // not exposed as a tool — but the reply the model sees should still not
    // hand it the action identifier. Nothing in model-visible text should be
    // usable to address the undo endpoint.
    with_test_pool(|pool| async move {
        let user_id = format!("undo-leak-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &user_id).await;
        let title = format!("Undo Leak {}", Uuid::new_v4().simple());

        let tool = CreateListingTool {
            ctx: tool_ctx(pool.clone(), &user_id),
        };
        let reply = tool.call(create_args(&title)).await.expect("publish");

        let action_id: Uuid = sqlx::query_scalar(
            "SELECT id FROM reversible_actions WHERE actor_user_id = $1 ORDER BY created_at DESC
             LIMIT 1",
        )
        .bind(&user_id)
        .fetch_one(&pool)
        .await
        .expect("action row");

        for rendering in [action_id.to_string(), action_id.simple().to_string()] {
            assert!(
                !reply.contains(&rendering),
                "undo action id must not appear in model-visible text: {reply}"
            );
        }
    })
    .await;
}
