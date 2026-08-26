//! Unified AgentRuntime loop.
//!
//! Replaces per-provider loops. Providers implement [`ModelDriver`];
//! the runtime handles budgets, loop detection, cancellation, and events.

use crate::agents::runtime::budget::ExecutionBudget;
use crate::agents::runtime::event::{
    AgentEvent, EventData, ModelEvent, ModelStopReason, RuntimeErrorCode, ToolCallData,
    ToolCallInfo, TurnId,
};
use crate::agents::runtime::loop_guard::LoopGuard;
use crate::agents::runtime::model::{ModelDriver, ModelEventStream, ModelRequest};
use crate::llm::UiAction;
use futures::StreamExt;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

/// Callback for executing a single tool call.
pub type ToolExecutor = Arc<
    dyn Fn(&str, &str) -> Pin<Box<dyn Future<Output = anyhow::Result<String>> + Send>>
        + Send
        + Sync,
>;

/// Events emitted during a turn, consumed by the SSE transport layer.
#[derive(Debug)]
pub enum TurnEvent {
    /// Serialize and send to client.
    Emit(AgentEvent),
    /// Internal: feed tool result back to the model for the next step.
    ToolResult {
        call_id: String,
        result_text: String,
    },
}

use crate::agents::runtime::event::UsageSummary;
use rig::completion::Message;

fn to_event_action(action: &crate::llm::UiAction) -> crate::agents::runtime::event::UiAction {
    crate::agents::runtime::event::UiAction {
        action_type: action.kind.clone(),
        payload: action.payload.clone(),
    }
}

pub struct AgentRuntime {
    pub budget: ExecutionBudget,
}

impl AgentRuntime {
    pub fn new(budget: ExecutionBudget) -> Self {
        Self { budget }
    }

    /// Run one full agent turn.
    ///
    /// Emits [`TurnEvent`]s to the caller via `on_event`.
    /// The turn ends when the model stops calling tools, the budget is
    /// exhausted, a loop is detected, or cancellation fires.
    #[allow(clippy::too_many_arguments)]
    pub async fn run_turn(
        &self,
        driver: &dyn ModelDriver,
        request: ModelRequest,
        execute_tool: ToolExecutor,
        turn_id: TurnId,
        conversation_id: &str,
        on_event: &mut dyn FnMut(TurnEvent),
    ) {
        let mut seq: u64 = 0;
        let mut guard = LoopGuard::new(
            self.budget.loop_warn_threshold,
            self.budget.loop_hard_stop_threshold,
        );

        macro_rules! emit {
            ($data:expr) => {{
                seq += 1;
                let event = AgentEvent::new(turn_id, conversation_id, seq, $data);
                on_event(TurnEvent::Emit(event));
            }};
        }

        // --- Turn started ---
        emit!(EventData::StatusChanged {
            status: "thinking".to_string(),
        });

        // --- Main loop ---
        let mut history = request.history.clone();
        let mut current_msg = request.message.clone();
        let tool_schemas = request.tool_schemas.clone();
        let mut total_tool_calls: u32 = 0;
        let mut prompt_tokens: Option<u64> = None;
        let mut completion_tokens: Option<u64> = None;

        for step in 0..self.budget.max_model_steps {
            if let Err(msg) = self.budget.check_step(step) {
                emit!(EventData::TurnFailed {
                    error: crate::agents::runtime::event::ErrorBody {
                        code: crate::agents::runtime::event::RuntimeErrorCode::BudgetExhausted,
                        message: msg,
                    },
                });
                return;
            }

            if let Err(msg) = self.budget.check_tool_calls(total_tool_calls) {
                emit!(EventData::TurnFailed {
                    error: crate::agents::runtime::event::ErrorBody {
                        code: crate::agents::runtime::event::RuntimeErrorCode::BudgetExhausted,
                        message: msg,
                    },
                });
                return;
            }

            // Call the model via the driver.
            let req = ModelRequest {
                message: current_msg.clone(),
                history: history.clone(),
                tool_schemas: tool_schemas.clone(),
            };

            let mut stream: ModelEventStream = match driver.stream_step(req).await {
                Ok(s) => s,
                Err(e) => {
                    emit!(EventData::TurnFailed {
                        error: crate::agents::runtime::event::ErrorBody {
                            code: crate::agents::runtime::event::RuntimeErrorCode::ProviderError,
                            message: format!("provider error: {e}"),
                        },
                    });
                    return;
                }
            };

            let mut collected_calls: Vec<ToolCallData> = vec![];
            let mut had_text = false;

            while let Some(event) = stream.next().await {
                match event {
                    Ok(ModelEvent::TextDelta(text)) => {
                        if !had_text {
                            had_text = true;
                            emit!(EventData::StatusChanged {
                                status: "answering".to_string(),
                            });
                        }
                        emit!(EventData::TextDelta { text });
                    }
                    Ok(ModelEvent::ToolCall(call)) => {
                        collected_calls.push(call);
                    }
                    Ok(ModelEvent::Usage(usage)) => {
                        prompt_tokens = Some(prompt_tokens.unwrap_or(0) + usage.prompt_tokens);
                        completion_tokens =
                            Some(completion_tokens.unwrap_or(0) + usage.completion_tokens);
                    }
                    Ok(ModelEvent::Stop(ModelStopReason::EndTurn)) => {}
                    Ok(ModelEvent::Stop(ModelStopReason::ToolUse)) => {}
                    Ok(ModelEvent::Stop(other)) => {
                        tracing::debug!("model stop reason: {:?}", other);
                    }
                    Err(e) => {
                        emit!(EventData::TurnFailed {
                            error: crate::agents::runtime::event::ErrorBody {
                                code:
                                    crate::agents::runtime::event::RuntimeErrorCode::ProviderError,
                                message: e.to_string(),
                            },
                        });
                        return;
                    }
                }
            }

            // If no tool calls were made, the model produced its final answer.
            if collected_calls.is_empty() {
                emit!(EventData::TurnCompleted {
                    usage: UsageSummary {
                        model_steps: step + 1,
                        tool_calls: total_tool_calls,
                        prompt_tokens,
                        completion_tokens,
                    },
                });
                return;
            }

            // Execute tool calls sequentially (v1; parallel read-only later).
            for call in &collected_calls {
                total_tool_calls += 1;
                if let Err(msg) = self.budget.check_tool_calls(total_tool_calls) {
                    emit!(EventData::TurnFailed {
                        error: crate::agents::runtime::event::ErrorBody {
                            code: crate::agents::runtime::event::RuntimeErrorCode::BudgetExhausted,
                            message: msg,
                        },
                    });
                    return;
                }

                emit!(EventData::ToolStarted {
                    call: ToolCallInfo {
                        name: call.name.clone(),
                        status: "started".to_string(),
                        duration_ms: None,
                    },
                });

                // Loop guard.
                let start = std::time::Instant::now();
                if let Err(loop_err) = guard.check(&call.name, &call.arguments, "") {
                    emit!(EventData::TurnFailed {
                        error: crate::agents::runtime::event::ErrorBody {
                            code: crate::agents::runtime::event::RuntimeErrorCode::LoopDetected,
                            message: loop_err,
                        },
                    });
                    return;
                }

                // Execute the tool.
                let tool_result = match execute_tool(&call.name, &call.arguments.to_string()).await
                {
                    Ok(result) => result,
                    Err(e) => {
                        emit!(EventData::ToolFinished {
                            call: ToolCallInfo {
                                name: call.name.clone(),
                                status: "failed".to_string(),
                                duration_ms: Some(start.elapsed().as_millis() as u64),
                            },
                        });
                        emit!(EventData::TurnFailed {
                            error: crate::agents::runtime::event::ErrorBody {
                                code: RuntimeErrorCode::ToolFailed,
                                message: e.to_string(),
                            },
                        });
                        return;
                    }
                };

                emit!(EventData::ToolFinished {
                    call: ToolCallInfo {
                        name: call.name.clone(),
                        status: "finished".to_string(),
                        duration_ms: Some(start.elapsed().as_millis() as u64),
                    },
                });

                // Parse UI actions from the tool result (legacy bridge).
                // Phase 4 replaces this with ToolResultEnvelope.
                for action in extract_ui_actions(&call.name, &tool_result) {
                    emit!(EventData::UiAction {
                        action: to_event_action(&action)
                    });
                }

                on_event(TurnEvent::ToolResult {
                    call_id: call.call_id.clone(),
                    result_text: tool_result,
                });
            }

            // Feed the last tool call back as the next user message.
            if let Some(last_call) = collected_calls.last() {
                current_msg = Message::user(format!(
                    "Tool {} returned: {}",
                    last_call.name, "see tool result above"
                ));
                history.push(current_msg.clone());
            }
        }

        // Budget exhausted after all steps.
        emit!(EventData::TurnFailed {
            error: crate::agents::runtime::event::ErrorBody {
                code: crate::agents::runtime::event::RuntimeErrorCode::BudgetExhausted,
                message: "max model steps reached".to_string(),
            },
        });
    }
}

/// Legacy bridge: extract UI actions from tool result strings.
/// Phase 4 replaces this with structured ToolResultEnvelope.
fn extract_ui_actions(tool_name: &str, result: &str) -> Vec<UiAction> {
    let mut actions = vec![];
    match tool_name {
        "search_inventory" | "find_related_posts" | "get_user_posts" => {
            if let Ok(ids) = crate::llm::extract_listing_ids(result) {
                if !ids.is_empty() {
                    actions.push(UiAction::show_posts(ids));
                }
            }
        }
        "get_listing_details" => {
            // Can't easily re-parse args here without passing them; skip for now.
        }
        "draft_comment" => {
            let parts: Vec<&str> = result.splitn(3, '|').collect();
            if parts.len() == 3 && parts[0] == "DRAFT_COMMENT" {
                actions.push(UiAction::open_comment_draft(parts[1], parts[2]));
            }
        }
        "draft_message" => {
            let parts: Vec<&str> = result.splitn(4, '|').collect();
            if parts.len() == 4 && parts[0] == "DRAFT_MESSAGE" {
                actions.push(UiAction::open_message_draft(parts[2], parts[1], parts[3]));
            }
        }
        _ => {}
    }
    actions
}
