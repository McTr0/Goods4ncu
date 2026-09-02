-- Migration 0113: Purge insecure demo seeds from 0005_seed_data.sql.
--
-- 0005_seed_data.sql historically seeded insecure demo accounts sharing the
-- published password 'Test1234' (including a platform admin).
--
-- This migration idempotently purges the 6 fixed demo seed accounts and their
-- dependent records, permanently resolving the security risk at schema migration
-- time and decoupling the production application binary from hardcoded test UUIDs.

DO $$
DECLARE
    seed_ids CONSTANT text[] := ARRAY[
        'a0000000-0000-0000-0000-000000000001',
        'b0000000-0000-0000-0000-000000000001',
        'b0000000-0000-0000-0000-000000000002',
        's0000000-0000-0000-0000-000000000001',
        's0000000-0000-0000-0000-000000000002',
        'banned00-0000-0000-0000-000000000001'
    ];
BEGIN
    -- Delete from documents if the table exists (it has no foreign key constraint to inventory)
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'documents'
    ) THEN
        DELETE FROM documents WHERE id IN (
            SELECT id FROM inventory WHERE owner_id = ANY(seed_ids)
        );
    END IF;

    -- Delete dependent orders
    DELETE FROM orders WHERE buyer_id = ANY(seed_ids) OR seller_id = ANY(seed_ids);

    -- Delete inventory items owned by seed users
    DELETE FROM inventory WHERE owner_id = ANY(seed_ids);

    -- Delete notifications for seed users
    DELETE FROM notifications WHERE user_id = ANY(seed_ids);

    -- Delete campus memberships for seed users
    DELETE FROM campus_memberships WHERE user_id = ANY(seed_ids);

    -- Delete demo users (foreign keys with ON DELETE CASCADE cover chat, watchlist, etc.)
    DELETE FROM users WHERE id = ANY(seed_ids);
END $$;
