-- Add privacy-controlled user discovery fields.
--
-- Username discovery stays enabled for compatibility with existing user search.
-- Email and student-id discovery default to off so users opt in explicitly.

ALTER TABLE users
ADD COLUMN IF NOT EXISTS student_id TEXT NULL;

ALTER TABLE users
ADD COLUMN IF NOT EXISTS discover_by_username BOOLEAN NOT NULL DEFAULT TRUE;

ALTER TABLE users
ADD COLUMN IF NOT EXISTS discover_by_email BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE users
ADD COLUMN IF NOT EXISTS discover_by_student_id BOOLEAN NOT NULL DEFAULT FALSE;

UPDATE users
SET student_id = substring(lower(email) from '^([0-9]{8,12})@email\.ncu\.edu\.cn$')
WHERE email IS NOT NULL
  AND student_id IS NULL
  AND lower(email) ~ '^[0-9]{8,12}@email\.ncu\.edu\.cn$';

CREATE UNIQUE INDEX IF NOT EXISTS users_student_id_unique_idx
ON users(student_id)
WHERE student_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS users_discoverable_username_idx
ON users(lower(username))
WHERE discover_by_username = TRUE;

CREATE INDEX IF NOT EXISTS users_discoverable_email_idx
ON users(lower(email))
WHERE discover_by_email = TRUE AND email IS NOT NULL;

CREATE INDEX IF NOT EXISTS users_discoverable_student_id_idx
ON users(student_id)
WHERE discover_by_student_id = TRUE AND student_id IS NOT NULL;
