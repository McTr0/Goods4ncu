//! Versioned agent event protocol.
//!
//! Every SSE frame the runtime produces is a serialized `AgentEvent`.
//! Each carries a monotonic sequence number within its turn, so the
//! client can detect gaps, reorder, or discard duplicates. Exactly one
//! terminal event (`turn_completed`, `turn_failed`, or `turn_cancelled`)
//! closes every turn.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub const PROTOCOL_VERSION: &str = "2.0";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct TurnId(pub Uuid);

impl TurnId {
    pub fn generate() -> Self {
        Self(Uuid::new_v4())
    }
}

impl std::fmt::Display for TurnId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

// ---------------------------------------------------------------------------
// Model-level events (what a provider emits, normalized)
// ---------------------------------------------------------------------------

/// Normalized events that any LLM provider produces after translation by
/// its `ModelDriver` adapter. The runtime loop consumes these; it never
/// sees provider-specific formats.
#[derive(Debug, Clone)]
pub enum ModelEvent {
    TextDelta(String),
    ToolCall(ToolCallData),
    Usage(AgentTokenUsage),
    Stop(ModelStopReason),
}

#[derive(Debug, Clone)]
pub struct ToolCallData {
    pub call_id: String,
    pub name: String,
    pub arguments: serde_json::Value,
}

#[derive(Debug, Clone)]
pub struct AgentTokenUsage {
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
}

#[derive(Debug, Clone)]
pub enum ModelStopReason {
    EndTurn,
    ToolUse,
    MaxTokens,
    Cancelled,
    Error(String),
}

// ---------------------------------------------------------------------------
// Client-facing protocol events (SSE frames)
// ---------------------------------------------------------------------------

/// A single tool execution reported to the client.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolCallInfo {
    pub name: String,
    pub status: String, // "started" | "finished" | "failed"
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
}

/// A UI action the client should perform (show posts, draft message, …).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UiAction {
    pub action_type: String,
    pub payload: serde_json::Value,
}

/// Token usage summary sent at turn end.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageSummary {
    pub model_steps: u32,
    pub tool_calls: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prompt_tokens: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completion_tokens: Option<u64>,
}

/// Stable error codes — never raw provider errors or stack traces.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErrorBody {
    pub code: RuntimeErrorCode,
    pub message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeErrorCode {
    ProviderError,
    BudgetExhausted,
    LoopDetected,
    ToolFailed,
    Cancelled,
    StreamInterrupted,
    TimeoutExceeded,
    InternalError,
}

/// The tagged event enum. Every variant serializes to a JSON object with
/// `"type"` set to the snake_case variant name.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum EventData {
    TurnStarted {
        category: String,
        route: String,
    },
    StatusChanged {
        status: String, // thinking | running_tool | answering
    },
    TextDelta {
        text: String,
    },
    ToolStarted {
        call: ToolCallInfo,
    },
    ToolFinished {
        call: ToolCallInfo,
    },
    UiAction {
        action: UiAction,
    },
    Usage {
        usage: UsageSummary,
    },
    Heartbeat,
    TurnCompleted {
        usage: UsageSummary,
    },
    TurnFailed {
        error: ErrorBody,
    },
    TurnCancelled {
        reason: String,
    },
}

/// Envelope wrapping event data with routing and ordering metadata.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentEvent {
    pub protocol_version: String,
    pub turn_id: TurnId,
    pub conversation_id: String,
    pub seq: u64,
    #[serde(flatten)]
    pub data: EventData,
}

impl AgentEvent {
    pub fn new(turn_id: TurnId, conversation_id: &str, seq: u64, data: EventData) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION.to_string(),
            turn_id,
            conversation_id: conversation_id.to_string(),
            seq,
            data,
        }
    }

    /// Whether this event terminates the turn (exactly one per turn).
    pub fn is_terminal(&self) -> bool {
        matches!(
            self.data,
            EventData::TurnCompleted { .. }
                | EventData::TurnFailed { .. }
                | EventData::TurnCancelled { .. }
        )
    }

    /// Serialize to an SSE-compatible JSON string.
    pub fn to_sse(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| "{}".to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn turn_started_serializes_with_type_tag() {
        let event = AgentEvent::new(
            TurnId(Uuid::nil()),
            "conv-1",
            0,
            EventData::TurnStarted {
                category: "offer".to_string(),
                route: "listing".to_string(),
            },
        );
        let parsed: Value = serde_json::from_str(&event.to_sse()).unwrap();
        assert_eq!(parsed["type"], "turn_started");
        assert_eq!(parsed["protocol_version"], "2.0");
        assert_eq!(parsed["seq"], 0);
        assert_eq!(parsed["category"], "offer");
    }

    #[test]
    fn text_delta_round_trips() {
        let event = AgentEvent::new(
            TurnId::generate(),
            "c",
            1,
            EventData::TextDelta {
                text: "你好".to_string(),
            },
        );
        let parsed: Value = serde_json::from_str(&event.to_sse()).unwrap();
        assert_eq!(parsed["type"], "text_delta");
        assert_eq!(parsed["text"], "你好");
    }

    #[test]
    fn tool_started_carries_name_and_status() {
        let event = AgentEvent::new(
            TurnId::generate(),
            "c",
            3,
            EventData::ToolStarted {
                call: ToolCallInfo {
                    name: "search_posts".to_string(),
                    status: "started".to_string(),
                    duration_ms: None,
                },
            },
        );
        let parsed: Value = serde_json::from_str(&event.to_sse()).unwrap();
        assert_eq!(parsed["type"], "tool_started");
        assert_eq!(parsed["call"]["name"], "search_posts");
    }

    #[test]
    fn turn_completed_is_terminal() {
        let event = AgentEvent::new(
            TurnId::generate(),
            "c",
            99,
            EventData::TurnCompleted {
                usage: UsageSummary {
                    model_steps: 3,
                    tool_calls: 2,
                    prompt_tokens: Some(100),
                    completion_tokens: Some(50),
                },
            },
        );
        assert!(event.is_terminal());
        let parsed: Value = serde_json::from_str(&event.to_sse()).unwrap();
        assert_eq!(parsed["type"], "turn_completed");
        assert_eq!(parsed["usage"]["model_steps"], 3);
    }

    #[test]
    fn turn_failed_carries_stable_error_code() {
        let event = AgentEvent::new(
            TurnId::generate(),
            "c",
            100,
            EventData::TurnFailed {
                error: ErrorBody {
                    code: RuntimeErrorCode::BudgetExhausted,
                    message: "预算耗尽".to_string(),
                },
            },
        );
        assert!(event.is_terminal());
        let parsed: Value = serde_json::from_str(&event.to_sse()).unwrap();
        assert_eq!(parsed["error"]["code"], "budget_exhausted");
    }

    #[test]
    fn heartbeat_has_no_payload() {
        let event = AgentEvent::new(TurnId::generate(), "c", 50, EventData::Heartbeat);
        let parsed: Value = serde_json::from_str(&event.to_sse()).unwrap();
        assert_eq!(parsed["type"], "heartbeat");
        assert!(!event.is_terminal());
    }

    use serde_json::Value;
}
