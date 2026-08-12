-- A retried agent request must not create a second pending ActionPlan.  The
-- key is scoped to the authenticated user and campus; the request hash makes
-- accidental reuse for a different action fail closed instead of silently
-- returning the first plan.

ALTER TABLE agent_action_plans
    ADD COLUMN IF NOT EXISTS proposal_idempotency_key TEXT,
    ADD COLUMN IF NOT EXISTS proposal_request_hash TEXT;

ALTER TABLE agent_action_plans
    DROP CONSTRAINT IF EXISTS agent_action_plans_proposal_idempotency_pair_check;

ALTER TABLE agent_action_plans
    ADD CONSTRAINT agent_action_plans_proposal_idempotency_pair_check CHECK (
        (proposal_idempotency_key IS NULL AND proposal_request_hash IS NULL)
        OR (
            proposal_idempotency_key IS NOT NULL
            AND char_length(proposal_idempotency_key) BETWEEN 1 AND 128
            AND proposal_request_hash IS NOT NULL
            AND char_length(proposal_request_hash) = 64
        )
    );

CREATE UNIQUE INDEX IF NOT EXISTS agent_action_plans_proposal_idempotency_uq
    ON agent_action_plans (campus_id, user_id, proposal_idempotency_key)
    WHERE proposal_idempotency_key IS NOT NULL;

COMMENT ON COLUMN agent_action_plans.proposal_idempotency_key IS
    'Opaque client retry key, scoped to the proposing user and campus';
COMMENT ON COLUMN agent_action_plans.proposal_request_hash IS
    'SHA-256 of the action/risk/arguments bound to proposal_idempotency_key';
