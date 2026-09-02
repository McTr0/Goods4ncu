//! Transactional outbox semantics: atomic enqueue, at-least-once dispatch,
//! backoff, dead-letter, lease exclusivity and audited replay.

use async_trait::async_trait;
use goods4ncu::services::notification::{NewNotification, NotificationService};
use goods4ncu::services::outbox::{
    self, enqueue_in_tx, process_batch, replay_dead_lettered, OutboxDispatcher,
};
use goods4ncu::test_infra::with_test_pool;
use sqlx::Row;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use uuid::Uuid;

/// Records dispatches; fails the first `fail_first` attempts per event batch.
struct RecordingDispatcher {
    calls: Mutex<Vec<(String, serde_json::Value)>>,
    failures_remaining: AtomicUsize,
}

impl RecordingDispatcher {
    fn new(fail_first: usize) -> Self {
        Self {
            calls: Mutex::new(Vec::new()),
            failures_remaining: AtomicUsize::new(fail_first),
        }
    }

    fn calls(&self) -> Vec<(String, serde_json::Value)> {
        self.calls.lock().unwrap().clone()
    }
}

#[async_trait]
impl OutboxDispatcher for RecordingDispatcher {
    async fn dispatch(&self, topic: &str, payload: &serde_json::Value) -> anyhow::Result<()> {
        if self
            .failures_remaining
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_sub(1))
            .is_ok()
        {
            anyhow::bail!("injected dispatch failure");
        }
        self.calls
            .lock()
            .unwrap()
            .push((topic.to_string(), payload.clone()));
        Ok(())
    }
}

async fn event_row(pool: &sqlx::PgPool, id: i64) -> (i32, bool, bool, Option<String>) {
    let row = sqlx::query(
        "SELECT attempts, processed_at IS NOT NULL AS processed,
                dead_lettered_at IS NOT NULL AS dead, last_error
         FROM outbox_events WHERE id = $1",
    )
    .bind(id)
    .fetch_one(pool)
    .await
    .expect("event row");
    (
        row.get("attempts"),
        row.get("processed"),
        row.get("dead"),
        row.get("last_error"),
    )
}

#[tokio::test]
async fn enqueue_is_atomic_with_the_business_transaction() {
    with_test_pool(|pool| async move {
        // Rolled-back transaction leaves no event behind.
        let mut tx = pool.begin().await.expect("begin");
        enqueue_in_tx(&mut tx, "test.rollback", &serde_json::json!({"n": 1}))
            .await
            .expect("enqueue");
        tx.rollback().await.expect("rollback");
        let count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM outbox_events WHERE topic = 'test.rollback'")
                .fetch_one(&pool)
                .await
                .expect("count");
        assert_eq!(count, 0, "a rolled-back enqueue must not survive");

        // Committed transaction persists exactly one event.
        let mut tx = pool.begin().await.expect("begin");
        let id = enqueue_in_tx(&mut tx, "test.commit", &serde_json::json!({"n": 2}))
            .await
            .expect("enqueue");
        tx.commit().await.expect("commit");
        let (attempts, processed, dead, _) = event_row(&pool, id).await;
        assert_eq!((attempts, processed, dead), (0, false, false));
    })
    .await;
}

#[tokio::test]
async fn worker_dispatches_and_marks_processed() {
    with_test_pool(|pool| async move {
        let mut tx = pool.begin().await.expect("begin");
        let id = enqueue_in_tx(&mut tx, "test.dispatch", &serde_json::json!({"k": "v"}))
            .await
            .expect("enqueue");
        tx.commit().await.expect("commit");

        let dispatcher = RecordingDispatcher::new(0);
        let claimed = process_batch(&pool, "worker-a", &dispatcher)
            .await
            .expect("batch");
        assert!(claimed >= 1);

        let calls = dispatcher.calls();
        assert!(calls
            .iter()
            .any(|(topic, payload)| topic == "test.dispatch" && payload["k"] == "v"));
        let (_, processed, dead, _) = event_row(&pool, id).await;
        assert!(processed, "successful dispatch must mark processed");
        assert!(!dead);

        // A processed event is never claimed again.
        let dispatcher2 = RecordingDispatcher::new(0);
        process_batch(&pool, "worker-b", &dispatcher2)
            .await
            .expect("batch 2");
        assert!(
            dispatcher2.calls().is_empty(),
            "processed events must not be re-dispatched"
        );
    })
    .await;
}

#[tokio::test]
async fn failures_back_off_then_dead_letter_and_replay_recovers() {
    with_test_pool(|pool| async move {
        let mut tx = pool.begin().await.expect("begin");
        let id = enqueue_in_tx(&mut tx, "test.fail", &serde_json::json!({}))
            .await
            .expect("enqueue");
        tx.commit().await.expect("commit");
        // Small budget so the test exercises the dead-letter path quickly.
        sqlx::query("UPDATE outbox_events SET max_attempts = 2 WHERE id = $1")
            .bind(id)
            .execute(&pool)
            .await
            .expect("shrink budget");

        let dispatcher = RecordingDispatcher::new(usize::MAX);

        // First failure: backed off, not yet dead.
        process_batch(&pool, "worker-a", &dispatcher)
            .await
            .expect("first attempt");
        let (attempts, processed, dead, last_error) = event_row(&pool, id).await;
        assert_eq!(attempts, 1);
        assert!(!processed && !dead);
        assert!(last_error.expect("error recorded").contains("injected"));

        // Backed-off events are not due yet.
        let claimed = process_batch(&pool, "worker-a", &dispatcher)
            .await
            .expect("premature attempt");
        assert_eq!(claimed, 0, "backoff must delay the retry");

        // Force the retry due, fail again → attempts exhausted → dead-letter.
        sqlx::query("UPDATE outbox_events SET available_at = NOW() WHERE id = $1")
            .bind(id)
            .execute(&pool)
            .await
            .expect("force due");
        process_batch(&pool, "worker-a", &dispatcher)
            .await
            .expect("second attempt");
        let (attempts, processed, dead, _) = event_row(&pool, id).await;
        assert_eq!(attempts, 2);
        assert!(dead, "exhausted events must dead-letter, not retry forever");
        assert!(!processed);

        // Dead-lettered events are ignored by the worker.
        let claimed = process_batch(&pool, "worker-a", &dispatcher)
            .await
            .expect("post-dead attempt");
        assert_eq!(claimed, 0);

        // Audited replay resets the event; a now-healthy dispatcher delivers.
        assert!(replay_dead_lettered(&pool, id).await.expect("replay"));
        let healthy = RecordingDispatcher::new(0);
        process_batch(&pool, "worker-a", &healthy)
            .await
            .expect("replay attempt");
        let (_, processed, dead, _) = event_row(&pool, id).await;
        assert!(processed && !dead, "replayed event must deliver");
        assert_eq!(healthy.calls().len(), 1);

        // Replaying a non-dead event is a no-op.
        assert!(!replay_dead_lettered(&pool, id).await.expect("noop replay"));
    })
    .await;
}

#[tokio::test]
async fn leases_prevent_concurrent_double_dispatch() {
    with_test_pool(|pool| async move {
        let mut tx = pool.begin().await.expect("begin");
        let id = enqueue_in_tx(&mut tx, "test.lease", &serde_json::json!({}))
            .await
            .expect("enqueue");
        tx.commit().await.expect("commit");

        // Simulate a crashed worker holding a live lease.
        sqlx::query(
            "UPDATE outbox_events
             SET locked_by = 'crashed-worker', locked_until = NOW() + interval '60 seconds'
             WHERE id = $1",
        )
        .bind(id)
        .execute(&pool)
        .await
        .expect("hold lease");

        let dispatcher = RecordingDispatcher::new(0);
        let claimed = process_batch(&pool, "worker-b", &dispatcher)
            .await
            .expect("claim during lease");
        assert_eq!(claimed, 0, "a live lease must block other workers");

        // Once the lease expires the event becomes reclaimable: at-least-once,
        // never lost.
        sqlx::query(
            "UPDATE outbox_events SET locked_until = NOW() - interval '1 second' WHERE id = $1",
        )
        .bind(id)
        .execute(&pool)
        .await
        .expect("expire lease");
        let claimed = process_batch(&pool, "worker-b", &dispatcher)
            .await
            .expect("claim after expiry");
        assert_eq!(claimed, 1, "an expired lease must be reclaimable");
        let (_, processed, _, _) = event_row(&pool, id).await;
        assert!(processed);
    })
    .await;
}

#[tokio::test]
async fn notification_create_enqueues_push_atomically() {
    with_test_pool(|pool| async move {
        let user_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
            .bind(&user_id)
            .bind(format!("outbox_user_{}", Uuid::new_v4()))
            .execute(&pool)
            .await
            .expect("insert user");
        let campus_id: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
            .fetch_one(&pool)
            .await
            .expect("ncu campus");

        let notification_id = NotificationService::new(pool.clone())
            .create(NewNotification {
                campus_id,
                user_id: &user_id,
                event_type: "outbox_test",
                title: "outbox",
                body: "durable push",
                related_order_id: None,
                related_listing_id: None,
                related_conversation_id: None,
                related_space_id: None,
            })
            .await
            .expect("create notification");

        // The push event exists, carries the notification id, and dispatching
        // it produces the WS payload for the right user.
        let dispatcher = RecordingDispatcher::new(0);
        process_batch(&pool, "worker-a", &dispatcher)
            .await
            .expect("batch");
        let calls = dispatcher.calls();
        let push = calls
            .iter()
            .find(|(topic, payload)| {
                topic == outbox::TOPIC_NOTIFICATION_PUSH && payload["user_id"] == *user_id
            })
            .expect("notification push event dispatched");
        assert_eq!(push.1["message"]["id"], notification_id);
        assert_eq!(push.1["message"]["event_type"], "outbox_test");
        assert_eq!(push.1["campus_id"], campus_id.to_string());

        // And the notification row itself committed alongside it.
        let exists: bool =
            sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM notifications WHERE id = $1)")
                .bind(&notification_id)
                .fetch_one(&pool)
                .await
                .expect("notification row");
        assert!(exists);
    })
    .await;
}

#[tokio::test]
async fn dead_letter_listing_and_replay_updates_metrics_and_state() {
    with_test_pool(|pool| async move {
        let mut tx = pool.begin().await.expect("begin");
        let id = enqueue_in_tx(
            &mut tx,
            "test.dead_letter_replay",
            &serde_json::json!({"msg": "fail"}),
        )
        .await
        .expect("enqueue");
        tx.commit().await.expect("commit");

        // Force attempts to max_attempts - 1 so next failure dead-letters it
        sqlx::query("UPDATE outbox_events SET attempts = max_attempts - 1 WHERE id = $1")
            .bind(id)
            .execute(&pool)
            .await
            .expect("set attempts");

        let dispatcher = RecordingDispatcher::new(1);
        process_batch(&pool, "worker-dl", &dispatcher)
            .await
            .expect("batch");

        // Verify it is dead-lettered
        let (_, processed, dead, last_err) = event_row(&pool, id).await;
        assert!(!processed);
        assert!(dead);
        assert!(last_err.is_some());

        // Test list_dead_lettered
        let (dead_list, total) = outbox::list_dead_lettered(&pool, 10, 0)
            .await
            .expect("list dead lettered");
        assert!(total >= 1);
        let found = dead_list
            .iter()
            .find(|e| e.id == id)
            .expect("found in dead letter list");
        assert_eq!(found.topic, "test.dead_letter_replay");
        assert_eq!(found.payload["msg"], "fail");

        // Test refresh_queue_metrics
        outbox::refresh_queue_metrics(&pool).await;

        // Test replay_dead_lettered
        let replayed = replay_dead_lettered(&pool, id)
            .await
            .expect("replay dead lettered");
        assert!(replayed);

        let (attempts, processed, dead, _) = event_row(&pool, id).await;
        assert_eq!(attempts, 0);
        assert!(!processed);
        assert!(!dead);

        // Can be dispatched successfully now
        let ok_dispatcher = RecordingDispatcher::new(0);
        let claimed = process_batch(&pool, "worker-dl2", &ok_dispatcher)
            .await
            .expect("batch after replay");
        assert_eq!(claimed, 1);
        let (_, processed, _, _) = event_row(&pool, id).await;
        assert!(processed);
    })
    .await;
}
