-- Interruption budget: proactive outreach is a scarce, accounted resource.
--
-- Why this exists. A community product that matches people and forms groups
-- has an unbounded supply of things it *could* tell you about. The failure
-- mode is not being unintelligent, it is being exhausting — and once users mute
-- the app they never come back. So the budget lives in the schema and the type
-- system rather than in each caller's good judgement.
--
-- Two kinds of notification, only one of which is budgeted:
--   * reactive  — someone acted on the user's own thing ("a buyer wants your
--     item"). The user set this in motion; it is an answer, not an
--     interruption. Not budgeted.
--   * proactive — the system decided to reach out ("this match looks right for
--     you", "a group is forming for Meiling on Saturday"). Budgeted.
--
-- Every proactive attempt is recorded whether or not it was delivered, so
-- "why didn't I hear about that?" and "why am I seeing this?" are both
-- answerable, and so suppression is measurable instead of invisible.

CREATE TABLE IF NOT EXISTS interruption_ledger (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campus_id      UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    user_id        TEXT NOT NULL,

    channel        TEXT NOT NULL,
    topic          TEXT NOT NULL,
    -- Shown verbatim to the user under "why am I seeing this". Storing it is
    -- what makes the requirement enforceable rather than aspirational.
    reason         TEXT NOT NULL,
    expected_value REAL NOT NULL,

    -- delivered | suppressed_budget | suppressed_muted | suppressed_quiet
    -- | suppressed_low_value
    decision       TEXT NOT NULL,
    delivered_at   TIMESTAMPTZ,
    accepted_at    TIMESTAMPTZ,
    dismissed_at   TIMESTAMPTZ,

    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Serves the budget check on every proactive attempt.
CREATE INDEX IF NOT EXISTS idx_interruption_ledger_spend
    ON interruption_ledger (user_id, delivered_at DESC)
    WHERE delivered_at IS NOT NULL;

-- Serves per-topic acceptance statistics used to down-weight topics the user
-- keeps ignoring.
CREATE INDEX IF NOT EXISTS idx_interruption_ledger_topic_stats
    ON interruption_ledger (user_id, topic, created_at DESC);

ALTER TABLE interruption_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE interruption_ledger FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON interruption_ledger;
CREATE POLICY tenant_isolation ON interruption_ledger
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

-- Per-user, not per-campus: someone's tolerance for being pinged travels with
-- them, so this table carries no campus_id and no tenant policy.
CREATE TABLE IF NOT EXISTS interruption_preferences (
    user_id      TEXT PRIMARY KEY,
    -- Deliberately small by default. The budget is meant to bind.
    daily_budget SMALLINT NOT NULL DEFAULT 3
                 CHECK (daily_budget >= 0 AND daily_budget <= 20),
    muted_topics TEXT[] NOT NULL DEFAULT '{}',
    -- "leave me alone for a while"
    quiet_until  TIMESTAMPTZ,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Ties a notification back to the ledger entry that decided its fate, so the
-- client can post an accept/dismiss receipt when the user acts on it. Without
-- this the acceptance statistics could never be gathered: nothing would tell
-- the app which ledger row a tapped notification belongs to.
--
-- Set for budgeted topics whether pushed or held back — a user who digs a
-- suppressed item out of their inbox and engages with it is exactly the signal
-- the per-topic threshold should learn from.
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS interruption_id UUID;
