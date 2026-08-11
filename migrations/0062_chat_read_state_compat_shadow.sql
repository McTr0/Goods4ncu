-- Keep the retired attention columns as a rollback shadow during the first
-- privacy migration window.  No application path reads or writes these
-- columns; all public chat state is derived from sent status, local device
-- markers, and explicit acknowledgements.  A later cleanup migration may
-- remove the shadow after old clients and rollback procedures are retired.

ALTER TABLE chat_messages
    ADD COLUMN IF NOT EXISTS read_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS read_by TEXT;

ALTER TABLE chat_conversation_members
    ADD COLUMN IF NOT EXISTS unread_count INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS last_read_message_id BIGINT,
    ADD COLUMN IF NOT EXISTS read_receipt_mode TEXT NOT NULL DEFAULT 'inherit';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'chat_conversation_members_read_receipt_mode_check'
    ) THEN
        ALTER TABLE chat_conversation_members
        ADD CONSTRAINT chat_conversation_members_read_receipt_mode_check
        CHECK (read_receipt_mode IN ('inherit', 'auto', 'manual'));
    END IF;
END $$;

ALTER TABLE chat_connections
    ADD COLUMN IF NOT EXISTS unread_count INTEGER NOT NULL DEFAULT 0;

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS chat_read_receipt_mode TEXT NOT NULL DEFAULT 'auto';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'users_chat_read_receipt_mode_check'
    ) THEN
        ALTER TABLE users
        ADD CONSTRAINT users_chat_read_receipt_mode_check
        CHECK (chat_read_receipt_mode IN ('auto', 'manual'));
    END IF;
END $$;

COMMENT ON COLUMN chat_messages.read_at IS
    'Retired compatibility shadow; never written or exposed by chat APIs.';
COMMENT ON COLUMN chat_messages.read_by IS
    'Retired compatibility shadow; never written or exposed by chat APIs.';
COMMENT ON COLUMN chat_conversation_members.unread_count IS
    'Retired compatibility shadow; device-local unread markers are authoritative.';
COMMENT ON COLUMN chat_conversation_members.last_read_message_id IS
    'Retired compatibility shadow; device-local seen markers are authoritative.';
COMMENT ON COLUMN chat_conversation_members.read_receipt_mode IS
    'Retired compatibility shadow; explicit message acknowledgements replace read preferences.';
COMMENT ON COLUMN chat_connections.unread_count IS
    'Retired compatibility shadow; device-local unread markers are authoritative.';
COMMENT ON COLUMN users.chat_read_receipt_mode IS
    'Retired compatibility shadow; explicit message acknowledgements replace read preferences.';
