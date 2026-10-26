//! Local HTTP/UI fixture with deterministic model output, no account seeding,
//! and no external provider calls. See docs/architecture-compliance-audit.md.

use anyhow::{ensure, Result};
use async_trait::async_trait;
use futures::Stream;
use goods4ncu::api::{ApiAgents, ApiInfrastructure, ApiSecrets, AppState};
use goods4ncu::llm::{
    AgentModelChunk, AgentStreamChunk, EmbeddingGenerator, EmbeddingModelMetadata, LlmProvider,
    MarketplaceAgent, ReplyAssistant,
};
use goods4ncu::repositories::{
    PostgresAuthRepository, PostgresListingRepository, PostgresOrderRepository,
    PostgresUserRepository,
};
use goods4ncu::services;
use rig::completion::Message;
use std::{pin::Pin, sync::Arc, time::Duration};

struct FixtureModel;

#[async_trait]
impl EmbeddingGenerator for FixtureModel {
    async fn generate(&self, _text: &str) -> Result<Vec<f64>> {
        Ok(vec![0.0; 768])
    }
}

#[async_trait]
impl LlmProvider for FixtureModel {
    fn name(&self) -> &str {
        "local-browser-fixture"
    }

    fn model(&self) -> &str {
        "deterministic-text"
    }

    async fn create_marketplace_agent(
        self: Arc<Self>,
        _pool: &sqlx::PgPool,
        _user_id: Option<String>,
        _campus_id: Option<uuid::Uuid>,
        _idempotency_key: Option<String>,
        _moderation: services::moderation::ModerationService,
    ) -> Result<Box<dyn MarketplaceAgent>> {
        Ok(Box::new(Self))
    }

    async fn create_reply_assistant(self: Arc<Self>) -> Result<Box<dyn ReplyAssistant>> {
        Ok(Box::new(Self))
    }

    fn embedding_generator(self: Arc<Self>) -> Arc<dyn EmbeddingGenerator> {
        self
    }

    fn embedding_metadata(&self) -> EmbeddingModelMetadata {
        EmbeddingModelMetadata {
            provider: "local-browser-fixture",
            model: "zero-vector",
            dimensions: 768,
        }
    }
}

#[async_trait]
impl MarketplaceAgent for FixtureModel {
    async fn prompt(&self, _message: String) -> Result<String> {
        Ok("本地模拟回复，不代表真实模型能力。".to_string())
    }

    async fn prompt_with_history(&self, message: String, _history: Vec<Message>) -> Result<String> {
        MarketplaceAgent::prompt(self, message).await
    }

    fn stream_chat(
        &self,
        _message: String,
        _history: Vec<Message>,
    ) -> Pin<Box<dyn Stream<Item = Result<AgentStreamChunk>> + Send>> {
        Box::pin(futures::stream::once(async {
            Ok(AgentStreamChunk::Text("本地模拟回复。".to_string()))
        }))
    }

    fn stream_model_step(
        &self,
        _message: Message,
        _history: Vec<Message>,
    ) -> Pin<Box<dyn Stream<Item = Result<AgentModelChunk>> + Send>> {
        Box::pin(async_stream::stream! {
            for index in 1..=100 {
                tokio::time::sleep(Duration::from_millis(100)).await;
                yield Ok(AgentModelChunk::Text(format!("验收片段{index}。")));
            }
            yield Ok(AgentModelChunk::Stop);
        })
    }

    async fn execute_tool(
        &self,
        _name: &str,
        _arguments: &str,
    ) -> Result<goods4ncu::agents::runtime::envelope::ToolResultEnvelope> {
        anyhow::bail!("the browser fixture does not execute tools")
    }
}

#[async_trait]
impl ReplyAssistant for FixtureModel {
    async fn prompt(&self, message: String) -> Result<String> {
        MarketplaceAgent::prompt(self, message).await
    }
}

fn validate_target(database_url: &str, production: bool) -> Result<()> {
    ensure!(!production, "the browser fixture cannot run in production");
    let target = reqwest::Url::parse(database_url)?;
    ensure!(
        matches!(target.host_str(), Some("localhost" | "127.0.0.1" | "[::1]")),
        "the browser fixture requires a loopback database"
    );
    ensure!(
        target.path().trim_start_matches('/').contains("_test"),
        "the browser fixture requires a database name containing _test"
    );
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let database_url = std::env::var("AUDIT_DATABASE_URL")?;
    validate_target(&database_url, goods4ncu::config::running_in_production())?;
    let pool = goods4ncu::db::init_db(&database_url).await?;
    let config = goods4ncu::config::AppConfig::test_defaults();
    let limiter = goods4ncu::middleware::rate_limit::RateLimiterFactory::new(1000, 60);
    let state = AppState {
        secrets: ApiSecrets {
            jwt_secret: uuid::Uuid::new_v4().to_string(),
            gemini_api_key: String::new(),
            oss_endpoint: "http://127.0.0.1:1".to_string(),
            oss_bucket: "audit-test".to_string(),
            oss_role_arn: None,
            oss_access_key_id: None,
            oss_access_key_secret: None,
        },
        infra: ApiInfrastructure {
            db: pool.clone(),
            rate_limit: goods4ncu::middleware::rate_limit::RateLimitStateHandle::new(
                limiter.build_local(),
            ),
            notification: services::notification::NotificationService::new(pool.clone()),
            ws_hub: Arc::new(goods4ncu::api::ws::WsHub::new()),
            metrics: Arc::new(goods4ncu::api::metrics::MetricsService::new()),
            order_service: services::order::OrderService::new(pool.clone()),
            admin_service: services::admin::AdminService::new(pool.clone()),
            moderation: services::moderation::ModerationService::new(&config),
            token_denylist: services::token_denylist::TokenDenylist::new(),
            media_signer: None,
            shutdown: goods4ncu::lifecycle::ShutdownSignal::never(),
            deployment_profile: goods4ncu::config::DeploymentProfile::Local,
            #[cfg(feature = "redis")]
            replicated_runtime: None,
        },
        agents: ApiAgents {
            llm_provider: Arc::new(FixtureModel),
            tri_tier_router: goods4ncu::agents::router::TriTierIntentRouter::new(
                goods4ncu::agents::router::IntentRouter::default(),
                None,
                None,
            ),
            agent_enabled: true,
        },
        listing_repo: PostgresListingRepository::new(pool.clone()),
        user_repo: PostgresUserRepository::new(pool.clone()),
        auth_repo: PostgresAuthRepository::new(pool.clone()),
        order_repo: PostgresOrderRepository::new(pool),
    };
    let router = goods4ncu::api::create_router(
        state,
        &[
            "http://127.0.0.1:3001".to_string(),
            "http://localhost:3001".to_string(),
        ],
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:3000").await?;
    eprintln!("Local browser fixture: http://127.0.0.1:3000 (simulated model; no account seeding)");
    axum::serve(listener, router).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures::StreamExt;

    #[test]
    fn fixture_rejects_remote_non_test_and_production_targets() {
        for (url, production) in [
            ("postgres://db.example/audit_test", false),
            ("postgres://127.0.0.1/goods4ncu", false),
            ("postgres://127.0.0.1/audit_test", true),
        ] {
            assert!(validate_target(url, production).is_err());
        }
        assert!(validate_target("postgres://127.0.0.1/audit_test", false).is_ok());
        assert!(validate_target("postgres://[::1]/audit_test", false).is_ok());
    }

    #[tokio::test(start_paused = true)]
    async fn fixture_streams_deterministic_text_and_one_stop_without_tools() {
        let chunks: Vec<_> = FixtureModel
            .stream_model_step(Message::user("hello"), vec![])
            .collect()
            .await;
        assert_eq!(chunks.len(), 101);
        for (index, chunk) in chunks.iter().enumerate().take(100) {
            assert!(
                matches!(chunk, Ok(AgentModelChunk::Text(text)) if text == &format!("验收片段{}。", index + 1))
            );
        }
        assert!(matches!(chunks.last(), Some(Ok(AgentModelChunk::Stop))));
    }
}
