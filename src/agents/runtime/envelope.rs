//! Structured tool result replacing legacy pipe-delimited strings.
//!
//! Every tool returns a `ToolResultEnvelope` with separate channels:
//! - `model_data`: text summary the model sees (safe, no raw IDs)
//! - `ui_actions`: typed client-side actions (never sent back to model)
//! - `resource_ids`: referenced entity IDs for audit

use crate::llm::UiAction;

#[derive(Debug, Clone)]
pub struct ToolResultEnvelope {
    /// Human/model-readable summary.
    pub model_data: String,
    /// Client-side actions extracted from the result.
    pub ui_actions: Vec<UiAction>,
    /// Referenced resource IDs for observability.
    pub resource_ids: Vec<String>,
}

impl ToolResultEnvelope {
    pub fn success(model_data: impl Into<String>) -> Self {
        Self {
            model_data: model_data.into(),
            ui_actions: vec![],
            resource_ids: vec![],
        }
    }

    pub fn with_action(mut self, action: UiAction) -> Self {
        self.ui_actions.push(action);
        self
    }

    pub fn with_resource(mut self, id: impl Into<String>) -> Self {
        self.resource_ids.push(id.into());
        self
    }
}

/// Parse legacy pipe-delimited strings into envelopes.
/// These are transitional — new tools should return envelopes directly.
pub mod legacy {
    use super::*;

    /// Convert one legacy string result into the structured channels used by
    /// Runtime v2. Unknown tools keep their textual result but never create a
    /// client-side action implicitly.
    pub fn from_tool_result(tool_name: &str, result: &str) -> ToolResultEnvelope {
        match tool_name {
            "draft_message" => draft_message(result),
            "draft_comment" => draft_comment(result),
            "search_inventory" | "find_related_posts" | "get_user_posts" => listing_ids(result),
            _ => None,
        }
        .unwrap_or_else(|| ToolResultEnvelope::success(result))
    }

    /// Parse `DRAFT_MESSAGE|{listing_id}|{receiver_id}|{text}`.
    pub fn draft_message(result: &str) -> Option<ToolResultEnvelope> {
        let parts: Vec<&str> = result.splitn(4, '|').collect();
        if parts.len() != 4 || parts[0] != "DRAFT_MESSAGE" {
            return None;
        }
        Some(
            ToolResultEnvelope::success("已为你生成一条私信草稿，请确认后发送。")
                .with_action(crate::llm::UiAction::open_message_draft(
                    parts[2], parts[1], parts[3],
                ))
                .with_resource(parts[1]),
        )
    }

    /// Parse `DRAFT_COMMENT|{post_id}|{text}`.
    pub fn draft_comment(result: &str) -> Option<ToolResultEnvelope> {
        let parts: Vec<&str> = result.splitn(3, '|').collect();
        if parts.len() != 3 || parts[0] != "DRAFT_COMMENT" {
            return None;
        }
        Some(
            ToolResultEnvelope::success("已为你生成一条回复草稿，请确认后发布。")
                .with_action(crate::llm::UiAction::open_comment_draft(parts[1], parts[2]))
                .with_resource(parts[1]),
        )
    }

    /// Parse listing IDs from search results and create show_posts action.
    pub fn listing_ids(result: &str) -> Option<ToolResultEnvelope> {
        let Ok(ids) = crate::llm::extract_listing_ids(result) else {
            return None;
        };
        if ids.is_empty() {
            return None;
        }
        let mut envelope =
            ToolResultEnvelope::success(format!("搜索到 {} 条相关帖子。", ids.len()));
        envelope = envelope.with_action(crate::llm::UiAction::show_posts(ids.clone()));
        for id in &ids {
            envelope = envelope.with_resource(id.clone());
        }
        Some(envelope)
    }
}
