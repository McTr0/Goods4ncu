-- User-controlled, campus-scoped role presentation.
--
-- A persona is a presentation layer, not an identity or an Agent.  The first
-- version stores only a validated token configuration and user-selected
-- labels.  Generated media and photo stylisation remain a later, separately
-- reviewed asset workflow.

CREATE TABLE IF NOT EXISTS social_personas (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    campus_id UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    representation_mode TEXT NOT NULL DEFAULT 'trait_mapped'
        CHECK (representation_mode IN ('trait_mapped', 'role_character')),
    style_version TEXT NOT NULL DEFAULT 'v1'
        CHECK (style_version = 'v1'),
    appearance_config JSONB NOT NULL DEFAULT
        '{"palette":"teal","silhouette":"soft","accessory":"none","outfit":"campus"}'::jsonb
        CHECK (jsonb_typeof(appearance_config) = 'object'),
    self_descriptions JSONB NOT NULL DEFAULT '[]'::jsonb
        CHECK (jsonb_typeof(self_descriptions) = 'array'),
    contact_posture TEXT NOT NULL DEFAULT 'leave_message'
        CHECK (contact_posture IN ('leave_message', 'connection_allowed', 'busy', 'later')),
    status TEXT NOT NULL DEFAULT 'draft'
        CHECK (status IN ('draft', 'published', 'archived')),
    published_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, campus_id)
);

CREATE INDEX IF NOT EXISTS idx_social_personas_campus_published
    ON social_personas(campus_id, updated_at DESC)
    WHERE status = 'published';

CREATE TABLE IF NOT EXISTS social_persona_audits (
    id BIGSERIAL PRIMARY KEY,
    persona_id UUID NOT NULL REFERENCES social_personas(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    campus_id UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    action TEXT NOT NULL
        CHECK (action IN ('created', 'edited', 'published', 'archived')),
    snapshot JSONB NOT NULL CHECK (jsonb_typeof(snapshot) = 'object'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_social_persona_audits_persona_created
    ON social_persona_audits(persona_id, created_at DESC, id DESC);

ALTER TABLE social_personas ENABLE ROW LEVEL SECURITY;
ALTER TABLE social_personas FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON social_personas;
CREATE POLICY tenant_isolation ON social_personas
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

ALTER TABLE social_persona_audits ENABLE ROW LEVEL SECURITY;
ALTER TABLE social_persona_audits FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON social_persona_audits;
CREATE POLICY tenant_isolation ON social_persona_audits
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

COMMENT ON TABLE social_personas IS
    'User-controlled role presentation; never an identity proof, Agent, or inferred presence state.';
COMMENT ON COLUMN social_personas.status IS
    'draft is private, published is visible in the campus, archived restores the ordinary avatar.';
COMMENT ON COLUMN social_personas.contact_posture IS
    'Explicit coarse contact preference; never online, typing, last-seen, or read state.';
