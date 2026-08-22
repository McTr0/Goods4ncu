-- Align the agent_runs route allow-list with the tri-tier intent router.
-- The campus-errands merge added offer / wanted / companion / help intents,
-- but this check constraint was never widened, so AgentRun envelopes for
-- those routes failed to persist.

ALTER TABLE agent_runs
    DROP CONSTRAINT IF EXISTS agent_runs_route_check;

ALTER TABLE agent_runs
    ADD CONSTRAINT agent_runs_route_check
        CHECK (route IN (
            'search', 'buy', 'offer', 'wanted', 'negotiate',
            'companion', 'help', 'chat', 'blocked'
        ));
