-- Agent ActionPlan: confirmation protocol for agent-initiated writes.
--
-- Agent write tools no longer execute directly. A tool call produces a plan
-- row (input snapshot, risk level, short expiry) and the user confirms it via
-- an authenticated HTTP endpoint carrying the confirmation token. The token is
-- returned only through the plans API — never through model-visible text — so
-- a prompt-injected model cannot confirm its own plan.
--
-- Status machine: pending -> executing -> executed | failed
--                 pending -> cancelled (user) | expired (lazy, on read/confirm)
CREATE TABLE IF NOT EXISTS agent_action_plans (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campus_id UUID NOT NULL REFERENCES campuses(id),
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    action TEXT NOT NULL,
    risk_level TEXT NOT NULL CHECK (risk_level IN ('L2', 'L3')),
    args JSONB NOT NULL,
    summary TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'executing', 'executed', 'failed', 'cancelled', 'expired')),
    confirmation_token TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    executed_at TIMESTAMPTZ,
    result TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_agent_action_plans_user_status
    ON agent_action_plans (user_id, status, created_at DESC);
