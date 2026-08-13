//! Durable cleanup for AgentRun rows abandoned by a process or request task.

use chrono::{Duration as ChronoDuration, Utc};
use sqlx::PgPool;
use std::time::Duration;

use crate::lifecycle::{tick_or_shutdown, ShutdownSignal};
use crate::services::agent_run::AgentRunService;

/// Keep this longer than the per-stream grace period so a healthy but slow
/// completion is not pre-empted. It also gives a restarted replica a bounded
/// window in which to reconcile rows left behind by the old process.
pub const STALE_RUN_MAX_AGE: Duration = Duration::from_secs(180);
const RECONCILIATION_INTERVAL: Duration = Duration::from_secs(30);
const RECONCILIATION_BATCH_SIZE: i64 = 100;

pub async fn run(db: PgPool, shutdown: ShutdownSignal) {
    let service = AgentRunService::new(db);
    let mut interval = tokio::time::interval(RECONCILIATION_INTERVAL);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    while tick_or_shutdown(&mut interval, &shutdown)
        .await
        .should_continue()
    {
        let cutoff = Utc::now()
            - ChronoDuration::from_std(STALE_RUN_MAX_AGE)
                .expect("AgentRun stale age must fit chrono duration");
        match service
            .reconcile_stale_started(cutoff, RECONCILIATION_BATCH_SIZE)
            .await
        {
            Ok(0) => {}
            Ok(reconciled) => tracing::info!(reconciled, "reconciled stale AgentRun rows"),
            Err(error) => tracing::error!(%error, "AgentRun reconciliation failed"),
        }
    }
    tracing::info!("AgentRun reconciliation worker stopped");
}
