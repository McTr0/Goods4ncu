-- Make the ActionPlan confirmation boundary transport-safe and make legacy
-- in-flight rows explicit rather than guessing whether their business effect
-- committed before a process interruption.

ALTER TABLE agent_action_plans
    ADD COLUMN second_confirmation_token TEXT,
    ADD COLUMN first_confirmed_at TIMESTAMPTZ,
    ADD COLUMN second_confirmed_at TIMESTAMPTZ;

-- A second L3 confirmation must use a different capability. Retrying the
-- primary token can therefore only replay the first-confirmation response.
UPDATE agent_action_plans
SET second_confirmation_token =
        replace(gen_random_uuid()::TEXT, '-', '') ||
        replace(gen_random_uuid()::TEXT, '-', '')
WHERE risk_level = 'L3'
  AND second_confirmation_token IS NULL;

-- Preserve the confirmation evidence that can be inferred safely from legacy
-- states. Cancellation/expiry cannot reveal whether the row previously passed
-- through confirmed_once, so those rows deliberately remain NULL.
UPDATE agent_action_plans
SET first_confirmed_at = COALESCE(updated_at, created_at)
WHERE risk_level = 'L3'
  AND status IN ('confirmed_once', 'executing', 'executed', 'failed')
  AND first_confirmed_at IS NULL;

UPDATE agent_action_plans
SET second_confirmed_at = COALESCE(executed_at, updated_at, created_at)
WHERE risk_level = 'L3'
  AND status IN ('executing', 'executed', 'failed')
  AND second_confirmed_at IS NULL;

ALTER TABLE agent_action_plans
    DROP CONSTRAINT IF EXISTS agent_action_plans_status_check;

-- Old executing rows straddle two independent transactions. They may have no
-- business effect or an already-committed one, and there is no plan-scoped
-- receipt with which to distinguish the cases. Never replay them automatically.
UPDATE agent_action_plans
SET status = 'interrupted',
    result = COALESCE(
        result,
        '执行被中断，结果不确定，需要人工核对；系统不会自动重放'
    ),
    updated_at = NOW()
WHERE status = 'executing';

ALTER TABLE agent_action_plans
    ADD CONSTRAINT agent_action_plans_status_check CHECK (
        status IN (
            'pending', 'confirmed_once', 'executing', 'executed', 'failed',
            'cancelled', 'expired', 'interrupted'
        )
    ),
    ADD CONSTRAINT agent_action_plans_l3_second_token_check CHECK (
        risk_level <> 'L3'
        OR (
            second_confirmation_token IS NOT NULL
            AND second_confirmation_token <> confirmation_token
        )
    );

COMMENT ON COLUMN agent_action_plans.second_confirmation_token IS
    'Independent L3 step-two capability; the primary token can never execute an armed plan';
COMMENT ON COLUMN agent_action_plans.first_confirmed_at IS
    'Database timestamp of the accepted first L3 confirmation';
COMMENT ON COLUMN agent_action_plans.second_confirmed_at IS
    'Database timestamp of the accepted second L3 confirmation';
COMMENT ON COLUMN agent_action_plans.status IS
    'interrupted marks ambiguous legacy executions that require reconciliation and are never replayed automatically';
