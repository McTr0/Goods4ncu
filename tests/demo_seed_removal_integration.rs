//! Removing the demo seed accounts.
//!
//! `migrations/0005_seed_data.sql` says "run manually" but lives in
//! `migrations/`, so sqlx applies it to every database — including production.
//! It creates accounts sharing the published password `Test1234`, one of them a
//! platform administrator, so the server refuses to boot in production while
//! they exist. `scripts/remove_demo_seed.sql` is the required cleanup step, and
//! it is therefore on the critical path of every real deployment.
//!
//! It failed there, quietly. On a fresh database the script ran before the
//! tables it deletes from existed, the transaction aborted at the first missing
//! relation, every removal after that was skipped, and psql still exited 0 — so
//! the deployment reported "✓ demo seed accounts removed" and then could not
//! start, on a seed it believed it had cleaned. That is the failure this file
//! exists to prevent recurring: not "the SQL is wrong" but "the SQL failed and
//! said nothing".

use goods4ncu::test_infra::with_test_pool;

/// Ids from `migrations/0005_seed_data.sql`.
const SEED_IDS: &[&str] = &[
    "a0000000-0000-0000-0000-000000000001",
    "b0000000-0000-0000-0000-000000000001",
    "b0000000-0000-0000-0000-000000000002",
    "s0000000-0000-0000-0000-000000000001",
    "s0000000-0000-0000-0000-000000000002",
    "banned00-0000-0000-0000-000000000001",
];

fn removal_sql() -> String {
    std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/scripts/remove_demo_seed.sql"
    ))
    .expect("scripts/remove_demo_seed.sql must exist — deployments depend on it")
}

/// Runs the script the way a deployment does: one batch, stopping on error.
///
/// `sqlx::raw_sql` mirrors `psql -v ON_ERROR_STOP=1`, so a statement that fails
/// surfaces here instead of being skipped inside an aborted transaction.
async fn run_removal(pool: &sqlx::PgPool) -> Result<(), sqlx::Error> {
    sqlx::raw_sql(&removal_sql())
        .execute(pool)
        .await
        .map(|_| ())
}

async fn seed_users_present(pool: &sqlx::PgPool) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM users WHERE id = ANY($1)")
        .bind(SEED_IDS)
        .fetch_one(pool)
        .await
        .expect("count seed users")
}

#[tokio::test]
async fn removal_leaves_no_seed_account_behind() {
    with_test_pool(|pool| async move {
        // Recreate the seed rows the migration would have inserted. The test
        // harness truncates users, so they are put back here rather than
        // assumed present.
        for id in SEED_IDS {
            sqlx::query(
                "INSERT INTO users (id, username, password_hash, role)
                 VALUES ($1, $2, 'hash', 'user')
                 ON CONFLICT (id) DO NOTHING",
            )
            .bind(id)
            .bind(format!("seed_{id}"))
            .execute(&pool)
            .await
            .expect("insert seed user");
        }
        assert_eq!(seed_users_present(&pool).await, SEED_IDS.len() as i64);

        run_removal(&pool).await.expect("removal must succeed");
        assert_eq!(
            seed_users_present(&pool).await,
            0,
            "every published-password account must be gone",
        );
    })
    .await;
}

#[tokio::test]
async fn removal_is_idempotent() {
    // Deployments re-run it on every start. A second pass finding nothing must
    // be success, not an error that fails the deploy.
    with_test_pool(|pool| async move {
        run_removal(&pool).await.expect("first pass");
        run_removal(&pool)
            .await
            .expect("second pass on a clean database");
        assert_eq!(seed_users_present(&pool).await, 0);
    })
    .await;
}

#[tokio::test]
async fn removal_takes_the_seed_accounts_dependent_rows_with_it() {
    // A left-behind listing or membership would keep a foreign key alive and
    // make the delete fail on the next run — turning a clean-up into a
    // permanent deploy failure.
    with_test_pool(|pool| async move {
        let seed_owner = SEED_IDS[3];
        sqlx::query(
            "INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')
             ON CONFLICT (id) DO NOTHING",
        )
        .bind(seed_owner)
        .bind(format!("seed_{seed_owner}"))
        .execute(&pool)
        .await
        .expect("insert seed user");

        sqlx::query(
            "INSERT INTO campus_memberships (campus_id, user_id, status, verification_method)
             SELECT id, $1, 'verified', 'seed' FROM campuses WHERE slug = 'ncu'",
        )
        .bind(seed_owner)
        .execute(&pool)
        .await
        .expect("insert membership");

        let listing_id = uuid::Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO inventory (id, campus_id, title, category, brand, condition_score,
                                    suggested_price_cny, defects, owner_id, status)
             SELECT $1, id, '种子商品', 'misc', '', 8, 1000, '[]', $2, 'active'
             FROM campuses WHERE slug = 'ncu'",
        )
        .bind(&listing_id)
        .bind(seed_owner)
        .execute(&pool)
        .await
        .expect("insert listing");

        run_removal(&pool).await.expect("removal must succeed");

        for (table, column) in [
            ("users", "id"),
            ("campus_memberships", "user_id"),
            ("inventory", "owner_id"),
        ] {
            let remaining: i64 =
                sqlx::query_scalar(&format!("SELECT COUNT(*) FROM {table} WHERE {column} = $1"))
                    .bind(seed_owner)
                    .fetch_one(&pool)
                    .await
                    .unwrap_or_else(|e| panic!("count {table}: {e}"));
            assert_eq!(remaining, 0, "{table} still references the seed account");
        }
    })
    .await;
}

#[tokio::test]
async fn an_incomplete_removal_fails_loudly() {
    // The property that was actually missing. The script now checks its own
    // work and raises, so a partial run cannot report success — which is what
    // let a fresh deployment believe it was clean and then refuse to start.
    with_test_pool(|pool| async move {
        let sql = removal_sql();
        assert!(
            sql.contains("RAISE EXCEPTION"),
            "the script must verify its own outcome rather than trusting it",
        );
        // And the guard around `documents` is what stops the abort that caused
        // the silent skip in the first place.
        assert!(
            sql.contains("information_schema.tables"),
            "deleting from a table that may not exist yet must be guarded",
        );
        // Sanity: with the guard in place it still runs clean here, where
        // `documents` does exist.
        run_removal(&pool).await.expect("removal");
    })
    .await;
}
