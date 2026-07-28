-- Per-user controls for listing recommendations and the campus intent stream.
--
-- `resource_id` is deliberately generic because inventory ids are TEXT while
-- intent ids are UUID. The API resolves the target inside the active campus and
-- derives `signal_key`; clients never get to manufacture a category/kind
-- signal for a resource that does not carry it.

CREATE TABLE IF NOT EXISTS feed_feedback (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campus_id       UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    user_id         TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    resource_type   TEXT NOT NULL CHECK (resource_type IN ('listing', 'intent')),
    resource_id     TEXT NOT NULL CHECK (char_length(btrim(resource_id)) BETWEEN 1 AND 255),
    action          TEXT NOT NULL CHECK (action IN ('hide', 'less_like_this', 'not_relevant')),
    -- listing:category:<category> or intent:kind:<kind>, always server-derived.
    signal_key      TEXT NOT NULL CHECK (char_length(btrim(signal_key)) BETWEEN 1 AND 255),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT feed_feedback_one_per_resource
        UNIQUE (user_id, campus_id, resource_type, resource_id)
);

CREATE INDEX IF NOT EXISTS idx_feed_feedback_exact
    ON feed_feedback (user_id, campus_id, resource_type, resource_id);
CREATE INDEX IF NOT EXISTS idx_feed_feedback_signal
    ON feed_feedback (user_id, campus_id, resource_type, signal_key, updated_at DESC)
    WHERE action = 'less_like_this';

CREATE TABLE IF NOT EXISTS feed_preferences (
    campus_id               UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    user_id                 TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    personalization_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    -- Signals older than this instant no longer influence ranking. Exact
    -- resource feedback remains an explicit hide regardless of this cutoff.
    signals_reset_at        TIMESTAMPTZ,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (campus_id, user_id)
);

ALTER TABLE feed_feedback ENABLE ROW LEVEL SECURITY;
ALTER TABLE feed_feedback FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON feed_feedback;
CREATE POLICY tenant_isolation ON feed_feedback
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

ALTER TABLE feed_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE feed_preferences FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON feed_preferences;
CREATE POLICY tenant_isolation ON feed_preferences
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
