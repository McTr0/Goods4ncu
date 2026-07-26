-- Bind each refresh-token session to one campus. Existing sessions remain
-- compatible and are backfilled from the user's best available membership.

ALTER TABLE refresh_tokens
    ADD COLUMN IF NOT EXISTS campus_id UUID
        REFERENCES campuses(id) ON DELETE RESTRICT;

UPDATE refresh_tokens rt
SET campus_id = (
    SELECT m.campus_id
    FROM campus_memberships m
    JOIN campuses c ON c.id = m.campus_id AND c.status = 'active'
    WHERE m.user_id = rt.user_id
      AND m.status IN ('verified', 'pending')
    ORDER BY (m.status = 'verified') DESC, m.created_at ASC
    LIMIT 1
)
WHERE rt.campus_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user_campus_active
    ON refresh_tokens(user_id, campus_id, expires_at DESC)
    WHERE revoked_at IS NULL;

COMMENT ON COLUMN refresh_tokens.campus_id IS
    'Active tenant for this device session. NULL is accepted only for legacy-token compatibility.';
