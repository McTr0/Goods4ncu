-- Retire the rollback-only columns from the attention migration.
--
-- 0062 deliberately recreated these columns for a short compatibility window
-- after the read/typing routes were made no-ops.  The application has now
-- removed those routes, settings, and WebSocket events; keeping the columns
-- would leave a misleading server-side attention surface for ad-hoc queries
-- and future code.  Device-local LOCALLY_SEEN and explicit acknowledgements
-- are the only supported semantics.

ALTER TABLE chat_messages
    DROP COLUMN IF EXISTS read_at,
    DROP COLUMN IF EXISTS read_by;

ALTER TABLE chat_conversation_members
    DROP COLUMN IF EXISTS unread_count,
    DROP COLUMN IF EXISTS last_read_message_id,
    DROP COLUMN IF EXISTS read_receipt_mode;

DO $$
BEGIN
    IF to_regclass('public.chat_connections') IS NOT NULL THEN
        ALTER TABLE chat_connections
            DROP COLUMN IF EXISTS unread_count;
    END IF;
END $$;

ALTER TABLE users
    DROP COLUMN IF EXISTS chat_read_receipt_mode;
