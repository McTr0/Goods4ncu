-- Make image-moderation claims recoverable after a worker crash.
--
-- Before this migration, a process killed after moving a row to `processing`
-- left that row there forever because the worker only selected `pending`.
-- A short-lived lease keeps at-most-one active claimant while allowing a later
-- worker to reclaim work whose owner disappeared.

ALTER TABLE moderation_jobs
    ADD COLUMN IF NOT EXISTS locked_by TEXT,
    ADD COLUMN IF NOT EXISTS locked_until TIMESTAMPTZ;

-- Rows left in the old transient state have no trustworthy owner or start
-- time. Make them immediately claimable before installing the invariant.
UPDATE moderation_jobs
SET status = 'pending', locked_by = NULL, locked_until = NULL
WHERE status = 'processing';

ALTER TABLE moderation_jobs
    DROP CONSTRAINT IF EXISTS moderation_jobs_processing_lease_check;
ALTER TABLE moderation_jobs
    ADD CONSTRAINT moderation_jobs_processing_lease_check
    CHECK (
        (status = 'processing' AND locked_by IS NOT NULL AND locked_until IS NOT NULL)
        OR (status <> 'processing' AND locked_by IS NULL AND locked_until IS NULL)
    );

CREATE INDEX IF NOT EXISTS idx_moderation_jobs_claim
    ON moderation_jobs(status, locked_until, created_at)
    WHERE status IN ('pending', 'processing');

COMMENT ON COLUMN moderation_jobs.locked_by IS
    'Ephemeral worker lease owner; NULL when the job is claimable.';
COMMENT ON COLUMN moderation_jobs.locked_until IS
    'Worker lease expiry; an expired processing row can be reclaimed.';
