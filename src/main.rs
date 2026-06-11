mod agents;
mod repositories;
mod services;

mod api;
mod cli;
mod config;
mod db;
mod llm;
mod middleware;
#[cfg(test)]
mod test_infra;
mod utils;

use std::sync::Arc;

use crate::llm::LlmProvider;

fn default_env_filter() -> anyhow::Result<tracing_subscriber::EnvFilter> {
    let mut filter = tracing_subscriber::EnvFilter::from_default_env();
    for directive in ["good4ncu=info", "hyper=warn", "tower=warn"] {
        let parsed = directive
            .parse()
            .map_err(|e| anyhow::anyhow!("invalid tracing directive '{directive}': {e}"))?;
        filter = filter.add_directive(parsed);
    }
    Ok(filter)
}

#[tokio::main]
async fn main() -> Result<(), anyhow::Error> {
    dotenvy::dotenv().ok();

    // Check for CLI commands first
    let cli_args: Vec<String> = std::env::args().collect();
    if cli::run_cli(&cli_args).await? {
        return Ok(());
    }

    // Initialize structured JSON logging for production observability
    tracing_subscriber::fmt()
        .with_env_filter(default_env_filter()?)
        .with_target(true)
        .with_thread_ids(true)
        .json()
        .init();

    // Load unified configuration at startup — fail fast if env vars are missing.
    // Merges TOML config file with env vars (env vars take precedence).
    let config = config::AppConfig::load_with_file(None);
    tracing::info!(provider = %config.llm_provider, vector_dim = config.vector_dim, "Initializing LLM provider");

    // Metrics service — shared across all request handlers
    let metrics = Arc::new(api::metrics::MetricsService::new());
    let _ = api::metrics::GLOBAL_METRICS.set(Arc::clone(&metrics));
    tracing::info!("Metrics service initialized");

    // Single PgPool for relational + vector data (pgvector lives in the same Postgres instance)
    let db_pool = db::init_db(&config.database_url).await?;
    db::assert_documents_embedding_dim(&db_pool, config.vector_dim).await?;
    db::assert_uuid_shadow_drift_zero(&db_pool).await?;

    // Build the LLM provider based on configuration
    let llm_provider: Arc<dyn LlmProvider> = match config.llm_provider.as_str() {
        "gemini" => {
            let api_key = &config.gemini_api_key;
            if api_key.is_empty() {
                return Err(anyhow::anyhow!(
                    "GEMINI_API_KEY must be set when LLM_PROVIDER=gemini"
                ));
            }
            Arc::new(crate::llm::gemini::GeminiProvider::new_with_model(
                api_key,
                config.vector_dim,
                &config.llm_model,
            )?)
        }
        "minimax" => {
            let api_key = config.minimax_api_key.as_ref().ok_or_else(|| {
                anyhow::anyhow!("MINIMAX_API_KEY must be set when LLM_PROVIDER=minimax")
            })?;
            let base_url = config.minimax_api_base_url.as_deref();
            Arc::new(crate::llm::minimax::MiniMaxProvider::new_with_model(
                api_key,
                base_url,
                &config.llm_model,
                &config.gemini_api_key,
                config.vector_dim,
            )?)
        }
        provider if config::is_openai_compatible_provider(provider) => {
            let api_key = config.llm_api_key.as_ref().ok_or_else(|| {
                anyhow::anyhow!(
                    "LLM_API_KEY or provider-specific key must be set when LLM_PROVIDER={}",
                    provider
                )
            })?;
            Arc::new(
                crate::llm::openai_compatible::OpenAiCompatibleProvider::new(
                    provider,
                    api_key,
                    config.llm_base_url.as_deref(),
                    &config.llm_model,
                    &config.gemini_api_key,
                    config.vector_dim,
                )?,
            )
        }
        provider => {
            return Err(anyhow::anyhow!(
                "Unsupported LLM_PROVIDER after config validation: {}",
                provider
            ));
        }
    };

    let (services, event_rx) = services::ServiceManager::new(db_pool.clone());
    let event_tx = services.event_tx.clone();
    let admin_service = services.admin.clone();

    let event_loop_handle = tokio::spawn(async move {
        services.run_event_loop(event_rx).await;
    });

    // WebSocket global state — shared across all connections.
    let ws_state = api::ws::new_ws_state();

    // Shared broadcast callback for WS push — passed to both NotificationService and hitl_expire.
    let broadcast: crate::services::notification::NotificationBroadcast =
        Arc::new(|user_id: String, payload: String| {
            api::ws::broadcast_to_user(&user_id, &payload);
        });

    // Build the notification service with WebSocket broadcast wired in.
    let notification = crate::services::notification::NotificationService::new(db_pool.clone())
        .with_broadcast(Arc::clone(&broadcast));

    let router = crate::agents::router::IntentRouter::new(config.blocked_keywords.clone());

    // HITL expiration worker: scans every 10 min for pending requests > 48h old.
    let hitl_expire_handle = tokio::spawn(services::hitl_expire::run(
        db_pool.clone(),
        Arc::clone(&broadcast),
    ));

    // Order lifecycle worker: 30-min payment timeout, 7-day auto-confirm.
    let order_worker_handle = tokio::spawn(services::order_worker::run(
        db_pool.clone(),
        Arc::clone(&broadcast),
    ));

    // Content moderation worker: polls pending image moderation jobs.
    let moderation_worker_cfg = services::moderation_worker::ModerationApiConfig::from_parts(
        config.moderation_image_enabled,
        config.moderation_image_api_url.clone(),
        config.moderation_image_api_key.clone(),
    );
    let moderation_worker_handle = tokio::spawn(
        services::moderation_worker::run_moderation_worker(db_pool.clone(), moderation_worker_cfg),
    );

    // Revoked token cleanup worker: prunes expired DB denylist rows hourly.
    let token_cleanup_handle = tokio::spawn(services::token_denylist::run_cleanup_worker(
        db_pool.clone(),
    ));

    // Build repository layer (concrete types - simpler than dyn traits for now)
    let listing_repo = repositories::PostgresListingRepository::new(db_pool.clone());
    let user_repo = repositories::PostgresUserRepository::new(db_pool.clone());
    let chat_repo = repositories::PostgresChatRepository::new(db_pool.clone());
    let auth_repo = repositories::PostgresAuthRepository::new(db_pool.clone());
    let order_repo = repositories::PostgresOrderRepository::new(db_pool.clone());

    let token_denylist = services::token_denylist::TokenDenylist::new();

    let app_state = api::AppState {
        secrets: api::ApiSecrets {
            jwt_secret: config.jwt_secret.clone(),
            jwt_secret_old: config.jwt_secret_old.clone(),
            gemini_api_key: config.gemini_api_key.clone(),
            oss_endpoint: config.oss_endpoint.clone(),
            oss_bucket: config.oss_bucket.clone(),
            oss_role_arn: config.oss_role_arn.clone(),
            oss_access_key_id: config.oss_access_key_id.clone(),
            oss_access_key_secret: config.oss_access_key_secret.clone(),
        },
        infra: api::ApiInfrastructure {
            db: db_pool.clone(),
            event_tx: event_tx.clone(),
            rate_limit: {
                let factory = middleware::rate_limit::RateLimiterFactory::new(
                    config.rate_limit_max_requests,
                    config.rate_limit_window_secs,
                );
                middleware::rate_limit::RateLimitStateHandle::new(factory.build_local())
            },
            notification,
            ws_connections: ws_state,
            metrics: Arc::clone(&metrics),
            order_service: services::order::OrderService::new(db_pool.clone()),
            admin_service,
            moderation: services::moderation::ModerationService::new(&config),
            token_denylist: token_denylist.clone(),
        },
        agents: api::ApiAgents {
            llm_provider: Arc::clone(&llm_provider),
            router,
        },
        listing_repo,
        user_repo,
        chat_repo,
        auth_repo,
        order_repo,
    };

    let app = api::create_router(app_state, &config.cors_origins);

    // Periodic cleanup of expired denylist entries (every 5 minutes)
    let denylist_cleanup = token_denylist.clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(tokio::time::Duration::from_secs(300)).await;
            denylist_cleanup.cleanup_expired();
        }
    });

    let bind_addr = format!("{}:{}", config.server_host, config.server_port);
    let listener = tokio::net::TcpListener::bind(&bind_addr).await?;
    tracing::info!(addr = %bind_addr, "Web Server started");

    let server_handle = tokio::spawn(async move {
        if let Err(e) = axum::serve(listener, app).await {
            tracing::error!(%e, "Server error");
        }
    });

    // Wait for Ctrl+C to shut down gracefully
    tokio::signal::ctrl_c().await?;
    tracing::info!("Ctrl+C received, shutting down.");

    server_handle.abort();
    event_loop_handle.abort();
    hitl_expire_handle.abort();
    order_worker_handle.abort();
    moderation_worker_handle.abort();
    token_cleanup_handle.abort();

    // Gracefully close the DB pool so Postgres can cleanly收回所有连接
    // and flush any pending transaction results in the buffer.
    db_pool.close().await;

    tracing::info!("Shutdown complete.");
    Ok(())
}
