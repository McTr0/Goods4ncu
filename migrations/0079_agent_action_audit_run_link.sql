-- Link an ActionPlan receipt to the AgentRun that proposed it when both facts
-- share the same authenticated request trace.  Confirmation-only requests
-- may still have NULL here: they are valid user actions that did not originate
-- from a chat run, and the receipt remains complete without inventing a run.

ALTER TABLE agent_action_audits
    ADD COLUMN IF NOT EXISTS agent_run_id UUID
        REFERENCES agent_runs(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_agent_action_audits_run_created
    ON agent_action_audits (agent_run_id, created_at DESC)
    WHERE agent_run_id IS NOT NULL;

COMMENT ON COLUMN agent_action_audits.agent_run_id IS
    'Optional explicit link to the AgentRun that proposed this action; confirmation-only receipts may be NULL';
