use super::common::*;
use crate::utils::cents_to_yuan;
use rig::completion::ToolDefinition;
use rig::tool::Tool;
use serde::Deserialize;
use serde_json::json;

#[derive(Deserialize)]
pub struct GetUserPostsArgs {
    pub user_id: String,
}

#[derive(Clone)]
pub struct GetUserPostsTool {
    pub ctx: ToolContext,
}

#[derive(sqlx::FromRow)]
struct ListingSummaryRow {
    id: String,
    title: String,
    category: String,
    condition_score: i32,
    suggested_price_cny: i64,
}

impl Tool for GetUserPostsTool {
    const NAME: &'static str = "get_user_posts";
    type Error = ToolError;
    type Args = GetUserPostsArgs;
    type Output = String;

    async fn definition(&self, _prompt: String) -> ToolDefinition {
        ToolDefinition {
            name: "get_user_posts".to_string(),
            description: "获取指定用户发布的所有在售帖子列表。".to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "user_id": { "type": "string", "description": "The user ID" }
                },
                "required": ["user_id"]
            }),
        }
    }

    async fn call(&self, args: Self::Args) -> Result<Self::Output, Self::Error> {
        let campus_id = resolve_read_campus(&self.ctx).await?;
        let rows = sqlx::query_as::<_, ListingSummaryRow>(
            "SELECT id, title, category, condition_score, suggested_price_cny
             FROM inventory WHERE owner_id = $1 AND campus_id = $2
               AND status = 'active' AND NOT listing_has_active_restriction(id)
             ORDER BY created_at DESC LIMIT 20",
        )
        .bind(&args.user_id)
        .bind(campus_id)
        .fetch_all(&self.ctx.db_pool)
        .await
        .map_err(|e| ToolError(format!("Query error: {}", e)))?;

        if rows.is_empty() {
            return Ok("该用户当前没有在售帖子。".to_string());
        }
        let mut out = format!("该用户共有 {} 条在售帖子：\n", rows.len());
        for (i, r) in rows.iter().enumerate() {
            out.push_str(&format!(
                "{}. [{}] {} — {} — 成色 {}/10 — {} 元\n",
                i + 1,
                r.id,
                r.title,
                r.category,
                r.condition_score,
                cents_to_yuan(r.suggested_price_cny),
            ));
        }
        Ok(out)
    }
}

// ---------------------------------------------------------------------------
// 10. FindRelatedPostsTool
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct FindRelatedPostsArgs {
    pub listing_id: String,
}

#[derive(Clone)]
pub struct FindRelatedPostsTool {
    pub ctx: ToolContext,
}

impl Tool for FindRelatedPostsTool {
    const NAME: &'static str = "find_related_posts";
    type Error = ToolError;
    type Args = FindRelatedPostsArgs;
    type Output = String;

    async fn definition(&self, _prompt: String) -> ToolDefinition {
        ToolDefinition {
            name: "find_related_posts".to_string(),
            description: "查找与指定帖子相似的其他在售帖子（同品类、相近价格）。".to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "listing_id": { "type": "string", "description": "The reference listing ID" }
                },
                "required": ["listing_id"]
            }),
        }
    }

    async fn call(&self, args: Self::Args) -> Result<Self::Output, Self::Error> {
        let campus_id = resolve_read_campus(&self.ctx).await?;
        let base = sqlx::query_as::<_, (String, i64)>(
            "SELECT category, suggested_price_cny FROM inventory WHERE id = $1",
        )
        .bind(&args.listing_id)
        .fetch_optional(&self.ctx.db_pool)
        .await
        .map_err(|e| ToolError(format!("Query error: {}", e)))?;

        let (category, price) = match base {
            Some(v) => v,
            None => return Ok(format!("未找到 ID 为 {} 的帖子。", args.listing_id)),
        };

        let min_price = (price as f64 * 0.6) as i64;
        let max_price = (price as f64 * 1.4) as i64;
        let rows = sqlx::query_as::<_, ListingSummaryRow>(
            "SELECT id, title, category, condition_score, suggested_price_cny
             FROM inventory
             WHERE id != $1 AND campus_id = $2 AND category = $3
               AND suggested_price_cny BETWEEN $4 AND $5
               AND status = 'active' AND NOT listing_has_active_restriction(id)
             ORDER BY ABS(suggested_price_cny - $6) ASC LIMIT 5",
        )
        .bind(&args.listing_id)
        .bind(campus_id)
        .bind(&category)
        .bind(min_price)
        .bind(max_price)
        .bind(price)
        .fetch_all(&self.ctx.db_pool)
        .await
        .map_err(|e| ToolError(format!("Query error: {}", e)))?;

        if rows.is_empty() {
            return Ok("没有找到相似的帖子。".to_string());
        }
        let mut out = format!("找到 {} 条相关帖子：\n", rows.len());
        for (i, r) in rows.iter().enumerate() {
            out.push_str(&format!(
                "{}. [{}] {} — 成色 {}/10 — {} 元\n",
                i + 1,
                r.id,
                r.title,
                r.condition_score,
                cents_to_yuan(r.suggested_price_cny),
            ));
        }
        Ok(out)
    }
}

// ---------------------------------------------------------------------------
// 11. GetCommentsTool
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct GetCommentsArgs {
    pub conversation_id: String,
}

#[derive(Clone)]
pub struct GetCommentsTool {
    pub ctx: ToolContext,
}

#[derive(sqlx::FromRow)]
struct CommentRow {
    sender: String,
    content: String,
    created_at: chrono::DateTime<chrono::Utc>,
}

impl Tool for GetCommentsTool {
    const NAME: &'static str = "get_comments";
    type Error = ToolError;
    type Args = GetCommentsArgs;
    type Output = String;

    async fn definition(&self, _prompt: String) -> ToolDefinition {
        ToolDefinition {
            name: "get_comments".to_string(),
            description: "获取某个商品对话中的最近留言记录。".to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "conversation_id": { "type": "string", "description": "The conversation thread ID" }
                },
                "required": ["conversation_id"]
            }),
        }
    }

    async fn call(&self, args: Self::Args) -> Result<Self::Output, Self::Error> {
        let current = self.ctx.current_user_id.clone().unwrap_or_default();
        if current.is_empty() {
            return Ok("[hidden] 请先登录后才能读取对话。".to_string());
        }
        let allowed = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS(
                 SELECT 1 FROM chat_messages
                 WHERE conversation_id = $1 AND (sender = $2 OR receiver = $2)
                 LIMIT 1)",
        )
        .bind(&args.conversation_id)
        .bind(&current)
        .fetch_one(&self.ctx.db_pool)
        .await
        .unwrap_or(false);

        if !allowed {
            return Ok("[hidden] 你不是这个对话的参与者。".to_string());
        }

        let rows = sqlx::query_as::<_, CommentRow>(
            "SELECT sender, content, created_at FROM chat_messages
             WHERE conversation_id = $1 AND is_agent = FALSE
             ORDER BY created_at DESC LIMIT 20",
        )
        .bind(&args.conversation_id)
        .fetch_all(&self.ctx.db_pool)
        .await
        .map_err(|e| ToolError(format!("Query error: {}", e)))?;

        if rows.is_empty() {
            return Ok("这个对话还没有留言。".to_string());
        }
        let mut out = format!("最近 {} 条留言：\n", rows.len());
        for r in &rows {
            out.push_str(&format!(
                "[{}] {}: {}\n",
                r.created_at.format("%m-%d %H:%M"),
                r.sender,
                r.content,
            ));
        }
        Ok(out)
    }
}

// ---------------------------------------------------------------------------
// 12. DraftMessageTool — generates a message draft without sending it
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct DraftMessageArgs {
    pub listing_id: String,
    pub receiver_id: String,
    pub draft_text: String,
}

#[derive(Clone)]
#[allow(dead_code)]
pub struct DraftMessageTool {
    pub ctx: ToolContext,
}

impl Tool for DraftMessageTool {
    const NAME: &'static str = "draft_message";
    type Error = ToolError;
    type Args = DraftMessageArgs;
    type Output = String;

    async fn definition(&self, _prompt: String) -> ToolDefinition {
        ToolDefinition {
            name: "draft_message".to_string(),
            description: "生成一条私信草稿给卖家。不会直接发送——用户确认后才发送。用于帮用户组织语言联系卖家。".to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "listing_id": { "type": "string", "description": "The related listing ID" },
                    "receiver_id": { "type": "string", "description": "The seller's user ID" },
                    "draft_text": { "type": "string", "description": "The draft message text to show the user for confirmation" }
                },
                "required": ["listing_id", "receiver_id", "draft_text"]
            }),
        }
    }

    async fn call(&self, args: Self::Args) -> Result<Self::Output, Self::Error> {
        // This tool does NOT send anything. It returns a formatted draft
        // for the frontend to show as a confirmation card.
        let listing_exists = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS(SELECT 1 FROM inventory WHERE id = $1 AND status = 'active')",
        )
        .bind(&args.listing_id)
        .fetch_one(&self.ctx.db_pool)
        .await
        .unwrap_or(false);

        let receiver_exists =
            sqlx::query_scalar::<_, bool>("SELECT EXISTS(SELECT 1 FROM users WHERE id = $1)")
                .bind(&args.receiver_id)
                .fetch_one(&self.ctx.db_pool)
                .await
                .unwrap_or(false);

        if !listing_exists || !receiver_exists {
            return Err(ToolError(
                "无法生成私信草稿：帖子或接收人不存在。".to_string(),
            ));
        }

        let envelope = crate::agents::runtime::envelope::ToolResultEnvelope::success(
            "已为你生成一条私信草稿，请确认后发送。",
        )
        .with_action(crate::llm::UiAction::open_message_draft(
            &args.receiver_id,
            &args.listing_id,
            &args.draft_text,
        ))
        .with_resource(args.listing_id);

        Ok(envelope.to_json())
    }
}

// 13. DraftCommentTool — packages a reply draft without posting it
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct DraftCommentArgs {
    pub post_id: String,
    pub draft_text: String,
}

#[derive(Clone)]
pub struct DraftCommentTool {
    pub ctx: ToolContext,
}

impl Tool for DraftCommentTool {
    const NAME: &'static str = "draft_comment";
    type Error = ToolError;
    type Args = DraftCommentArgs;
    type Output = String;

    async fn definition(&self, _prompt: String) -> ToolDefinition {
        ToolDefinition {
            name: "draft_comment".to_string(),
            description: "为一条校园帖子生成一条公开回复草稿。不会直接发布——用户确认后才发布。用于帮用户组织回帖语言。".to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "post_id": { "type": "string", "description": "The post ID to reply to" },
                    "draft_text": { "type": "string", "description": "The draft reply text to show the user for confirmation" }
                },
                "required": ["post_id", "draft_text"]
            }),
        }
    }

    async fn call(&self, args: Self::Args) -> Result<Self::Output, Self::Error> {
        // Read-safe packaging only: verify the target post exists and is
        // active. Real permission checks run again on the publish endpoint
        // after the user confirms.
        let post_exists = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS(SELECT 1 FROM posts WHERE id = $1::uuid AND status = 'active')",
        )
        .bind(&args.post_id)
        .fetch_one(&self.ctx.db_pool)
        .await
        .unwrap_or(false);

        if !post_exists {
            return Err(ToolError(
                "无法生成回复草稿：目标帖子不存在或已关闭。".to_string(),
            ));
        }

        let envelope = crate::agents::runtime::envelope::ToolResultEnvelope::success(
            "已为你生成一条回复草稿，请确认后发布。",
        )
        .with_action(crate::llm::UiAction::open_comment_draft(
            &args.post_id,
            &args.draft_text,
        ))
        .with_resource(args.post_id);

        Ok(envelope.to_json())
    }
}
