//! Unified AgentRun envelope integration coverage.

use goods4ncu::services::agent_run::AgentRunService;
use goods4ncu::test_infra::with_test_pool;
use uuid::Uuid;

fn ncu_campus_id() -> Uuid {
    Uuid::parse_str("c0000000-0000-0000-0000-000000000001").expect("valid NCU campus id")
}

async fn seed_verified_user(pool: &sqlx::PgPool, user_id: &str) {
    sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
        .bind(user_id)
        .bind(format!("agent_run_{}", Uuid::new_v4().simple()))
        .execute(pool)
        .await
        .expect("insert user");
    sqlx::query(
        "INSERT INTO campus_memberships (
             campus_id, user_id, status, verification_method, verified_at
         )
         SELECT id, $1, 'verified', 'test_fixture', NOW()
         FROM campuses WHERE slug = 'ncu'",
    )
    .bind(user_id)
    .execute(pool)
    .await
    .expect("insert membership");
}

#[tokio::test]
async fn agent_run_is_idempotent_typed_and_body_free() {
    with_test_pool(|pool| async move {
        let user_id = format!("agent-run-user-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &user_id).await;
        let service = AgentRunService::new(pool.clone());
        let trace_id = format!("agent-run-trace-{}", Uuid::new_v4().simple());

        let run_id = service
            .start(
                &trace_id,
                ncu_campus_id(),
                &user_id,
                "agent-user-1",
                "search",
                0.85,
                Some("gemini"),
                Some("gemini-test-model"),
            )
            .await
            .expect("start run");
        let replayed_id = service
            .start(
                &trace_id,
                ncu_campus_id(),
                &user_id,
                "agent-user-1",
                "search",
                0.85,
                Some("gemini"),
                Some("gemini-test-model"),
            )
            .await
            .expect("replay start");
        assert_eq!(run_id, replayed_id);

        assert!(service
            .record_ttft(&trace_id, ncu_campus_id(), &user_id, 17)
            .await
            .expect("record first-token latency"));
        assert!(!service
            .record_ttft(&trace_id, ncu_campus_id(), &user_id, 23)
            .await
            .expect("first-token latency is write-once"));

        assert!(service
            .record_retrieval(
                &trace_id,
                ncu_campus_id(),
                &user_id,
                "search_inventory",
                2,
                Some(1),
                vec!["listing-a".to_string(), "listing-b".to_string()],
            )
            .await
            .expect("record retrieval"));
        assert!(service
            .record_tool(
                &trace_id,
                ncu_campus_id(),
                &user_id,
                "search_inventory",
                Some("L1"),
                "retrieved",
            )
            .await
            .expect("record tool"));
        assert!(service
            .finish_with_usage(
                &trace_id,
                ncu_campus_id(),
                &user_id,
                "completed",
                "llm_completed",
                None,
                Some(111),
                Some(37),
                Some(25),
            )
            .await
            .expect("finish run"));
        assert!(!service
            .finish(
                &trace_id,
                ncu_campus_id(),
                &user_id,
                "failed",
                "llm_failed",
                Some("provider_error"),
                Some(30),
            )
            .await
            .expect("terminal finish is idempotent"));
        assert!(!service
            .record_tool(
                &trace_id,
                ncu_campus_id(),
                &user_id,
                "search_inventory",
                Some("L1"),
                "late_event",
            )
            .await
            .expect("late tool event is ignored"));
        assert!(!service
            .record_retrieval(
                &trace_id,
                ncu_campus_id(),
                &user_id,
                "search_inventory",
                1,
                None,
                vec!["listing-late".to_string()],
            )
            .await
            .expect("late retrieval event is ignored"));

        let runs = service
            .list_recent(&user_id, ncu_campus_id(), 20)
            .await
            .expect("list runs");
        assert_eq!(runs.len(), 1);
        let run = &runs[0];
        assert_eq!(run.id, run_id);
        assert_eq!(run.status, "completed");
        assert_eq!(run.outcome_code.as_deref(), Some("llm_completed"));
        assert_eq!(run.provider.as_deref(), Some("gemini"));
        assert_eq!(run.model.as_deref(), Some("gemini-test-model"));
        assert_eq!(run.retrieval_count, Some(2));
        assert_eq!(run.retrieval_filtered_count, Some(1));
        assert_eq!(run.tool_call_count, 1);
        assert_eq!(
            run.final_resource_ids,
            serde_json::json!(["listing-a", "listing-b"])
        );
        assert_eq!(run.duration_ms, Some(25));
        assert_eq!(run.ttft_ms, Some(17));

        let (token_input, token_output): (i32, i32) =
            sqlx::query_as("SELECT token_input, token_output FROM agent_runs WHERE id = $1")
                .bind(run_id)
                .fetch_one(&pool)
                .await
                .expect("read token usage");
        assert_eq!((token_input, token_output), (111, 37));

        let event_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM agent_run_events WHERE run_id = $1")
                .bind(run_id)
                .fetch_one(&pool)
                .await
                .expect("count run events");
        assert_eq!(event_count, 4);

        let metadata: String = sqlx::query_scalar(
            "SELECT string_agg(metadata::text, ' ') FROM agent_run_events WHERE run_id = $1",
        )
        .bind(run_id)
        .fetch_one(&pool)
        .await
        .expect("read event metadata");
        assert!(!metadata.contains("agent-user"));
        assert!(!metadata.contains("listing-a"));
        assert!(!metadata.contains("prompt"));
    })
    .await;
}

#[tokio::test]
async fn abandoned_agent_run_can_be_reconciled_as_cancelled() {
    with_test_pool(|pool| async move {
        let user_id = format!("agent-run-cancel-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &user_id).await;
        let service = AgentRunService::new(pool.clone());
        let trace_id = format!("agent-run-cancel-trace-{}", Uuid::new_v4().simple());

        service
            .start(
                &trace_id,
                ncu_campus_id(),
                &user_id,
                "agent-user-1",
                "chat",
                0.5,
                Some("gemini"),
                Some("gemini-test-model"),
            )
            .await
            .expect("start cancellable run");

        assert!(service
            .cancel_started(
                &trace_id,
                ncu_campus_id(),
                &user_id,
                Some("client_disconnect_or_timeout"),
                Some(120_000),
            )
            .await
            .expect("reconcile cancelled run"));
        assert!(!service
            .cancel_started(
                &trace_id,
                ncu_campus_id(),
                &user_id,
                Some("client_disconnect_or_timeout"),
                Some(120_001),
            )
            .await
            .expect("duplicate cancellation is ignored"));

        let run = service
            .list_recent(&user_id, ncu_campus_id(), 20)
            .await
            .expect("list cancelled run")
            .pop()
            .expect("cancelled run exists");
        assert_eq!(run.status, "cancelled");
        assert_eq!(run.outcome_code.as_deref(), Some("cancelled"));
        assert_eq!(run.duration_ms, Some(120_000));

        let error_code: Option<String> =
            sqlx::query_scalar("SELECT error_code FROM agent_runs WHERE trace_id = $1")
                .bind(&trace_id)
                .fetch_one(&pool)
                .await
                .expect("read cancellation error code");
        assert_eq!(error_code.as_deref(), Some("client_disconnect_or_timeout"));
    })
    .await;
}

#[tokio::test]
async fn stale_started_runs_are_reconciled_once_by_the_durable_worker_path() {
    with_test_pool(|pool| async move {
        let user_id = format!("agent-run-stale-{}", Uuid::new_v4().simple());
        seed_verified_user(&pool, &user_id).await;
        let service = AgentRunService::new(pool.clone());
        let trace_id = format!("agent-run-stale-trace-{}", Uuid::new_v4().simple());
        let run_id = service
            .start(
                &trace_id,
                ncu_campus_id(),
                &user_id,
                "agent-user-1",
                "chat",
                0.5,
                Some("gemini"),
                Some("gemini-test-model"),
            )
            .await
            .expect("start stale run");
        sqlx::query(
            "UPDATE agent_runs
             SET updated_at = NOW() - interval '5 minutes'
             WHERE id = $1",
        )
        .bind(run_id)
        .execute(&pool)
        .await
        .expect("age stale run");

        let reconciled = service
            .reconcile_stale_started(chrono::Utc::now() - chrono::Duration::minutes(3), 100)
            .await
            .expect("reconcile stale run");
        assert_eq!(reconciled, 1);
        assert_eq!(
            service
                .reconcile_stale_started(chrono::Utc::now() - chrono::Duration::minutes(3), 100,)
                .await
                .expect("reconcile is idempotent"),
            0
        );

        let (status, outcome, error): (String, String, String) =
            sqlx::query_as("SELECT status, outcome_code, error_code FROM agent_runs WHERE id = $1")
                .bind(run_id)
                .fetch_one(&pool)
                .await
                .expect("read stale outcome");
        assert_eq!(status, "cancelled");
        assert_eq!(outcome, "cancelled");
        assert_eq!(error, "stale_reconciliation");

        let metadata: String = sqlx::query_scalar(
            "SELECT metadata::text FROM agent_run_events
             WHERE run_id = $1 AND event_type = 'outcome'",
        )
        .bind(run_id)
        .fetch_one(&pool)
        .await
        .expect("read stale outcome event");
        assert!(metadata.contains("reconciled"));
    })
    .await;
}
