-- Remove the demo seed accounts and their data (migrations/0005_seed_data.sql).
--
-- Those rows exist in every database because 0005 lives in migrations/ despite
-- being labelled "run manually". They share the published password 'Test1234'
-- and include a platform administrator, so production must not keep them —
-- src/db.rs refuses to start in production while they are present.
--
-- Safe to run repeatedly. Child rows go first; FK cascades cover the rest.
--
-- `documents` is created by the application at boot, not by a migration, so on a
-- brand-new database this script runs before that table exists. An unguarded
-- DELETE against it aborted the whole transaction and silently skipped every
-- removal that followed, leaving the seed accounts in place — and a fresh
-- production deployment then refused to start at all. The guard below is the
-- fix; the table simply has nothing to clean when it is absent.
BEGIN;

-- ON COMMIT DROP so the script leaves no session state behind. Without it a
-- second run on the same connection failed with "relation already exists",
-- which made "safe to run repeatedly" true only for callers that happened to
-- reconnect between runs.
CREATE TEMP TABLE demo_seed_users(id TEXT PRIMARY KEY) ON COMMIT DROP;
INSERT INTO demo_seed_users VALUES
    ('a0000000-0000-0000-0000-000000000001'),
    ('b0000000-0000-0000-0000-000000000001'),
    ('b0000000-0000-0000-0000-000000000002'),
    ('s0000000-0000-0000-0000-000000000001'),
    ('s0000000-0000-0000-0000-000000000002'),
    ('banned00-0000-0000-0000-000000000001');

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'documents'
    ) THEN
        DELETE FROM documents WHERE id IN (
            SELECT id FROM inventory WHERE owner_id IN (SELECT id FROM demo_seed_users)
        );
    END IF;
END $$;
DELETE FROM orders WHERE buyer_id IN (SELECT id FROM demo_seed_users)
                      OR seller_id IN (SELECT id FROM demo_seed_users);
DELETE FROM inventory WHERE owner_id IN (SELECT id FROM demo_seed_users);
DELETE FROM notifications WHERE user_id IN (SELECT id FROM demo_seed_users);
DELETE FROM campus_memberships WHERE user_id IN (SELECT id FROM demo_seed_users);
DELETE FROM users WHERE id IN (SELECT id FROM demo_seed_users);

-- Fail loudly rather than leaving the caller to believe it worked. The previous
-- failure mode was a script that reported success while the accounts survived.
DO $$
DECLARE
    remaining INT;
BEGIN
    SELECT COUNT(*) INTO remaining
    FROM users WHERE id IN (SELECT id FROM demo_seed_users);
    IF remaining > 0 THEN
        RAISE EXCEPTION 'demo seed removal incomplete: % account(s) remain', remaining;
    END IF;
END $$;

COMMIT;
