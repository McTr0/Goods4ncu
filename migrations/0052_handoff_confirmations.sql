-- Trust built from what actually happened.
--
-- Star ratings are an e-commerce import and they fail badly on a campus. In a
-- place where you keep seeing the same people, everyone gives five stars — so
-- the signal is worthless — and anyone who does not is picking a fight with
-- someone they will meet at breakfast. The rating that is safe to give carries
-- no information, and the one that carries information is unsafe to give.
--
-- So nothing subjective is recorded. Two questions with checkable answers:
-- did the handoff happen, and were they on time. "Was it good" is not asked,
-- because it cannot be answered without a social cost.
--
-- Reputation is then a statement of fact — "completed 12 arrangements, on time
-- 11 times" — which a person can dispute against their own memory. A score out
-- of five cannot be disputed, only resented.
--
-- Note what is deliberately missing: any way to leave a comment, and any
-- public negative. A missed meeting lowers someone's matching weight; it does
-- not put a mark on their profile for the rest of their degree.

CREATE TABLE IF NOT EXISTS handoff_confirmations (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campus_id    UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    -- The arrangement this was about.
    agreement_id UUID NOT NULL REFERENCES agreements(id) ON DELETE CASCADE,

    -- Who is answering, and about whom. TEXT to match users.id.
    confirmer_id TEXT NOT NULL,
    subject_id   TEXT NOT NULL,

    -- The only two facts recorded.
    happened     BOOLEAN NOT NULL,
    -- NULL when it did not happen: punctuality is meaningless then, and forcing
    -- an answer would manufacture data.
    on_time      BOOLEAN,

    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- One answer per person per arrangement. Asking twice would let someone
    -- revise their account after a disagreement.
    CONSTRAINT handoff_one_per_confirmer UNIQUE (agreement_id, confirmer_id),
    CONSTRAINT handoff_distinct_parties CHECK (confirmer_id <> subject_id),
    CONSTRAINT handoff_on_time_only_when_happened CHECK (
        (happened AND on_time IS NOT NULL) OR (NOT happened AND on_time IS NULL)
    )
);

-- Serves the reputation summary for one person.
CREATE INDEX IF NOT EXISTS idx_handoff_subject
    ON handoff_confirmations (campus_id, subject_id);

ALTER TABLE handoff_confirmations ENABLE ROW LEVEL SECURITY;
ALTER TABLE handoff_confirmations FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON handoff_confirmations;
CREATE POLICY tenant_isolation ON handoff_confirmations
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
