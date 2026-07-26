-- Private-reservation price matching.
--
-- What this replaces. Haggling in public is a poor fit for a campus. Opening low
-- looks like you are not serious, refusing looks unfriendly, and you will see
-- this person in the canteen tomorrow — so a lot of trades die at "不好意思开口"
-- rather than at any real disagreement about price.
--
-- The mechanism: each side privately states its limit. The buyer's most, the
-- seller's least. The system answers only whether a deal exists and at what
-- price. Neither ever learns the other's number, including when there is no
-- deal — especially then, because "you were 20 short" is itself a bargaining
-- position handed to one side.
--
-- Opt-in on both sides. Someone who would rather haggle keeps the existing
-- negotiation flow; a mechanism nobody chose is not a kindness.
--
-- The reservation is the most sensitive number in the product. It is a
-- statement about what someone will privately accept, worth more to a
-- counterparty than any listing detail. It must never appear in an API
-- response, a log line, or model context — the same standard as an ActionPlan
-- confirmation token, and tested to it.

CREATE TABLE IF NOT EXISTS price_discovery_sessions (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campus_id     UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    listing_id    TEXT NOT NULL,
    -- TEXT to match users.id.
    seller_id     TEXT NOT NULL,
    buyer_id      TEXT NOT NULL,

    -- proposed:  one side asked, the other has not agreed to the mechanism
    -- open:      both agreed; waiting on reservations
    -- matched:   a price exists, and both may see it
    -- no_deal:   the limits do not overlap. How far apart is never recorded,
    --            because storing it would make leaking it possible.
    -- declined:  the other side would rather negotiate normally
    status        TEXT NOT NULL DEFAULT 'proposed',
    -- Only ever set on `matched`. This is the one figure both sides may see:
    -- it is the agreement, not either party's position.
    matched_cents BIGINT,

    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at   TIMESTAMPTZ,

    CONSTRAINT price_discovery_status_check CHECK (
        status IN ('proposed', 'open', 'matched', 'no_deal', 'declined')
    ),
    CONSTRAINT price_discovery_distinct_parties CHECK (seller_id <> buyer_id),
    -- A matched session must carry its price; an unmatched one must not carry a
    -- number at all.
    CONSTRAINT price_discovery_price_only_when_matched CHECK (
        (status = 'matched' AND matched_cents IS NOT NULL)
        OR (status <> 'matched' AND matched_cents IS NULL)
    ),
    -- One live session per pair per listing, so nobody can run the mechanism
    -- repeatedly to triangulate the other side's limit.
    CONSTRAINT price_discovery_one_per_pair UNIQUE (listing_id, seller_id, buyer_id)
);

CREATE INDEX IF NOT EXISTS idx_price_discovery_participant
    ON price_discovery_sessions (campus_id, status);

ALTER TABLE price_discovery_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE price_discovery_sessions FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON price_discovery_sessions;
CREATE POLICY tenant_isolation ON price_discovery_sessions
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

-- The private limits.
--
-- Deliberately a separate table rather than two columns on the session, so that
-- reading a session never brings the reservations along by accident. Every
-- `SELECT *` on the session is then safe by construction, which matters more
-- than the join: the leak this guards against is a careless query, not an
-- attack.
CREATE TABLE IF NOT EXISTS price_reservations (
    session_id UUID NOT NULL REFERENCES price_discovery_sessions(id) ON DELETE CASCADE,
    user_id    TEXT NOT NULL,
    -- The buyer's most, or the seller's least.
    cents      BIGINT NOT NULL CHECK (cents >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (session_id, user_id)
);
