//! Stable error codes for the runtime. Raw provider errors, stack traces,
//! prompts, and tool arguments never cross this boundary.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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

impl RuntimeErrorCode {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::ProviderError => "provider_error",
            Self::BudgetExhausted => "budget_exhausted",
            Self::LoopDetected => "loop_detected",
            Self::ToolFailed => "tool_failed",
            Self::Cancelled => "cancelled",
            Self::StreamInterrupted => "stream_interrupted",
            Self::TimeoutExceeded => "timeout_exceeded",
            Self::InternalError => "internal_error",
        }
    }
}
