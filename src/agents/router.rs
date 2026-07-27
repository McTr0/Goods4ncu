//! Lightweight intent router — no extra LLM call required.
//!
//! Classifies user messages into intent categories using heuristic keyword matching.
//! Blocks prohibited content before it reaches the LLM.
//!
//! Intent categories:
//! - `search` — user wants to browse/search inventory
//! - `buy` — user has purchase intent
//! - `negotiate` — user wants to negotiate price
//! - `chat` — casual conversation, no marketplace action needed
//! - `blocked` — message contains prohibited keywords

use serde::{Deserialize, Serialize};
use std::sync::Arc;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_search_keywords() {
        let router = IntentRouter::default();
        assert_eq!(router.classify("帮我搜索一下耳机").intent, Intent::Search);
        assert_eq!(router.classify("有没有二手书").intent, Intent::Search);
        assert_eq!(router.classify("搜索 iPhone").intent, Intent::Search);
    }

    #[test]
    fn test_buy_keywords() {
        let router = IntentRouter::default();
        assert_eq!(router.classify("我要买一个耳机").intent, Intent::Buy);
        assert_eq!(router.classify("这个怎么买").intent, Intent::Buy);
        assert_eq!(router.classify("下单").intent, Intent::Buy);
    }

    #[test]
    fn test_negotiate_keywords() {
        let router = IntentRouter::default();
        assert_eq!(router.classify("能便宜点吗").intent, Intent::Negotiate);
        assert_eq!(router.classify("还价").intent, Intent::Negotiate);
        assert_eq!(
            router.classify("180太贵了，150行吗").intent,
            Intent::Negotiate
        );
    }

    #[test]
    fn test_chat_keywords() {
        let router = IntentRouter::default();
        assert_eq!(router.classify("你好").intent, Intent::Chat);
        assert_eq!(router.classify("你是谁").intent, Intent::Chat);
        assert_eq!(router.classify("今天天气不错").intent, Intent::Chat);
    }

    #[test]
    fn test_blocked_default_keywords() {
        let router = IntentRouter::default();
        assert_eq!(router.classify("我要买一把刀").intent, Intent::Blocked);
        assert_eq!(router.classify("帮我找个毒品").intent, Intent::Blocked);
    }

    #[test]
    fn test_mixed_intent_takes_highest() {
        let router = IntentRouter::default();
        // "买" is higher priority than "搜索"
        assert_eq!(
            router.classify("帮我买个耳机，搜索一下有哪些").intent,
            Intent::Buy
        );
    }
}

/// Intent classification result.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum Intent {
    Search,
    Buy,
    Negotiate,
    Chat,
    Blocked,
}

impl Intent {
    pub fn as_str(&self) -> &'static str {
        match self {
            Intent::Search => "search",
            Intent::Buy => "buy",
            Intent::Negotiate => "negotiate",
            Intent::Chat => "chat",
            Intent::Blocked => "blocked",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct IntentResult {
    pub intent: Intent,
    pub confidence: f32,
}

impl IntentResult {
    pub fn new(intent: Intent, confidence: f32) -> Self {
        Self { intent, confidence }
    }

    pub fn certain(intent: Intent) -> Self {
        Self::new(intent, 1.0)
    }
}

/// Shortcut responses for chat and blocked intents — no LLM needed.
impl IntentResult {
    /// Returns a direct response string for chat intents, or None if LLM should handle it.
    pub fn direct_response(&self, message: &str) -> Option<String> {
        match self.intent {
            Intent::Chat => {
                let msg = message.trim();
                // Both greetings, because plenty of people still type the formal one
                // even where the product answers in the familiar register.
                if msg == "你好" || msg == "您好" {
                    Some("你好！我是续樟校园二手交易平台的智能助手。我可以帮你搜索商品、发起购买或议价。有什么想买的吗？".to_string())
                } else if msg == "你是谁" || msg == "你是谁？" {
                    Some("我是续樟校园二手交易平台的 AI 助手，可以帮你搜索商品、了解详情、发起购买和议价。有什么需要帮忙的吗？".to_string())
                } else if msg == "谢谢" || msg == "谢谢！" {
                    Some("不客气！有需要随时找我~".to_string())
                } else if msg == "再见" || msg == "拜拜" {
                    Some("再见，祝你交易愉快！".to_string())
                } else {
                    // Casual chat — use LLM for these
                    None
                }
            }
            Intent::Blocked => Some("抱歉，你的消息包含了平台不支持的内容，无法处理。".to_string()),
            _ => None,
        }
    }
}

/// Intent router with configurable blocked keyword list.
#[derive(Clone)]
pub struct IntentRouter {
    /// Blocked keywords — messages containing any of these are classified as Blocked.
    blocked_keywords: Arc<Vec<String>>,
}

impl Default for IntentRouter {
    fn default() -> Self {
        Self {
            blocked_keywords: Arc::new(Self::default_blocked_keywords()),
        }
    }
}

impl IntentRouter {
    /// Default prohibited keyword list (Chinese marketplace sensitive terms).
    fn default_blocked_keywords() -> Vec<String> {
        vec![
            // Weapons / controlled items
            "刀".to_string(),
            "枪".to_string(),
            "毒品".to_string(),
            "大麻".to_string(),
            "海洛因".to_string(),
            // Illegal services
            "假证".to_string(),
            "代考".to_string(),
            "作弊".to_string(),
            // Fraud signals
            "刷单".to_string(),
            "套现".to_string(),
        ]
    }

    pub fn new(blocked_keywords: Vec<String>) -> Self {
        Self {
            blocked_keywords: Arc::new(blocked_keywords),
        }
    }

    /// Classify a user message intent.
    pub fn classify(&self, message: &str) -> IntentResult {
        let msg = message.trim();

        // Step 1: Blocked keyword check — highest priority
        if self.is_blocked(msg) {
            return IntentResult::certain(Intent::Blocked);
        }

        // Step 2: Intent keyword matching (ordered by priority)
        // Priority: negotiate > buy > search > chat
        let lower = msg.to_lowercase();

        // Negotiate: price counter-offer language
        if self.contains_any(
            &lower,
            &[
                "还价",
                "便宜",
                "降价",
                "便宜点",
                "打个折",
                "便宜吗",
                "减",
                "折扣",
                "多少钱能",
                "能不能",
                "能便宜",
                "贵",
                "太贵",
                "便宜点吧",
                "再便宜",
                "再减",
                "便宜点行",
                "行",
                "可以吗",
                "能行",
                "接受",
                "成交价",
            ],
        ) {
            return IntentResult::new(Intent::Negotiate, 0.92);
        }

        // Buy: purchase intent
        if self.contains_any(
            &lower,
            &[
                "买",
                "购买",
                "下单",
                "要这个",
                "我要",
                "帮我买",
                "支付",
                "付款",
                "购买",
                "订单",
                "成交",
                "购买意向",
            ],
        ) {
            return IntentResult::new(Intent::Buy, 0.90);
        }

        // Search: browse/search intent
        if self.contains_any(
            &lower,
            &[
                "搜索",
                "找",
                "查找",
                "有没有",
                "有没有卖",
                "想买个",
                "看看",
                "查一下",
                "了解一下",
                "有吗",
                "在吗",
            ],
        ) {
            return IntentResult::new(Intent::Search, 0.85);
        }

        // Chat: casual conversation
        if self.contains_any(
            &lower,
            &[
                "你好",
                "你好",
                "hi",
                "hello",
                "嗨",
                "嘿",
                "你是谁",
                "谢谢",
                "拜拜",
                "再见",
                "好",
                "不好",
                "嗯",
                "哦",
                "好吧",
                "好的",
                "没问题",
                "干嘛",
                "干啥",
            ],
        ) {
            return IntentResult::certain(Intent::Chat);
        }

        // Default: unclear intent — use LLM
        IntentResult::new(Intent::Chat, 0.50)
    }

    fn is_blocked(&self, message: &str) -> bool {
        let lower = message.to_lowercase();
        self.blocked_keywords
            .iter()
            .any(|kw| lower.contains(&kw.to_lowercase()))
    }

    fn contains_any(&self, text: &str, keywords: &[&str]) -> bool {
        keywords.iter().any(|kw| text.contains(kw))
    }
}
