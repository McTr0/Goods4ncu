//! Compile-time fixed-order hooks for the agent runtime.
//!
//! Hooks observe and optionally veto runtime actions. They can never grant
//! permissions — ActionPlan remains the final authorization boundary.
//!
//! Hook execution order is deterministic (the order they appear in the
//! `HookChain` construction). No user-provided scripts are loaded.

use crate::agents::runtime::event::{AgentEvent, ErrorBody, RuntimeErrorCode};

/// Context passed to every hook invocation.
#[derive(Debug)]
pub struct HookContext<'a> {
    pub category: &'a str,
    pub conversation_id: &'a str,
    pub user_id: &'a str,
    pub lifecycle: Option<&'a str>,
}

/// Result of a hook check: proceed or reject with a reason.
#[derive(Debug, Clone)]
pub enum HookDecision {
    Proceed,
    Reject {
        code: RuntimeErrorCode,
        message: String,
    },
}

impl HookDecision {
    pub fn reject(message: impl Into<String>) -> Self {
        Self::Reject {
            code: RuntimeErrorCode::ToolFailed,
            message: message.into(),
        }
    }
}

/// A single hook in the chain.
pub trait Hook: Send + Sync {
    fn name(&self) -> &'static str;

    /// Called before each model inference step. Return Reject to abort the turn.
    fn before_model(&self, _ctx: &HookContext) -> HookDecision {
        HookDecision::Proceed
    }

    /// Called after model output is received, before tool dispatch.
    fn after_model(&self, _ctx: &HookContext) -> HookDecision {
        HookDecision::Proceed
    }

    /// Called before a tool executes. Return Reject to prevent execution.
    fn before_tool(
        &self,
        _ctx: &HookContext,
        _tool_name: &str,
        _args: &serde_json::Value,
    ) -> HookDecision {
        HookDecision::Proceed
    }

    /// Called after tool execution completes.
    fn after_tool(&self, _ctx: &HookContext, _tool_name: &str) {}

    /// Called once when the turn reaches a terminal state.
    fn on_terminal(&self, _ctx: &HookContext, _event: &AgentEvent) {}
}

// ---------------------------------------------------------------------------
// Built-in hooks
// ---------------------------------------------------------------------------

/// Blocks tools that are not appropriate for the post's category.
pub struct CategoryTagPolicy;

impl Hook for CategoryTagPolicy {
    fn name(&self) -> &'static str {
        "category_tag_policy"
    }

    fn before_tool(
        &self,
        ctx: &HookContext,
        tool_name: &str,
        _args: &serde_json::Value,
    ) -> HookDecision {
        if matches!(ctx.category, "discussion" | "question" | "share")
            && matches!(
                tool_name,
                "purchase_item" | "negotiate_item" | "update_listing"
            )
        {
            return HookDecision::Reject {
                code: RuntimeErrorCode::ToolFailed,
                message: format!("{tool_name} 不适用于{}帖子", ctx.category),
            };
        }
        HookDecision::Proceed
    }
}

/// Records metrics for observability.
pub struct MetricsHook;

impl Hook for MetricsHook {
    fn name(&self) -> &'static str {
        "metrics"
    }
}

// ---------------------------------------------------------------------------
// Chain
// ---------------------------------------------------------------------------

/// Fixed-order hook chain. First rejection short-circuits the rest.
pub struct HookChain {
    hooks: Vec<Box<dyn Hook>>,
}

/// Rejection event produced by the chain.
pub type HookRejection = AgentEvent;

impl HookChain {
    pub fn builder() -> HookChainBuilder {
        HookChainBuilder { hooks: vec![] }
    }

    pub fn before_tool(
        &self,
        ctx: &HookContext,
        tool_name: &str,
        args: &serde_json::Value,
    ) -> Result<(), Box<HookRejection>> {
        for hook in &self.hooks {
            let decision = hook.before_tool(ctx, tool_name, args);
            if let HookDecision::Reject { code, message } = decision {
                return Err(Box::new(self.make_rejection(code, message)));
            }
        }
        Ok(())
    }

    pub fn before_model(&self, ctx: &HookContext) -> Result<(), Box<HookRejection>> {
        for hook in &self.hooks {
            if let HookDecision::Reject { code, message } = hook.before_model(ctx) {
                return Err(Box::new(self.make_rejection(code, message)));
            }
        }
        Ok(())
    }

    pub fn after_model(&self, ctx: &HookContext) -> Result<(), Box<HookRejection>> {
        for hook in &self.hooks {
            if let HookDecision::Reject { code, message } = hook.after_model(ctx) {
                return Err(Box::new(self.make_rejection(code, message)));
            }
        }
        Ok(())
    }

    pub fn after_tool(&self, ctx: &HookContext, tool_name: &str) {
        for hook in &self.hooks {
            hook.after_tool(ctx, tool_name);
        }
    }

    pub fn on_terminal(&self, ctx: &HookContext, event: &AgentEvent) {
        for hook in &self.hooks {
            hook.on_terminal(ctx, event);
        }
    }

    fn make_rejection(&self, code: RuntimeErrorCode, message: String) -> HookRejection {
        crate::agents::runtime::event::AgentEvent {
            protocol_version: "2.0".to_string(),
            turn_id: crate::agents::runtime::event::TurnId(uuid::Uuid::nil()),
            conversation_id: String::new(),
            seq: 0,
            data: crate::agents::runtime::event::EventData::TurnFailed {
                error: ErrorBody { code, message },
            },
        }
    }
}

pub struct HookChainBuilder {
    hooks: Vec<Box<dyn Hook>>,
}

impl HookChainBuilder {
    pub fn push_hook(mut self, hook: Box<dyn Hook>) -> Self {
        self.hooks.push(hook);
        self
    }

    pub fn build(self) -> HookChain {
        HookChain { hooks: self.hooks }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct AlwaysReject;

    impl Hook for AlwaysReject {
        fn name(&self) -> &'static str {
            "always_reject"
        }

        fn before_tool(
            &self,
            _ctx: &HookContext,
            _tool_name: &str,
            _args: &serde_json::Value,
        ) -> HookDecision {
            HookDecision::reject("blocked by test")
        }
    }

    #[test]
    fn rejection_short_circuits_chain() {
        let chain = HookChain::builder()
            .push_hook(Box::new(AlwaysReject))
            .build();

        let ctx = HookContext {
            category: "offer",
            conversation_id: "c1",
            user_id: "u1",
            lifecycle: None,
        };

        assert!(chain
            .before_tool(&ctx, "search", &serde_json::json!({}))
            .is_err());
    }

    #[test]
    fn category_policy_blocks_discussion_commerce() {
        let chain = HookChain::builder()
            .push_hook(Box::new(CategoryTagPolicy))
            .build();

        let disc_ctx = HookContext {
            category: "discussion",
            conversation_id: "c1",
            user_id: "u1",
            lifecycle: None,
        };

        assert!(chain
            .before_tool(&disc_ctx, "purchase_item", &json!({}))
            .is_err());

        let offer_ctx = HookContext {
            category: "offer",
            ..disc_ctx
        };
        assert!(chain.before_tool(&offer_ctx, "search", &json!({})).is_ok());
    }

    use serde_json::json;
}
