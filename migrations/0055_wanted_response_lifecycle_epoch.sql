-- Isolate explicit wanted responses by lifecycle round.
--
-- A fulfilled/deleted wanted can later be reopened.  Without a round marker,
-- an old pending response becomes actionable again as soon as the parent
-- listing returns to `active`, and the old partial unique index prevents the
-- same offer from being recommended in the new round.
--
-- Legacy rows are backfilled only when their current round is provable;
-- ambiguous history remains NULL/read-only. The application increments the
-- inventory epoch only when a wanted listing is reopened, captures that epoch
-- while creating a response, and treats a non-active, NULL or mismatched round
-- as read-only history.

ALTER TABLE inventory
    ADD COLUMN IF NOT EXISTS lifecycle_epoch BIGINT NOT NULL DEFAULT 1;

ALTER TABLE inventory
    DROP CONSTRAINT IF EXISTS inventory_lifecycle_epoch_check;
ALTER TABLE inventory
    ADD CONSTRAINT inventory_lifecycle_epoch_check
    CHECK (lifecycle_epoch > 0);

ALTER TABLE wanted_responses
    ADD COLUMN IF NOT EXISTS lifecycle_epoch BIGINT,
    ADD COLUMN IF NOT EXISTS idempotency_key TEXT,
    ADD COLUMN IF NOT EXISTS idempotency_hash TEXT;

-- Legacy builds allowed another response after the previous one became
-- terminal and did not record reopen events. An active wanted's old pending
-- row therefore cannot be assumed to belong to its current round. Backfill
-- only rows created after the listing's latest update (a sufficient signal
-- that they followed its last reopen), choosing one per pair. Ambiguous and
-- inactive history remains NULL/read-only. New inserts are always assigned a
-- non-NULL epoch by the trigger below.
WITH ranked_legacy AS (
    SELECT
        response.id,
        wanted.lifecycle_epoch,
        ROW_NUMBER() OVER (
            PARTITION BY response.wanted_listing_id, response.offer_listing_id
            ORDER BY
                (response.status = 'pending') DESC,
                response.created_at DESC,
                response.id DESC
        ) AS position
    FROM wanted_responses AS response
    JOIN inventory AS wanted ON wanted.id = response.wanted_listing_id
    WHERE response.lifecycle_epoch IS NULL
      AND wanted.status = 'active'
      AND response.created_at >= wanted.updated_at
)
UPDATE wanted_responses AS response
SET lifecycle_epoch = ranked_legacy.lifecycle_epoch
FROM ranked_legacy
WHERE response.id = ranked_legacy.id
  AND ranked_legacy.position = 1;

ALTER TABLE wanted_responses
    DROP CONSTRAINT IF EXISTS wanted_responses_lifecycle_epoch_check;
ALTER TABLE wanted_responses
    ADD CONSTRAINT wanted_responses_lifecycle_epoch_check
    CHECK (lifecycle_epoch IS NULL OR lifecycle_epoch > 0);

ALTER TABLE wanted_responses
    DROP CONSTRAINT IF EXISTS wanted_responses_idempotency_pair_check;
ALTER TABLE wanted_responses
    ADD CONSTRAINT wanted_responses_idempotency_pair_check CHECK (
        (idempotency_key IS NULL AND idempotency_hash IS NULL)
        OR
        (
            idempotency_key IS NOT NULL
            AND idempotency_hash IS NOT NULL
            AND char_length(idempotency_hash) = 64
        )
    );

DROP INDEX IF EXISTS idx_wanted_responses_pending_unique;
CREATE UNIQUE INDEX wanted_responses_round_offer_uq
    ON wanted_responses (
        wanted_listing_id,
        lifecycle_epoch,
        offer_listing_id
    )
    WHERE lifecycle_epoch IS NOT NULL;

CREATE INDEX idx_wanted_responses_round_pending
    ON wanted_responses (wanted_listing_id, lifecycle_epoch)
    INCLUDE (responder_id)
    WHERE status = 'pending';

CREATE UNIQUE INDEX IF NOT EXISTS wanted_responses_responder_idempotency_uq
    ON wanted_responses (campus_id, responder_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;

-- Rolling-deploy compatibility and a database-level invariant: an old binary
-- that omits lifecycle_epoch still locks and derives the active wanted round.
-- Locking wanted before offer matches every new application transaction.
CREATE OR REPLACE FUNCTION assign_wanted_response_lifecycle_epoch()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    wanted_row RECORD;
    offer_row RECORD;
BEGIN
    SELECT campus_id, owner_id, status, direction, lifecycle_epoch
    INTO wanted_row
    FROM inventory
    WHERE id = NEW.wanted_listing_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN NEW; -- The existing foreign key reports the missing parent.
    END IF;

    SELECT campus_id, owner_id, status, direction
    INTO offer_row
    FROM inventory
    WHERE id = NEW.offer_listing_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN NEW; -- The existing foreign key reports the missing parent.
    END IF;

    IF wanted_row.direction <> 'wanted'
       OR wanted_row.status <> 'active'
       OR offer_row.direction <> 'offer'
       OR offer_row.status <> 'active'
       OR wanted_row.campus_id <> NEW.campus_id
       OR offer_row.campus_id <> NEW.campus_id
       OR wanted_row.owner_id <> NEW.requester_id
       OR offer_row.owner_id <> NEW.responder_id
       OR NEW.requester_id = NEW.responder_id
    THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'wanted response parents are not eligible';
    END IF;

    IF NEW.lifecycle_epoch IS NULL THEN
        NEW.lifecycle_epoch := wanted_row.lifecycle_epoch;
    ELSIF NEW.lifecycle_epoch <> wanted_row.lifecycle_epoch THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'wanted response lifecycle epoch is not current';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS wanted_responses_assign_lifecycle_epoch
    ON wanted_responses;
CREATE TRIGGER wanted_responses_assign_lifecycle_epoch
    BEFORE INSERT ON wanted_responses
    FOR EACH ROW
    EXECUTE FUNCTION assign_wanted_response_lifecycle_epoch();

-- An old binary reopens by changing only status. Make that transition advance
-- exactly one round; a new binary may provide the increment explicitly.
CREATE OR REPLACE FUNCTION enforce_wanted_lifecycle_epoch_transition()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.direction = 'wanted' THEN
        IF OLD.status <> 'active' AND NEW.status = 'active' THEN
            IF NEW.lifecycle_epoch = OLD.lifecycle_epoch THEN
                NEW.lifecycle_epoch := OLD.lifecycle_epoch + 1;
            ELSIF NEW.lifecycle_epoch <> OLD.lifecycle_epoch + 1 THEN
                RAISE EXCEPTION USING
                    ERRCODE = '23514',
                    MESSAGE = 'wanted reopen must advance exactly one lifecycle epoch';
            END IF;
        ELSIF NEW.lifecycle_epoch <> OLD.lifecycle_epoch THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'wanted lifecycle epoch can change only on reopen';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS inventory_enforce_wanted_lifecycle_epoch
    ON inventory;
CREATE TRIGGER inventory_enforce_wanted_lifecycle_epoch
    BEFORE UPDATE OF status, lifecycle_epoch ON inventory
    FOR EACH ROW
    EXECUTE FUNCTION enforce_wanted_lifecycle_epoch_transition();

COMMENT ON COLUMN inventory.lifecycle_epoch IS
    'Current lifecycle round; incremented atomically when a wanted listing is reopened';
COMMENT ON COLUMN wanted_responses.lifecycle_epoch IS
    'Wanted lifecycle round captured atomically on create; NULL denotes ambiguous legacy history';
COMMENT ON COLUMN wanted_responses.idempotency_key IS
    'Opaque Idempotency-Key supplied by the responder for one recommendation attempt';
COMMENT ON COLUMN wanted_responses.idempotency_hash IS
    'SHA-256 of normalized wanted/offer/message input used to reject key reuse with different data';
