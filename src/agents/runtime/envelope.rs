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
    /// Convert a tool result into the structured channels used by Runtime v2.
    pub fn from_tool_result(tool_name: &str, result: &str) -> Self {
        match tool_name {
            "draft_message" => Self::parse_draft_message(result),
            "draft_comment" => Self::parse_draft_comment(result),
            "search_inventory" | "find_related_posts" | "get_user_posts" => {
                Self::parse_listing_ids(result)
            }
            _ => None,
        }
        .unwrap_or_else(|| Self::success(result))
    }

    fn parse_draft_message(result: &str) -> Option<Self> {
        let v: serde_json::Value = serde_json::from_str(result).ok()?;
        if v.get("action").and_then(|a| a.as_str()) != Some("open_message_draft") {
            return None;
        }
        let listing_id = v.get("listing_id").and_then(|s| s.as_str())?;
        let receiver_id = v.get("receiver_id").and_then(|s| s.as_str())?;
        let draft_text = v.get("draft_text").and_then(|s| s.as_str())?;

        Some(
            Self::success("已为你生成一条私信草稿，请确认后发送。")
                .with_action(crate::llm::UiAction::open_message_draft(
                    receiver_id,
                    listing_id,
                    draft_text,
                ))
                .with_resource(listing_id),
        )
    }

    fn parse_draft_comment(result: &str) -> Option<Self> {
        let v: serde_json::Value = serde_json::from_str(result).ok()?;
        if v.get("action").and_then(|a| a.as_str()) != Some("open_comment_draft") {
            return None;
        }
        let post_id = v.get("post_id").and_then(|s| s.as_str())?;
        let draft_text = v.get("draft_text").and_then(|s| s.as_str())?;

        Some(
            Self::success("已为你生成一条回复草稿，请确认后发布。")
                .with_action(crate::llm::UiAction::open_comment_draft(
                    post_id, draft_text,
                ))
                .with_resource(post_id),
        )
    }

    fn parse_listing_ids(result: &str) -> Option<Self> {
        let ids = crate::llm::extract_listing_ids(result).ok()?;
        if ids.is_empty() {
            return None;
        }
        let mut envelope = Self::success(result);
        envelope = envelope.with_action(crate::llm::UiAction::show_posts(ids.clone()));
        for id in &ids {
            envelope = envelope.with_resource(id.clone());
        }
        Some(envelope)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn listing_results_keep_model_data_and_add_ui_action() {
        let result = "Found 1 item(s):\n- [listing-1] Math Book (Brand: None, Category: books, Condition: 8/10, Price: 20 CNY)\n";
        let envelope = ToolResultEnvelope::from_tool_result("search_inventory", result);

        assert_eq!(envelope.model_data, result);
        assert_eq!(envelope.resource_ids, vec!["listing-1".to_string()]);
        assert_eq!(envelope.ui_actions.len(), 1);
        assert_eq!(envelope.ui_actions[0].kind, "SHOW_POSTS");
    }

    #[test]
    fn draft_comment_json_parses_to_ui_action() {
        let json = serde_json::json!({
            "action": "open_comment_draft",
            "post_id": "post-123",
            "draft_text": "hello"
        })
        .to_string();
        let envelope = ToolResultEnvelope::from_tool_result("draft_comment", &json);
        assert_eq!(envelope.ui_actions.len(), 1);
        assert_eq!(envelope.ui_actions[0].kind, "OPEN_COMMENT_DRAFT");
        assert_eq!(envelope.resource_ids, vec!["post-123".to_string()]);
    }
}
