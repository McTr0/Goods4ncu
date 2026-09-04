//! Structured tool result replacing legacy pipe-delimited strings.
//!
//! Every tool returns a `ToolResultEnvelope` with separate channels:
//! - `model_data`: text summary the model sees (safe, no raw IDs)
//! - `ui_actions`: typed client-side actions (never sent back to model)
//! - `resource_ids`: referenced entity IDs for audit

use crate::llm::UiAction;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| self.model_data.clone())
    }

    /// Parse from JSON envelope string if valid; otherwise gracefully wrap raw text.
    pub fn parse(raw: &str) -> Self {
        serde_json::from_str::<Self>(raw).unwrap_or_else(|_| Self::success(raw))
    }

    pub fn with_action(mut self, action: UiAction) -> Self {
        self.ui_actions.push(action);
        self
    }

    pub fn with_resource(mut self, id: impl Into<String>) -> Self {
        self.resource_ids.push(id.into());
        self
    }

    pub fn with_resources(mut self, ids: impl IntoIterator<Item = impl Into<String>>) -> Self {
        self.resource_ids.extend(ids.into_iter().map(Into::into));
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn envelope_builders_and_serialization() {
        let envelope = ToolResultEnvelope::success("Found items")
            .with_action(UiAction::show_posts(vec!["p-1".to_string()]))
            .with_resources(vec!["p-1", "p-2"]);

        assert_eq!(envelope.model_data, "Found items");
        assert_eq!(envelope.ui_actions.len(), 1);
        assert_eq!(envelope.ui_actions[0].kind, "SHOW_POSTS");
        assert_eq!(
            envelope.resource_ids,
            vec!["p-1".to_string(), "p-2".to_string()]
        );

        let json = envelope.to_json();
        let decoded: ToolResultEnvelope = serde_json::from_str(&json).expect("decode");
        assert_eq!(decoded, envelope);

        // Test resilient parsing
        assert_eq!(ToolResultEnvelope::parse(&json), envelope);
        assert_eq!(
            ToolResultEnvelope::parse("plain raw string"),
            ToolResultEnvelope::success("plain raw string")
        );
    }
}
