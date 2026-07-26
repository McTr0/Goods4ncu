-- Reversible actions: the storage behind "do it now, undo within a window".
--
-- Why this exists. The ActionPlan boundary (0038) made every agent write wait
-- for an up-front confirmation dialog. That is correct for money and identity,
-- but for ordinary writes it charges every user a confirmation on every action
-- to catch the rare wrong one — the assistant degrades into a form filler.
-- L2 actions instead execute immediately and register a row here; the actor
-- gets an undo affordance inline with the result.
--
-- Undo is a CONDITIONAL revert, not a snapshot restore. `expected_state` holds
-- the values this action wrote. Undo reverts a field only while it still holds
-- that value; if the world moved on (someone bought the item, the owner edited
-- the price), undo refuses and says so rather than silently clobbering newer
-- state with an older snapshot. `prior_state` is what to write back once that
-- guard passes.
--
-- Undo is deliberately NOT exposed as an agent tool — only through the
-- authenticated API from the UI. A prompt-injected model can therefore not
-- revert a user's legitimate actions, and no undo secret needs to exist for it
-- to leak: the actor's own session is the authorisation.

CREATE TABLE IF NOT EXISTS reversible_actions (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campus_id      UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    -- TEXT to match agent_action_plans.user_id and inventory.owner_id.
    actor_user_id  TEXT NOT NULL,

    action_kind    TEXT NOT NULL,
    target_type    TEXT NOT NULL,
    target_id      TEXT NOT NULL,
    -- Human text shown beside the undo affordance.
    summary        TEXT NOT NULL,

    expected_state JSONB NOT NULL DEFAULT '{}'::jsonb,
    prior_state    JSONB NOT NULL DEFAULT '{}'::jsonb,

    undo_deadline  TIMESTAMPTZ NOT NULL,
    undone_at      TIMESTAMPTZ,
    -- Recorded so a repeat undo returns the same answer instead of re-running.
    undo_result    TEXT,

    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Serves the hot path: "what can this user still undo right now".
CREATE INDEX IF NOT EXISTS idx_reversible_actions_open
    ON reversible_actions (actor_user_id, undo_deadline DESC)
    WHERE undone_at IS NULL;

-- Serves the retention sweep.
CREATE INDEX IF NOT EXISTS idx_reversible_actions_created
    ON reversible_actions (created_at);

-- Same tenancy model as 0042: fail-open with no context, isolating once
-- `app.campus_id` is armed for the transaction, enforced even for the owner.
ALTER TABLE reversible_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE reversible_actions FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON reversible_actions;
CREATE POLICY tenant_isolation ON reversible_actions
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
