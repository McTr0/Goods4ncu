-- Intents: what someone wants, before it has been forced into a form.
--
-- The problem this addresses. Today a wish only enters the system once it has
-- been shaped into whatever the relevant module demands — a listing form to
-- sell something, a post in some board to find a badminton partner. That
-- threshold quietly excludes most of the demand on a campus. Nobody fills in
-- twenty listing forms when they are emptying a dorm room at graduation, and
-- nobody writes a post to ask whether anyone fancies a game.
--
-- So the intent is the record, and a listing becomes one *projection* of it.
--
-- Three kinds, one table, on purpose. A thing to sell, a person to find, a
-- favour to ask are handled by three separate mechanisms in a conventional
-- product (marketplace, group chat, forum). They are the same object: someone
-- wants something, it may or may not be specific, and it stops mattering after
-- a while. Matching them is one problem, not three.
--
-- `slots` is JSONB rather than columns because the shape genuinely differs per
-- kind and — more importantly — because a slot may legitimately hold "I don't
-- care". A price of "whatever you'll give me" and a time of "any evening this
-- week" are complete answers, not missing data. Columns would push us back into
-- demanding a number.

CREATE TABLE IF NOT EXISTS intents (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campus_id   UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    -- TEXT to match users.id and inventory.owner_id.
    author_id   TEXT NOT NULL,

    -- goods_offer | goods_seek | companion | help | activity
    kind        TEXT NOT NULL,

    -- What the person actually said or sent. Kept verbatim: it is the only
    -- record of their intent that no interpretation stands between, so a
    -- re-parse after a model improvement can start from the source rather than
    -- from an earlier reading of it.
    raw_input   TEXT NOT NULL,
    -- Structured reading of raw_input. See services::intent::Slots.
    slots       JSONB NOT NULL DEFAULT '{}'::jsonb,
    -- 0..1 confidence in that reading. Low-confidence intents can be surfaced
    -- for confirmation instead of silently entering the matching pool.
    confidence  REAL NOT NULL DEFAULT 1.0,

    -- draft: awaiting the author's confirmation (anything the model split out
    --   of a photo or a sentence starts here, so a bad decomposition cannot
    --   produce matchable junk)
    -- active | fulfilled | withdrawn | expired
    status      TEXT NOT NULL DEFAULT 'draft',
    -- campus | private
    visibility  TEXT NOT NULL DEFAULT 'campus',

    -- When this stops being true. NULL means open-ended. An intent that expires
    -- is not a failure — "this weekend" is genuinely over on Monday, and
    -- keeping it alive would produce matches nobody wants.
    valid_until TIMESTAMPTZ,

    -- Set when a goods intent is mirrored into `inventory` for the existing
    -- browse/search surfaces. The projection is derived; this is the link back.
    projected_listing_id TEXT,

    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT intents_kind_check CHECK (
        kind IN ('goods_offer', 'goods_seek', 'companion', 'help', 'activity')
    ),
    CONSTRAINT intents_status_check CHECK (
        status IN ('draft', 'active', 'fulfilled', 'withdrawn', 'expired')
    ),
    CONSTRAINT intents_visibility_check CHECK (visibility IN ('campus', 'private')),
    CONSTRAINT intents_confidence_range CHECK (confidence >= 0.0 AND confidence <= 1.0),
    CONSTRAINT intents_raw_input_not_blank CHECK (btrim(raw_input) <> '')
);

-- The matching pool: live, visible intents of a kind on a campus.
CREATE INDEX IF NOT EXISTS idx_intents_pool
    ON intents (campus_id, kind, status)
    WHERE status = 'active' AND visibility = 'campus';

-- "What have I got outstanding", including drafts awaiting confirmation.
CREATE INDEX IF NOT EXISTS idx_intents_author
    ON intents (author_id, status, created_at DESC);

-- Drives the expiry sweep.
CREATE INDEX IF NOT EXISTS idx_intents_expiry
    ON intents (valid_until)
    WHERE status = 'active' AND valid_until IS NOT NULL;

-- One intent per projected listing, so the mirror cannot fork.
CREATE UNIQUE INDEX IF NOT EXISTS idx_intents_projection
    ON intents (projected_listing_id)
    WHERE projected_listing_id IS NOT NULL;

-- Same tenancy model as 0042.
ALTER TABLE intents ENABLE ROW LEVEL SECURITY;
ALTER TABLE intents FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON intents;
CREATE POLICY tenant_isolation ON intents
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
