//! Agent Runtime v2 evaluation scenarios using FakeModelDriver.

use goods4ncu::agents::runtime::budget::ExecutionBudget;
use goods4ncu::agents::runtime::engine::{AgentRuntime, ToolExecutor, TurnEvent};
use goods4ncu::agents::runtime::event::{AgentEvent, EventData, TurnId};
use goods4ncu::agents::runtime::fake_driver::{FakeModelDriver, FakeStep};
use goods4ncu::agents::runtime::model::ModelRequest;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

fn noop_executor() -> ToolExecutor {
    Arc::new(|_name: &str, _args: &str| {
        Box::pin(async { Ok("ok".to_string()) })
            as Pin<Box<dyn Future<Output = anyhow::Result<String>> + Send>>
    })
}

#[tokio::test]
async fn text_only_turn_completes() {
    let driver = FakeModelDriver::text_only("你好！我是小昌。");
    let runtime = AgentRuntime::new(ExecutionBudget::default());
    let request = ModelRequest::user("你好", vec![]);

    let mut emitted = vec![];
    runtime
        .run_turn(
            &driver,
            request,
            noop_executor(),
            TurnId::generate(),
            "conv-test",
            &mut |event| match event {
                TurnEvent::Emit(e) => emitted.push(e),
                _ => {}
            },
        )
        .await;

    assert!(!emitted.is_empty());
    let terminal = emitted
        .iter()
        .find(|e| e.is_terminal())
        .expect("terminal event");
    assert!(matches!(terminal.data, EventData::TurnCompleted { .. }));
}

#[tokio::test]
async fn provider_error_produces_turn_failed() {
    let driver = FakeModelDriver::error("connection refused");
    let runtime = AgentRuntime::new(ExecutionBudget::default());
    let request = ModelRequest::user("hello", vec![]);

    let mut emitted = vec![];
    runtime
        .run_turn(
            &driver,
            request,
            noop_executor(),
            TurnId::generate(),
            "conv-err",
            &mut |event| match event {
                TurnEvent::Emit(e) => emitted.push(e),
                _ => {}
            },
        )
        .await;

    let failed = emitted
        .iter()
        .find(|e| matches!(e.data, EventData::TurnFailed { .. }))
        .expect("turn_failed");
    if let EventData::TurnFailed { error } = &failed.data {
        assert_eq!(
            error.code,
            goods4ncu::agents::runtime::event::RuntimeErrorCode::ProviderError
        );
    }
}

#[tokio::test]
async fn budget_exhaustion_stops_runaway_loop() {
    // Driver that always returns a tool call — should hit max_model_steps.
    let steps: Vec<FakeStep> = (0..20)
        .map(|_| FakeStep::ToolCall {
            name: "search_inventory".to_string(),
            args: serde_json::json!({"query": "test"}),
        })
        .collect();
    let mut all_steps = steps;
    all_steps.push(FakeStep::StopEndTurn);

    let driver = FakeModelDriver { steps: all_steps };
    let budget = ExecutionBudget {
        max_model_steps: 3,
        ..ExecutionBudget::default()
    };
    let runtime = AgentRuntime::new(budget);
    let request = ModelRequest::user("search", vec![]);

    let executor: ToolExecutor = Arc::new(|_name: &str, _args: &str| {
        Box::pin(async { Ok("result text".to_string()) })
            as Pin<Box<dyn Future<Output = anyhow::Result<String>> + Send>>
    });

    let mut emitted = vec![];
    runtime
        .run_turn(
            &driver,
            request,
            executor,
            TurnId::generate(),
            "conv-budget",
            &mut |event| match event {
                TurnEvent::Emit(e) => emitted.push(e),
                _ => {}
            },
        )
        .await;

    let failed = emitted
        .iter()
        .find(|e| matches!(e.data, EventData::TurnFailed { .. }))
        .expect("budget exhausted");
    if let EventData::TurnFailed { error } = &failed.data {
        assert_eq!(
            error.code,
            goods4ncu::agents::runtime::event::RuntimeErrorCode::LoopDetected
        );
    }
}
