-- Ephemeral viewer leases for campus location chats.
--
-- Location chats are campus commons rather than groups. Opening one does not
-- create a durable chat_space_members row. A client renews a short lease while
-- the room is visible, and counts exclude expired leases. Exact location and
-- historical presence are intentionally not stored.

CREATE TABLE IF NOT EXISTS chat_space_presence (
    space_id UUID NOT NULL,
    campus_id UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (space_id, user_id),
    CONSTRAINT chat_space_presence_space_campus_fk
        FOREIGN KEY (space_id, campus_id)
        REFERENCES chat_spaces(id, campus_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_chat_space_presence_active
    ON chat_space_presence(space_id, campus_id, expires_at);

ALTER TABLE chat_space_presence ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat_space_presence FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON chat_space_presence;
CREATE POLICY tenant_isolation ON chat_space_presence
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

COMMENT ON TABLE chat_space_presence IS
    'Short-lived location-chat viewer leases; never durable group membership or location history.';
COMMENT ON COLUMN chat_space_presence.expires_at IS
    'Lease deadline. API counts only rows later than NOW(); clients renew every 30-60 seconds.';
