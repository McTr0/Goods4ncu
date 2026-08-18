//! Tri-tier intent router for Goods4ncu agents.
//!
//! Tier 0: Fast deterministic rules and moderation blocks (< 1ms).
//! Tier 1: pgvector cosine similarity against semantic intent exemplars (5-15ms).
//! Tier 2: Structured slot decomposition and intent clarification.
//!
//! Falls back gracefully when database or embeddings are unavailable.

use crate::llm::EmbeddingGenerator;
use serde::{Deserialize, Serialize};
use sqlx::{PgPool, Row};
use std::sync::Arc;
use uuid::Uuid;

/// Expanded intent categories matching the unified campus intent model.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum Intent {
    Search,
    Buy,
    Offer,
    Wanted,
    Negotiate,
    Companion,
    Help,
    Chat,
    Blocked,
}

impl Intent {
    pub fn as_str(&self) -> &'static str {
        match self {
            Intent::Search => "search",
            Intent::Buy => "buy",
            Intent::Offer => "offer",
            Intent::Wanted => "wanted",
            Intent::Negotiate => "negotiate",
            Intent::Companion => "companion",
            Intent::Help => "help",
            Intent::Chat => "chat",
            Intent::Blocked => "blocked",
        }
    }

    pub fn from_str_lenient(s: &str) -> Self {
        match s.to_lowercase().as_str() {
            "search" => Intent::Search,
            "buy" => Intent::Buy,
            "offer" | "publish" | "sell" => Intent::Offer,
            "wanted" | "seek" => Intent::Wanted,
            "negotiate" | "bargain" => Intent::Negotiate,
            "companion" | "activity" | "team" => Intent::Companion,
            "help" | "assist" => Intent::Help,
            "blocked" => Intent::Blocked,
            _ => Intent::Chat,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct IntentResult {
    pub intent: Intent,
    pub confidence: f32,
    pub matched_tier: u8,
    pub category_hint: Option<String>,
}

impl IntentResult {
    #[allow(dead_code)]
    pub fn new(intent: Intent, confidence: f32) -> Self {
        Self {
            intent,
            confidence,
            matched_tier: 0,
            category_hint: None,
        }
    }

    pub fn with_tier(intent: Intent, confidence: f32, tier: u8) -> Self {
        Self {
            intent,
            confidence,
            matched_tier: tier,
            category_hint: None,
        }
    }

    #[allow(dead_code)]
    pub fn certain(intent: Intent) -> Self {
        Self::new(intent, 1.0)
    }

    /// Returns a direct response string for greetings/blocked intents, or None if the agent should handle it.
    pub fn direct_response(&self, message: &str) -> Option<String> {
        match self.intent {
            Intent::Chat => {
                let msg = message.trim();
                if msg == "你好" || msg == "您好" {
                    Some("你好！我是续樟校园智能助手小昌。我可以帮你搜索闲置、草拟出/收信息、查询校内互助或协助议价。有什么我可以帮你的吗？".to_string())
                } else if msg == "你是谁" || msg == "你是谁？" {
                    Some("我是续樟校园平台的 AI 智能助手小昌，专注于帮你发现校园里的闲置好物、寻找搭子与校园求助。".to_string())
                } else if msg == "谢谢" || msg == "谢谢！" || msg == "多谢" {
                    Some("不客气！随时乐意为你效劳~".to_string())
                } else if msg == "再见" || msg == "拜拜" {
                    Some("再见，祝你在南昌大学学习生活愉快！".to_string())
                } else {
                    None
                }
            }
            Intent::Blocked => {
                Some("抱歉，你的消息包含了平台禁止发布或不支持的内容，无法继续处理。".to_string())
            }
            _ => None,
        }
    }
}

/// Tier 0 Rule Router (Deterministic & Fast).
#[derive(Clone)]
pub struct IntentRouter {
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
    pub fn default_blocked_keywords() -> Vec<String> {
        vec![
            // Weapons / controlled items
            "刀".to_string(),
            "枪".to_string(),
            "毒品".to_string(),
            "大麻".to_string(),
            "海洛因".to_string(),
            // Illegal / academic dishonesty
            "假证".to_string(),
            "代考".to_string(),
            "替考".to_string(),
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

    pub fn is_blocked(&self, message: &str) -> bool {
        let lower = message.to_lowercase();
        self.blocked_keywords
            .iter()
            .any(|kw| lower.contains(&kw.to_lowercase()))
    }

    /// Synchronous classification via Tier 0 heuristics.
    pub fn classify(&self, message: &str) -> IntentResult {
        let msg = message.trim();

        // 1. Blocked keyword check
        if self.is_blocked(msg) {
            return IntentResult::with_tier(Intent::Blocked, 1.0, 0);
        }

        let lower = msg.to_lowercase();

        // 2. Offer / Publish intent
        if self.contains_any(
            &lower,
            &[
                "我想出",
                "出闲置",
                "出个",
                "卖个",
                "卖掉",
                "转手",
                "出二手",
                "发布闲置",
                "出一部",
                "出一台",
                "出本",
                "自用出",
                "毕业出",
            ],
        ) {
            return IntentResult::with_tier(Intent::Offer, 0.95, 0);
        }

        // 3. Wanted / Seek intent
        if self.contains_any(
            &lower,
            &[
                "求购",
                "想收",
                "收个",
                "收一本",
                "收一台",
                "收一部",
                "有没有人出",
                "有人出吗",
                "收二手",
                "求收",
                "预算",
            ],
        ) && !self.contains_any(&lower, &["卖", "出掉"])
        {
            return IntentResult::with_tier(Intent::Wanted, 0.93, 0);
        }

        // 4. Negotiate intent
        if self.contains_any(
            &lower,
            &[
                "还价",
                "便宜点",
                "降价",
                "打个折",
                "小刀",
                "能不能便宜",
                "太贵了",
                "便宜行吗",
                "能少点吗",
                "最低多少",
            ],
        ) {
            return IntentResult::with_tier(Intent::Negotiate, 0.92, 0);
        }

        // 5. Buy intent
        if self.contains_any(
            &lower,
            &[
                "我要买",
                "买下",
                "下单",
                "直接买",
                "要这个",
                "怎么购买",
                "发起交易",
                "付款购买",
            ],
        ) {
            return IntentResult::with_tier(Intent::Buy, 0.90, 0);
        }

        // 6. Companion / Activity intent
        if self.contains_any(
            &lower,
            &[
                "搭子",
                "组队",
                "一起自习",
                "羽毛球搭子",
                "夜跑",
                "拼车",
                "约球",
                "爬山",
            ],
        ) {
            return IntentResult::with_tier(Intent::Companion, 0.90, 0);
        }

        // 7. Help intent
        if self.contains_any(
            &lower,
            &["求助", "请问教务", "校医院", "怎么补办", "谁会修"],
        ) {
            return IntentResult::with_tier(Intent::Help, 0.88, 0);
        }

        // 8. Search intent
        if self.contains_any(
            &lower,
            &[
                "搜索",
                "找找",
                "搜一下",
                "有没有",
                "看看有没有",
                "查一下",
                "找个",
                "看下",
            ],
        ) {
            return IntentResult::with_tier(Intent::Search, 0.85, 0);
        }

        // 9. Standard greetings / chat
        if self.contains_any(
            &lower,
            &[
                "你好",
                "您好",
                "hi",
                "hello",
                "嗨",
                "你是谁",
                "谢谢",
                "拜拜",
                "再见",
            ],
        ) {
            return IntentResult::with_tier(Intent::Chat, 0.99, 0);
        }

        // Default: general chat / unknown
        IntentResult::with_tier(Intent::Chat, 0.50, 0)
    }

    fn contains_any(&self, text: &str, keywords: &[&str]) -> bool {
        keywords.iter().any(|kw| text.contains(kw))
    }
}

/// Tri-tier intent router integrating pgvector semantic similarity.
#[derive(Clone)]
pub struct TriTierIntentRouter {
    rule_router: IntentRouter,
    db_pool: Option<PgPool>,
    embedding_gen: Option<Arc<dyn EmbeddingGenerator>>,
}

impl TriTierIntentRouter {
    pub fn new(
        rule_router: IntentRouter,
        db_pool: Option<PgPool>,
        embedding_gen: Option<Arc<dyn EmbeddingGenerator>>,
    ) -> Self {
        Self {
            rule_router,
            db_pool,
            embedding_gen,
        }
    }

    /// Classify a message using the cascading pipeline: Tier 0 -> Tier 1 -> Tier 0 fallback.
    pub async fn classify(&self, message: &str, campus_id: Option<Uuid>) -> IntentResult {
        let msg = message.trim();
        if msg.is_empty() {
            return IntentResult::with_tier(Intent::Chat, 1.0, 0);
        }

        // Tier 0: Blocked check & high-confidence deterministic rules
        let tier0_result = self.rule_router.classify(msg);
        if tier0_result.intent == Intent::Blocked || tier0_result.confidence >= 0.95 {
            return tier0_result;
        }

        // Tier 1: pgvector semantic matching
        if let (Some(db), Some(embedder)) = (&self.db_pool, &self.embedding_gen) {
            match embedder.generate(msg).await {
                Ok(embedding_vec) => {
                    let vec_f32: Vec<f32> = embedding_vec.iter().map(|&v| v as f32).collect();
                    let pg_vec = pgvector::Vector::from(vec_f32);

                    let query_res = sqlx::query(
                        "SELECT intent_name, category_hint, 1.0 - (embedding <=> $1) AS similarity
                         FROM intent_exemplars
                         WHERE embedding IS NOT NULL
                           AND (campus_id IS NULL OR campus_id = $2)
                         ORDER BY embedding <=> $1
                         LIMIT 1",
                    )
                    .bind(pg_vec)
                    .bind(campus_id)
                    .fetch_optional(db)
                    .await;

                    if let Ok(Some(row)) = query_res {
                        let intent_name: String = row.get("intent_name");
                        let category_hint: Option<String> = row.get("category_hint");
                        let similarity: f64 = row.get("similarity");

                        if similarity >= 0.80 {
                            let mut res = IntentResult::with_tier(
                                Intent::from_str_lenient(&intent_name),
                                similarity as f32,
                                1,
                            );
                            res.category_hint = category_hint;
                            return res;
                        }
                    }
                }
                Err(err) => {
                    tracing::debug!("Tier 1 embedding generator skipped: {}", err);
                }
            }
        }

        // Fallback to Tier 0 result
        tier0_result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tier0_search() {
        let router = IntentRouter::default();
        assert_eq!(router.classify("帮我搜索一下耳机").intent, Intent::Search);
        assert_eq!(router.classify("有没有二手书").intent, Intent::Search);
    }

    #[test]
    fn test_tier0_offer_and_wanted() {
        let router = IntentRouter::default();
        assert_eq!(
            router.classify("我想出掉宿舍的旧台灯，20元").intent,
            Intent::Offer
        );
        assert_eq!(
            router.classify("求购一个二手显示器，预算300").intent,
            Intent::Wanted
        );
    }

    #[test]
    fn test_tier0_companion_and_help() {
        let router = IntentRouter::default();
        assert_eq!(
            router.classify("找个今晚去天健操场跑步的搭子").intent,
            Intent::Companion
        );
        assert_eq!(
            router.classify("求助，请问教务处补办学生证在哪").intent,
            Intent::Help
        );
    }

    #[test]
    fn test_tier0_blocked() {
        let router = IntentRouter::default();
        assert_eq!(
            router.classify("我要买一把管制刀具").intent,
            Intent::Blocked
        );
        assert_eq!(router.classify("代考替考").intent, Intent::Blocked);
    }
}
