-- Scope administrative audit events and moderation jobs to a campus. Platform
-- operators may inspect another campus only through an explicitly audited API
-- path; background moderation always inherits the resource campus.

ALTER TABLE admin_audit_logs
    ADD COLUMN IF NOT EXISTS campus_id UUID
        REFERENCES campuses(id) ON DELETE RESTRICT,
    ADD COLUMN IF NOT EXISTS scope_reason TEXT;

UPDATE admin_audit_logs log
SET campus_id = COALESCE(
    (SELECT i.campus_id FROM inventory i WHERE i.id = log.target_id LIMIT 1),
    (SELECT o.campus_id FROM orders o WHERE o.id = log.target_id LIMIT 1),
    (
        SELECT m.campus_id
        FROM campus_memberships m
        WHERE m.user_id = log.target_id
        ORDER BY (m.status = 'verified') DESC, m.created_at ASC
        LIMIT 1
    ),
    (
        SELECT m.campus_id
        FROM campus_memberships m
        WHERE m.user_id = log.admin_id
        ORDER BY (m.status = 'verified') DESC, m.created_at ASC
        LIMIT 1
    ),
    (SELECT id FROM campuses WHERE slug = 'ncu' LIMIT 1)
)
WHERE log.campus_id IS NULL;

ALTER TABLE admin_audit_logs
    ALTER COLUMN campus_id SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_admin_audit_campus_created
    ON admin_audit_logs(campus_id, created_at DESC);

ALTER TABLE moderation_jobs
    ADD COLUMN IF NOT EXISTS campus_id UUID
        REFERENCES campuses(id) ON DELETE RESTRICT;

UPDATE moderation_jobs job
SET campus_id = COALESCE(
    (
        SELECT i.campus_id
        FROM inventory i
        WHERE job.resource_type = 'listing_image'
          AND i.id = job.resource_id
        LIMIT 1
    ),
    (
        SELECT c.campus_id
        FROM chat_messages message
        JOIN chat_conversations c ON c.id = message.direct_conversation_id
        WHERE job.resource_type = 'chat_image'
          AND message.id::text = job.resource_id
        LIMIT 1
    ),
    (
        SELECT m.campus_id
        FROM campus_memberships m
        WHERE job.resource_type = 'avatar'
          AND m.user_id = job.resource_id
        ORDER BY (m.status = 'verified') DESC, m.created_at ASC
        LIMIT 1
    ),
    (SELECT id FROM campuses WHERE slug = 'ncu' LIMIT 1)
)
WHERE job.campus_id IS NULL;

ALTER TABLE moderation_jobs
    ALTER COLUMN campus_id SET NOT NULL;

-- The worker claims jobs by moving them through processing. The original 0011
-- constraint omitted that transient state, which made enabled workers fail.
ALTER TABLE moderation_jobs
    DROP CONSTRAINT IF EXISTS moderation_jobs_status_check;
ALTER TABLE moderation_jobs
    ADD CONSTRAINT moderation_jobs_status_check
        CHECK (status IN ('pending', 'processing', 'approved', 'rejected', 'failed'));

CREATE INDEX IF NOT EXISTS idx_moderation_jobs_campus_status_created
    ON moderation_jobs(campus_id, status, created_at);

COMMENT ON COLUMN admin_audit_logs.campus_id IS
    'Campus whose data was inspected or mutated by this administrative action.';
COMMENT ON COLUMN admin_audit_logs.scope_reason IS
    'Required reason when a platform administrator overrides the active campus.';
COMMENT ON COLUMN moderation_jobs.campus_id IS
    'Campus inherited from the resource being moderated.';
