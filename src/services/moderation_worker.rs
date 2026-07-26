//! Background worker for async image moderation.
//!
//! Polls the `moderation_jobs` table for pending jobs and calls the external
//! image moderation API (Alibaba IMAN). Updates job status to approved/rejected/failed.

use serde_json::Value;
use sqlx::{PgPool, Postgres, Transaction};
use std::time::Duration;

use crate::lifecycle::{sleep_or_shutdown, ShutdownSignal};
use crate::services::moderation_case::create_case_for_rejected_job;

/// Polling interval between batch scans.
const POLL_INTERVAL_SECS: u64 = 5;

/// Maximum jobs to process per poll cycle.
const MAX_JOBS_PER_CYCLE: i64 = 20;

/// Maximum retry attempts before marking a job as failed.
const MAX_RETRIES: i32 = 3;

#[derive(Clone)]
pub struct ModerationApiConfig {
    pub enabled: bool,
    pub api_url: Option<String>,
    pub api_key: Option<String>,
}

impl ModerationApiConfig {
    pub fn from_parts(enabled: bool, api_url: Option<String>, api_key: Option<String>) -> Self {
        Self {
            enabled,
            api_url,
            api_key,
        }
    }
}

/// Run the moderation worker loop.
/// Spawn this as a background `tokio::spawn` task in `main.rs`.
pub async fn run_moderation_worker(db: PgPool, cfg: ModerationApiConfig, shutdown: ShutdownSignal) {
    tracing::info!("Moderation worker started");
    if !cfg.enabled {
        tracing::info!("Image moderation is disabled by configuration");
    }
    let mut backoff_secs = POLL_INTERVAL_SECS;
    let max_backoff_secs = 60;
    loop {
        match process_pending_jobs(&db, &cfg).await {
            Ok(count) => {
                if count > 0 {
                    tracing::debug!(count, "moderation jobs processed");
                }
                // Reset backoff on success.
                backoff_secs = POLL_INTERVAL_SECS;
            }
            Err(e) => {
                tracing::error!(%e, "moderation worker error, backing off");
                // Exponential backoff on consecutive errors.
                backoff_secs = (backoff_secs * 2).min(max_backoff_secs);
            }
        }
        // Finish the batch already claimed, then stop before claiming more.
        // Jobs left in `processing` by a hard kill need manual recovery, so the
        // cycle boundary is the only safe place to exit.
        if !sleep_or_shutdown(Duration::from_secs(backoff_secs), &shutdown)
            .await
            .should_continue()
        {
            break;
        }
    }

    tracing::info!("Moderation worker stopped");
}

/// Fetch and process up to MAX_JOBS_PER_CYCLE pending jobs.
async fn process_pending_jobs(db: &PgPool, cfg: &ModerationApiConfig) -> anyhow::Result<i64> {
    // Claim jobs by updating status from 'pending' → 'processing' atomically.
    // This prevents multiple workers from claiming the same job.
    let rows = sqlx::query_as::<_, (String, String, String, String, i32)>(
        r#"
        WITH claimed AS (
            SELECT id, resource_type, resource_id, image_url, retry_count
            FROM moderation_jobs
            WHERE status = 'pending'
            ORDER BY created_at ASC
            LIMIT $1
            FOR UPDATE SKIP LOCKED
        )
        UPDATE moderation_jobs m
        SET status = 'processing'
        FROM claimed c
        WHERE m.id = c.id
        RETURNING m.id, c.resource_type, c.resource_id, c.image_url, c.retry_count
        "#,
    )
    .bind(MAX_JOBS_PER_CYCLE)
    .fetch_all(db)
    .await?;

    if rows.is_empty() {
        return Ok(0);
    }

    let count = rows.len() as i64;
    for (id, resource_type, resource_id, image_url, retry_count) in rows {
        let result = moderate_image(&image_url, cfg).await;
        let (new_status, reject_reason) = match result {
            Ok(true) => ("approved", None),
            Ok(false) => ("rejected", Some("图片内容不合规".to_string())),
            Err(e) => {
                tracing::warn!(job_id = %id, %e, "moderation API call failed");
                if retry_count + 1 >= MAX_RETRIES {
                    ("failed", Some(format!("审核服务错误: {}", e)))
                } else {
                    // Increment retry count and put back to pending.
                    if let Err(e) = sqlx::query(
                        "UPDATE moderation_jobs SET status = 'pending', retry_count = retry_count + 1 WHERE id = $1",
                    )
                    .bind(&id)
                    .execute(db)
                    .await
                    {
                        tracing::error!(job_id = %id, %e, "failed to re-queue moderation job for retry");
                    }
                    continue;
                }
            }
        };

        if let Err(e) = finalize_job(
            db,
            &id,
            &resource_type,
            &resource_id,
            new_status,
            reject_reason.as_deref(),
        )
        .await
        {
            tracing::error!(job_id = %id, resource_type = %resource_type, resource_id = %resource_id, %e, "failed to finalize moderation job");
        }
    }

    Ok(count)
}

async fn finalize_job(
    db: &PgPool,
    job_id: &str,
    resource_type: &str,
    resource_id: &str,
    status: &str,
    reject_reason: Option<&str>,
) -> anyhow::Result<()> {
    let mut tx = db.begin().await?;
    sqlx::query(
        "UPDATE moderation_jobs
         SET status = $1, reject_reason = $2, processed_at = CURRENT_TIMESTAMP
         WHERE id = $3",
    )
    .bind(status)
    .bind(reject_reason)
    .bind(job_id)
    .execute(&mut *tx)
    .await?;
    update_resource_status(&mut tx, resource_type, resource_id, status).await?;
    if status == "rejected" {
        create_case_for_rejected_job(&mut tx, job_id)
            .await
            .map_err(|error| anyhow::anyhow!(error.to_string()))?;
    }
    tx.commit().await?;
    Ok(())
}

/// Call the external image moderation API for the given URL.
/// Returns `Ok(true)` = approved, `Ok(false)` = rejected, `Err` = API error.
async fn moderate_image(image_url: &str, cfg: &ModerationApiConfig) -> anyhow::Result<bool> {
    if !cfg.enabled {
        return Ok(true);
    }

    let api_url = cfg
        .api_url
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("MODERATION_IMAGE_API_URL is not configured"))?;
    let api_key = cfg
        .api_key
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("MODERATION_IMAGE_API_KEY is not configured"))?;

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(8))
        .build()?;

    let body = serde_json::json!({
        "image_url": image_url,
        "source": "goods4ncu"
    });

    let resp = client
        .post(api_url)
        .header(reqwest::header::AUTHORIZATION, format!("Bearer {api_key}"))
        .json(&body)
        .send()
        .await?;

    let status = resp.status();
    if !status.is_success() {
        let text = resp.text().await.unwrap_or_default();
        return Err(anyhow::anyhow!(
            "moderation api non-success status={} body={}",
            status,
            text
        ));
    }

    let payload: Value = resp.json().await?;
    parse_moderation_verdict(&payload)
        .ok_or_else(|| anyhow::anyhow!("unable to parse moderation verdict from response"))
}

fn parse_moderation_verdict(payload: &Value) -> Option<bool> {
    if let Some(v) = payload.get("approved").and_then(|v| v.as_bool()) {
        return Some(v);
    }
    if let Some(v) = payload.get("pass").and_then(|v| v.as_bool()) {
        return Some(v);
    }
    if let Some(v) = payload.get("ok").and_then(|v| v.as_bool()) {
        return Some(v);
    }

    for key in ["status", "result", "verdict"] {
        if let Some(s) = payload
            .get(key)
            .and_then(|v| v.as_str())
            .map(|s| s.to_ascii_lowercase())
        {
            if ["approved", "pass", "passed", "ok", "clean", "safe"].contains(&s.as_str()) {
                return Some(true);
            }
            if ["rejected", "reject", "blocked", "unsafe", "deny", "denied"].contains(&s.as_str()) {
                return Some(false);
            }
        }
    }

    if let Some(s) = payload
        .pointer("/data/status")
        .and_then(|v| v.as_str())
        .map(|s| s.to_ascii_lowercase())
    {
        if ["approved", "pass", "passed", "ok", "clean", "safe"].contains(&s.as_str()) {
            return Some(true);
        }
        if ["rejected", "reject", "blocked", "unsafe", "deny", "denied"].contains(&s.as_str()) {
            return Some(false);
        }
    }

    if let Some(v) = payload.pointer("/data/approved").and_then(|v| v.as_bool()) {
        return Some(v);
    }

    None
}

/// Update the per-resource moderation status column.
async fn update_resource_status(
    tx: &mut Transaction<'_, Postgres>,
    resource_type: &str,
    resource_id: &str,
    status: &str,
) -> anyhow::Result<()> {
    crate::services::moderation::set_media_moderation_status(
        tx,
        resource_type,
        resource_id,
        status,
    )
    .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_verdict_from_boolean_keys() {
        let p = serde_json::json!({"approved": true});
        assert_eq!(parse_moderation_verdict(&p), Some(true));

        let p = serde_json::json!({"pass": false});
        assert_eq!(parse_moderation_verdict(&p), Some(false));
    }

    #[test]
    fn parse_verdict_from_status_words() {
        let p = serde_json::json!({"status": "approved"});
        assert_eq!(parse_moderation_verdict(&p), Some(true));

        let p = serde_json::json!({"result": "blocked"});
        assert_eq!(parse_moderation_verdict(&p), Some(false));
    }

    #[test]
    fn parse_verdict_from_nested_data() {
        let p = serde_json::json!({"data": {"status": "safe"}});
        assert_eq!(parse_moderation_verdict(&p), Some(true));

        let p = serde_json::json!({"data": {"approved": false}});
        assert_eq!(parse_moderation_verdict(&p), Some(false));
    }

    #[test]
    fn parse_verdict_unknown_shape_returns_none() {
        let p = serde_json::json!({"foo": "bar"});
        assert_eq!(parse_moderation_verdict(&p), None);
    }
}
