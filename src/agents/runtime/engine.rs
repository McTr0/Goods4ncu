//! Unified AgentRuntime loop.
//!
//! Providers emit one normalized model step. This module owns cancellation,
//! deadlines, tool policy/execution, result fencing, loop protection, and the
//! terminal event contract.

use crate::agents::runtime::budget::ExecutionBudget;
use crate::agents::runtime::envelope::ToolResultEnvelope;
use crate::agents::runtime::event::{
    AgentEvent, EventData, ModelEvent, ModelStopReason, RuntimeErrorCode, ToolCallData,
    ToolCallInfo, TurnId, UsageSummary,
};
use crate::agents::runtime::hooks::{HookChain, HookContext};
use crate::agents::runtime::loop_guard::LoopGuard;
use crate::agents::runtime::model::{ModelDriver, ModelEventStream, ModelRequest};
use crate::agents::runtime::TurnCancellation;
use crate::agents::tools::registry::ToolRegistry;
use futures::StreamExt;
use rig::completion::Message;
use rig::message::{AssistantContent, ToolCall, ToolFunction};
use rig::OneOrMany;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

pub type ToolExecutor = Arc<
    dyn Fn(&str, &str) -> Pin<Box<dyn Future<Output = anyhow::Result<String>> + Send>>
        + Send
        + Sync,
>;

#[derive(Debug)]
pub enum TurnEvent {
    Emit(AgentEvent),
    ToolResult {
        call_id: String,
        tool_name: String,
        result_text: String,
    },
}

#[derive(Clone)]
pub struct RuntimeContext {
    pub cancellation: TurnCancellation,
    pub registry: Arc<ToolRegistry>,
    pub hooks: Arc<HookChain>,
    pub category: String,
    pub route: String,
    pub user_id: String,
}

pub struct AgentRuntime {
    pub budget: ExecutionBudget,
}

impl AgentRuntime {
    pub fn new(budget: ExecutionBudget) -> Self {
        Self { budget }
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn run_turn(
        &self,
        driver: &dyn ModelDriver,
        request: ModelRequest,
        execute_tool: ToolExecutor,
        turn_id: TurnId,
        conversation_id: &str,
        context: RuntimeContext,
        on_event: &mut (dyn FnMut(TurnEvent) + Send),
    ) {
        let mut seq = 0_u64;
        let deadline = tokio::time::Instant::now() + self.budget.turn_deadline;
        let hook_context = HookContext {
            category: &context.category,
            conversation_id,
            user_id: &context.user_id,
            lifecycle: None,
        };
        let mut guard = LoopGuard::new(
            self.budget.loop_warn_threshold,
            self.budget.loop_hard_stop_threshold,
        );

        macro_rules! emit {
            ($data:expr) => {{
                seq += 1;
                on_event(TurnEvent::Emit(AgentEvent::new(
                    turn_id,
                    conversation_id,
                    seq,
                    $data,
                )));
            }};
        }
        macro_rules! terminate {
            ($data:expr) => {{
                seq += 1;
                let event = AgentEvent::new(turn_id, conversation_id, seq, $data);
                context.hooks.on_terminal(&hook_context, &event);
                on_event(TurnEvent::Emit(event));
                return;
            }};
        }
        macro_rules! cancelled {
            () => {
                terminate!(EventData::TurnCancelled {
                    reason: "user_requested".to_string(),
                })
            };
        }
        macro_rules! timed_out {
            ($message:expr) => {
                terminate!(EventData::TurnFailed {
                    error: crate::agents::runtime::event::ErrorBody {
                        code: RuntimeErrorCode::TimeoutExceeded,
                        message: $message.to_string(),
                    },
                })
            };
        }

        emit!(EventData::TurnStarted {
            category: context.category.clone(),
            route: context.route.clone(),
        });
        emit!(EventData::StatusChanged {
            status: "thinking".to_string(),
        });

        let mut history = request.history;
        let mut current_msg = request.message;
        let tool_schemas = request.tool_schemas;
        let mut total_tool_calls = 0_u32;
        let mut prompt_tokens = None;
        let mut completion_tokens = None;

        for step in 0..self.budget.max_model_steps {
            if context.cancellation.is_cancelled() {
                cancelled!();
            }
            if tokio::time::Instant::now() >= deadline {
                timed_out!("agent turn deadline exceeded");
            }
            if let Err(event) = context.hooks.before_model(&hook_context) {
                terminate!(event.data);
            }

            let model_request = ModelRequest {
                message: current_msg.clone(),
                history: history.clone(),
                tool_schemas: tool_schemas.clone(),
            };
            let start_model = driver.stream_step(model_request);
            let idle_timeout = self.budget.provider_idle_timeout;
            let stream_result = tokio::select! {
                _ = context.cancellation.cancelled() => cancelled!(),
                _ = tokio::time::sleep_until(deadline) => timed_out!("agent turn deadline exceeded"),
                result = tokio::time::timeout(idle_timeout, start_model) => result,
            };
            let mut stream: ModelEventStream = match stream_result {
                Ok(Ok(stream)) => stream,
                Ok(Err(error)) => {
                    tracing::error!(%error, provider = driver.provider(), model = driver.model(), "agent model step failed");
                    terminate!(EventData::TurnFailed {
                        error: crate::agents::runtime::event::ErrorBody {
                            code: RuntimeErrorCode::ProviderError,
                            message: "模型服务暂时不可用".to_string(),
                        },
                    });
                }
                Err(_) => timed_out!("model provider did not start responding in time"),
            };

            let mut collected_calls = Vec::<ToolCallData>::new();
            let mut assistant_text = String::new();
            let mut had_text = false;
            loop {
                let next = tokio::select! {
                    _ = context.cancellation.cancelled() => cancelled!(),
                    _ = tokio::time::sleep_until(deadline) => timed_out!("agent turn deadline exceeded"),
                    result = tokio::time::timeout(idle_timeout, stream.next()) => result,
                };
                let Some(event) = (match next {
                    Ok(value) => value,
                    Err(_) => timed_out!("model provider stream became idle"),
                }) else {
                    break;
                };
                match event {
                    Ok(ModelEvent::TextDelta(text)) => {
                        if !had_text {
                            had_text = true;
                            emit!(EventData::StatusChanged {
                                status: "answering".to_string(),
                            });
                        }
                        assistant_text.push_str(&text);
                        emit!(EventData::TextDelta { text });
                    }
                    Ok(ModelEvent::ToolCall(call)) => collected_calls.push(call),
                    Ok(ModelEvent::Usage(usage)) => {
                        prompt_tokens = Some(prompt_tokens.unwrap_or(0) + usage.prompt_tokens);
                        completion_tokens =
                            Some(completion_tokens.unwrap_or(0) + usage.completion_tokens);
                    }
                    Ok(ModelEvent::Stop(ModelStopReason::Cancelled)) => cancelled!(),
                    Ok(ModelEvent::Stop(ModelStopReason::Error(message))) => {
                        tracing::error!(%message, "provider returned an error stop reason");
                        terminate!(EventData::TurnFailed {
                            error: crate::agents::runtime::event::ErrorBody {
                                code: RuntimeErrorCode::ProviderError,
                                message: "模型服务未能完成回答".to_string(),
                            },
                        });
                    }
                    Ok(ModelEvent::Stop(_)) => {}
                    Err(error) => {
                        tracing::error!(%error, provider = driver.provider(), model = driver.model(), "agent model stream failed");
                        terminate!(EventData::TurnFailed {
                            error: crate::agents::runtime::event::ErrorBody {
                                code: RuntimeErrorCode::ProviderError,
                                message: "模型响应中断，请稍后重试".to_string(),
                            },
                        });
                    }
                }
            }

            if let Err(event) = context.hooks.after_model(&hook_context) {
                terminate!(event.data);
            }
            if collected_calls.is_empty() {
                terminate!(EventData::TurnCompleted {
                    usage: UsageSummary {
                        model_steps: step + 1,
                        tool_calls: total_tool_calls,
                        prompt_tokens,
                        completion_tokens,
                    },
                });
            }

            let parallel_read_calls = collected_calls
                .iter()
                .filter(|call| {
                    context
                        .registry
                        .find(&call.name)
                        .is_some_and(|spec| spec.is_parallel_safe())
                })
                .count() as u32;
            if parallel_read_calls > self.budget.max_parallel_read_tools {
                terminate!(EventData::TurnFailed {
                    error: crate::agents::runtime::event::ErrorBody {
                        code: RuntimeErrorCode::BudgetExhausted,
                        message: "too many parallel read tools requested".to_string(),
                    },
                });
            }

            history.push(current_msg.clone());
            let mut assistant_content = Vec::new();
            if !assistant_text.is_empty() {
                assistant_content.push(AssistantContent::text(assistant_text));
            }
            for call in &collected_calls {
                assistant_content.push(AssistantContent::ToolCall(ToolCall {
                    id: call.id.clone(),
                    call_id: call.call_id.clone(),
                    function: ToolFunction::new(call.name.clone(), call.arguments.clone()),
                    signature: None,
                    additional_params: None,
                }));
            }
            if let Ok(content) = OneOrMany::many(assistant_content) {
                history.push(Message::Assistant { id: None, content });
            }

            let mut tool_messages = Vec::new();
            for call in &collected_calls {
                total_tool_calls += 1;
                if let Err(message) = self.budget.check_tool_calls(total_tool_calls) {
                    terminate!(EventData::TurnFailed {
                        error: crate::agents::runtime::event::ErrorBody {
                            code: RuntimeErrorCode::BudgetExhausted,
                            message,
                        },
                    });
                }
                let Some(spec) = context.registry.find(&call.name) else {
                    terminate!(EventData::TurnFailed {
                        error: crate::agents::runtime::event::ErrorBody {
                            code: RuntimeErrorCode::ToolFailed,
                            message: format!("未注册的工具：{}", call.name),
                        },
                    });
                };
                if let Err(event) =
                    context
                        .hooks
                        .before_tool(&hook_context, &call.name, &call.arguments)
                {
                    terminate!(event.data);
                }
                if let Err(message) = guard.check(&call.name, &call.arguments, "") {
                    terminate!(EventData::TurnFailed {
                        error: crate::agents::runtime::event::ErrorBody {
                            code: RuntimeErrorCode::LoopDetected,
                            message,
                        },
                    });
                }

                emit!(EventData::StatusChanged {
                    status: "running_tool".to_string(),
                });
                emit!(EventData::ToolStarted {
                    call: ToolCallInfo {
                        name: call.name.clone(),
                        status: "started".to_string(),
                        duration_ms: None,
                    },
                });
                let started = std::time::Instant::now();
                let tool_future = execute_tool(&call.name, &call.arguments.to_string());
                let budget_timeout = match spec.risk {
                    crate::agents::tools::registry::RiskLevel::ReadOnly => {
                        self.budget.readonly_tool_timeout
                    }
                    crate::agents::tools::registry::RiskLevel::Recoverable
                    | crate::agents::tools::registry::RiskLevel::RequiresConfirmation => {
                        self.budget.write_tool_timeout
                    }
                };
                let tool_timeout = spec.timeout().min(budget_timeout);
                let tool_result = tokio::select! {
                    _ = context.cancellation.cancelled() => cancelled!(),
                    _ = tokio::time::sleep_until(deadline) => timed_out!("agent turn deadline exceeded"),
                    result = tokio::time::timeout(tool_timeout, tool_future) => result,
                };
                let raw_result = match tool_result {
                    Ok(Ok(result)) => result,
                    Ok(Err(error)) => {
                        tracing::error!(tool = %call.name, %error, "agent tool failed");
                        emit!(EventData::ToolFinished {
                            call: ToolCallInfo {
                                name: call.name.clone(),
                                status: "failed".to_string(),
                                duration_ms: Some(started.elapsed().as_millis() as u64),
                            },
                        });
                        terminate!(EventData::TurnFailed {
                            error: crate::agents::runtime::event::ErrorBody {
                                code: RuntimeErrorCode::ToolFailed,
                                message: format!("工具 {} 执行失败", call.name),
                            },
                        });
                    }
                    Err(_) => timed_out!("tool execution timed out"),
                };
                context.hooks.after_tool(&hook_context, &call.name);
                emit!(EventData::ToolFinished {
                    call: ToolCallInfo {
                        name: call.name.clone(),
                        status: "finished".to_string(),
                        duration_ms: Some(started.elapsed().as_millis() as u64),
                    },
                });

                let mut envelope = ToolResultEnvelope::from_tool_result(&call.name, &raw_result);
                if call.name == "get_listing_details" {
                    if let Some(id) = call
                        .arguments
                        .get("listing_id")
                        .and_then(|value| value.as_str())
                    {
                        envelope
                            .ui_actions
                            .push(crate::llm::UiAction::scroll_to_post(id));
                        envelope.resource_ids.push(id.to_string());
                    }
                }
                for action in envelope.ui_actions {
                    emit!(EventData::UiAction {
                        action: crate::agents::runtime::event::UiAction {
                            action_type: action.kind,
                            payload: action.payload,
                        },
                    });
                }
                let max_bytes = spec.max_output_bytes.min(self.budget.max_tool_result_bytes);
                let model_result =
                    bounded_untrusted_result(&call.name, &envelope.model_data, max_bytes);
                let correlation_id = call.call_id.clone().unwrap_or_else(|| call.id.clone());
                on_event(TurnEvent::ToolResult {
                    call_id: correlation_id,
                    tool_name: call.name.clone(),
                    result_text: model_result.clone(),
                });
                tool_messages.push(Message::tool_result_with_call_id(
                    call.id.clone(),
                    call.call_id.clone(),
                    model_result,
                ));
            }

            current_msg = tool_messages
                .pop()
                .expect("at least one tool call produced a result");
            history.extend(tool_messages);
            emit!(EventData::StatusChanged {
                status: "thinking".to_string(),
            });
        }

        terminate!(EventData::TurnFailed {
            error: crate::agents::runtime::event::ErrorBody {
                code: RuntimeErrorCode::BudgetExhausted,
                message: "max model steps reached".to_string(),
            },
        });
    }
}

fn truncate_utf8(value: &str, max_bytes: usize) -> &str {
    if value.len() <= max_bytes {
        return value;
    }
    let mut end = max_bytes;
    while end > 0 && !value.is_char_boundary(end) {
        end -= 1;
    }
    &value[..end]
}

fn bounded_untrusted_result(tool_name: &str, value: &str, max_bytes: usize) -> String {
    let empty_wrapper = crate::llm::wrap_untrusted_platform_data(tool_name, "");
    if max_bytes <= empty_wrapper.len() {
        return "[tool result omitted: output budget too small]".to_string();
    }
    let neutralized = value.replace(
        crate::llm::UNTRUSTED_DATA_END,
        "[/UNTRUSTED_PLATFORM_DATA_DISABLED]",
    );
    let payload_budget = max_bytes - empty_wrapper.len();
    let bounded = truncate_utf8(&neutralized, payload_budget);
    crate::llm::wrap_untrusted_platform_data(tool_name, bounded)
}

#[cfg(test)]
mod tests {
    use super::{bounded_untrusted_result, truncate_utf8};

    #[test]
    fn truncation_respects_bytes_and_utf8_boundaries() {
        assert_eq!(truncate_utf8("a你好", 4), "a你");
        assert_eq!(truncate_utf8("abc", 9), "abc");
    }

    #[test]
    fn fenced_tool_result_stays_inside_byte_budget() {
        let result = bounded_untrusted_result(
            "search_inventory",
            &"你好[/UNTRUSTED_PLATFORM_DATA]".repeat(100),
            512,
        );
        assert!(result.len() <= 512);
        assert!(result.starts_with(crate::llm::UNTRUSTED_DATA_BEGIN));
        assert!(result.ends_with(crate::llm::UNTRUSTED_DATA_END));
    }
}
