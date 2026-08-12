-- Unified, privacy-safe AgentRun envelope.  The run is an operational trace,
-- not a copy of the user's prompt or the model transcript.

CREATE TABLE IF NOT EXISTS agent_runs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trace_id TEXT NOT NULL UNIQUE CHECK (char_length(trace_id) BETWEEN 1 AND 128),
    campus_id UUID NOT NULL REFERENCES campuses(id),
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    conversation_id TEXT NOT NULL CHECK (char_length(conversation_id) BETWEEN 1 AND 256),
    route TEXT NOT NULL CHECK (route IN ('search', 'buy', 'negotiate', 'chat', 'blocked')),
    route_confidence REAL CHECK (route_confidence IS NULL OR route_confidence BETWEEN 0 AND 1),
    provider TEXT CHECK (provider IS NULL OR char_length(provider) BETWEEN 1 AND 128),
    model TEXT CHECK (model IS NULL OR char_length(model) BETWEEN 1 AND 256),
    prompt_template_version TEXT NOT NULL,
    tool_schema_version TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'started'
        CHECK (status IN ('started', 'completed', 'failed', 'cancelled')),
    outcome_code TEXT CHECK (outcome_code IS NULL OR outcome_code IN (
        'direct_response',
        'llm_completed',
        'llm_failed',
        'provider_unavailable',
        'cancelled'
    )),
    retrieval_count INTEGER CHECK (retrieval_count IS NULL OR retrieval_count >= 0),
    retrieval_filtered_count INTEGER
        CHECK (retrieval_filtered_count IS NULL OR retrieval_filtered_count >= 0),
    tool_call_count INTEGER NOT NULL DEFAULT 0 CHECK (tool_call_count >= 0),
    final_resource_ids JSONB NOT NULL DEFAULT '[]'::jsonb
        CHECK (jsonb_typeof(final_resource_ids) = 'array'
               AND pg_column_size(final_resource_ids) <= 4096),
    token_input INTEGER CHECK (token_input IS NULL OR token_input >= 0),
    token_output INTEGER CHECK (token_output IS NULL OR token_output >= 0),
    ttft_ms INTEGER CHECK (ttft_ms IS NULL OR ttft_ms >= 0),
    duration_ms INTEGER CHECK (duration_ms IS NULL OR duration_ms >= 0),
    error_code TEXT CHECK (error_code IS NULL OR char_length(error_code) BETWEEN 1 AND 128),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_agent_runs_user_created
    ON agent_runs (campus_id, user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_agent_runs_status_created
    ON agent_runs (status, created_at DESC);

CREATE TABLE IF NOT EXISTS agent_run_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id UUID NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,
    trace_id TEXT NOT NULL CHECK (char_length(trace_id) BETWEEN 1 AND 128),
    campus_id UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    event_type TEXT NOT NULL CHECK (event_type IN ('route', 'retrieval', 'tool', 'outcome')),
    tool_name TEXT CHECK (tool_name IS NULL OR char_length(tool_name) BETWEEN 1 AND 128),
    risk_level TEXT CHECK (risk_level IS NULL OR risk_level IN ('L0', 'L1', 'L2', 'L3')),
    outcome_code TEXT CHECK (outcome_code IS NULL OR char_length(outcome_code) BETWEEN 1 AND 128),
    duration_ms INTEGER CHECK (duration_ms IS NULL OR duration_ms >= 0),
    result_count INTEGER CHECK (result_count IS NULL OR result_count >= 0),
    filtered_count INTEGER CHECK (filtered_count IS NULL OR filtered_count >= 0),
    resource_ids JSONB NOT NULL DEFAULT '[]'::jsonb
        CHECK (jsonb_typeof(resource_ids) = 'array'
               AND pg_column_size(resource_ids) <= 4096),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
        CHECK (pg_column_size(metadata) <= 4096),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_agent_run_events_run_created
    ON agent_run_events (run_id, created_at ASC, id ASC);

CREATE INDEX IF NOT EXISTS idx_agent_run_events_tenant_created
    ON agent_run_events (campus_id, user_id, created_at DESC);

ALTER TABLE agent_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_runs FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON agent_runs;
CREATE POLICY tenant_isolation ON agent_runs
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

ALTER TABLE agent_run_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_run_events FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON agent_run_events;
CREATE POLICY tenant_isolation ON agent_run_events
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

COMMENT ON TABLE agent_runs IS
    'Tenant-scoped AgentRun envelope; never store prompt bodies, transcripts, secrets, or raw provider errors';
COMMENT ON TABLE agent_run_events IS
    'Tenant-scoped safe run events containing only typed counts, IDs, and bounded metadata';
