-- Prevent duplicate listings when a client retries a timed-out publication.
-- Existing clients remain compatible because both columns are nullable.
ALTER TABLE inventory
    ADD COLUMN IF NOT EXISTS idempotency_key TEXT,
    ADD COLUMN IF NOT EXISTS idempotency_hash TEXT;

ALTER TABLE inventory
    DROP CONSTRAINT IF EXISTS inventory_idempotency_pair_check;

ALTER TABLE inventory
    ADD CONSTRAINT inventory_idempotency_pair_check CHECK (
        (idempotency_key IS NULL AND idempotency_hash IS NULL)
        OR
        (
            idempotency_key IS NOT NULL
            AND idempotency_hash IS NOT NULL
            AND char_length(idempotency_hash) = 64
        )
    );

CREATE UNIQUE INDEX IF NOT EXISTS inventory_owner_idempotency_key_uq
    ON inventory (owner_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;

COMMENT ON COLUMN inventory.idempotency_key IS
    'Opaque Idempotency-Key supplied by the listing owner for one publication attempt';
COMMENT ON COLUMN inventory.idempotency_hash IS
    'SHA-256 of the normalized create-listing input used to reject key reuse with different data';
