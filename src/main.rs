mod agents;
mod repositories;
mod services;

mod api;
mod categories;
mod cli;
mod config;
mod db;
mod lifecycle;
mod llm;
mod middleware;
#[cfg(test)]
mod test_infra;
mod utils;

use std::sync::Arc;

use crate::llm::LlmProvider;

fn default_env_filter() -> anyhow::Result<tracing_subscriber::EnvFilter> {
    let mut filter = tracing_subscriber::EnvFilter::from_default_env();
    for directive in ["goods4ncu=info", "hyper=warn", "tower=warn"] {
        let parsed = directive
            .parse()
            .map_err(|e| anyhow::anyhow!("invalid tracing directive '{directive}': {e}"))?;
        filter = filter.add_directive(parsed);
    }
    Ok(filter)
}

fn build_private_media_bucket(
    config: &config::AppConfig,
) -> Result<Option<services::storage::PrivateBucket>, anyhow::Error> {
    if !config.media_private_bucket {
        return Ok(None);
    }
    let (Some(access_key_id), Some(secret_access_key)) = (
        config.oss_access_key_id.clone(),
        config.oss_access_key_secret.clone(),
    ) else {
        return Err(anyhow::anyhow!(
            "MEDIA_PRIVATE_BUCKET=true requires OSS_ACCESS_KEY_ID and OSS_ACCESS_KEY_SECRET"
        ));
    };
    Ok(Some(services::storage::PrivateBucket {
        endpoint: config.oss_endpoint.clone(),
        bucket: config.oss_bucket.clone(),
        region: config.media_region.clone(),
        access_key_id,
        secret_access_key,
        path_style: config.media_path_style,
    }))
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
    let private_media_bucket = build_private_media_bucket(&config)?;
    tracing::info!(provider = %config.llm_provider, vector_dim = config.vector_dim, "Initializing LLM provider");

    // Metrics service — shared across all request handlers
    let metrics = Arc::new(api::metrics::MetricsService::new());
    let _ = api::metrics::GLOBAL_METRICS.set(Arc::clone(&metrics));
    tracing::info!("Metrics service initialized");

    // Single PgPool for relational + vector data (pgvector lives in the same Postgres instance)
    let db_pool = db::init_db(&config.database_url).await?;
    db::assert_documents_embedding_dim(&db_pool, config.vector_dim).await?;
    db::assert_uuid_shadow_drift_zero(&db_pool).await?;
    // A production database must not carry the demo seed accounts: they share a
    // published password and include a platform admin.
    db::assert_no_demo_seed_in_production(&db_pool, config::running_in_production()).await?;

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

    // One shutdown flag drives readiness, the HTTP listener and every worker,
    // so a SIGTERM cannot leave part of the process draining and part of it
    // still accepting new work.
    let shutdown_controller = lifecycle::ShutdownController::new();
    let shutdown = shutdown_controller.signal();

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

    // Notification pushes are delivered via the transactional outbox; the
    // direct broadcast callback remains only for ephemeral worker events.
    let notification = crate::services::notification::NotificationService::new(db_pool.clone());

    // Outbox worker: dispatches durable events (currently notification pushes)
    // enqueued in the same transaction as the business write.
    struct WsPushDispatcher;
    #[async_trait::async_trait]
    impl services::outbox::OutboxDispatcher for WsPushDispatcher {
        async fn dispatch(&self, topic: &str, payload: &serde_json::Value) -> anyhow::Result<()> {
            match topic {
                services::outbox::TOPIC_NOTIFICATION_PUSH => {
                    let user_id = payload["user_id"]
                        .as_str()
                        .ok_or_else(|| anyhow::anyhow!("missing user_id"))?;
                    let message = payload["message"].to_string();
                    let campus_id = payload["campus_id"]
                        .as_str()
                        .and_then(|value| uuid::Uuid::parse_str(value).ok());
                    // Idempotent for our purposes: re-delivery re-sends the
                    // same notification id, which clients key on.
                    if let Some(campus_id) = campus_id {
                        api::ws::broadcast_to_user_in_campus(user_id, campus_id, &message);
                    } else {
                        api::ws::broadcast_to_user(user_id, &message);
                    }
                    Ok(())
                }
                other => {
                    // Unknown topics fail (and eventually dead-letter) loudly
                    // instead of being silently dropped as "processed".
                    anyhow::bail!("no dispatcher for outbox topic '{other}'")
                }
            }
        }
    }
    let outbox_worker_handle = tokio::spawn(services::outbox::run_outbox_worker(
        db_pool.clone(),
        Arc::new(WsPushDispatcher),
        shutdown.clone(),
    ));

    let embedding_metadata = llm_provider.embedding_metadata();
    let embedding_generator = Arc::clone(&llm_provider).embedding_generator();
    let embedding_worker_handle = tokio::spawn(services::embedding_worker::run_embedding_worker(
        db_pool.clone(),
        embedding_generator,
        embedding_metadata,
        shutdown.clone(),
    ));

    let router = crate::agents::router::IntentRouter::new(config.blocked_keywords.clone());

    // HITL expiration worker: scans every 10 min for pending requests > 48h old.
    let hitl_expire_handle = tokio::spawn(services::hitl_expire::run(
        db_pool.clone(),
        Arc::clone(&broadcast),
        shutdown.clone(),
    ));

    // Order lifecycle worker is a no-op in offline deal mode.
    let order_worker_handle = tokio::spawn(services::order_worker::run(
        db_pool.clone(),
        Arc::clone(&broadcast),
        shutdown.clone(),
    ));

    // Content moderation worker: polls pending image moderation jobs.
    let moderation_worker_cfg = services::moderation_worker::ModerationApiConfig::from_parts(
        config.moderation_image_enabled,
        config.moderation_image_api_url.clone(),
        config.moderation_image_api_key.clone(),
    )
    .with_media_bucket(private_media_bucket.clone(), config.media_url_ttl_secs);
    let moderation_worker_handle =
        tokio::spawn(services::moderation_worker::run_moderation_worker(
            db_pool.clone(),
            moderation_worker_cfg,
            shutdown.clone(),
        ));

    // Revoked token cleanup worker: prunes expired DB denylist rows hourly.
    let token_cleanup_handle = tokio::spawn(services::token_denylist::run_cleanup_worker(
        db_pool.clone(),
        shutdown.clone(),
    ));

    let chat_expiry_handle = tokio::spawn(services::chat_expire::run_chat_expiry_worker(
        db_pool.clone(),
        shutdown.clone(),
    ));

    // Durable AgentRun reconciliation covers process restarts and request
    // tasks that disappear before their in-process stream watchdog can write.
    let agent_run_reconciler_handle = tokio::spawn(services::agent_run_reconciler::run(
        db_pool.clone(),
        shutdown.clone(),
    ));

    // Undo retention worker: prunes reversible_actions past their retention.
    let undo_prune_handle = tokio::spawn(services::undo::run_prune_worker(
        db_pool.clone(),
        shutdown.clone(),
    ));

    // Intent expiry worker: retires intents whose moment has passed.
    let intent_expiry_handle = tokio::spawn(services::intent::run_expiry_worker(
        db_pool.clone(),
        shutdown.clone(),
    ));

    // Space formation worker: assembles spaces from intent density and archives
    // the ones whose reason is spent.
    let space_formation_handle = tokio::spawn(services::aggregation::run_formation_worker(
        db_pool.clone(),
        shutdown.clone(),
    ));

    // Multi-replica realtime: when REDIS_URL is configured, WS broadcasts
    // route through Redis pub/sub so any replica can deliver to the sockets it
    // holds. Without it (or without the `redis` feature) delivery stays local.
    #[cfg(feature = "redis")]
    let ws_fanout_handle = config
        .redis_url
        .clone()
        .map(|redis_url| tokio::spawn(services::ws_fanout::run(redis_url, shutdown.clone())));

    // Build repository layer (concrete types - simpler than dyn traits for now)
    let listing_repo = repositories::PostgresListingRepository::new(db_pool.clone());
    let user_repo = repositories::PostgresUserRepository::new(db_pool.clone());
    let chat_repo = repositories::PostgresChatRepository::new(db_pool.clone());
    let auth_repo = repositories::PostgresAuthRepository::new(db_pool.clone());
    let order_repo = repositories::PostgresOrderRepository::new(db_pool.clone());

    let token_denylist = services::token_denylist::TokenDenylist::new();

    // Private-bucket media: build the presigner when enabled and fully
    // configured. Missing credentials with the flag on is a configuration
    // error, not a silent downgrade to public serving.
    let media_signer = if let Some(bucket) = private_media_bucket.clone() {
        tracing::info!(
            bucket = %config.oss_bucket,
            ttl_secs = config.media_url_ttl_secs,
            "Private media bucket enabled; persona uploads and approved media use presigned URLs"
        );
        Some(Arc::new(api::MediaSigner {
            bucket,
            ttl_secs: config.media_url_ttl_secs,
        }))
    } else {
        None
    };

    // Revoked shared files retain their server-generated key until the
    // durable cleanup worker receives a successful platform DELETE. Reuse the
    // deployment's long-lived OSS credentials (the same credentials used to
    // obtain upload STS tokens); without them the worker stays explicitly
    // disabled rather than claiming cleanup succeeded.
    let shared_object_cleanup_bucket = match (
        config.oss_access_key_id.clone(),
        config.oss_access_key_secret.clone(),
    ) {
        (Some(access_key_id), Some(secret_access_key)) => Some(services::storage::PrivateBucket {
            endpoint: config.oss_endpoint.clone(),
            bucket: config.oss_bucket.clone(),
            region: config.media_region.clone(),
            access_key_id,
            secret_access_key,
            path_style: config.media_path_style,
        }),
        _ => None,
    };
    let shared_object_cleanup_handle = tokio::spawn(services::shared_object_cleanup::run(
        db_pool.clone(),
        services::shared_object_cleanup::SharedObjectCleanupConfig {
            bucket: shared_object_cleanup_bucket,
            request_timeout_secs: 10,
        },
        shutdown.clone(),
    ));

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
                #[cfg(feature = "redis")]
                let handle = if let Some(redis_url) = config.redis_url.as_deref() {
                    match factory.build_redis(redis_url).await {
                        Ok(limiter) => {
                            tracing::info!("Distributed rate limiting enabled (Redis)");
                            middleware::rate_limit::RateLimitStateHandle::new(limiter)
                        }
                        Err(error) => {
                            // Fail closed to local limiting rather than
                            // refusing to boot: a Redis outage should degrade
                            // per-instance, not take the API down.
                            tracing::error!(%error, "Redis rate limiter unavailable; using local limiter");
                            middleware::rate_limit::RateLimitStateHandle::new(factory.build_local())
                        }
                    }
                } else {
                    middleware::rate_limit::RateLimitStateHandle::new(factory.build_local())
                };
                #[cfg(not(feature = "redis"))]
                let handle =
                    middleware::rate_limit::RateLimitStateHandle::new(factory.build_local());
                handle
            },
            notification,
            ws_connections: ws_state,
            metrics: Arc::clone(&metrics),
            order_service: services::order::OrderService::new(db_pool.clone()),
            admin_service,
            moderation: services::moderation::ModerationService::new(&config),
            token_denylist: token_denylist.clone(),
            secret_chat_new_sessions_enabled: config.secret_chat_new_sessions_enabled,
            media_signer: media_signer.clone(),
            shutdown: shutdown.clone(),
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
    let denylist_shutdown = shutdown.clone();
    let denylist_handle = tokio::spawn(async move {
        while lifecycle::sleep_or_shutdown(
            tokio::time::Duration::from_secs(300),
            &denylist_shutdown,
        )
        .await
        .should_continue()
        {
            denylist_cleanup.cleanup_expired();
        }
    });

    let bind_addr = format!("{}:{}", config.server_host, config.server_port);
    let listener = tokio::net::TcpListener::bind(&bind_addr).await?;
    tracing::info!(addr = %bind_addr, "Web Server started");

    // Axum stops accepting once this future resolves, then waits for in-flight
    // requests. Delaying it by the drain grace period gives the load balancer
    // time to observe the failing readiness probe and stop routing here, so
    // requests are never accepted onto a socket that is about to close.
    let drain_grace = tokio::time::Duration::from_secs(config.shutdown_drain_secs);
    let listener_shutdown = shutdown.clone();
    let server_handle = tokio::spawn(async move {
        let service = app.into_make_service_with_connect_info::<std::net::SocketAddr>();
        let result = axum::serve(listener, service)
            .with_graceful_shutdown(async move {
                listener_shutdown.wait().await;
                if !drain_grace.is_zero() {
                    tracing::info!(
                        drain_secs = drain_grace.as_secs(),
                        "Draining: readiness now failing, still serving in-flight traffic"
                    );
                    tokio::time::sleep(drain_grace).await;
                }
                tracing::info!("Drain grace elapsed, closing listener");
            })
            .await;
        if let Err(e) = result {
            tracing::error!(%e, "Server error");
        }
    });

    let signal_name = lifecycle::terminate_signal().await;
    tracing::info!(
        signal = signal_name,
        "Termination signal received, draining"
    );
    shutdown_controller.trigger();

    // Bound the whole drain so a stuck request cannot hold the process past the
    // orchestrator's grace period and turn an orderly stop into a SIGKILL.
    let shutdown_timeout = tokio::time::Duration::from_secs(config.shutdown_timeout_secs);
    let graceful = async {
        if let Err(e) = server_handle.await {
            tracing::error!(%e, "HTTP server task failed during shutdown");
        }
        tracing::info!("HTTP listener closed, waiting for background workers");

        // Workers stop between iterations, so joining them means no scan is cut
        // off mid-transaction.
        let workers = tokio::join!(
            hitl_expire_handle,
            order_worker_handle,
            moderation_worker_handle,
            shared_object_cleanup_handle,
            token_cleanup_handle,
            chat_expiry_handle,
            agent_run_reconciler_handle,
            denylist_handle,
            outbox_worker_handle,
            undo_prune_handle,
            intent_expiry_handle,
            space_formation_handle,
            embedding_worker_handle,
        );
        #[cfg(feature = "redis")]
        if let Some(handle) = ws_fanout_handle {
            if let Err(e) = handle.await {
                tracing::error!(worker = "ws_fanout", %e, "Worker task failed during shutdown");
            }
        }
        for (name, result) in [
            ("hitl_expire", workers.0),
            ("order_worker", workers.1),
            ("moderation_worker", workers.2),
            ("shared_object_cleanup", workers.3),
            ("token_cleanup", workers.4),
            ("chat_expiry", workers.5),
            ("agent_run_reconciler", workers.6),
            ("denylist_cleanup", workers.7),
            ("outbox", workers.8),
            ("undo_prune", workers.9),
            ("intent_expiry", workers.10),
            ("space_formation", workers.11),
            ("embedding_worker", workers.12),
        ] {
            if let Err(e) = result {
                tracing::error!(worker = name, %e, "Worker task failed during shutdown");
            }
        }
    };

    if tokio::time::timeout(shutdown_timeout, graceful)
        .await
        .is_err()
    {
        tracing::warn!(
            timeout_secs = shutdown_timeout.as_secs(),
            "Graceful shutdown timed out; abandoning remaining work"
        );
    }

    // The event loop drains last: workers and handlers can still emit events
    // while they finish, and aborting it earlier would silently drop them.
    event_loop_handle.abort();

    // Close the pool so Postgres reclaims connections promptly instead of
    // waiting for TCP timeouts, which otherwise slow the next deploy's
    // connection budget.
    db_pool.close().await;

    tracing::info!("Shutdown complete.");
    Ok(())
}
