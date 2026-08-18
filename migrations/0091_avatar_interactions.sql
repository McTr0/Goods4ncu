-- Durable, user-controlled avatar interactions for active realtime chats.
--
-- An interaction is presentation state, not presence, read state, or an
-- autonomous agent message. The sender remains the only actor recorded on the
-- message; the recipient policy only selects the choreography rendered by
-- clients.

ALTER TABLE chat_messages
    DROP CONSTRAINT IF EXISTS chat_messages_kind_check;

ALTER TABLE chat_messages
    ADD CONSTRAINT chat_messages_kind_check
        CHECK (kind IN ('opening', 'message', 'avatar_interaction')),
    ADD COLUMN IF NOT EXISTS interaction_payload JSONB;

ALTER TABLE chat_messages
    DROP CONSTRAINT IF EXISTS chat_messages_interaction_payload_check;

ALTER TABLE chat_messages
    ADD CONSTRAINT chat_messages_interaction_payload_check CHECK (
        (kind = 'avatar_interaction' AND jsonb_typeof(interaction_payload) = 'object')
        OR (kind <> 'avatar_interaction' AND interaction_payload IS NULL)
    );

CREATE TABLE IF NOT EXISTS avatar_interaction_preferences (
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    campus_id UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    policies JSONB NOT NULL DEFAULT
        '{"wave":"light","poke":"receive_only","high_five":"light","encourage":"light"}'::jsonb
        CHECK (jsonb_typeof(policies) = 'object'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, campus_id)
);

CREATE TABLE IF NOT EXISTS avatar_interaction_contact_overrides (
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    peer_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    campus_id UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    policies JSONB NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(policies) = 'object'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, peer_user_id, campus_id),
    CONSTRAINT avatar_interaction_contact_overrides_no_self
        CHECK (user_id <> peer_user_id)
);

CREATE INDEX IF NOT EXISTS idx_avatar_interaction_contact_overrides_peer
    ON avatar_interaction_contact_overrides(peer_user_id, campus_id, user_id);

ALTER TABLE avatar_interaction_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE avatar_interaction_preferences FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON avatar_interaction_preferences;
CREATE POLICY tenant_isolation ON avatar_interaction_preferences
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

ALTER TABLE avatar_interaction_contact_overrides ENABLE ROW LEVEL SECURITY;
ALTER TABLE avatar_interaction_contact_overrides FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON avatar_interaction_contact_overrides;
CREATE POLICY tenant_isolation ON avatar_interaction_contact_overrides
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

COMMENT ON COLUMN chat_messages.interaction_payload IS
    'Versioned avatar choreography payload. Never presence, read state, emotion inference, or an autonomous agent reply.';
COMMENT ON TABLE avatar_interaction_preferences IS
    'Campus-scoped inbound avatar interaction defaults controlled by the recipient.';
COMMENT ON TABLE avatar_interaction_contact_overrides IS
    'Per-contact inbound avatar interaction overrides; absent actions inherit the global preference.';
