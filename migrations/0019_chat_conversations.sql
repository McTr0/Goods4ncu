-- Replace permanent user connections with independent realtime sessions and mail threads.

CREATE TABLE IF NOT EXISTS chat_conversations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_request_id UUID NOT NULL,
    mode TEXT NOT NULL CHECK (mode IN ('realtime', 'mail')),
    state TEXT NOT NULL CHECK (
        state IN ('syn_sent', 'syn_ack', 'active', 'declined', 'cancelled', 'expired', 'closed', 'open')
    ),
    initiator_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    recipient_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    listing_id TEXT REFERENCES inventory(id) ON DELETE SET NULL,
    subject TEXT,
    invite_expires_at TIMESTAMPTZ,
    ack_expires_at TIMESTAMPTZ,
    idle_expires_at TIMESTAMPTZ,
    established_at TIMESTAMPTZ,
    closed_at TIMESTAMPTZ,
    close_reason TEXT,
    last_activity_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chat_conversations_no_self CHECK (initiator_id <> recipient_id),
    CONSTRAINT chat_conversations_mode_state CHECK (
        (mode = 'mail' AND state = 'open' AND subject IS NOT NULL AND char_length(btrim(subject)) BETWEEN 1 AND 120)
        OR
        (mode = 'realtime' AND state <> 'open' AND subject IS NULL)
    ),
    UNIQUE (initiator_id, client_request_id)
);

CREATE TABLE IF NOT EXISTS chat_conversation_members (
    conversation_id UUID NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    unread_count INTEGER NOT NULL DEFAULT 0 CHECK (unread_count >= 0),
    last_read_message_id BIGINT,
    archived_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (conversation_id, user_id)
);

CREATE TABLE IF NOT EXISTS chat_conversation_events (
    id BIGSERIAL PRIMARY KEY,
    conversation_id UUID NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
    actor_id TEXT REFERENCES users(id) ON DELETE SET NULL,
    event_type TEXT NOT NULL,
    from_state TEXT,
    to_state TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS chat_blocks (
    blocker_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    blocked_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (blocker_id, blocked_id),
    CONSTRAINT chat_blocks_no_self CHECK (blocker_id <> blocked_id)
);

ALTER TABLE chat_messages
    ADD COLUMN IF NOT EXISTS direct_conversation_id UUID REFERENCES chat_conversations(id) ON DELETE CASCADE,
    ADD COLUMN IF NOT EXISTS client_message_id UUID,
    ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'message'
        CHECK (kind IN ('opening', 'message'));

ALTER TABLE notifications
    ADD COLUMN IF NOT EXISTS related_conversation_id UUID REFERENCES chat_conversations(id) ON DELETE SET NULL;

-- Preserve every legacy connection as a closed realtime session with the same UUID.
INSERT INTO chat_conversations (
    id,
    client_request_id,
    mode,
    state,
    initiator_id,
    recipient_id,
    established_at,
    closed_at,
    close_reason,
    last_activity_at,
    created_at,
    updated_at
)
SELECT
    cc.id,
    cc.id,
    'realtime',
    'closed',
    cc.requester_id,
    cc.receiver_id,
    cc.established_at,
    NOW(),
    'legacy_migrated',
    COALESCE(MAX(cm.timestamp), cc.established_at, cc.created_at, NOW()),
    COALESCE(cc.created_at, NOW()),
    NOW()
FROM chat_connections cc
LEFT JOIN chat_messages cm ON cm.conversation_id = cc.id::text
GROUP BY cc.id, cc.requester_id, cc.receiver_id, cc.established_at, cc.created_at
ON CONFLICT (id) DO NOTHING;

UPDATE chat_messages cm
SET direct_conversation_id = cc.id,
    kind = 'message'
FROM chat_connections cc
WHERE cm.conversation_id = cc.id::text
  AND cm.direct_conversation_id IS NULL;

INSERT INTO chat_conversation_members (
    conversation_id,
    user_id,
    unread_count,
    last_read_message_id
)
SELECT
    cc.id,
    participant.user_id,
    COUNT(cm.id) FILTER (
        WHERE cm.receiver = participant.user_id AND cm.read_at IS NULL
    )::integer,
    MAX(cm.id) FILTER (
        WHERE cm.receiver = participant.user_id AND cm.read_at IS NOT NULL
    )
FROM chat_connections cc
CROSS JOIN LATERAL (
    VALUES (cc.requester_id), (cc.receiver_id)
) AS participant(user_id)
LEFT JOIN chat_messages cm ON cm.conversation_id = cc.id::text
GROUP BY cc.id, participant.user_id
ON CONFLICT (conversation_id, user_id) DO NOTHING;

INSERT INTO chat_conversation_events (
    conversation_id,
    event_type,
    from_state,
    to_state,
    metadata,
    created_at
)
SELECT
    id,
    'legacy_migrated',
    status,
    'closed',
    jsonb_build_object('legacy_status', status),
    NOW()
FROM chat_connections;

CREATE UNIQUE INDEX IF NOT EXISTS chat_conversations_one_live_realtime_idx
    ON chat_conversations (
        LEAST(initiator_id, recipient_id),
        GREATEST(initiator_id, recipient_id),
        COALESCE(listing_id, '')
    )
    WHERE mode = 'realtime' AND state IN ('syn_sent', 'syn_ack', 'active');

CREATE INDEX IF NOT EXISTS idx_chat_conversations_initiator_activity
    ON chat_conversations(initiator_id, last_activity_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_conversations_recipient_activity
    ON chat_conversations(recipient_id, last_activity_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_conversations_expiry
    ON chat_conversations(state, invite_expires_at, ack_expires_at, idle_expires_at)
    WHERE state IN ('syn_sent', 'syn_ack', 'active');
CREATE INDEX IF NOT EXISTS idx_chat_conversation_members_user
    ON chat_conversation_members(user_id, archived_at, conversation_id);
CREATE INDEX IF NOT EXISTS idx_chat_conversation_events_conversation
    ON chat_conversation_events(conversation_id, id);
CREATE INDEX IF NOT EXISTS idx_chat_messages_direct_conversation
    ON chat_messages(direct_conversation_id, timestamp, id)
    WHERE direct_conversation_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS chat_messages_sender_client_id_idx
    ON chat_messages(sender, client_message_id)
    WHERE client_message_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_chat_blocks_blocked
    ON chat_blocks(blocked_id, blocker_id);

DROP TABLE chat_connections;
