//! Process lifecycle: OS signal handling, readiness gating and graceful shutdown.
//!
//! Container orchestrators stop a process by sending `SIGTERM` and only escalate
//! to `SIGKILL` after a grace period. A server that only waits on Ctrl+C is
//! terminated outright on every rolling deploy: in-flight responses are
//! truncated, and a request can die between a committed database write and the
//! response the client needs in order to observe it. Draining is therefore a
//! correctness concern, not only an availability one.
//!
//! The shutdown sequence built on this module:
//!
//! 1. `SIGTERM`/`SIGINT` arrives and the process flips to *draining*.
//! 2. `/api/readyz` starts failing so the load balancer stops routing new
//!    requests here, while `/api/livez` keeps succeeding so the orchestrator
//!    does not mistake an orderly drain for a crash and kill the pod early.
//! 3. After the drain grace period the listener stops accepting, and the
//!    requests already in flight are allowed to finish.
//! 4. Background workers observe the same signal and stop between iterations
//!    rather than mid-transaction.
//!
//! Everything is built on a single [`tokio::sync::watch`] channel so that a
//! signal delivered before a task starts waiting is still observed — a plain
//! broadcast or notify would lose that race during fast restarts.

use std::sync::Arc;
use std::time::Duration;

use tokio::sync::watch;

/// Owns the shutdown flag and can flip it.
///
/// Held by `main`; every other component gets a [`ShutdownSignal`] instead so
/// that only the process entry point decides when draining begins.
#[derive(Clone)]
pub struct ShutdownController {
    tx: Arc<watch::Sender<bool>>,
}

impl ShutdownController {
    pub fn new() -> Self {
        let (tx, _rx) = watch::channel(false);
        Self { tx: Arc::new(tx) }
    }

    /// Hand out an observer of this controller's shutdown flag.
    pub fn signal(&self) -> ShutdownSignal {
        ShutdownSignal {
            tx: Arc::clone(&self.tx),
        }
    }

    /// Begin draining. Returns `true` only for the call that flipped the flag,
    /// so a second signal (an impatient operator pressing Ctrl+C again) can be
    /// distinguished from the first and escalated instead of restarting the
    /// drain timer.
    pub fn trigger(&self) -> bool {
        !self.tx.send_replace(true)
    }
}

impl Default for ShutdownController {
    fn default() -> Self {
        Self::new()
    }
}

/// A cloneable observer of the process shutdown flag.
///
/// Holds the sender behind an `Arc` rather than a bare `watch::Receiver` so the
/// channel stays open for the lifetime of any observer. A receiver whose sender
/// has been dropped reports "closed", which is indistinguishable from "shutting
/// down" at the await point and would make request handlers drain spuriously.
#[derive(Clone)]
pub struct ShutdownSignal {
    tx: Arc<watch::Sender<bool>>,
}

impl ShutdownSignal {
    /// A signal that never fires. For tests and any code path that constructs
    /// application state without a running process supervisor.
    pub fn never() -> Self {
        ShutdownController::new().signal()
    }

    /// Whether the process has begun draining. Cheap enough for a health probe.
    pub fn is_draining(&self) -> bool {
        *self.tx.borrow()
    }

    /// Resolve once draining has begun, including when it began before this
    /// call. Safe to call from many tasks concurrently.
    pub async fn wait(&self) {
        let mut rx = self.tx.subscribe();
        if *rx.borrow() {
            return;
        }
        // `changed()` only errors when every sender is gone. This type keeps one
        // alive, so the loop ends via the flag rather than the error path.
        while rx.changed().await.is_ok() {
            if *rx.borrow_and_update() {
                return;
            }
        }
    }
}

impl Default for ShutdownSignal {
    fn default() -> Self {
        Self::never()
    }
}

/// What a background worker should do after waiting for its next turn.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkerTick {
    /// Run another iteration.
    Continue,
    /// Shutdown started; stop without beginning new work.
    Stop,
}

impl WorkerTick {
    pub fn should_continue(self) -> bool {
        matches!(self, WorkerTick::Continue)
    }
}

/// Wait for the next interval tick, unless shutdown starts first.
///
/// Workers use this instead of a bare `ticker.tick().await` so that a drain
/// interrupts the idle gap between iterations — with a one hour cleanup
/// interval, an uninterruptible sleep would otherwise hold the process open
/// well past the orchestrator's grace period and turn every deploy into a
/// `SIGKILL`.
pub async fn tick_or_shutdown(
    ticker: &mut tokio::time::Interval,
    shutdown: &ShutdownSignal,
) -> WorkerTick {
    tokio::select! {
        biased;
        _ = shutdown.wait() => WorkerTick::Stop,
        _ = ticker.tick() => {
            // A tick and a signal can become ready in the same poll; re-check so
            // shutdown always wins that race.
            if shutdown.is_draining() { WorkerTick::Stop } else { WorkerTick::Continue }
        }
    }
}

/// Sleep for `duration`, unless shutdown starts first.
pub async fn sleep_or_shutdown(duration: Duration, shutdown: &ShutdownSignal) -> WorkerTick {
    tokio::select! {
        biased;
        _ = shutdown.wait() => WorkerTick::Stop,
        _ = tokio::time::sleep(duration) => {
            if shutdown.is_draining() { WorkerTick::Stop } else { WorkerTick::Continue }
        }
    }
}

/// Resolve when the process is asked to terminate, returning the signal name.
///
/// `SIGTERM` is the one that matters in production: Docker, Kubernetes and
/// systemd all send it. `SIGINT` is included so an interactive Ctrl+C follows
/// the same drain path a real deploy does, rather than exercising an untested
/// second code path.
#[cfg(unix)]
pub async fn terminate_signal() -> &'static str {
    use tokio::signal::unix::{signal, SignalKind};

    let mut sigterm = match signal(SignalKind::terminate()) {
        Ok(s) => s,
        Err(e) => {
            // Without SIGTERM there is no orderly stop in a container, so fall
            // back to SIGINT only rather than pretending shutdown is wired up.
            tracing::error!(%e, "Failed to install SIGTERM handler; only Ctrl+C will drain");
            let _ = tokio::signal::ctrl_c().await;
            return "SIGINT";
        }
    };
    let mut sigint = match signal(SignalKind::interrupt()) {
        Ok(s) => s,
        Err(e) => {
            tracing::error!(%e, "Failed to install SIGINT handler; only SIGTERM will drain");
            sigterm.recv().await;
            return "SIGTERM";
        }
    };

    tokio::select! {
        _ = sigterm.recv() => "SIGTERM",
        _ = sigint.recv() => "SIGINT",
    }
}

#[cfg(not(unix))]
pub async fn terminate_signal() -> &'static str {
    let _ = tokio::signal::ctrl_c().await;
    "CTRL_C"
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::time::{timeout, Duration};

    #[tokio::test]
    async fn signal_starts_not_draining() {
        let controller = ShutdownController::new();
        let signal = controller.signal();
        assert!(!signal.is_draining());
        // Nothing has triggered, so waiting must not resolve.
        assert!(timeout(Duration::from_millis(50), signal.wait())
            .await
            .is_err());
    }

    #[tokio::test]
    async fn trigger_is_observed_by_existing_waiters() {
        let controller = ShutdownController::new();
        let signal = controller.signal();
        let waiter = tokio::spawn(async move { signal.wait().await });

        tokio::time::sleep(Duration::from_millis(20)).await;
        assert!(controller.trigger());

        timeout(Duration::from_secs(1), waiter)
            .await
            .expect("waiter should observe shutdown")
            .expect("waiter task should not panic");
    }

    #[tokio::test]
    async fn trigger_before_wait_is_not_missed() {
        // The race that a broadcast channel would lose: signal first, wait after.
        let controller = ShutdownController::new();
        controller.trigger();
        let signal = controller.signal();

        assert!(signal.is_draining());
        timeout(Duration::from_secs(1), signal.wait())
            .await
            .expect("an already-triggered signal must resolve immediately");
    }

    #[tokio::test]
    async fn trigger_reports_only_the_first_call() {
        let controller = ShutdownController::new();
        assert!(controller.trigger(), "first trigger flips the flag");
        assert!(
            !controller.trigger(),
            "a repeated signal must be distinguishable from the first"
        );
    }

    #[tokio::test]
    async fn signal_is_shared_across_clones() {
        let controller = ShutdownController::new();
        let a = controller.signal();
        let b = a.clone();
        controller.trigger();
        assert!(a.is_draining());
        assert!(b.is_draining());
    }

    #[tokio::test]
    async fn never_signal_stays_pending_after_controller_is_dropped() {
        // Guards the reason ShutdownSignal holds the sender: a dangling receiver
        // would resolve instantly and make handlers report a false drain.
        let signal = ShutdownSignal::never();
        assert!(!signal.is_draining());
        assert!(timeout(Duration::from_millis(50), signal.wait())
            .await
            .is_err());
    }

    #[tokio::test(start_paused = true)]
    async fn tick_or_shutdown_continues_until_signalled() {
        let controller = ShutdownController::new();
        let signal = controller.signal();
        let mut ticker = tokio::time::interval(Duration::from_secs(60));
        // The first tick of a tokio interval completes immediately.
        assert_eq!(
            tick_or_shutdown(&mut ticker, &signal).await,
            WorkerTick::Continue
        );

        controller.trigger();
        assert_eq!(
            tick_or_shutdown(&mut ticker, &signal).await,
            WorkerTick::Stop
        );
    }

    #[tokio::test(start_paused = true)]
    async fn tick_or_shutdown_does_not_wait_out_a_long_interval() {
        // A worker on an hourly schedule must still stop promptly.
        let controller = ShutdownController::new();
        let signal = controller.signal();
        let mut ticker = tokio::time::interval(Duration::from_secs(3600));
        ticker.tick().await; // consume the immediate first tick

        controller.trigger();
        let tick = timeout(
            Duration::from_secs(5),
            tick_or_shutdown(&mut ticker, &signal),
        )
        .await
        .expect("shutdown must interrupt the idle interval");
        assert_eq!(tick, WorkerTick::Stop);
    }

    #[tokio::test(start_paused = true)]
    async fn sleep_or_shutdown_returns_stop_when_draining() {
        let controller = ShutdownController::new();
        let signal = controller.signal();
        controller.trigger();
        assert_eq!(
            sleep_or_shutdown(Duration::from_secs(3600), &signal).await,
            WorkerTick::Stop
        );
    }

    #[tokio::test(start_paused = true)]
    async fn sleep_or_shutdown_completes_the_sleep_when_running() {
        let signal = ShutdownSignal::never();
        assert_eq!(
            sleep_or_shutdown(Duration::from_millis(10), &signal).await,
            WorkerTick::Continue
        );
    }

    #[test]
    fn worker_tick_should_continue_maps_variants() {
        assert!(WorkerTick::Continue.should_continue());
        assert!(!WorkerTick::Stop.should_continue());
    }
}
