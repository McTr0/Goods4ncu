-- Scope persisted notifications to one campus. Business-linked history is
-- backfilled from its owning fact; only legacy general notices fall back to the
-- user's best available membership.

ALTER TABLE notifications
    ADD COLUMN IF NOT EXISTS campus_id UUID
        REFERENCES campuses(id) ON DELETE RESTRICT;

UPDATE notifications n
SET campus_id = COALESCE(
    (
        SELECT o.campus_id
        FROM orders o
        WHERE o.id = n.related_order_id
        LIMIT 1
    ),
    (
        SELECT i.campus_id
        FROM inventory i
        WHERE i.id = n.related_listing_id
        LIMIT 1
    ),
    (
        SELECT c.campus_id
        FROM chat_conversations c
        WHERE c.id = n.related_conversation_id
        LIMIT 1
    ),
    (
        SELECT m.campus_id
        FROM campus_memberships m
        JOIN campuses c ON c.id = m.campus_id AND c.status = 'active'
        WHERE m.user_id = n.user_id
          AND m.status IN ('verified', 'pending')
        ORDER BY (m.status = 'verified') DESC, m.created_at ASC
        LIMIT 1
    ),
    (SELECT id FROM campuses WHERE slug = 'ncu' LIMIT 1)
)
WHERE n.campus_id IS NULL;

ALTER TABLE notifications
    ALTER COLUMN campus_id SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_notifications_user_campus_created
    ON notifications(user_id, campus_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_notifications_user_campus_unread
    ON notifications(user_id, campus_id, created_at DESC)
    WHERE is_read = FALSE;

COMMENT ON COLUMN notifications.campus_id IS
    'Tenant that owns this notification. Reads and read-state updates must match the active device campus.';
