-- Durable remote-object cleanup for revoked/deleted shared files.
--
-- Revoking the database projection must not leave an orphaned object in the
-- platform bucket. The request is recorded in the same transaction as the
-- revoke, then a worker performs an idempotent signed DELETE with retries.

ALTER TABLE chat_shared_objects
    ADD COLUMN IF NOT EXISTS cleanup_requested_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS cleanup_completed_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS cleanup_next_attempt_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS cleanup_attempts INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS cleanup_last_error TEXT;

ALTER TABLE chat_shared_objects
    ADD CONSTRAINT chat_shared_objects_cleanup_attempts_check
    CHECK (cleanup_attempts >= 0);

-- Rows revoked before this migration still need an opportunity to be
-- collected. Links have no storage key and are intentionally excluded.
UPDATE chat_shared_objects
SET cleanup_requested_at = COALESCE(revoked_at, updated_at, NOW())
WHERE kind = 'file'
  AND status IN ('revoked', 'deleted')
  AND storage_key IS NOT NULL
  AND cleanup_requested_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_chat_shared_objects_cleanup_queue
    ON chat_shared_objects(cleanup_next_attempt_at, cleanup_requested_at, id)
    WHERE kind = 'file'
      AND status IN ('revoked', 'deleted')
      AND storage_key IS NOT NULL
      AND cleanup_completed_at IS NULL;

COMMENT ON COLUMN chat_shared_objects.cleanup_requested_at IS
    'The revoke/delete transaction requested remote storage cleanup.';
COMMENT ON COLUMN chat_shared_objects.cleanup_completed_at IS
    'The platform DELETE was acknowledged or the object was already absent.';
COMMENT ON COLUMN chat_shared_objects.cleanup_next_attempt_at IS
    'Retry gate used by the durable cleanup worker after a failure or crash.';
COMMENT ON COLUMN chat_shared_objects.cleanup_last_error IS
    'Sanitized provider error retained for operations; it is not user content.';
