-- Listing policy enforcement is orthogonal to the owner/order lifecycle.
-- A case owns exactly one reversible effect; effective visibility requires no
-- active effect from any case.  This prevents one appeal from clearing a
-- restriction imposed by another case and prevents restore from resurrecting
-- owner-deleted, sold, or fulfilled listings.

CREATE TABLE listing_restriction_effects (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campus_id UUID NOT NULL REFERENCES campuses(id) ON DELETE RESTRICT,
    listing_id TEXT NOT NULL REFERENCES inventory(id) ON DELETE RESTRICT,
    case_id UUID NOT NULL REFERENCES moderation_cases(id) ON DELETE RESTRICT,
    effect_type TEXT NOT NULL DEFAULT 'visibility_restriction'
        CHECK (effect_type IN ('visibility_restriction')),
    source_kind TEXT NOT NULL DEFAULT 'moderation_case'
        CHECK (source_kind IN ('moderation_case', 'admin_takedown', 'legacy_admin_takedown')),
    imposed_by TEXT REFERENCES users(id) ON DELETE SET NULL,
    imposed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    released_by TEXT REFERENCES users(id) ON DELETE SET NULL,
    released_at TIMESTAMPTZ,
    release_reason TEXT CHECK (
        release_reason IS NULL OR char_length(btrim(release_reason)) BETWEEN 1 AND 2000
    ),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    CHECK (
        (released_at IS NULL AND released_by IS NULL AND release_reason IS NULL)
        OR released_at IS NOT NULL
    ),
    UNIQUE (case_id, effect_type)
);

CREATE INDEX listing_restriction_effects_active_listing_idx
    ON listing_restriction_effects(campus_id, listing_id)
    WHERE released_at IS NULL;

-- At most one current emergency takedown. Case-owned report restrictions are
-- intentionally composable and may coexist.
CREATE UNIQUE INDEX listing_restriction_effects_active_admin_uq
    ON listing_restriction_effects(campus_id, listing_id, effect_type)
    WHERE released_at IS NULL AND source_kind IN ('admin_takedown', 'legacy_admin_takedown');

ALTER TABLE listing_restriction_effects ENABLE ROW LEVEL SECURITY;
ALTER TABLE listing_restriction_effects FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON listing_restriction_effects
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

CREATE OR REPLACE FUNCTION validate_listing_restriction_effect()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    listing_campus UUID;
    case_row RECORD;
BEGIN
    SELECT campus_id INTO listing_campus
    FROM inventory WHERE id = NEW.listing_id;

    SELECT campus_id, resource_type, resource_id INTO case_row
    FROM moderation_cases WHERE id = NEW.case_id;

    IF listing_campus IS NULL OR case_row.campus_id IS NULL
       OR listing_campus <> NEW.campus_id
       OR case_row.campus_id <> NEW.campus_id
       OR case_row.resource_type <> 'listing'
       OR case_row.resource_id <> NEW.listing_id
    THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'listing restriction effect does not match its tenant-scoped case and listing';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER listing_restriction_effect_validate
    BEFORE INSERT OR UPDATE OF campus_id, listing_id, case_id
    ON listing_restriction_effects
    FOR EACH ROW EXECUTE FUNCTION validate_listing_restriction_effect();

CREATE OR REPLACE FUNCTION listing_has_active_restriction(candidate_id TEXT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT EXISTS (
        SELECT 1 FROM listing_restriction_effects effect
        WHERE effect.listing_id = candidate_id AND effect.released_at IS NULL
    )
$$;

-- Database-level rolling-deploy guard: old binaries only know how to relist by
-- setting status=active. They must fail closed while any policy effect exists.
CREATE OR REPLACE FUNCTION prevent_restricted_listing_activation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status <> 'active' AND NEW.status = 'active'
       AND listing_has_active_restriction(NEW.id)
    THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'listing has an active moderation restriction';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER inventory_prevent_restricted_activation
    BEFORE UPDATE OF status ON inventory
    FOR EACH ROW EXECUTE FUNCTION prevent_restricted_listing_activation();

-- The 0055 parent trigger locks wanted then offer before this trigger runs
-- (PostgreSQL orders same-kind triggers by name). This second guard keeps old
-- application binaries from inserting a response for a policy-hidden parent.
CREATE OR REPLACE FUNCTION reject_restricted_wanted_response()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF listing_has_active_restriction(NEW.wanted_listing_id)
       OR listing_has_active_restriction(NEW.offer_listing_id)
    THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'wanted response parent has an active moderation restriction';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER wanted_responses_restriction_guard
    BEFORE INSERT ON wanted_responses
    FOR EACH ROW EXECUTE FUNCTION reject_restricted_wanted_response();

-- Only high-confidence legacy takedowns are reconstructed automatically.
-- Ambiguous deleted rows remain lifecycle-deleted and require reconciliation.
WITH ranked_legacy_takedowns AS (
    SELECT audit.*, listing.owner_id,
           ROW_NUMBER() OVER (
               PARTITION BY audit.campus_id, listing.id
               ORDER BY audit.created_at DESC, audit.id DESC
           ) AS position
    FROM admin_audit_logs audit
    JOIN inventory listing
      ON listing.id = audit.target_id AND listing.campus_id = audit.campus_id
    WHERE audit.action = 'takedown_listing'
      AND audit.new_value = 'deleted'
      AND audit.old_value IN ('active', 'fulfilled')
      AND listing.status = 'deleted'
      AND audit.created_at >= listing.updated_at
)
INSERT INTO moderation_cases (
    campus_id, subject_user_id, resource_type, resource_id,
    source_type, source_ref_id, status, reason_category, public_reason,
    internal_details, resolution, opened_by, decided_by, decided_at,
    created_at, updated_at
)
SELECT
    audit.campus_id, audit.owner_id, 'listing', audit.target_id,
    'manual', 'legacy_admin_audit:' || audit.id, 'actioned',
    'admin_takedown', '该发布已由平台下架',
    jsonb_build_object('legacy_admin_audit_id', audit.id, 'backfilled', true),
    'content_restricted', audit.admin_id, audit.admin_id, audit.created_at,
    audit.created_at, audit.created_at
FROM ranked_legacy_takedowns audit
WHERE audit.position = 1
ON CONFLICT (source_type, source_ref_id) DO NOTHING;

INSERT INTO listing_restriction_effects (
    campus_id, listing_id, case_id, source_kind, imposed_by, imposed_at, metadata
)
SELECT moderation_case.campus_id, moderation_case.resource_id,
       moderation_case.id, 'legacy_admin_takedown', moderation_case.decided_by,
       moderation_case.decided_at,
       jsonb_build_object('backfilled', true)
FROM moderation_cases moderation_case
WHERE moderation_case.source_type = 'manual'
  AND moderation_case.source_ref_id LIKE 'legacy_admin_audit:%'
ON CONFLICT (case_id, effect_type) DO NOTHING;

INSERT INTO moderation_case_events (
    case_id, actor_id, event_type, from_status, to_status, note, created_at
)
SELECT moderation_case.id, moderation_case.decided_by, 'content_restricted',
       'open', 'actioned', 'Backfilled from a high-confidence legacy admin takedown',
       moderation_case.decided_at
FROM moderation_cases moderation_case
WHERE moderation_case.source_type = 'manual'
  AND moderation_case.source_ref_id LIKE 'legacy_admin_audit:%'
  AND NOT EXISTS (
      SELECT 1 FROM moderation_case_events event
      WHERE event.case_id = moderation_case.id AND event.event_type = 'content_restricted'
  );
