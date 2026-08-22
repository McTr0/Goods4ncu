//! Hierarchical Agent Memory and User Profiling Service.
//!
//! Enforces strict privacy boundaries:
//! - Memories and profiles are scoped by user_id and campus_id.
//! - Users have complete visibility and deletion rights over their stored memories.
//! - Context injection respects privacy levels (standard, strict, minimal).

use crate::llm::EmbeddingGenerator;
use anyhow::Result;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use std::sync::Arc;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct UserAgentProfile {
    pub user_id: String,
    pub campus_id: Uuid,
    pub preferred_locations: Vec<String>,
    pub interested_categories: Vec<String>,
    pub budget_preferences: serde_json::Value,
    pub custom_instructions: Option<String>,
    pub privacy_level: String,
    pub is_memory_enabled: bool,
    pub is_proactive_enabled: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[cfg(test)]
mod tests {
    use super::AgentMemoryService;

    #[test]
    fn page_context_fields_are_extractable_for_grounding() {
        let context = serde_json::json!({
            "page": "post_detail",
            "postId": "post_1",
            "listingId": "listing_1",
        });

        let page = context
            .get("page")
            .and_then(serde_json::Value::as_str)
            .expect("page");
        let post_id = context
            .get("postId")
            .and_then(serde_json::Value::as_str)
            .expect("post id");
        let listing_id = context
            .get("listingId")
            .and_then(serde_json::Value::as_str)
            .expect("listing id");

        assert_eq!(page, "post_detail");
        assert_eq!(post_id, "post_1");
        assert_eq!(listing_id, "listing_1");
    }

    #[test]
    fn page_context_lines_are_built_without_profile_access() {
        let context = serde_json::json!({
            "page": "post_detail",
            "postId": "post_1",
            "listingId": "listing_1",
        });

        let lines = AgentMemoryService::page_context_lines(Some(&context));

        assert_eq!(lines.len(), 4);
        assert!(lines[0].contains("当前页面上下文"));
        assert!(lines.iter().any(|line| line.contains("post_1")));
        assert!(lines.iter().any(|line| line.contains("listing_1")));

        assert_eq!(
            AgentMemoryService::page_context_lines(None),
            Vec::<String>::new()
        );
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateProfileInput {
    pub preferred_locations: Option<Vec<String>>,
    pub interested_categories: Option<Vec<String>>,
    pub budget_preferences: Option<serde_json::Value>,
    pub custom_instructions: Option<String>,
    pub privacy_level: Option<String>,
    pub is_memory_enabled: Option<bool>,
    pub is_proactive_enabled: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct AgentMemory {
    pub id: Uuid,
    pub user_id: String,
    pub campus_id: Uuid,
    pub memory_type: String,
    pub content: String,
    pub source_ref: Option<String>,
    pub confidence: f32,
    pub created_at: DateTime<Utc>,
    pub last_accessed_at: DateTime<Utc>,
}

pub struct CreateMemoryInput<'a> {
    pub user_id: &'a str,
    pub campus_id: Uuid,
    pub memory_type: &'a str,
    pub content: &'a str,
    pub source_ref: Option<&'a str>,
    pub confidence: f32,
}

#[derive(Clone)]
pub struct AgentMemoryService {
    db: PgPool,
}

impl AgentMemoryService {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    async fn existing_profile(&self, user_id: &str) -> Result<Option<UserAgentProfile>> {
        let profile = sqlx::query_as::<_, UserAgentProfile>(
            "SELECT user_id, campus_id, preferred_locations, interested_categories,
                    budget_preferences, custom_instructions, privacy_level,
                    is_memory_enabled, is_proactive_enabled, created_at, updated_at
             FROM user_agent_profiles
             WHERE user_id = $1",
        )
        .bind(user_id)
        .fetch_optional(&self.db)
        .await?;

        Ok(profile)
    }

    /// Record the topic and result ids of the latest platform search so the
    /// next turn can resolve follow-ups like “最近发的” (goal §36).
    ///
    /// The recency list is merged newest-first and capped; the topic is only
    /// overwritten when a new one is supplied.
    pub async fn record_session_search(
        &self,
        user_id: &str,
        topic: Option<&str>,
        listing_ids: &[String],
    ) -> Result<()> {
        const SESSION_RECENT_LIMIT: usize = 10;

        let mut merged: Vec<String> = listing_ids.to_vec();
        merged.extend(self.session_recent_listing_ids(user_id).await?);
        let mut seen = std::collections::HashSet::new();
        merged.retain(|id| seen.insert(id.clone()));
        merged.truncate(SESSION_RECENT_LIMIT);

        sqlx::query(
            "INSERT INTO agent_session_memory (user_id, current_topic, recent_listing_ids)
             VALUES ($1, COALESCE($2, ''), $3::jsonb)
             ON CONFLICT (user_id) DO UPDATE SET
                current_topic = CASE
                    WHEN $2 IS NOT NULL AND $2 <> '' THEN $2
                    ELSE agent_session_memory.current_topic END,
                recent_listing_ids = EXCLUDED.recent_listing_ids,
                updated_at = NOW()",
        )
        .bind(user_id)
        .bind(topic)
        .bind(serde_json::to_string(&merged)?)
        .execute(&self.db)
        .await?;
        Ok(())
    }

    /// Convenience wrapper for single-listing views (opened/focused posts).
    pub async fn record_session_view(&self, user_id: &str, listing_id: &str) -> Result<()> {
        self.record_session_search(user_id, None, std::slice::from_ref(&listing_id.to_string()))
            .await
    }

    /// Session-scoped working context lines for the prompt (goal §36).
    pub async fn session_context_lines(&self, user_id: &str) -> Result<Vec<String>> {
        let row: Option<(String, serde_json::Value)> = sqlx::query_as(
            "SELECT current_topic, recent_listing_ids
             FROM agent_session_memory WHERE user_id = $1",
        )
        .bind(user_id)
        .fetch_optional(&self.db)
        .await?;

        let Some((topic, ids_json)) = row else {
            return Ok(Vec::new());
        };
        let ids: Vec<String> = serde_json::from_value(ids_json).unwrap_or_default();

        let mut lines = Vec::new();
        if !topic.trim().is_empty() {
            lines.push(format!("- **会话当前话题**：{}", topic.trim()));
        }
        if !ids.is_empty() {
            lines.push(format!(
                "- **会话中出现过的帖子（新→旧）**：{}",
                ids.join("、")
            ));
        }
        Ok(lines)
    }

    /// True when the user explicitly opted out of agent memory.
    async fn session_memory_suppressed(&self, user_id: &str) -> bool {
        matches!(
            self.existing_profile(user_id).await,
            Ok(Some(profile)) if !profile.is_memory_enabled || profile.privacy_level == "minimal"
        )
    }

    async fn session_recent_listing_ids(&self, user_id: &str) -> Result<Vec<String>> {
        let row: Option<(serde_json::Value,)> = sqlx::query_as(
            "SELECT recent_listing_ids FROM agent_session_memory WHERE user_id = $1",
        )
        .bind(user_id)
        .fetch_optional(&self.db)
        .await?;
        let Some((ids,)) = row else {
            return Ok(Vec::new());
        };
        Ok(serde_json::from_value(ids).unwrap_or_default())
    }

    /// Retrieve or initialize default user agent profile.
    pub async fn get_or_create_profile(
        &self,
        user_id: &str,
        campus_id: Uuid,
    ) -> Result<UserAgentProfile> {
        let existing = self.existing_profile(user_id).await?;

        if let Some(profile) = existing {
            return Ok(profile);
        }

        let inserted = sqlx::query_as::<_, UserAgentProfile>(
            "INSERT INTO user_agent_profiles (user_id, campus_id)
             VALUES ($1, $2)
             ON CONFLICT (user_id) DO UPDATE SET campus_id = $2
             RETURNING user_id, campus_id, preferred_locations, interested_categories,
                       budget_preferences, custom_instructions, privacy_level,
                       is_memory_enabled, is_proactive_enabled, created_at, updated_at",
        )
        .bind(user_id)
        .bind(campus_id)
        .fetch_one(&self.db)
        .await?;

        Ok(inserted)
    }

    /// Update user profile settings.
    pub async fn update_profile(
        &self,
        user_id: &str,
        campus_id: Uuid,
        input: UpdateProfileInput,
    ) -> Result<UserAgentProfile> {
        let current = self.get_or_create_profile(user_id, campus_id).await?;

        let locations = input
            .preferred_locations
            .unwrap_or(current.preferred_locations);
        let categories = input
            .interested_categories
            .unwrap_or(current.interested_categories);
        let budget = input
            .budget_preferences
            .unwrap_or(current.budget_preferences);
        let custom_instructions = input.custom_instructions.or(current.custom_instructions);
        let privacy = input.privacy_level.unwrap_or(current.privacy_level);
        let memory_enabled = input.is_memory_enabled.unwrap_or(current.is_memory_enabled);
        let proactive_enabled = input
            .is_proactive_enabled
            .unwrap_or(current.is_proactive_enabled);

        let updated = sqlx::query_as::<_, UserAgentProfile>(
            "UPDATE user_agent_profiles
             SET preferred_locations = $2,
                 interested_categories = $3,
                 budget_preferences = $4,
                 custom_instructions = $5,
                 privacy_level = $6,
                 is_memory_enabled = $7,
                 is_proactive_enabled = $8,
                 updated_at = CURRENT_TIMESTAMP
             WHERE user_id = $1
             RETURNING user_id, campus_id, preferred_locations, interested_categories,
                       budget_preferences, custom_instructions, privacy_level,
                       is_memory_enabled, is_proactive_enabled, created_at, updated_at",
        )
        .bind(user_id)
        .bind(&locations)
        .bind(&categories)
        .bind(&budget)
        .bind(&custom_instructions)
        .bind(&privacy)
        .bind(memory_enabled)
        .bind(proactive_enabled)
        .fetch_one(&self.db)
        .await?;

        Ok(updated)
    }

    /// Add a new episodic or preference memory record.
    pub async fn add_memory(
        &self,
        input: CreateMemoryInput<'_>,
        embedder: Option<&Arc<dyn EmbeddingGenerator>>,
    ) -> Result<AgentMemory> {
        let mut pg_vec: Option<pgvector::Vector> = None;
        if let Some(gen) = embedder {
            if let Ok(vec) = gen.generate(input.content).await {
                let vec_f32: Vec<f32> = vec.iter().map(|&v| v as f32).collect();
                pg_vec = Some(pgvector::Vector::from(vec_f32));
            }
        }

        let memory = sqlx::query_as::<_, AgentMemory>(
            "INSERT INTO agent_memories (user_id, campus_id, memory_type, content, embedding, source_ref, confidence)
             VALUES ($1, $2, $3, $4, $5, $6, $7)
             RETURNING id, user_id, campus_id, memory_type, content, source_ref, confidence, created_at, last_accessed_at",
        )
        .bind(input.user_id)
        .bind(input.campus_id)
        .bind(input.memory_type)
        .bind(input.content)
        .bind(pg_vec)
        .bind(input.source_ref)
        .bind(input.confidence)
        .fetch_one(&self.db)
        .await?;

        Ok(memory)
    }

    /// Recall top relevant memories for a user based on semantic similarity.
    pub async fn recall_memories(
        &self,
        user_id: &str,
        campus_id: Uuid,
        query: &str,
        embedder: Option<&Arc<dyn EmbeddingGenerator>>,
        limit: i64,
    ) -> Result<Vec<AgentMemory>> {
        if let Some(gen) = embedder {
            if let Ok(vec) = gen.generate(query).await {
                let vec_f32: Vec<f32> = vec.iter().map(|&v| v as f32).collect();
                let pg_vec = pgvector::Vector::from(vec_f32);

                let memories = sqlx::query_as::<_, AgentMemory>(
                    "SELECT id, user_id, campus_id, memory_type, content, source_ref, confidence, created_at, last_accessed_at
                     FROM agent_memories
                     WHERE user_id = $1 AND campus_id = $2 AND embedding IS NOT NULL
                     ORDER BY embedding <=> $3
                     LIMIT $4",
                )
                .bind(user_id)
                .bind(campus_id)
                .bind(pg_vec)
                .bind(limit)
                .fetch_all(&self.db)
                .await?;

                if !memories.is_empty() {
                    return Ok(memories);
                }
            }
        }

        // Fallback to recent memories if embedding is unavailable
        let memories = sqlx::query_as::<_, AgentMemory>(
            "SELECT id, user_id, campus_id, memory_type, content, source_ref, confidence, created_at, last_accessed_at
             FROM agent_memories
             WHERE user_id = $1 AND campus_id = $2
             ORDER BY created_at DESC
             LIMIT $3",
        )
        .bind(user_id)
        .bind(campus_id)
        .bind(limit)
        .fetch_all(&self.db)
        .await?;

        Ok(memories)
    }

    /// List memories for management UI.
    pub async fn list_memories(
        &self,
        user_id: &str,
        memory_type: Option<&str>,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<AgentMemory>, i64)> {
        let total = if let Some(mtype) = memory_type {
            sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM agent_memories WHERE user_id = $1 AND memory_type = $2",
            )
            .bind(user_id)
            .bind(mtype)
            .fetch_one(&self.db)
            .await?
        } else {
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM agent_memories WHERE user_id = $1")
                .bind(user_id)
                .fetch_one(&self.db)
                .await?
        };

        let items = if let Some(mtype) = memory_type {
            sqlx::query_as::<_, AgentMemory>(
                "SELECT id, user_id, campus_id, memory_type, content, source_ref, confidence, created_at, last_accessed_at
                 FROM agent_memories
                 WHERE user_id = $1 AND memory_type = $2
                 ORDER BY created_at DESC
                 LIMIT $3 OFFSET $4",
            )
            .bind(user_id)
            .bind(mtype)
            .bind(limit)
            .bind(offset)
            .fetch_all(&self.db)
            .await?
        } else {
            sqlx::query_as::<_, AgentMemory>(
                "SELECT id, user_id, campus_id, memory_type, content, source_ref, confidence, created_at, last_accessed_at
                 FROM agent_memories
                 WHERE user_id = $1
                 ORDER BY created_at DESC
                 LIMIT $2 OFFSET $3",
            )
            .bind(user_id)
            .bind(limit)
            .bind(offset)
            .fetch_all(&self.db)
            .await?
        };

        Ok((items, total))
    }

    /// Delete a single memory by ID (user-isolated).
    pub async fn delete_memory(&self, user_id: &str, memory_id: Uuid) -> Result<bool> {
        let result = sqlx::query("DELETE FROM agent_memories WHERE id = $1 AND user_id = $2")
            .bind(memory_id)
            .bind(user_id)
            .execute(&self.db)
            .await?;

        Ok(result.rows_affected() > 0)
    }

    /// Clear all memories for a user.
    pub async fn clear_all_memories(&self, user_id: &str) -> Result<u64> {
        let result = sqlx::query("DELETE FROM agent_memories WHERE user_id = $1")
            .bind(user_id)
            .execute(&self.db)
            .await?;

        Ok(result.rows_affected())
    }

    fn page_context_lines(page_context: Option<&serde_json::Value>) -> Vec<String> {
        let Some(ctx) = page_context else {
            return Vec::new();
        };

        let mut lines = vec!["### 用户当前页面上下文：".to_string()];
        if let Some(page) = ctx.get("page").and_then(|v| v.as_str()) {
            lines.push(format!("- **当前页面**：{}", page));
        }
        if let Some(post_id) = ctx.get("postId").and_then(|v| v.as_str()) {
            lines.push(format!(
                "- **正在查看的帖子 ID**：{}（当用户说\"这个帖子\"或\"它\"时，优先使用此 ID）",
                post_id
            ));
        }
        if let Some(listing_id) = ctx.get("listingId").and_then(|v| v.as_str()) {
            lines.push(format!(
                "- **正在查看的商品/Listing ID**：{}（读取商品详情、查找相关帖子或拟私信时优先使用此 ID）",
                listing_id
            ));
        }
        lines
    }

    fn join_context(lines: Vec<String>) -> String {
        if lines.len() <= 1 {
            return String::new();
        }

        let mut lines = lines;
        lines.push(
            "（注意：以上信息用于提供更贴合用户校区和偏好的建议，严禁将个人偏好当成绝对事实外泄）"
                .to_string(),
        );
        lines.join("\n")
    }

    /// Build dynamic memory context for injecting into agent prompt.
    pub async fn format_memory_context(
        &self,
        user_id: &str,
        campus_id: Uuid,
        query: &str,
        page_context: Option<&serde_json::Value>,
        embedder: Option<&Arc<dyn EmbeddingGenerator>>,
    ) -> Result<String> {
        let mut lines = Self::page_context_lines(page_context);

        // Session-scoped working context (goal §36): what the user is
        // currently exploring. Independent of the long-term profile so fresh
        // users keep cross-turn continuity; an explicit memory opt-out still
        // suppresses it.
        if !self.session_memory_suppressed(user_id).await {
            let session_lines = self.session_context_lines(user_id).await?;
            if !session_lines.is_empty() {
                lines.push("### 当前会话记忆：".to_string());
                lines.extend(session_lines);
            }
        }

        let profile = self.existing_profile(user_id).await?;

        let Some(profile) = profile else {
            return Ok(Self::join_context(lines));
        };
        if !profile.is_memory_enabled || profile.privacy_level == "minimal" {
            return Ok(Self::join_context(lines));
        }

        lines.push("### 用户个性化画像与记忆：".to_string());

        if !profile.preferred_locations.is_empty() {
            lines.push(format!(
                "- **常驻校区/地点**：{}",
                profile.preferred_locations.join("、")
            ));
        }
        if !profile.interested_categories.is_empty() {
            lines.push(format!(
                "- **关注品类**：{}",
                profile.interested_categories.join("、")
            ));
        }
        if let Some(custom) = &profile.custom_instructions {
            if !custom.trim().is_empty() {
                lines.push(format!("- **用户个性化要求**：{}", custom.trim()));
            }
        }

        // Recall episodic memories
        if profile.privacy_level == "standard" {
            let memories = self
                .recall_memories(user_id, campus_id, query, embedder, 3)
                .await?;
            if !memories.is_empty() {
                lines.push("- **相关历史偏好与记录**：".to_string());
                for mem in memories {
                    lines.push(format!("  • {}", mem.content));
                }
            }
        }

        Ok(Self::join_context(lines))
    }
}
