-- Explicit relationship-space memory facts.
--
-- A Pin is a user action on an existing direct message.  It is deliberately
-- not a second message/event authority: the source message remains the source
-- of truth and a hidden/deleted/inaccessible source invalidates the projection.
-- Pins are visible to both participants in the same campus, with the actor
-- preserved so the UI never implies that the other person pinned it.

CREATE TABLE IF NOT EXISTS chat_relationship_pins (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campus_id UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    conversation_id UUID NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
    message_id BIGINT NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, message_id)
);

CREATE INDEX IF NOT EXISTS idx_chat_relationship_pins_conversation
    ON chat_relationship_pins(conversation_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_chat_relationship_pins_message
    ON chat_relationship_pins(message_id, created_at DESC, id DESC);

ALTER TABLE chat_relationship_pins ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat_relationship_pins FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON chat_relationship_pins;
CREATE POLICY tenant_isolation ON chat_relationship_pins
    USING (
        current_setting('app.campus_id', true) IS NULL
        OR current_setting('app.campus_id', true) = ''
        OR campus_id = current_setting('app.campus_id', true)::uuid
    )
    WITH CHECK (
        current_setting('app.campus_id', true) IS NULL
        OR current_setting('app.campus_id', true) = ''
        OR campus_id = current_setting('app.campus_id', true)::uuid
    );

COMMENT ON TABLE chat_relationship_pins IS
    'Explicit shared memory markers on existing direct messages; never inferred from opening, push, typing, or media playback.';
