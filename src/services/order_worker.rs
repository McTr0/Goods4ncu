//! Order lifecycle background worker.
//!
//! Good4NCU only records offline deal intent and seller confirmation. It does
//! not intermediate funds, verify handoff, or run payment/logistics timers. The
//! worker remains as a no-op compatibility task so startup wiring stays stable.

use crate::services::notification::NotificationBroadcast;
use sqlx::PgPool;
use std::time::Duration;
use tokio::time::interval;

pub async fn run(_db_pool: PgPool, _broadcast: NotificationBroadcast) {
    tracing::info!("Order lifecycle worker disabled for offline deal mode");
    let mut ticker = interval(Duration::from_secs(5 * 60));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        ticker.tick().await;
    }
}
