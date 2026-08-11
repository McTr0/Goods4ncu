-- Make attention explicit: a recipient may publish one intentional response per
-- message.  This table is separate from read_at/read_by so opening a thread,
-- receiving a push, or beginning to type never creates a public attention fact.

CREATE TABLE IF NOT EXISTS chat_message_acknowledgements (
    message_id BIGINT NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind IN ('received', 'will_review', 'completed')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (message_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_chat_message_acknowledgements_message
    ON chat_message_acknowledgements(message_id, updated_at DESC);

COMMENT ON TABLE chat_message_acknowledgements IS
    'Explicit recipient actions; never inferred from delivery, push, open, typing, or media playback';
