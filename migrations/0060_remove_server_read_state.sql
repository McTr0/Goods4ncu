-- Complete the attention-privacy migration.
--
-- Read position is now device-local and explicit acknowledgement is the only
-- public response.  The rollback window for the old automatic read/typing
-- protocol has ended, so remove its persisted columns instead of leaving a
-- tempting server-side source of attention facts.

DROP INDEX IF EXISTS idx_chat_messages_unread;

ALTER TABLE chat_messages
    DROP COLUMN IF EXISTS read_at,
    DROP COLUMN IF EXISTS read_by;

ALTER TABLE chat_conversation_members
    DROP COLUMN IF EXISTS unread_count,
    DROP COLUMN IF EXISTS last_read_message_id,
    DROP COLUMN IF EXISTS read_receipt_mode;

-- The legacy permanent-connection table is no longer a write path, but its
-- unread counter would still look like a server-side reading position during
-- rollback or ad-hoc queries.  Migration 0019 removes this table on a fresh
-- schema, while older installations may still have it during the compatibility
-- window, so keep this step conditional.
DO $$
BEGIN
    IF to_regclass('public.chat_connections') IS NOT NULL THEN
        ALTER TABLE chat_connections
            DROP COLUMN IF EXISTS unread_count;
    END IF;
END $$;

ALTER TABLE users
    DROP COLUMN IF EXISTS chat_read_receipt_mode;
