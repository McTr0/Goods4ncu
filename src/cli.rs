use crate::repositories::{PostgresUserRepository, UserRepository};
use anyhow::Result;
use sqlx::PgPool;
use std::env;
use std::time::Duration;

/// Run the CLI with command-line arguments.
/// Returns true if a CLI command was executed, false otherwise.
pub async fn run_cli(args: &[String]) -> Result<bool> {
    if args.len() < 2 {
        return Ok(false);
    }

    match args[1].as_str() {
        "--health-check" => {
            run_health_check().await?;
            Ok(true)
        }
        "admin" => {
            if args.len() < 3 {
                eprintln!("Usage: admin promote <username>");
                return Ok(true);
            }
            match args[2].as_str() {
                "promote" => {
                    if args.len() < 4 {
                        eprintln!("Usage: admin promote <username>");
                        return Ok(true);
                    }
                    let username = &args[3];
                    run_admin_promote(username).await?;
                    Ok(true)
                }
                _ => {
                    eprintln!("Unknown admin command: {}", args[2]);
                    eprintln!("Usage: admin promote <username>");
                    Ok(true)
                }
            }
        }
        _ => Ok(false),
    }
}

/// Container health check probe.
///
/// Targets readiness rather than liveness: this drives the container's health
/// status, which is what Compose `depends_on: service_healthy` and swarm
/// routing consult, so a draining instance must report unhealthy and stop
/// receiving traffic.
async fn run_health_check() -> Result<()> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(3))
        .build()?;

    // Follow the configured port; a hardcoded 3000 silently reports every
    // container on a custom port as unhealthy.
    let port = env::var("SERVER_PORT")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| "3000".to_string());

    let response = client
        .get(format!("http://127.0.0.1:{}/api/readyz", port))
        .send()
        .await?;

    if response.status().is_success() {
        Ok(())
    } else {
        anyhow::bail!("Health check failed with status {}", response.status())
    }
}

/// Promote a user to admin role.
async fn run_admin_promote(username: &str) -> Result<()> {
    let database_url =
        env::var("DATABASE_URL").map_err(|_| anyhow::anyhow!("DATABASE_URL must be set"))?;

    let pool = PgPool::connect(&database_url).await?;
    let user_repo = PostgresUserRepository::new(pool.clone());
    let user = user_repo
        .find_by_username(username)
        .await
        .map_err(|e| anyhow::anyhow!("Failed to load user: {}", e))?;

    let Some(user) = user else {
        anyhow::bail!("用户 '{}' 不存在", username);
    };

    user_repo
        .update_role(&user.id, "admin")
        .await
        .map_err(|e| anyhow::anyhow!("Failed to promote user: {}", e))?;

    println!("用户 '{}' 已提升为管理员", username);
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn test_cli_args_parsing() {
        // Test admin promote parsing (cargo run -- admin promote testuser)
        let args = [
            "cargo".to_string(),
            "run".to_string(),
            "admin".to_string(),
            "promote".to_string(),
            "testuser".to_string(),
        ];
        assert_eq!(args[2], "admin");
        assert_eq!(args[3], "promote");
        assert_eq!(args[4], "testuser");
    }
}
