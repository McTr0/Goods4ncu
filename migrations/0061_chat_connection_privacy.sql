-- Connection requests are an explicit interruption.  A stranger may leave a
-- message, but cannot open a realtime invite unless the recipient opted in.

CREATE TABLE IF NOT EXISTS chat_connection_preferences (
    user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    allow_strangers BOOLEAN NOT NULL DEFAULT FALSE,
    busy_until TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS chat_contact_permissions (
    owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    peer_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    allow_connection BOOLEAN NOT NULL DEFAULT TRUE,
    muted_until TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (owner_id, peer_id),
    CHECK (owner_id <> peer_id)
);

CREATE INDEX IF NOT EXISTS chat_contact_permissions_peer_idx
    ON chat_contact_permissions(peer_id, owner_id);

-- A live realtime request is a peer-level fact, not a per-listing fact.  This
-- closes the race where the same requester opens parallel invites with
-- different listing ids.  The old index was listing-scoped, so close any
-- pre-existing duplicates before installing the stricter unique index.  The
-- newest session remains authoritative and the older rows stay in history.
WITH ranked AS (
    SELECT
        id,
        ROW_NUMBER() OVER (
            PARTITION BY LEAST(initiator_id, recipient_id),
                         GREATEST(initiator_id, recipient_id),
                         campus_id
            ORDER BY last_activity_at DESC, id DESC
        ) AS duplicate_rank
    FROM chat_conversations
    WHERE mode = 'realtime'
      AND state IN ('syn_sent', 'syn_ack', 'active')
)
UPDATE chat_conversations AS conversation
SET state = 'closed',
    closed_at = COALESCE(conversation.closed_at, NOW()),
    close_reason = COALESCE(conversation.close_reason, 'privacy_duplicate_closed'),
    invite_expires_at = NULL,
    ack_expires_at = NULL,
    idle_expires_at = NULL,
    updated_at = NOW(),
    version = conversation.version + 1
FROM ranked
WHERE conversation.id = ranked.id
  AND ranked.duplicate_rank > 1;

DROP INDEX IF EXISTS chat_conversations_one_live_realtime_idx;
CREATE UNIQUE INDEX IF NOT EXISTS chat_conversations_one_live_realtime_pair_idx
    ON chat_conversations (
        campus_id,
        LEAST(initiator_id, recipient_id),
        GREATEST(initiator_id, recipient_id)
    )
    WHERE mode = 'realtime' AND state IN ('syn_sent', 'syn_ack', 'active');
