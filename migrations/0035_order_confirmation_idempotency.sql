-- Make seller confirmation safe to retry after a network timeout.
-- The key is scoped to the seller so a client cannot accidentally replay a
-- confirmation key against another seller's order.
ALTER TABLE orders
    ADD COLUMN IF NOT EXISTS confirm_idempotency_key TEXT,
    ADD COLUMN IF NOT EXISTS confirm_request_hash TEXT;

ALTER TABLE orders
    DROP CONSTRAINT IF EXISTS orders_confirm_request_pair_check;

ALTER TABLE orders
    ADD CONSTRAINT orders_confirm_request_pair_check CHECK (
        (confirm_idempotency_key IS NULL AND confirm_request_hash IS NULL)
        OR
        (
            confirm_idempotency_key IS NOT NULL
            AND confirm_request_hash IS NOT NULL
            AND char_length(confirm_request_hash) = 64
        )
    );

CREATE UNIQUE INDEX IF NOT EXISTS orders_seller_confirm_idempotency_uq
    ON orders (seller_id, confirm_idempotency_key)
    WHERE confirm_idempotency_key IS NOT NULL;

COMMENT ON COLUMN orders.confirm_idempotency_key IS
    'Opaque client key for one seller confirmation attempt';
COMMENT ON COLUMN orders.confirm_request_hash IS
    'SHA-256 of order id and auto-delist choice for the confirmation key';
