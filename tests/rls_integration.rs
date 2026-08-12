//! Row-Level Security enforcement (Phase 1 defense-in-depth).
//!
//! Proves the `app.campus_id` policies actually bite: with a tenant context
//! armed via `SET LOCAL`, other campuses' rows are invisible to reads and
//! unwritable — even for the table-owning role (FORCE) — while an unarmed
//! session behaves exactly as before.

use goods4ncu::test_infra::with_test_pool;
use uuid::Uuid;

/// Provision a non-superuser role for RLS probing. Local test clusters often
/// run as a superuser, and superusers bypass RLS entirely (FORCE covers table
/// owners, not superusers) — production must never run the app as a
/// superuser, and these tests exercise the same non-superuser condition.
async fn ensure_probe_role(pool: &sqlx::PgPool) {
    sqlx::query(
        "DO $$ BEGIN
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'rls_probe') THEN
                CREATE ROLE rls_probe NOLOGIN;
            END IF;
        END $$;",
    )
    .execute(pool)
    .await
    .expect("create probe role");
    sqlx::query("GRANT USAGE ON SCHEMA public TO rls_probe")
        .execute(pool)
        .await
        .expect("grant schema");
    sqlx::query("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO rls_probe")
        .execute(pool)
        .await
        .expect("grant tables");
    sqlx::query("GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO rls_probe")
        .execute(pool)
        .await
        .expect("grant sequences");
}

async fn arm(tx: &mut sqlx::Transaction<'_, sqlx::Postgres>, campus_id: Uuid) {
    sqlx::query("SET LOCAL ROLE rls_probe")
        .execute(&mut **tx)
        .await
        .expect("assume probe role");
    sqlx::query(&format!("SET LOCAL app.campus_id = '{campus_id}'"))
        .execute(&mut **tx)
        .await
        .expect("arm tenant context");
}

async fn seed_two_campus_listings(pool: &sqlx::PgPool) -> (Uuid, Uuid, String, String) {
    let ncu_id: Uuid = sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
        .fetch_one(pool)
        .await
        .expect("ncu campus");
    let other_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO campuses (id, slug, name_zh, name_en, email_domains)
         VALUES ($1, $2, 'RLS 测试大学', 'RLS Test University', ARRAY['rls.test'])",
    )
    .bind(other_id)
    .bind(format!("rls-{}", &other_id.to_string()[..8]))
    .execute(pool)
    .await
    .expect("insert campus");

    let owner_id = Uuid::new_v4().to_string();
    sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
        .bind(&owner_id)
        .bind(format!("rls_owner_{}", Uuid::new_v4().simple()))
        .execute(pool)
        .await
        .expect("insert user");

    let ncu_listing = Uuid::new_v4().to_string();
    let other_listing = Uuid::new_v4().to_string();
    for (id, campus) in [(&ncu_listing, ncu_id), (&other_listing, other_id)] {
        sqlx::query(
            "INSERT INTO inventory (id, campus_id, title, category, brand, condition_score,
                                    suggested_price_cny, defects, owner_id, status)
             VALUES ($1, $2, 'RLS Item', 'misc', 'Brand', 8, 10000, '[]', $3, 'active')",
        )
        .bind(id)
        .bind(campus)
        .bind(&owner_id)
        .execute(pool)
        .await
        .expect("insert listing");
    }
    (ncu_id, other_id, ncu_listing, other_listing)
}

#[tokio::test]
async fn armed_tenant_context_hides_other_campus_rows() {
    with_test_pool(|pool| async move {
        let (ncu_id, _other_id, ncu_listing, other_listing) = seed_two_campus_listings(&pool).await;
        ensure_probe_role(&pool).await;

        // Unarmed: both rows visible (app-layer enforcement is primary).
        let visible: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM inventory WHERE id IN ($1, $2)")
                .bind(&ncu_listing)
                .bind(&other_listing)
                .fetch_one(&pool)
                .await
                .expect("unarmed count");
        assert_eq!(visible, 2, "without a tenant context nothing is filtered");

        // Armed to NCU: the other campus's row is invisible even though this
        // role owns the table (FORCE ROW LEVEL SECURITY).
        let mut tx = pool.begin().await.expect("begin");
        arm(&mut tx, ncu_id).await;
        let visible: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM inventory WHERE id IN ($1, $2)")
                .bind(&ncu_listing)
                .bind(&other_listing)
                .fetch_one(&mut *tx)
                .await
                .expect("armed count");
        assert_eq!(visible, 1, "armed context must hide the other campus");
        let seen: String = sqlx::query_scalar("SELECT id FROM inventory WHERE id IN ($1, $2)")
            .bind(&ncu_listing)
            .bind(&other_listing)
            .fetch_one(&mut *tx)
            .await
            .expect("armed row");
        assert_eq!(seen, ncu_listing);
        tx.rollback().await.expect("rollback");

        // SET LOCAL scope ends with the transaction: visibility restored.
        let visible: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM inventory WHERE id IN ($1, $2)")
                .bind(&ncu_listing)
                .bind(&other_listing)
                .fetch_one(&pool)
                .await
                .expect("post-tx count");
        assert_eq!(visible, 2, "context must not leak past the transaction");
    })
    .await;
}

#[tokio::test]
async fn armed_tenant_context_blocks_cross_campus_writes() {
    with_test_pool(|pool| async move {
        let (ncu_id, other_id, _ncu_listing, other_listing) = seed_two_campus_listings(&pool).await;
        ensure_probe_role(&pool).await;
        let owner_id: String = sqlx::query_scalar("SELECT owner_id FROM inventory WHERE id = $1")
            .bind(&other_listing)
            .fetch_one(&pool)
            .await
            .expect("owner");

        let mut tx = pool.begin().await.expect("begin");
        arm(&mut tx, ncu_id).await;

        // INSERT tagged with another campus violates WITH CHECK.
        let result = sqlx::query(
            "INSERT INTO inventory (id, campus_id, title, category, brand, condition_score,
                                    suggested_price_cny, defects, owner_id, status)
             VALUES ($1, $2, 'Cross Write', 'misc', 'Brand', 8, 10000, '[]', $3, 'active')",
        )
        .bind(Uuid::new_v4().to_string())
        .bind(other_id)
        .bind(&owner_id)
        .execute(&mut *tx)
        .await;
        assert!(
            result
                .expect_err("cross-campus insert must fail")
                .to_string()
                .contains("row-level security"),
            "failure must come from the RLS policy"
        );
        tx.rollback().await.expect("rollback");

        // UPDATE cannot reach the other campus's row at all (0 rows matched).
        let mut tx = pool.begin().await.expect("begin");
        arm(&mut tx, ncu_id).await;
        let updated = sqlx::query("UPDATE inventory SET title = 'Hijacked' WHERE id = $1")
            .bind(&other_listing)
            .execute(&mut *tx)
            .await
            .expect("update executes");
        assert_eq!(
            updated.rows_affected(),
            0,
            "an armed context must not be able to touch other-campus rows"
        );
        tx.rollback().await.expect("rollback");
    })
    .await;
}

#[tokio::test]
async fn armed_tenant_context_isolates_feed_controls() {
    with_test_pool(|pool| async move {
        let (ncu_id, other_id, ncu_listing, other_listing) = seed_two_campus_listings(&pool).await;
        let user_id: String = sqlx::query_scalar("SELECT owner_id FROM inventory WHERE id = $1")
            .bind(&ncu_listing)
            .fetch_one(&pool)
            .await
            .expect("owner");
        for (campus_id, resource_id) in [
            (ncu_id, ncu_listing.as_str()),
            (other_id, other_listing.as_str()),
        ] {
            sqlx::query(
                "INSERT INTO feed_preferences (campus_id, user_id, personalization_enabled)
                 VALUES ($1, $2, FALSE)",
            )
            .bind(campus_id)
            .bind(&user_id)
            .execute(&pool)
            .await
            .expect("insert feed preferences");
            sqlx::query(
                "INSERT INTO feed_feedback (
                    campus_id, user_id, resource_type, resource_id, action, signal_key
                 ) VALUES ($1, $2, 'listing', $3, 'hide', 'listing:category:misc')",
            )
            .bind(campus_id)
            .bind(&user_id)
            .bind(resource_id)
            .execute(&pool)
            .await
            .expect("insert feed feedback");
        }
        ensure_probe_role(&pool).await;

        let mut tx = pool.begin().await.expect("begin");
        arm(&mut tx, ncu_id).await;
        let visible_preferences: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM feed_preferences WHERE user_id = $1")
                .bind(&user_id)
                .fetch_one(&mut *tx)
                .await
                .expect("visible preferences");
        let visible_feedback: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM feed_feedback WHERE user_id = $1")
                .bind(&user_id)
                .fetch_one(&mut *tx)
                .await
                .expect("visible feedback");
        assert_eq!((visible_preferences, visible_feedback), (1, 1));
        let visible_resource: String =
            sqlx::query_scalar("SELECT resource_id FROM feed_feedback WHERE user_id = $1")
                .bind(&user_id)
                .fetch_one(&mut *tx)
                .await
                .expect("visible resource");
        assert_eq!(visible_resource, ncu_listing);

        let updated = sqlx::query(
            "UPDATE feed_preferences SET personalization_enabled = TRUE
             WHERE campus_id = $1 AND user_id = $2",
        )
        .bind(other_id)
        .bind(&user_id)
        .execute(&mut *tx)
        .await
        .expect("cross-campus update is filtered");
        assert_eq!(updated.rows_affected(), 0);
        tx.rollback().await.expect("rollback");
    })
    .await;
}

#[tokio::test]
async fn armed_tenant_context_isolates_listing_restriction_effects() {
    with_test_pool(|pool| async move {
        let (ncu_id, other_id, ncu_listing, other_listing) = seed_two_campus_listings(&pool).await;
        let owner_id: String = sqlx::query_scalar("SELECT owner_id FROM inventory WHERE id = $1")
            .bind(&ncu_listing)
            .fetch_one(&pool)
            .await
            .expect("owner");
        let mut case_ids = Vec::new();
        for (campus_id, listing_id) in [
            (ncu_id, ncu_listing.as_str()),
            (other_id, other_listing.as_str()),
        ] {
            let case_id = Uuid::new_v4();
            sqlx::query(
                "INSERT INTO moderation_cases (
                     id, campus_id, subject_user_id, resource_type, resource_id,
                     source_type, source_ref_id, status, reason_category, public_reason
                 ) VALUES (
                     $1, $2, $3, 'listing', $4, 'manual', $5, 'actioned',
                     'admin_takedown', 'RLS restriction fixture'
                 )",
            )
            .bind(case_id)
            .bind(campus_id)
            .bind(&owner_id)
            .bind(listing_id)
            .bind(format!("rls-effect:{case_id}"))
            .execute(&pool)
            .await
            .expect("insert restriction case");
            sqlx::query(
                "INSERT INTO listing_restriction_effects (
                     campus_id, listing_id, case_id, source_kind
                 ) VALUES ($1, $2, $3, 'moderation_case')",
            )
            .bind(campus_id)
            .bind(listing_id)
            .bind(case_id)
            .execute(&pool)
            .await
            .expect("insert restriction effect");
            case_ids.push(case_id);
        }
        ensure_probe_role(&pool).await;

        let mut tx = pool.begin().await.expect("begin");
        arm(&mut tx, ncu_id).await;
        let visible: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM listing_restriction_effects
             WHERE case_id = ANY($1)",
        )
        .bind(&case_ids)
        .fetch_one(&mut *tx)
        .await
        .expect("visible effects");
        assert_eq!(visible, 1, "another campus's effect must be invisible");
        let visible_case: Uuid = sqlx::query_scalar(
            "SELECT case_id FROM listing_restriction_effects WHERE case_id = ANY($1)",
        )
        .bind(&case_ids)
        .fetch_one(&mut *tx)
        .await
        .expect("visible case");
        assert_eq!(visible_case, case_ids[0]);

        let updated = sqlx::query(
            "UPDATE listing_restriction_effects SET released_at = NOW()
             WHERE case_id = $1",
        )
        .bind(case_ids[1])
        .execute(&mut *tx)
        .await
        .expect("cross-campus update is invisibly filtered");
        assert_eq!(updated.rows_affected(), 0);
        tx.rollback().await.expect("rollback");

        let other_still_active: bool = sqlx::query_scalar(
            "SELECT released_at IS NULL FROM listing_restriction_effects WHERE case_id = $1",
        )
        .bind(case_ids[1])
        .fetch_one(&pool)
        .await
        .expect("other effect after probe");
        assert!(other_still_active);
    })
    .await;
}

/// The policies cover every tenant-scoped table, not just inventory.
#[tokio::test]
async fn rls_policies_exist_on_all_tenant_tables() {
    with_test_pool(|pool| async move {
        let expected = [
            "inventory",
            "orders",
            "hitl_requests",
            "wanted_responses",
            "notifications",
            "chat_conversations",
            "chat_spaces",
            "chat_secret_sessions",
            "moderation_jobs",
            "moderation_cases",
            "moderation_appeals",
            "content_reports",
            "intents",
            "feed_feedback",
            "feed_preferences",
            "agent_action_plans",
            "agent_action_audits",
            "admin_audit_logs",
            "campus_memberships",
            "refresh_tokens",
            "social_personas",
            "social_persona_audits",
            "social_persona_assets",
            "chat_relationship_pins",
            "chat_shared_objects",
        ];
        for table in expected {
            let (enabled, forced): (bool, bool) = sqlx::query_as(
                "SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname = $1",
            )
            .bind(table)
            .fetch_one(&pool)
            .await
            .unwrap_or_else(|e| panic!("{table}: {e}"));
            assert!(enabled, "{table} must have RLS enabled");
            assert!(
                forced,
                "{table} must FORCE RLS so the owner role is covered"
            );

            let policy: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM pg_policies
                 WHERE tablename = $1 AND policyname = 'tenant_isolation'",
            )
            .bind(table)
            .fetch_one(&pool)
            .await
            .expect("policy count");
            assert_eq!(policy, 1, "{table} must carry the tenant_isolation policy");
        }
    })
    .await;
}
