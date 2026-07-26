-- Adopt campus ownership on core business facts.
-- The NCU default keeps legacy SQL and historical fixtures compatible while the
-- application moves every official write path to server-derived tenant context.
-- Remove these defaults before enabling a second campus.

ALTER TABLE inventory
    ADD COLUMN IF NOT EXISTS campus_id UUID NOT NULL
        DEFAULT 'c0000000-0000-0000-0000-000000000001'
        REFERENCES campuses(id) ON DELETE RESTRICT;

ALTER TABLE orders
    ADD COLUMN IF NOT EXISTS campus_id UUID NOT NULL
        DEFAULT 'c0000000-0000-0000-0000-000000000001'
        REFERENCES campuses(id) ON DELETE RESTRICT;

ALTER TABLE hitl_requests
    ADD COLUMN IF NOT EXISTS campus_id UUID NOT NULL
        DEFAULT 'c0000000-0000-0000-0000-000000000001'
        REFERENCES campuses(id) ON DELETE RESTRICT;

ALTER TABLE wanted_responses
    ADD COLUMN IF NOT EXISTS campus_id UUID NOT NULL
        DEFAULT 'c0000000-0000-0000-0000-000000000001'
        REFERENCES campuses(id) ON DELETE RESTRICT;

ALTER TABLE chat_conversations
    ADD COLUMN IF NOT EXISTS campus_id UUID NOT NULL
        DEFAULT 'c0000000-0000-0000-0000-000000000001'
        REFERENCES campuses(id) ON DELETE RESTRICT;

ALTER TABLE chat_spaces
    ADD COLUMN IF NOT EXISTS campus_id UUID NOT NULL
        DEFAULT 'c0000000-0000-0000-0000-000000000001'
        REFERENCES campuses(id) ON DELETE RESTRICT;

ALTER TABLE chat_secret_sessions
    ADD COLUMN IF NOT EXISTS campus_id UUID NOT NULL
        DEFAULT 'c0000000-0000-0000-0000-000000000001'
        REFERENCES campuses(id) ON DELETE RESTRICT;

-- Child facts inherit the owning listing or conversation campus rather than a
-- user-supplied value. This also repairs any pre-migration compatibility rows.
UPDATE orders o
SET campus_id = i.campus_id
FROM inventory i
WHERE i.id = o.listing_id AND o.campus_id IS DISTINCT FROM i.campus_id;

UPDATE hitl_requests h
SET campus_id = i.campus_id
FROM inventory i
WHERE i.id = h.listing_id AND h.campus_id IS DISTINCT FROM i.campus_id;

UPDATE wanted_responses r
SET campus_id = wanted.campus_id
FROM inventory wanted
WHERE wanted.id = r.wanted_listing_id
  AND r.campus_id IS DISTINCT FROM wanted.campus_id;

UPDATE chat_conversations c
SET campus_id = i.campus_id
FROM inventory i
WHERE i.id = c.listing_id AND c.campus_id IS DISTINCT FROM i.campus_id;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'inventory_id_campus_unique'
    ) THEN
        ALTER TABLE inventory
            ADD CONSTRAINT inventory_id_campus_unique UNIQUE (id, campus_id);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'orders_listing_campus_fk'
    ) THEN
        ALTER TABLE orders
            ADD CONSTRAINT orders_listing_campus_fk
            FOREIGN KEY (listing_id, campus_id)
            REFERENCES inventory(id, campus_id) ON DELETE CASCADE;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'hitl_listing_campus_fk'
    ) THEN
        ALTER TABLE hitl_requests
            ADD CONSTRAINT hitl_listing_campus_fk
            FOREIGN KEY (listing_id, campus_id)
            REFERENCES inventory(id, campus_id) ON DELETE CASCADE;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'wanted_response_wanted_campus_fk'
    ) THEN
        ALTER TABLE wanted_responses
            ADD CONSTRAINT wanted_response_wanted_campus_fk
            FOREIGN KEY (wanted_listing_id, campus_id)
            REFERENCES inventory(id, campus_id) ON DELETE CASCADE;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'wanted_response_offer_campus_fk'
    ) THEN
        ALTER TABLE wanted_responses
            ADD CONSTRAINT wanted_response_offer_campus_fk
            FOREIGN KEY (offer_listing_id, campus_id)
            REFERENCES inventory(id, campus_id) ON DELETE CASCADE;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'chat_conversation_listing_campus_fk'
    ) THEN
        ALTER TABLE chat_conversations
            ADD CONSTRAINT chat_conversation_listing_campus_fk
            FOREIGN KEY (listing_id, campus_id)
            REFERENCES inventory(id, campus_id);
    END IF;
END $$;

DROP INDEX IF EXISTS chat_conversations_one_live_realtime_idx;
CREATE UNIQUE INDEX chat_conversations_one_live_realtime_idx
    ON chat_conversations (
        campus_id,
        LEAST(initiator_id, recipient_id),
        GREATEST(initiator_id, recipient_id),
        COALESCE(listing_id, '')
    )
    WHERE mode = 'realtime' AND state IN ('syn_sent', 'syn_ack', 'active');

CREATE INDEX IF NOT EXISTS idx_inventory_campus_status_created
    ON inventory(campus_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_orders_campus_created
    ON orders(campus_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_hitl_requests_campus_status
    ON hitl_requests(campus_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_wanted_responses_campus_status
    ON wanted_responses(campus_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_conversations_campus_activity
    ON chat_conversations(campus_id, last_activity_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_spaces_campus_activity
    ON chat_spaces(campus_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_secret_sessions_campus_created
    ON chat_secret_sessions(campus_id, created_at DESC);

COMMENT ON COLUMN inventory.campus_id IS
    'Tenant owner. The NCU default is transitional and must be removed before multi-campus launch.';
