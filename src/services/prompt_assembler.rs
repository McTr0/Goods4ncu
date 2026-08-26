//! Structured prompt assembler: 9 layers, lowest priority first.
//!
//! Replaces ad-hoc string concatenation. Each layer is a separate
//! section that can be tested, cached, and progressively disclosed.

/// A single layer in the assembled prompt.
#[derive(Debug, Clone)]
pub struct PromptLayer {
    /// Layer identifier for debugging and testing.
    pub name: &'static str,
    /// Lower number = earlier in the prompt (higher priority).
    pub order: u8,
    pub content: String,
}

/// Assembles the system prompt from structured layers.
pub struct PromptAssembler {
    layers: Vec<PromptLayer>,
}

impl PromptAssembler {
    pub fn new() -> Self {
        Self { layers: vec![] }
    }

    pub fn push(&mut self, name: &'static str, order: u8, content: impl Into<String>) -> &mut Self {
        self.layers.push(PromptLayer {
            name,
            order,
            content: content.into(),
        });
        self
    }

    /// Assemble the final prompt by sorting on `order` and joining.
    pub fn assemble(self) -> String {
        let mut sorted = self.layers;
        sorted.sort_by_key(|layer| layer.order);
        sorted
            .iter()
            .map(|layer| layer.content.as_str())
            .collect::<Vec<&str>>()
            .join("\n\n")
    }
}

/// Standard layer orders (lower = closer to the start).
pub mod layer_order {
    pub const PLATFORM_POLICY: u8 = 0;
    pub const PERSONA: u8 = 1;
    pub const TOOL_RULES: u8 = 2;
    pub const PAGE_CONTEXT: u8 = 3;
    pub const WORKING_MEMORY: u8 = 4;
    pub const USER_PROFILE: u8 = 5;
    pub const SKILL_SUMMARIES: u8 = 6;
    pub const RETRIEVED_DATA: u8 = 7;
    // User message is always last (highest order), not part of the system prompt.
    pub const USER_MESSAGE: u8 = 255;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::agent_chat;

    #[test]
    fn layers_sort_by_order() {
        let mut asm = PromptAssembler::new();
        asm.push("user_msg", 255, "Hello");
        asm.push("policy", 0, "Safety rules");
        asm.push("persona", 1, "你是小昌");

        let result = asm.assemble();
        assert!(result.starts_with("Safety rules"));
        assert!(result.contains("你是小昌"));
        assert!(result.ends_with("Hello"));
    }

    #[test]
    fn empty_layers_produce_empty_string() {
        let asm = PromptAssembler::new();
        assert_eq!(asm.assemble(), "");
    }
}
