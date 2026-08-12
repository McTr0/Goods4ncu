-- Expire abandoned persona uploads so an interrupted client cannot leave an
-- unbounded number of private-bucket objects behind.
--
-- The cleanup worker is the authority for this transition.  An expired
-- pending_upload is revoked (never public) and then follows the same signed
-- DELETE/retry path as an explicit user revoke.

ALTER TABLE social_persona_audits
    DROP CONSTRAINT IF EXISTS social_persona_audits_action_check;
ALTER TABLE social_persona_audits
    ADD CONSTRAINT social_persona_audits_action_check
    CHECK (action IN (
        'created', 'edited', 'published', 'archived',
        'asset_created', 'asset_revoked', 'asset_expired'
    ));

CREATE INDEX IF NOT EXISTS idx_social_persona_assets_pending_expiry
    ON social_persona_assets(created_at, id)
    WHERE status = 'pending_upload'
      AND cleanup_requested_at IS NULL;

COMMENT ON COLUMN social_persona_assets.status IS
    'Upload and moderation lifecycle; stale pending_upload rows are revoked by the cleanup worker and never become public.';
