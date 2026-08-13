-- SocialPersona is now a system-owned role/skin catalog.
--
-- Keep the legacy asset table and its cleanup columns for rollback and audit
-- history, but stop projecting any user-imported media.  New clients select
-- the allow-listed tokens served by the application; they never upload a
-- role, skin, image, URL, or prompt-derived public asset.

UPDATE social_personas
SET selected_asset_id = NULL,
    updated_at = NOW()
WHERE selected_asset_id IS NOT NULL;

WITH revoked AS (
    UPDATE social_persona_assets
    SET status = CASE WHEN status = 'deleted' THEN status ELSE 'revoked' END,
        revoked_at = COALESCE(revoked_at, NOW()),
        cleanup_requested_at = COALESCE(cleanup_requested_at, NOW()),
        cleanup_next_attempt_at = NULL,
        updated_at = NOW()
    WHERE status NOT IN ('deleted', 'revoked')
    RETURNING id, persona_id, user_id, campus_id, asset_type,
              status, moderation_status
)
INSERT INTO social_persona_audits
    (persona_id, user_id, campus_id, action, snapshot)
SELECT persona_id, user_id, campus_id, 'asset_revoked',
       jsonb_build_object(
           'asset_id', id,
           'asset_type', asset_type,
           'status', status,
           'moderation_status', moderation_status,
           'reason', 'system_catalog_only'
       )
FROM revoked;

COMMENT ON TABLE social_persona_assets IS
    'Legacy rollback/audit table only. Current clients cannot import or publish user-provided role media; SocialPersona uses the server-owned token catalog.';

COMMENT ON COLUMN social_personas.selected_asset_id IS
    'Legacy nullable reference retained for rollback only; current public projections ignore it and new clients select system catalog tokens.';
