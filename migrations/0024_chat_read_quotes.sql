-- Add user-controlled read receipt preferences and structured message quotes.

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

ALTER TABLE chat_conversation_members
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

ALTER TABLE chat_messages
ADD COLUMN IF NOT EXISTS quote_kind TEXT NULL,
ADD COLUMN IF NOT EXISTS quote_ref_id TEXT NULL,
ADD COLUMN IF NOT EXISTS quote_snapshot JSONB NOT NULL DEFAULT '{}'::jsonb;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'chat_messages_quote_kind_check'
    ) THEN
        ALTER TABLE chat_messages
        ADD CONSTRAINT chat_messages_quote_kind_check
        CHECK (quote_kind IS NULL OR quote_kind IN ('listing', 'order', 'hitl_offer'));
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_chat_messages_quote_ref
ON chat_messages(quote_kind, quote_ref_id)
WHERE quote_kind IS NOT NULL AND quote_ref_id IS NOT NULL;
