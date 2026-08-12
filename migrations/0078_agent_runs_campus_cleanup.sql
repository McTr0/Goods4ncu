-- Keep tenant cleanup deterministic when a temporary or deactivated campus is
-- removed. Events already cascade through agent_runs; the parent run must do
-- the same for its campus foreign key.

ALTER TABLE agent_runs
    DROP CONSTRAINT IF EXISTS agent_runs_campus_id_fkey;

ALTER TABLE agent_runs
    ADD CONSTRAINT agent_runs_campus_id_fkey
    FOREIGN KEY (campus_id) REFERENCES campuses(id) ON DELETE CASCADE;
