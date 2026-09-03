-- Prevent duplicate posts when a client retries a timed-out publication.
ALTER TABLE posts
    ADD COLUMN IF NOT EXISTS idempotency_key TEXT,
    ADD COLUMN IF NOT EXISTS idempotency_hash TEXT;

ALTER TABLE posts
    DROP CONSTRAINT IF EXISTS posts_idempotency_pair_check;

ALTER TABLE posts
    ADD CONSTRAINT posts_idempotency_pair_check CHECK (
        (idempotency_key IS NULL AND idempotency_hash IS NULL)
        OR
        (
            idempotency_key IS NOT NULL
            AND idempotency_hash IS NOT NULL
            AND char_length(idempotency_hash) = 64
        )
    );

CREATE UNIQUE INDEX IF NOT EXISTS posts_author_idempotency_key_uq
    ON posts (author_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;

COMMENT ON COLUMN posts.idempotency_key IS
    'Opaque Idempotency-Key supplied by the post author for one publication attempt';
COMMENT ON COLUMN posts.idempotency_hash IS
    'SHA-256 of the normalized create-post input used to reject key reuse with different data';
