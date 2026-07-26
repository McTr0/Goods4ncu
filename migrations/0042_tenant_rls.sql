-- Row-Level Security on tenant-scoped tables (Phase 1 defense-in-depth).
--
-- Enforcement model: policies key on the per-transaction GUC `app.campus_id`.
--   * GUC unset  -> policy passes for every row. The application's service
--     layer remains the primary tenancy boundary (extensively regression
--     tested), and all existing queries, migrations, workers and backups run
--     unchanged.
--   * GUC set    -> rows from any other campus become invisible to reads and
--     unwritable (WITH CHECK), for EVERY role including the table owner
--     (FORCE). `SET LOCAL app.campus_id = '<uuid>'` inside a transaction arms
--     it for that transaction only.
--
-- This is deliberately fail-open when no context is set: flipping to
-- fail-closed requires threading the GUC through every repository call and is
-- the Phase 4 multi-replica hardening step. What this migration buys today:
--   1. The mechanism exists, is armed per-transaction, and is proven by
--      integration tests (tests/rls_integration.rs) — not a paper design.
--   2. Any future non-owner role (analytics, support tooling, read replicas)
--      is subject to these policies from day one.
--   3. High-risk paths can opt in incrementally with SET LOCAL without a
--      big-bang migration.
--
-- NULL campus_id rows (none exist today; columns are NOT NULL on all these
-- tables except none) would be hidden under an armed context — correct: an
-- untagged row has no business being visible in a tenant-scoped view.

DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'inventory', 'orders', 'hitl_requests', 'wanted_responses',
        'notifications', 'chat_conversations', 'chat_spaces',
        'chat_secret_sessions', 'moderation_jobs', 'moderation_cases',
        'moderation_appeals', 'agent_action_plans', 'admin_audit_logs',
        'campus_memberships', 'refresh_tokens'
    ] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %I', t);
        EXECUTE format(
            'CREATE POLICY tenant_isolation ON %I
             USING (
                 current_setting(''app.campus_id'', true) IS NULL
                 OR current_setting(''app.campus_id'', true) = ''''
                 OR campus_id = current_setting(''app.campus_id'', true)::uuid
             )
             WITH CHECK (
                 current_setting(''app.campus_id'', true) IS NULL
                 OR current_setting(''app.campus_id'', true) = ''''
                 OR campus_id = current_setting(''app.campus_id'', true)::uuid
             )',
            t
        );
    END LOOP;
END $$;
