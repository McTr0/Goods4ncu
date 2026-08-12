-- Keep the server-owned object key next to an image moderation job so a
-- private-bucket worker can mint a fresh, short-lived URL when it claims the
-- job.  Persisting a presigned URL itself is unsafe: a queue delay can make it
-- expire before the provider receives it.

ALTER TABLE moderation_jobs
    ADD COLUMN IF NOT EXISTS storage_key TEXT;

CREATE INDEX IF NOT EXISTS idx_moderation_jobs_storage_key
    ON moderation_jobs(storage_key)
    WHERE storage_key IS NOT NULL;

COMMENT ON COLUMN moderation_jobs.storage_key IS
    'Optional server-owned object key; private media workers re-sign it per attempt instead of reusing an expired URL.';
