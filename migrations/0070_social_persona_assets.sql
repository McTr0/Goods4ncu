-- Reviewed image assets for the user-controlled SocialPersona layer.
--
-- An asset is never an identity proof and is never public merely because a
-- client claims that an upload succeeded.  The API creates the UUID and
-- storage key, probes the platform object after upload, and only then moves
-- the row through moderation to `active`.  A persona selects an asset
-- explicitly; publishing the persona remains a separate user action.

CREATE TABLE IF NOT EXISTS social_persona_assets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    persona_id UUID NOT NULL REFERENCES social_personas(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    campus_id UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    asset_type TEXT NOT NULL
        CHECK (asset_type IN ('illustration', 'photo_stylized')),
    storage_key TEXT NOT NULL UNIQUE,
    declared_mime_type TEXT NOT NULL
        CHECK (declared_mime_type IN ('image/png', 'image/jpeg', 'image/webp')),
    declared_size_bytes BIGINT NOT NULL
        CHECK (declared_size_bytes BETWEEN 1 AND 10485760),
    uploaded_size_bytes BIGINT
        CHECK (uploaded_size_bytes IS NULL OR uploaded_size_bytes BETWEEN 1 AND 10485760),
    uploaded_mime_type TEXT,
    storage_verified_at TIMESTAMPTZ,
    moderation_status TEXT NOT NULL DEFAULT 'not_required'
        CHECK (moderation_status IN ('not_required', 'pending', 'approved', 'rejected', 'failed')),
    status TEXT NOT NULL DEFAULT 'pending_upload'
        CHECK (status IN ('pending_upload', 'pending_review', 'active', 'rejected', 'revoked', 'deleted')),
    reject_reason TEXT,
    cleanup_requested_at TIMESTAMPTZ,
    cleanup_completed_at TIMESTAMPTZ,
    cleanup_attempts INTEGER NOT NULL DEFAULT 0,
    cleanup_next_attempt_at TIMESTAMPTZ,
    cleanup_last_error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    revoked_at TIMESTAMPTZ,
    CHECK (storage_key = ('persona/' || campus_id::text || '/' || persona_id::text || '/' || id::text)),
    CHECK (status <> 'active' OR storage_verified_at IS NOT NULL),
    CHECK (status <> 'active' OR moderation_status IN ('not_required', 'approved')),
    CHECK (status NOT IN ('pending_review', 'active') OR uploaded_size_bytes IS NOT NULL)
);

ALTER TABLE social_personas
    ADD COLUMN IF NOT EXISTS selected_asset_id UUID;

ALTER TABLE social_persona_assets
    ADD CONSTRAINT social_persona_assets_id_persona_unique
    UNIQUE (id, persona_id);

ALTER TABLE social_persona_audits
    DROP CONSTRAINT IF EXISTS social_persona_audits_action_check;
ALTER TABLE social_persona_audits
    ADD CONSTRAINT social_persona_audits_action_check
    CHECK (action IN (
        'created', 'edited', 'published', 'archived',
        'asset_created', 'asset_revoked'
    ));

ALTER TABLE social_personas
    DROP CONSTRAINT IF EXISTS social_personas_selected_asset_fk;
ALTER TABLE social_personas
    ADD CONSTRAINT social_personas_selected_asset_fk
    FOREIGN KEY (selected_asset_id, id)
    REFERENCES social_persona_assets(id, persona_id);

CREATE INDEX IF NOT EXISTS idx_social_persona_assets_owner
    ON social_persona_assets(user_id, campus_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_social_persona_assets_cleanup
    ON social_persona_assets(status, cleanup_next_attempt_at, cleanup_requested_at)
    WHERE cleanup_requested_at IS NOT NULL AND cleanup_completed_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_moderation_jobs_persona_asset_live
    ON moderation_jobs(resource_type, resource_id)
    WHERE resource_type = 'social_persona_asset'
      AND status IN ('pending', 'processing');

ALTER TABLE social_persona_assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE social_persona_assets FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON social_persona_assets;
CREATE POLICY tenant_isolation ON social_persona_assets
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

COMMENT ON TABLE social_persona_assets IS
    'Explicitly selected, moderated presentation images; never identity proof or inferred presence.';
COMMENT ON COLUMN social_persona_assets.storage_key IS
    'Server-generated private-bucket key; clients cannot choose an arbitrary object key.';
COMMENT ON COLUMN social_persona_assets.status IS
    'Upload and moderation lifecycle; only active assets can be selected or publicly projected.';
