-- Spaces that form because a need existed, and archive when it is over.
--
-- The problem. Preset boards assume rooms first and people later. At the scale
-- of one campus that cannot work: a niche interest at NCU — 考研数学互助,
-- 羽毛球搭子, 手工陶艺 — has ten or twenty active people, and spread across
-- rooms nobody enters, each room shows a last message from three weeks ago.
-- Anyone who looks in once does not come back. Creating more rooms creates more
-- of that. It is the same failure the health metrics report as an unanswered
-- post: the demand exists, the container does not find it.
--
-- So a space is a consequence of intents, not a place waiting for them. It
-- carries the reason it formed, an expectation of how long it should matter,
-- and it archives itself when that is over. A dead space is worse than no
-- space, because it teaches people the place is empty.
--
-- `chat_spaces` is extended rather than replaced: existing groups keep working
-- and simply carry origin='manual'.

ALTER TABLE chat_spaces
    -- ai_formed: assembled from intent density
    -- promoted:  an ai_formed space that kept attracting intents and earned
    --            a permanent place — grown, not designated
    -- manual:    someone created it by hand
    ADD COLUMN IF NOT EXISTS origin TEXT NOT NULL DEFAULT 'manual',
    -- What this space is for, in words a member would recognise. Shown on
    -- joining, because being added to a room with no stated purpose is how
    -- group chats become noise.
    ADD COLUMN IF NOT EXISTS purpose TEXT,
    -- Why *these* people. The formation is an automated decision about someone's
    -- social life, so it has to be explainable to them.
    ADD COLUMN IF NOT EXISTS formation_reason TEXT,
    -- The intent kind it was assembled from.
    ADD COLUMN IF NOT EXISTS source_intent_kind TEXT,
    -- When it should stop mattering if nothing keeps it alive. NULL for
    -- open-ended spaces.
    ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS archive_reason TEXT;

ALTER TABLE chat_spaces
    DROP CONSTRAINT IF EXISTS chat_spaces_origin_check;
ALTER TABLE chat_spaces
    ADD CONSTRAINT chat_spaces_origin_check
    CHECK (origin IN ('ai_formed', 'promoted', 'manual'));

-- Drives the archive sweep.
CREATE INDEX IF NOT EXISTS idx_chat_spaces_expiry
    ON chat_spaces (expires_at)
    WHERE status = 'active' AND expires_at IS NOT NULL;

-- Which intents produced which space.
--
-- Needed for two things beyond bookkeeping: telling a member why they are here,
-- and knowing when the space's reason for existing is spent — every source
-- intent fulfilled, withdrawn or expired means the thing is over.
CREATE TABLE IF NOT EXISTS space_formation_sources (
    space_id  UUID NOT NULL REFERENCES chat_spaces(id) ON DELETE CASCADE,
    intent_id UUID NOT NULL REFERENCES intents(id) ON DELETE CASCADE,
    PRIMARY KEY (space_id, intent_id)
);

CREATE INDEX IF NOT EXISTS idx_space_formation_sources_intent
    ON space_formation_sources (intent_id);

-- Who has been grouped with whom, by automated formation.
--
-- This exists to make filter bubbles measurable rather than a footnote.
-- Similarity-based grouping tends to hand the same people to each other, and on
-- a campus that hardens divisions — by department, by home province — that
-- already exist. Recording every pairing lets formation see how much overlap it
-- is about to create and refuse to keep reproducing the same clique.
CREATE TABLE IF NOT EXISTS space_formation_pairs (
    campus_id UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    -- Unordered: LEAST/GREATEST at write time, so a pair is one row.
    lo_user   TEXT NOT NULL,
    hi_user   TEXT NOT NULL,
    times     INT NOT NULL DEFAULT 1,
    last_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (campus_id, lo_user, hi_user),
    CONSTRAINT space_formation_pairs_ordered CHECK (lo_user < hi_user)
);

ALTER TABLE space_formation_pairs ENABLE ROW LEVEL SECURITY;
ALTER TABLE space_formation_pairs FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON space_formation_pairs;
CREATE POLICY tenant_isolation ON space_formation_pairs
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

-- Notifications need somewhere to point at a space.
--
-- `related_conversation_id` is not it: that column has a foreign key to
-- `chat_conversations`, so storing a space id there fails the constraint and
-- takes the whole notification down with it. A member then ends up in a room
-- nobody told them about — which is the one outcome space formation must never
-- produce.
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS related_space_id UUID
    REFERENCES chat_spaces(id) ON DELETE SET NULL;
