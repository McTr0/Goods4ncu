-- A mail sender may communicate a coarse handling horizon without creating
-- an urgency or attention signal. The recipient's contact mute/busy rules
-- still decide whether any notification is emitted.

ALTER TABLE chat_conversations
    ADD COLUMN IF NOT EXISTS mail_expectation TEXT NOT NULL DEFAULT 'ordinary';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'chat_conversations_mail_expectation_check'
    ) THEN
        ALTER TABLE chat_conversations
            ADD CONSTRAINT chat_conversations_mail_expectation_check
            CHECK (mail_expectation IN ('ordinary', 'today'));
    END IF;
END $$;

COMMENT ON COLUMN chat_conversations.mail_expectation IS
    'Sender-declared mail handling horizon; never an online, read, typing, or notification priority fact';
