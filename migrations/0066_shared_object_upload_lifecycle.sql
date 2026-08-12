-- Make file references truthful about storage and moderation.
--
-- 0065 created the authoritative row before the mobile client could upload to
-- the server-generated key.  A file must therefore remain hidden from quotes
-- and media endpoints until the API probes the platform object after upload.
-- Link objects do not need this phase and remain active immediately.

ALTER TABLE chat_shared_objects
    ADD COLUMN IF NOT EXISTS moderation_status TEXT NOT NULL DEFAULT 'not_required',
    ADD COLUMN IF NOT EXISTS storage_verified_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS uploaded_size_bytes BIGINT,
    ADD COLUMN IF NOT EXISTS uploaded_mime_type TEXT,
    ADD COLUMN IF NOT EXISTS storage_etag TEXT,
    ADD COLUMN IF NOT EXISTS last_error TEXT;

ALTER TABLE chat_shared_objects
    DROP CONSTRAINT IF EXISTS chat_shared_objects_status_check;
ALTER TABLE chat_shared_objects
    ADD CONSTRAINT chat_shared_objects_status_check
    CHECK (status IN ('pending_upload', 'pending_review', 'active', 'rejected', 'revoked', 'deleted'));

ALTER TABLE chat_shared_objects
    DROP CONSTRAINT IF EXISTS chat_shared_objects_moderation_status_check;
ALTER TABLE chat_shared_objects
    ADD CONSTRAINT chat_shared_objects_moderation_status_check
    CHECK (moderation_status IN ('not_required', 'pending', 'approved', 'rejected', 'failed'));

ALTER TABLE chat_shared_objects
    ADD CONSTRAINT chat_shared_objects_uploaded_size_check
    CHECK (uploaded_size_bytes IS NULL OR (uploaded_size_bytes >= 0 AND uploaded_size_bytes <= 2147483648));

ALTER TABLE chat_shared_objects
    ADD CONSTRAINT chat_shared_objects_active_moderation_check
    CHECK (status <> 'active' OR moderation_status IN ('approved', 'not_required'));

ALTER TABLE chat_shared_objects
    ADD CONSTRAINT chat_shared_objects_active_storage_check
    CHECK (kind = 'link' OR status <> 'active' OR storage_verified_at IS NOT NULL);

-- Existing 0065 file rows were never storage-verified.  Keep their history but
-- remove the false promise that they are ready to open or quote.  Links remain
-- active because their canonical URL is the object itself.
UPDATE chat_shared_objects
SET status = 'pending_upload',
    moderation_status = 'not_required',
    storage_verified_at = NULL
WHERE kind = 'file' AND status = 'active';

UPDATE chat_shared_objects
SET moderation_status = 'approved'
WHERE kind = 'link' AND status = 'active' AND moderation_status = 'not_required';

CREATE INDEX IF NOT EXISTS idx_chat_shared_objects_upload_lifecycle
    ON chat_shared_objects(kind, status, storage_verified_at, updated_at);

-- Completion retries may race after a provider timeout.  Only one live image
-- moderation job may exist for a shared object; the API takes the object row
-- lock before inserting so this index also protects older clients.
CREATE UNIQUE INDEX IF NOT EXISTS idx_moderation_jobs_shared_object_live
    ON moderation_jobs(resource_type, resource_id)
    WHERE resource_type = 'chat_shared_object'
      AND status IN ('pending', 'processing');

COMMENT ON COLUMN chat_shared_objects.status IS
    'File lifecycle: pending_upload -> pending_review/active -> revoked/deleted; links start active.';
COMMENT ON COLUMN chat_shared_objects.storage_verified_at IS
    'Server probe confirmed the platform object exists; client upload claims alone do not set this.';
COMMENT ON COLUMN chat_shared_objects.moderation_status IS
    'Image moderation state. Non-image files and links use not_required.';
