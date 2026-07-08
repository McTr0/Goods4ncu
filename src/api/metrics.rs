//! Application metrics for observability.
//!
//! Exposes key business and infrastructure metrics in Prometheus text format
//! via the [`MetricsService`] struct. All metrics are process-local atomic
//! counters/gauges — no external dependency required.
//!
//! Key metrics:
//! - HTTP request counts and latencies per endpoint
//! - Offline deal events (intent created, confirmed, cancelled)
//! - Chat message counts
//! - Rate limit rejections
//! - LLM call counts and errors

use prometheus::{Counter, CounterVec, HistogramOpts, HistogramVec, Opts, Registry, TextEncoder};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

pub static GLOBAL_METRICS: OnceLock<Arc<MetricsService>> = OnceLock::new();

/// Centralized metrics registry for the application.
/// All metric collectors are registered here and exposed via `/api/metrics`.
pub struct MetricsService {
    registry: Registry,
    // HTTP
    pub http_requests_total: CounterVec,
    pub http_request_duration_seconds: HistogramVec,
    // Business
    pub deal_intents_created_total: Counter,
    pub deals_confirmed_total: Counter,
    pub deals_cancelled_total: Counter,
    pub chat_messages_total: Counter,
    // Infrastructure
    pub rate_limit_rejected_total: Counter,
    pub llm_calls_total: Counter,
    pub llm_errors_total: Counter,
    pub ws_messages_dropped_total: Counter,
    pub ws_stale_connections_pruned_total: Counter,
    pub chat_media_url_messages_total: Counter,
    pub chat_media_base64_messages_total: Counter,
}

impl MetricsService {
    /// Create a new MetricsService and register all metric collectors.
    pub fn new() -> Self {
        let registry = Registry::new();

        let http_requests_total = CounterVec::new(
            Opts::new(
                "http_requests_total",
                "Total HTTP requests by method, path, status",
            ),
            &["method", "path", "status"],
        )
        .expect("metric definition is valid");
        let http_request_duration_seconds = HistogramVec::new(
            HistogramOpts::new(
                "http_request_duration_seconds",
                "HTTP request latency distribution",
            )
            .buckets(vec![
                0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5,
            ]),
            &["method", "path"],
        )
        .expect("metric definition is valid");

        let deal_intents_created_total = Counter::new(
            "deal_intents_created_total",
            "Total offline deal intents created",
        )
        .expect("metric definition is valid");
        let deals_confirmed_total =
            Counter::new("deals_confirmed_total", "Total offline deals confirmed")
                .expect("metric definition is valid");
        let deals_cancelled_total = Counter::new(
            "deals_cancelled_total",
            "Total offline deal records cancelled",
        )
        .expect("metric definition is valid");
        let chat_messages_total =
            Counter::new("chat_messages_total", "Total chat messages processed")
                .expect("metric definition is valid");
        let rate_limit_rejected_total = Counter::new(
            "rate_limit_rejected_total",
            "Total requests rejected by rate limiter",
        )
        .expect("metric definition is valid");
        let llm_calls_total = Counter::new("llm_calls_total", "Total LLM API calls made")
            .expect("metric definition is valid");
        let llm_errors_total = Counter::new("llm_errors_total", "Total LLM API errors")
            .expect("metric definition is valid");
        let ws_messages_dropped_total = Counter::new(
            "ws_messages_dropped_total",
            "Total websocket messages dropped due to full or closed channels",
        )
        .expect("metric definition is valid");
        let ws_stale_connections_pruned_total = Counter::new(
            "ws_stale_connections_pruned_total",
            "Total stale websocket sender entries pruned from connection registry",
        )
        .expect("metric definition is valid");
        let chat_media_url_messages_total = Counter::new(
            "chat_media_url_messages_total",
            "Total chat messages carrying media URL fields",
        )
        .expect("metric definition is valid");
        let chat_media_base64_messages_total = Counter::new(
            "chat_media_base64_messages_total",
            "Total chat messages carrying base64 media fields",
        )
        .expect("metric definition is valid");

        // Register all metrics
        registry
            .register(Box::new(http_requests_total.clone()))
            .expect("metric is unique");
        registry
            .register(Box::new(http_request_duration_seconds.clone()))
            .expect("metric is unique");
        registry
            .register(Box::new(deal_intents_created_total.clone()))
            .expect("metric is unique");
        registry
            .register(Box::new(deals_confirmed_total.clone()))
            .expect("metric is unique");
        registry
            .register(Box::new(deals_cancelled_total.clone()))
            .expect("metric is unique");
        registry
            .register(Box::new(chat_messages_total.clone()))
            .expect("metric is unique");
        registry
            .register(Box::new(rate_limit_rejected_total.clone()))
            .expect("metric is unique");
        registry
            .register(Box::new(llm_calls_total.clone()))
            .expect("metric is unique");
        registry
            .register(Box::new(llm_errors_total.clone()))
            .expect("metric is unique");
        registry
            .register(Box::new(ws_messages_dropped_total.clone()))
            .expect("metric is unique");
        registry
            .register(Box::new(ws_stale_connections_pruned_total.clone()))
            .expect("metric is unique");
        registry
            .register(Box::new(chat_media_url_messages_total.clone()))
            .expect("metric is unique");
        registry
            .register(Box::new(chat_media_base64_messages_total.clone()))
            .expect("metric is unique");

        Self {
            registry,
            http_requests_total,
            http_request_duration_seconds,
            deal_intents_created_total,
            deals_confirmed_total,
            deals_cancelled_total,
            chat_messages_total,
            rate_limit_rejected_total,
            llm_calls_total,
            llm_errors_total,
            ws_messages_dropped_total,
            ws_stale_connections_pruned_total,
            chat_media_url_messages_total,
            chat_media_base64_messages_total,
        }
    }

    /// Record an HTTP request (pending HTTP metrics middleware).
    #[allow(dead_code)]
    pub fn record_http(&self, method: &str, path: &str, status: u16, duration: Duration) {
        let status_str = status.to_string();
        self.http_requests_total
            .with_label_values(&[method, path, &status_str])
            .inc();
        self.http_request_duration_seconds
            .with_label_values(&[method, path])
            .observe(duration.as_secs_f64());
    }

    pub fn record_deal_intent_created(&self) {
        self.deal_intents_created_total.inc();
    }

    pub fn record_deal_confirmed(&self) {
        self.deals_confirmed_total.inc();
    }

    pub fn record_deal_cancelled(&self) {
        self.deals_cancelled_total.inc();
    }

    /// Record a chat message processed.
    pub fn record_chat_message(&self) {
        self.chat_messages_total.inc();
    }

    /// Record a rate limit rejection.
    pub fn record_rate_limit_rejected(&self) {
        self.rate_limit_rejected_total.inc();
    }

    /// Record an LLM API call.
    pub fn record_llm_call(&self) {
        self.llm_calls_total.inc();
    }

    /// Record an LLM API error.
    pub fn record_llm_error(&self) {
        self.llm_errors_total.inc();
    }

    pub fn record_ws_message_dropped(&self) {
        self.ws_messages_dropped_total.inc();
    }

    pub fn record_ws_stale_pruned(&self, count: usize) {
        if count > 0 {
            self.ws_stale_connections_pruned_total.inc_by(count as f64);
        }
    }

    pub fn record_chat_media_url_message(&self) {
        self.chat_media_url_messages_total.inc();
    }

    pub fn record_chat_media_base64_message(&self) {
        self.chat_media_base64_messages_total.inc();
    }

    /// Render all metrics in Prometheus text format.
    pub fn render(&self) -> String {
        let encoder = TextEncoder::new();
        let metric_families = self.registry.gather();
        encoder
            .encode_to_string(&metric_families)
            .expect("encoding is infallible")
    }
}

impl Default for MetricsService {
    fn default() -> Self {
        Self::new()
    }
}
