//! Autonomous ReAct (Reasoning + Acting) and Self-Healing Engine for Goods4ncu agents.
//!
//! Provides a bounded, observable execution loop:
//! - Think & Plan -> Action / Tool Dispatch -> Observe Output -> Reflect / Self-Heal -> Next Step or Final Answer.
//! - Bounded by `max_steps` (default 6) and execution timeout.
//! - Integrates with L0-L3 action boundaries: L2/L3 actions halt the loop and generate `ActionPlan` views for user confirmation.
//! - When tool executions produce errors or empty lists, reflection heuristics allow the agent to self-heal (e.g. broadening search queries, fixing arguments) instead of failing immediately.

#![allow(dead_code)]

use crate::agents::tools::{
    CreateListingArgs, CreateListingTool, DeleteListingArgs, DeleteListingTool, DraftMessageArgs,
    DraftMessageTool, FindRelatedPostsArgs, FindRelatedPostsTool, GetCommentsArgs, GetCommentsTool,
    GetListingDetailsArgs, GetListingDetailsTool, GetMyListingsArgs, GetMyListingsTool,
    GetUserPostsArgs, GetUserPostsTool, NegotiateItemArgs, NegotiateItemTool,
    PurchaseItemIntentArgs, PurchaseItemIntentTool, SearchInventoryArgs, SearchInventoryTool,
    ToolContext,
};
use crate::llm::AgentTokenUsage;
use rig::tool::Tool;
use serde::{Deserialize, Serialize};
use std::str::FromStr;
use std::time::{Duration, Instant};

pub const DEFAULT_MAX_STEPS: usize = 6;
pub const DEFAULT_STEP_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum StepActionType {
    SearchInventory,
    GetListingDetails,
    GetUserPosts,
    FindRelatedPosts,
    GetComments,
    DraftMessage,
    GetMyListings,
    CreateListing,
    UpdateListing,
    DeleteListing,
    PurchaseItem,
    NegotiatePrice,
    FinalAnswer,
    Unknown(String),
}

impl FromStr for StepActionType {
    type Err = std::convert::Infallible;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(match s.trim().to_lowercase().as_str() {
            "search_inventory" | "search" => Self::SearchInventory,
            "get_listing_details" | "details" => Self::GetListingDetails,
            "get_user_posts" | "user_posts" => Self::GetUserPosts,
            "find_related_posts" | "related" => Self::FindRelatedPosts,
            "get_comments" | "comments" => Self::GetComments,
            "draft_message" | "draft" => Self::DraftMessage,
            "get_my_listings" | "my_listings" => Self::GetMyListings,
            "create_listing" | "create" => Self::CreateListing,
            "update_listing" | "update" => Self::UpdateListing,
            "delete_listing" | "delete" => Self::DeleteListing,
            "purchase_item" | "purchase" => Self::PurchaseItem,
            "negotiate_price" | "negotiate" => Self::NegotiatePrice,
            "final_answer" | "answer" => Self::FinalAnswer,
            other => Self::Unknown(other.to_string()),
        })
    }
}

impl StepActionType {
    pub fn is_high_risk(&self) -> bool {
        matches!(
            self,
            Self::UpdateListing | Self::DeleteListing | Self::PurchaseItem | Self::NegotiatePrice
        )
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReActStep {
    pub step_index: usize,
    pub thought: String,
    pub action_type: String,
    pub action_args: serde_json::Value,
    pub observation: String,
    pub reflection: Option<String>,
    pub duration_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ReActStatus {
    Completed {
        final_answer: String,
    },
    Suspended {
        plan_summary: String,
        plan_id: Option<String>,
    },
    MaxStepsReached {
        last_observation: String,
    },
    Failed {
        error: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReActExecutionResult {
    pub status: ReActStatus,
    pub steps: Vec<ReActStep>,
    pub total_duration_ms: u64,
    pub token_usage: Option<AgentTokenUsage>,
}

/// Bounded ReAct engine coordinator.
pub struct ReActEngine {
    max_steps: usize,
    step_timeout: Duration,
    tool_ctx: ToolContext,
}

impl ReActEngine {
    pub fn new(tool_ctx: ToolContext) -> Self {
        Self {
            max_steps: DEFAULT_MAX_STEPS,
            step_timeout: DEFAULT_STEP_TIMEOUT,
            tool_ctx,
        }
    }

    pub fn with_max_steps(mut self, max_steps: usize) -> Self {
        self.max_steps = max_steps.clamp(1, 10);
        self
    }

    pub fn with_step_timeout(mut self, timeout: Duration) -> Self {
        self.step_timeout = timeout;
        self
    }

    pub fn max_steps(&self) -> usize {
        self.max_steps
    }

    pub fn step_timeout(&self) -> Duration {
        self.step_timeout
    }

    /// Dispatch a single tool execution within the shared ToolContext and measure observation & reflection.
    pub async fn execute_action(
        &self,
        action: StepActionType,
        args: serde_json::Value,
    ) -> (String, Option<String>) {
        let start = Instant::now();
        let (obs, refl) = match action {
            StepActionType::SearchInventory => {
                let parsed: Result<SearchInventoryArgs, _> = serde_json::from_value(args.clone());
                match parsed {
                    Ok(parsed_args) => {
                        let tool = SearchInventoryTool {
                            ctx: self.tool_ctx.clone(),
                        };
                        match tool.call(parsed_args).await {
                            Ok(res) => {
                                if res.contains("未找到相关商品")
                                    || res.contains("0 件")
                                    || res.contains("No items found")
                                {
                                    (
                                        res,
                                        Some(
                                            "搜索结果为空，可尝试放宽关键词或更换分类重试"
                                                .to_string(),
                                        ),
                                    )
                                } else {
                                    (res, None)
                                }
                            }
                            Err(e) => (
                                format!("搜索出错: {}", e),
                                Some("工具调用异常，建议调整参数".to_string()),
                            ),
                        }
                    }
                    Err(e) => (
                        format!("参数解析失败: {}", e),
                        Some("提供的搜索参数格式不正确".to_string()),
                    ),
                }
            }
            StepActionType::GetListingDetails => {
                let parsed: Result<GetListingDetailsArgs, _> = serde_json::from_value(args.clone());
                match parsed {
                    Ok(parsed_args) => {
                        let tool = GetListingDetailsTool {
                            ctx: self.tool_ctx.clone(),
                        };
                        match tool.call(parsed_args).await {
                            Ok(res) => (res, None),
                            Err(e) => (
                                format!("获取详情失败: {}", e),
                                Some("商品可能已下架或不存在".to_string()),
                            ),
                        }
                    }
                    Err(e) => (
                        format!("参数解析失败: {}", e),
                        Some("无效的商品ID参数".to_string()),
                    ),
                }
            }
            StepActionType::GetUserPosts => {
                let parsed: Result<GetUserPostsArgs, _> = serde_json::from_value(args.clone());
                match parsed {
                    Ok(parsed_args) => {
                        let tool = GetUserPostsTool {
                            ctx: self.tool_ctx.clone(),
                        };
                        match tool.call(parsed_args).await {
                            Ok(res) => (res, None),
                            Err(e) => (format!("获取用户帖子失败: {}", e), None),
                        }
                    }
                    Err(e) => (format!("参数解析失败: {}", e), None),
                }
            }
            StepActionType::FindRelatedPosts => {
                let parsed: Result<FindRelatedPostsArgs, _> = serde_json::from_value(args.clone());
                match parsed {
                    Ok(parsed_args) => {
                        let tool = FindRelatedPostsTool {
                            ctx: self.tool_ctx.clone(),
                        };
                        match tool.call(parsed_args).await {
                            Ok(res) => (res, None),
                            Err(e) => (format!("查找相似帖子失败: {}", e), None),
                        }
                    }
                    Err(e) => (format!("参数解析失败: {}", e), None),
                }
            }
            StepActionType::GetComments => {
                let parsed: Result<GetCommentsArgs, _> = serde_json::from_value(args.clone());
                match parsed {
                    Ok(parsed_args) => {
                        let tool = GetCommentsTool {
                            ctx: self.tool_ctx.clone(),
                        };
                        match tool.call(parsed_args).await {
                            Ok(res) => (res, None),
                            Err(e) => (format!("获取留言失败: {}", e), None),
                        }
                    }
                    Err(e) => (format!("参数解析失败: {}", e), None),
                }
            }
            StepActionType::DraftMessage => {
                let parsed: Result<DraftMessageArgs, _> = serde_json::from_value(args.clone());
                match parsed {
                    Ok(parsed_args) => {
                        let tool = DraftMessageTool {
                            ctx: self.tool_ctx.clone(),
                        };
                        match tool.call(parsed_args).await {
                            Ok(res) => (res, None),
                            Err(e) => (format!("生成草稿失败: {}", e), None),
                        }
                    }
                    Err(e) => (format!("参数解析失败: {}", e), None),
                }
            }
            StepActionType::GetMyListings => {
                let parsed: Result<GetMyListingsArgs, _> = serde_json::from_value(args.clone());
                match parsed {
                    Ok(parsed_args) => {
                        let tool = GetMyListingsTool {
                            ctx: self.tool_ctx.clone(),
                        };
                        match tool.call(parsed_args).await {
                            Ok(res) => (res, None),
                            Err(e) => (format!("获取我的发布失败: {}", e), None),
                        }
                    }
                    Err(e) => (format!("参数解析失败: {}", e), None),
                }
            }
            StepActionType::CreateListing => {
                let parsed: Result<CreateListingArgs, _> = serde_json::from_value(args.clone());
                match parsed {
                    Ok(parsed_args) => {
                        let tool = CreateListingTool {
                            ctx: self.tool_ctx.clone(),
                        };
                        match tool.call(parsed_args).await {
                            Ok(res) => (res, None),
                            Err(e) => (
                                format!("发布闲置失败: {}", e),
                                Some("请检查价格与描述是否合规".to_string()),
                            ),
                        }
                    }
                    Err(e) => (format!("参数解析失败: {}", e), None),
                }
            }
            StepActionType::UpdateListing => {
                let parsed: Result<crate::agents::tools::UpdateListingArgs, _> =
                    serde_json::from_value(args.clone());
                match parsed {
                    Ok(parsed_args) => {
                        let tool = crate::agents::tools::UpdateListingTool {
                            ctx: self.tool_ctx.clone(),
                        };
                        match tool.call(parsed_args).await {
                            Ok(res) => (res, None),
                            Err(e) => (format!("修改商品计划失败: {}", e), None),
                        }
                    }
                    Err(e) => (format!("参数解析失败: {}", e), None),
                }
            }
            StepActionType::DeleteListing => {
                let parsed: Result<DeleteListingArgs, _> = serde_json::from_value(args.clone());
                match parsed {
                    Ok(parsed_args) => {
                        let tool = DeleteListingTool {
                            ctx: self.tool_ctx.clone(),
                        };
                        match tool.call(parsed_args).await {
                            Ok(res) => (res, None),
                            Err(e) => (format!("删除商品计划失败: {}", e), None),
                        }
                    }
                    Err(e) => (format!("参数解析失败: {}", e), None),
                }
            }
            StepActionType::PurchaseItem => {
                let parsed: Result<PurchaseItemIntentArgs, _> =
                    serde_json::from_value(args.clone());
                match parsed {
                    Ok(parsed_args) => {
                        let tool = PurchaseItemIntentTool {
                            ctx: self.tool_ctx.clone(),
                        };
                        match tool.call(parsed_args).await {
                            Ok(res) => (res, None),
                            Err(e) => (format!("发起购买意向失败: {}", e), None),
                        }
                    }
                    Err(e) => (format!("参数解析失败: {}", e), None),
                }
            }
            StepActionType::NegotiatePrice => {
                let parsed: Result<NegotiateItemArgs, _> = serde_json::from_value(args.clone());
                match parsed {
                    Ok(parsed_args) => {
                        let tool = NegotiateItemTool {
                            ctx: self.tool_ctx.clone(),
                        };
                        match tool.call(parsed_args).await {
                            Ok(res) => (res, None),
                            Err(e) => (format!("发起议价意向失败: {}", e), None),
                        }
                    }
                    Err(e) => (format!("参数解析失败: {}", e), None),
                }
            }
            StepActionType::FinalAnswer => {
                let answer = args
                    .get("answer")
                    .and_then(|v| v.as_str())
                    .unwrap_or("任务已完成")
                    .to_string();
                (answer, None)
            }
            StepActionType::Unknown(cmd) => (
                format!("未知的操作类型: {}", cmd),
                Some("请选择合法的工具类型进行调用".to_string()),
            ),
        };
        tracing::debug!(elapsed_ms = start.elapsed().as_millis(), "Action executed");
        (obs, refl)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_step_action_type_parsing() {
        assert_eq!(
            "search_inventory".parse::<StepActionType>().unwrap(),
            StepActionType::SearchInventory
        );
        assert_eq!(
            "search".parse::<StepActionType>().unwrap(),
            StepActionType::SearchInventory
        );
        assert_eq!(
            "create_listing".parse::<StepActionType>().unwrap(),
            StepActionType::CreateListing
        );
        assert_eq!(
            "update_listing".parse::<StepActionType>().unwrap(),
            StepActionType::UpdateListing
        );
        assert_eq!(
            "final_answer".parse::<StepActionType>().unwrap(),
            StepActionType::FinalAnswer
        );
    }

    #[test]
    fn test_high_risk_classification() {
        assert!(!StepActionType::SearchInventory.is_high_risk());
        assert!(!StepActionType::CreateListing.is_high_risk());
        assert!(StepActionType::UpdateListing.is_high_risk());
        assert!(StepActionType::DeleteListing.is_high_risk());
        assert!(StepActionType::PurchaseItem.is_high_risk());
        assert!(StepActionType::NegotiatePrice.is_high_risk());
    }
}
