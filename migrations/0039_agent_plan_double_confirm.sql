-- L3 plans require two confirmations (roadmap Phase 3: 报价、议价、成交确认使用
-- 二次确认). The intermediate state records that the first confirmation
-- happened; only a second confirmation moves the plan into execution.
ALTER TABLE agent_action_plans
    DROP CONSTRAINT IF EXISTS agent_action_plans_status_check;
ALTER TABLE agent_action_plans
    ADD CONSTRAINT agent_action_plans_status_check CHECK (
        status IN (
            'pending', 'confirmed_once', 'executing',
            'executed', 'failed', 'cancelled', 'expired'
        )
    );
