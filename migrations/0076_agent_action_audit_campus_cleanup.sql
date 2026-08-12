-- Campus records are normally deactivated rather than deleted, but keeping
-- the audit FK cascading makes temporary/test tenant teardown deterministic.
-- A deleted campus has no remaining user-visible audit surface to retain.

ALTER TABLE agent_action_audits
    DROP CONSTRAINT IF EXISTS agent_action_audits_campus_id_fkey;

ALTER TABLE agent_action_audits
    ADD CONSTRAINT agent_action_audits_campus_id_fkey
    FOREIGN KEY (campus_id) REFERENCES campuses(id) ON DELETE CASCADE;
