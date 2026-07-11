-- Add bidirectional marketplace semantics:
-- offer = I want to sell/transfer this item.
-- wanted = I want to receive/find this item.

ALTER TABLE inventory
ADD COLUMN IF NOT EXISTS direction TEXT NOT NULL DEFAULT 'offer';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'inventory_direction_check'
    ) THEN
        ALTER TABLE inventory
        ADD CONSTRAINT inventory_direction_check
        CHECK (direction IN ('offer', 'wanted'));
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_inventory_direction_status_created_at
ON inventory(direction, status, created_at DESC);

CREATE TABLE IF NOT EXISTS wanted_responses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    wanted_listing_id TEXT NOT NULL REFERENCES inventory(id) ON DELETE CASCADE,
    offer_listing_id TEXT NOT NULL REFERENCES inventory(id) ON DELETE CASCADE,
    responder_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    requester_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    message TEXT,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'dismissed', 'accepted', 'withdrawn')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    responded_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_wanted_responses_pending_unique
ON wanted_responses(wanted_listing_id, offer_listing_id, responder_id)
WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_wanted_responses_requester_status
ON wanted_responses(requester_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_wanted_responses_responder_status
ON wanted_responses(responder_id, status, created_at DESC);
