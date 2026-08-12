-- Authoritative file/link references for one-to-one Relationship Spaces.
--
-- A message quote is only a reference to this row.  It is not allowed to
-- carry an arbitrary storage URL or an unfetched link preview.  File objects
-- are keyed inside the configured platform bucket; link objects retain a
-- normalized URL and are opened only after an explicit user action.

CREATE TABLE IF NOT EXISTS chat_shared_objects (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campus_id UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    conversation_id UUID NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
    created_by TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind IN ('file', 'link')),
    title TEXT NOT NULL CHECK (char_length(title) BETWEEN 1 AND 200),
    storage_key TEXT,
    canonical_url TEXT,
    mime_type TEXT,
    size_bytes BIGINT CHECK (size_bytes IS NULL OR (size_bytes >= 0 AND size_bytes <= 2147483648)),
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'revoked', 'deleted')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    revoked_at TIMESTAMPTZ,
    CHECK (
        (kind = 'file'
            AND storage_key = ('chat/' || campus_id::text || '/' || id::text)
            AND canonical_url IS NULL)
        OR
        (kind = 'link' AND storage_key IS NULL AND canonical_url IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_chat_shared_objects_conversation
    ON chat_shared_objects(conversation_id, status, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_chat_shared_objects_creator
    ON chat_shared_objects(created_by, created_at DESC, id DESC);

ALTER TABLE chat_shared_objects ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat_shared_objects FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON chat_shared_objects;
CREATE POLICY tenant_isolation ON chat_shared_objects
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

-- Expand the structured-quote vocabulary only after the authoritative table
-- exists.  Existing listing/order/hitl_offer rows remain valid and unchanged.
ALTER TABLE chat_messages
    DROP CONSTRAINT IF EXISTS chat_messages_quote_kind_check;
ALTER TABLE chat_messages
    ADD CONSTRAINT chat_messages_quote_kind_check
    CHECK (quote_kind IS NULL OR quote_kind IN ('listing', 'order', 'hitl_offer', 'file', 'link'));

COMMENT ON TABLE chat_shared_objects IS
    'Authoritative file/link references for direct Relationship Spaces; message quotes point here and never infer attention.';
