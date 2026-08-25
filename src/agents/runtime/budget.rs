//! Execution budgets: hard limits that prevent runaway turns.
//!
//! All values are configurable at startup; the defaults below are safe
//! for a campus marketplace companion.

use std::time::Duration;

#[derive(Debug, Clone)]
pub struct ExecutionBudget {
    /// Maximum model inference steps (one step = one provider call + tool
    /// dispatch round). Prevents infinite agent loops.
    pub max_model_steps: u32,
    /// Maximum total tool invocations across all steps.
    pub max_tool_calls: u32,
    /// Maximum read-only tools dispatched in parallel within a single step.
    pub max_parallel_read_tools: u32,
    /// Wall-clock deadline for the entire turn.
    pub turn_deadline: Duration,
    /// Idle timeout waiting for a provider's first token or next chunk.
    pub provider_idle_timeout: Duration,
    /// Timeout for read-only tool execution.
    pub readonly_tool_timeout: Duration,
    /// Timeout for write / ActionPlan tool execution.
    pub write_tool_timeout: Duration,
    /// Maximum bytes of a single tool result forwarded to the model.
    pub max_tool_result_bytes: usize,
    /// Number of identical consecutive calls before warning.
    pub loop_warn_threshold: u32,
    /// Number of identical consecutive calls before hard stop.
    pub loop_hard_stop_threshold: u32,
}

impl Default for ExecutionBudget {
    fn default() -> Self {
        Self {
            max_model_steps: 6,
            max_tool_calls: 10,
            max_parallel_read_tools: 4,
            turn_deadline: Duration::from_secs(120),
            provider_idle_timeout: Duration::from_secs(45),
            readonly_tool_timeout: Duration::from_secs(10),
            write_tool_timeout: Duration::from_secs(15),
            max_tool_result_bytes: 16 * 1024, // 16 KiB
            loop_warn_threshold: 2,
            loop_hard_stop_threshold: 3,
        }
    }
}

impl ExecutionBudget {
    /// Returns an error message if the given step exceeds the budget.
    pub fn check_step(&self, current_step: u32) -> Result<(), String> {
        if current_step >= self.max_model_steps {
            return Err(format!(
                "model step {current_step} exceeded budget of {}",
                self.max_model_steps
            ));
        }
        Ok(())
    }

    /// Returns an error message if the given tool call count is over budget.
    pub fn check_tool_calls(&self, current_count: u32) -> Result<(), String> {
        if current_count >= self.max_tool_calls {
            return Err(format!(
                "tool call {current_count} exceeded budget of {}",
                self.max_tool_calls
            ));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_budget_enforces_limits() {
        let b = ExecutionBudget::default();
        assert!(b.check_step(0).is_ok());
        assert!(b.check_step(5).is_ok());
        assert!(b.check_step(6).is_err());
        assert!(b.check_tool_calls(9).is_ok());
        assert!(b.check_tool_calls(10).is_err());
    }

    #[test]
    fn loop_thresholds_are_ordered() {
        let b = ExecutionBudget::default();
        assert!(b.loop_warn_threshold < b.loop_hard_stop_threshold);
    }
}
