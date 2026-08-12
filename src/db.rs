use anyhow::Result;
use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;
use sqlx::Row;

/// Initializes the database: creates the pgvector extension and runs migrations.
/// Returns a single PgPool that handles both relational and vector data.
pub async fn init_db(database_url: &str) -> Result<PgPool> {
    // Create a PgPool for relational + vector data
    let db_pool = PgPoolOptions::new()
        .min_connections(2) // Pre-warm pool to reduce cold-start latency
        .max_connections(20)
        .connect(database_url)
        .await?;

    // Enable pgvector extension (creates the vector type and operators)
    // This must be done before running migrations since the vector type is needed
    // by the documents table migration.
    //
    // Creating an extension requires superuser (pgvector is not a "trusted"
    // extension), but the application role MUST NOT be a superuser: superusers
    // bypass Row-Level Security entirely, which would silently disable the
    // tenant policies from migration 0042. So: if the extension is already
    // installed — the correct production state, provisioned once by a DBA — we
    // skip creation entirely and never need the privilege. Only a fresh
    // developer database takes the create path, and a permission failure there
    // is reported with the exact command an operator should run.
    {
        const EXTENSION_BOOT_LOCK: i64 = 7_315_900_422;
        let mut conn = db_pool.acquire().await?;
        sqlx::query("SELECT pg_advisory_lock($1)")
            .bind(EXTENSION_BOOT_LOCK)
            .execute(&mut *conn)
            .await?;

        let already_installed: bool = sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector')",
        )
        .fetch_one(&mut *conn)
        .await?;

        // Serialized under the advisory lock: `IF NOT EXISTS` does not protect
        // two replicas booting a fresh database concurrently — both pass the
        // existence check and one fails on the pg_extension catalog's unique
        // index. Surfaced by scripts/production_rehearsal.sh.
        let outcome = if already_installed {
            Ok(())
        } else {
            sqlx::query("CREATE EXTENSION IF NOT EXISTS vector")
                .execute(&mut *conn)
                .await
                .map(|_| ())
        };

        // Release the session lock before propagating any error so a failed
        // boot cannot wedge the other replica.
        sqlx::query("SELECT pg_advisory_unlock($1)")
            .bind(EXTENSION_BOOT_LOCK)
            .execute(&mut *conn)
            .await?;

        if let Err(error) = outcome {
            let insufficient_privilege = error
                .as_database_error()
                .and_then(|db| db.code())
                .is_some_and(|code| code == "42501");
            if insufficient_privilege {
                return Err(anyhow::anyhow!(
                    "the pgvector extension is not installed and this role may not create it.\n\
                     Install it once as a superuser, then restart:\n\
                     \n    psql -d <database> -c 'CREATE EXTENSION vector;'\n\n\
                     The application role must NOT be a superuser — superusers bypass \
                     Row-Level Security, which would disable tenant isolation."
                ));
            }
            return Err(error.into());
        }
    }

    // Run versioned migrations (includes all CREATE TABLE, CREATE INDEX, etc.)
    // Keep the literal path here so sqlx embeds the current on-disk migration set at compile time, including new files.
    // Migrations are embedded in the binary; deployment must rebuild whenever
    // files under migrations/ change rather than reusing an older executable.
    // Keep this comment adjacent to the macro so adding a migration also
    // invalidates binaries in environments whose build cache watches files
    // conservatively.
    sqlx::migrate!("./migrations").run(&db_pool).await?;

    Ok(db_pool)
}

/// Refuse to run in production while the demo seed accounts exist.
///
/// `migrations/0005_seed_data.sql` says "run manually" but lives in
/// `migrations/`, so sqlx applies it to EVERY database — including production.
/// It inserts `admin`, `buyer1`, `seller1`… all sharing the published password
/// `Test1234`, and `admin` has the platform-admin role. A production deployment
/// would therefore ship with a publicly-known administrator login.
///
/// Deleting or editing 0005 is not safe (sqlx validates checksums of applied
/// migrations), so the guard lives here where the environment is known: fail
/// fast with the exact cleanup command instead of silently serving.
pub async fn assert_no_demo_seed_in_production(
    db_pool: &PgPool,
    is_production: bool,
) -> Result<()> {
    if !is_production {
        return Ok(());
    }
    // Match on the seed's fixed ids rather than usernames: a real user could
    // legitimately be called "admin", but these UUIDs only come from 0005.
    const SEED_IDS: &[&str] = &[
        "a0000000-0000-0000-0000-000000000001",
        "b0000000-0000-0000-0000-000000000001",
        "b0000000-0000-0000-0000-000000000002",
        "s0000000-0000-0000-0000-000000000001",
        "s0000000-0000-0000-0000-000000000002",
        "banned00-0000-0000-0000-000000000001",
    ];
    let present: Vec<String> =
        sqlx::query_scalar("SELECT username FROM users WHERE id = ANY($1) ORDER BY username")
            .bind(SEED_IDS)
            .fetch_all(db_pool)
            .await?;
    if present.is_empty() {
        return Ok(());
    }
    anyhow::bail!(
        "refusing to start in production: demo seed accounts are present ({}).\n\
         They share the published password 'Test1234' and include a platform admin.\n\
         Remove them, then restart:\n\
         \n    psql -d <database> -f scripts/remove_demo_seed.sql\n",
        present.join(", ")
    );
}

pub async fn assert_documents_embedding_dim(db_pool: &PgPool, expected_dim: usize) -> Result<()> {
    let row = sqlx::query(
        r#"
        SELECT format_type(a.atttypid, a.atttypmod) AS embedding_type
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = current_schema()
          AND c.relname = 'documents'
          AND a.attname = 'embedding'
          AND a.attnum > 0
          AND NOT a.attisdropped
        "#,
    )
    .fetch_optional(db_pool)
    .await?;

    let row = row.ok_or_else(|| anyhow::anyhow!("documents.embedding column not found"))?;
    let embedding_type: String = row.get("embedding_type");
    let actual_dim = parse_vector_type_dim(&embedding_type).ok_or_else(|| {
        anyhow::anyhow!(
            "failed to parse documents.embedding type '{embedding_type}' as vector(dim)"
        )
    })?;

    if actual_dim != expected_dim {
        anyhow::bail!(
            "documents.embedding dimension mismatch: schema has {actual_dim}, config expects {expected_dim}"
        );
    }

    Ok(())
}

pub async fn assert_uuid_shadow_drift_zero(db_pool: &PgPool) -> Result<()> {
    let rows = sqlx::query(
        r#"
        SELECT relation_name, missing_shadow_ids, fk_drift_rows
        FROM uuid_shadow_divergence
        WHERE missing_shadow_ids > 0 OR fk_drift_rows > 0
        ORDER BY relation_name
        "#,
    )
    .fetch_all(db_pool)
    .await?;

    if rows.is_empty() {
        return Ok(());
    }

    let details = rows
        .into_iter()
        .map(|row| {
            let relation_name: String = row.get("relation_name");
            let missing_shadow_ids: i64 = row.get("missing_shadow_ids");
            let fk_drift_rows: i64 = row.get("fk_drift_rows");
            format!(
                "{relation_name}(missing_shadow_ids={missing_shadow_ids}, fk_drift_rows={fk_drift_rows})"
            )
        })
        .collect::<Vec<_>>()
        .join(", ");

    anyhow::bail!("uuid shadow drift detected: {details}");
}

fn parse_vector_type_dim(vector_type: &str) -> Option<usize> {
    vector_type
        .strip_prefix("vector(")?
        .strip_suffix(')')?
        .parse()
        .ok()
}

#[cfg(test)]
mod tests {
    use super::parse_vector_type_dim;

    #[test]
    fn parse_vector_type_dim_accepts_valid_pgvector_type() {
        assert_eq!(parse_vector_type_dim("vector(768)"), Some(768));
    }

    #[test]
    fn parse_vector_type_dim_rejects_unexpected_shapes() {
        assert_eq!(parse_vector_type_dim("text"), None);
        assert_eq!(parse_vector_type_dim("vector"), None);
        assert_eq!(parse_vector_type_dim("vector(foo)"), None);
    }
}
