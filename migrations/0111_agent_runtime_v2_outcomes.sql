-- Allow the Runtime v2 transport to persist its terminal outcome codes.

ALTER TABLE agent_runs
    DROP CONSTRAINT IF EXISTS agent_runs_outcome_code_check;

ALTER TABLE agent_runs
    ADD CONSTRAINT agent_runs_outcome_code_check
        CHECK (outcome_code IS NULL OR outcome_code IN (
            'direct_response',
            'llm_completed',
            'llm_failed',
            'provider_unavailable',
            'cancelled',
            'runtime_completed',
            'runtime_failed',
            'user_cancelled'
        ));
