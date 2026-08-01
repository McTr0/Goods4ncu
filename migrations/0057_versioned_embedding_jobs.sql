-- Durable, coalescing projection queue for listing embeddings.
--
-- The queue stores the latest desired revision per listing. Producers never
-- call an embedding provider: every inventory write and visibility-policy
-- change records projection work in the same database transaction.

ALTER TABLE inventory
    ADD COLUMN content_revision BIGINT NOT NULL DEFAULT 1;

ALTER TABLE inventory
    ADD CONSTRAINT inventory_content_revision_positive
    CHECK (content_revision > 0);

-- Projection metadata is nullable for compatibility with legacy documents
-- that may not correspond to an inventory row or whose original model is
-- unknown. The embedding worker replaces these fields on its first rebuild.
ALTER TABLE documents
    ADD COLUMN campus_id UUID,
    ADD COLUMN source_revision BIGINT,
    ADD COLUMN content_hash TEXT,
    ADD COLUMN embedding_provider TEXT,
    ADD COLUMN embedding_model TEXT,
    ADD COLUMN embedding_version TEXT,
    ADD COLUMN embedded_at TIMESTAMPTZ;

UPDATE documents AS document
SET campus_id = inventory.campus_id
FROM inventory
WHERE inventory.id = document.id
  AND document.campus_id IS NULL;

-- Do not infer source_revision for legacy vectors: their text may predate the
-- current inventory row. NULL forces the backfill worker to rebuild them.

ALTER TABLE documents
    ADD CONSTRAINT documents_source_revision_positive
    CHECK (source_revision IS NULL OR source_revision > 0),
    ADD CONSTRAINT documents_content_hash_nonempty
    CHECK (content_hash IS NULL OR char_length(content_hash) > 0);

CREATE INDEX documents_projection_freshness_idx
    ON documents (campus_id, id, source_revision);

CREATE TABLE embedding_jobs (
    listing_id TEXT PRIMARY KEY,
    campus_id UUID NOT NULL,
    desired_revision BIGINT NOT NULL CHECK (desired_revision > 0),
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'processing', 'completed', 'dead_lettered')),
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    max_attempts INTEGER NOT NULL DEFAULT 8 CHECK (max_attempts > 0),
    available_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    locked_by TEXT,
    locked_until TIMESTAMPTZ,
    last_error TEXT,
    requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    dead_lettered_at TIMESTAMPTZ,
    CHECK ((locked_by IS NULL) = (locked_until IS NULL)),
    CHECK (
        (status = 'processing' AND locked_by IS NOT NULL)
        OR (status <> 'processing' AND locked_by IS NULL)
    ),
    CHECK ((status = 'dead_lettered') = (dead_lettered_at IS NOT NULL))
);

CREATE INDEX embedding_jobs_claim_idx
    ON embedding_jobs (available_at, requested_at, listing_id)
    WHERE status IN ('pending', 'processing');

CREATE INDEX embedding_jobs_campus_status_idx
    ON embedding_jobs (campus_id, status, requested_at);

ALTER TABLE embedding_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE embedding_jobs FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON embedding_jobs
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

-- Coalesce a request without stealing an in-flight lease. If a listing changes
-- while revision N is processing, its row remains owned by that worker but the
-- desired revision advances to N+1. Completion/failure APIs compare revisions
-- and return the newest work to pending instead of publishing stale state.
CREATE OR REPLACE FUNCTION request_listing_embedding(
    requested_listing_id TEXT,
    requested_campus_id UUID,
    requested_revision BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO embedding_jobs (
        listing_id, campus_id, desired_revision, status, attempts,
        available_at, requested_at
    )
    VALUES (
        requested_listing_id, requested_campus_id, requested_revision,
        'pending', 0, NOW(), NOW()
    )
    ON CONFLICT (listing_id) DO UPDATE
    SET campus_id = EXCLUDED.campus_id,
        desired_revision = GREATEST(
            embedding_jobs.desired_revision,
            EXCLUDED.desired_revision
        ),
        status = CASE
            WHEN embedding_jobs.status = 'processing' THEN 'processing'
            ELSE 'pending'
        END,
        attempts = CASE
            WHEN embedding_jobs.status = 'processing' THEN embedding_jobs.attempts
            ELSE 0
        END,
        available_at = CASE
            WHEN embedding_jobs.status = 'processing' THEN embedding_jobs.available_at
            ELSE NOW()
        END,
        locked_by = CASE
            WHEN embedding_jobs.status = 'processing' THEN embedding_jobs.locked_by
            ELSE NULL
        END,
        locked_until = CASE
            WHEN embedding_jobs.status = 'processing' THEN embedding_jobs.locked_until
            ELSE NULL
        END,
        last_error = NULL,
        requested_at = NOW(),
        completed_at = NULL,
        dead_lettered_at = NULL;
END;
$$;

-- content_revision is database-owned. Semantic or visibility changes always
-- advance exactly once. A +1 supplied without such a change is reserved for
-- policy triggers (notably restriction effects); all other direct mutations
-- are discarded so revisions cannot move backwards or skip values.
CREATE OR REPLACE FUNCTION maintain_inventory_content_revision()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    projection_changed BOOLEAN;
BEGIN
    projection_changed :=
        NEW.title IS DISTINCT FROM OLD.title
        OR NEW.category IS DISTINCT FROM OLD.category
        OR NEW.brand IS DISTINCT FROM OLD.brand
        OR NEW.condition_score IS DISTINCT FROM OLD.condition_score
        OR NEW.defects IS DISTINCT FROM OLD.defects
        OR NEW.description IS DISTINCT FROM OLD.description
        OR NEW.direction IS DISTINCT FROM OLD.direction
        OR NEW.status IS DISTINCT FROM OLD.status
        OR NEW.campus_id IS DISTINCT FROM OLD.campus_id;

    IF projection_changed THEN
        NEW.content_revision := OLD.content_revision + 1;
    ELSIF NEW.content_revision = OLD.content_revision + 1 THEN
        -- Deliberate policy-driven invalidation.
        NULL;
    ELSE
        NEW.content_revision := OLD.content_revision;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER inventory_maintain_content_revision
    BEFORE UPDATE ON inventory
    FOR EACH ROW
    EXECUTE FUNCTION maintain_inventory_content_revision();

CREATE OR REPLACE FUNCTION enqueue_inventory_embedding()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM request_listing_embedding(
        NEW.id, NEW.campus_id, NEW.content_revision
    );
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION enqueue_deleted_inventory_embedding()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM request_listing_embedding(
        OLD.id, OLD.campus_id, OLD.content_revision + 1
    );
    RETURN OLD;
END;
$$;

CREATE TRIGGER inventory_enqueue_embedding_insert
    AFTER INSERT ON inventory
    FOR EACH ROW
    EXECUTE FUNCTION enqueue_inventory_embedding();

CREATE TRIGGER inventory_enqueue_embedding_update
    AFTER UPDATE ON inventory
    FOR EACH ROW
    WHEN (NEW.content_revision IS DISTINCT FROM OLD.content_revision)
    EXECUTE FUNCTION enqueue_inventory_embedding();

CREATE TRIGGER inventory_enqueue_embedding_delete
    AFTER DELETE ON inventory
    FOR EACH ROW
    EXECUTE FUNCTION enqueue_deleted_inventory_embedding();

-- Restriction effects alter effective visibility without necessarily touching
-- inventory.status. Advance the listing revision for impose, release, restore,
-- retarget and delete so the worker can re-read policy and choose embed/delete.
CREATE OR REPLACE FUNCTION invalidate_restricted_listing_embedding()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        UPDATE inventory
        SET content_revision = content_revision + 1
        WHERE id = OLD.listing_id;
        RETURN OLD;
    END IF;

    IF TG_OP = 'INSERT' THEN
        UPDATE inventory
        SET content_revision = content_revision + 1
        WHERE id = NEW.listing_id;
        RETURN NEW;
    END IF;

    IF OLD.listing_id IS DISTINCT FROM NEW.listing_id THEN
        UPDATE inventory
        SET content_revision = content_revision + 1
        WHERE id = OLD.listing_id;
    END IF;

    IF OLD.listing_id IS DISTINCT FROM NEW.listing_id
       OR OLD.campus_id IS DISTINCT FROM NEW.campus_id
       OR OLD.released_at IS DISTINCT FROM NEW.released_at
    THEN
        UPDATE inventory
        SET content_revision = content_revision + 1
        WHERE id = NEW.listing_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER listing_restriction_effect_invalidate_embedding
    AFTER INSERT OR DELETE OR UPDATE OF listing_id, campus_id, released_at
    ON listing_restriction_effects
    FOR EACH ROW
    EXECUTE FUNCTION invalidate_restricted_listing_embedding();

-- Existing rows did not fire the new inventory trigger. Queue every listing;
-- the worker deliberately decides from authoritative status/restrictions
-- whether the correct projection operation is an upsert or deletion.
INSERT INTO embedding_jobs (
    listing_id, campus_id, desired_revision, status, available_at, requested_at
)
SELECT id, campus_id, content_revision, 'pending', NOW(), NOW()
FROM inventory
ON CONFLICT (listing_id) DO NOTHING;
