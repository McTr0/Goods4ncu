-- Telegram-inspired chat upgrade for direct conversations and campus spaces.
-- This migration is additive: existing direct conversations keep their data and
-- get message-level interactions through side tables.

ALTER TABLE chat_messages
    ADD COLUMN IF NOT EXISTS reply_to_message_id BIGINT REFERENCES chat_messages(id) ON DELETE SET NULL;

CREATE TABLE IF NOT EXISTS chat_message_hidden_members (
    message_id BIGINT NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    hidden_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (message_id, user_id)
);

CREATE TABLE IF NOT EXISTS chat_message_reactions (
    message_id BIGINT NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    emoji TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (message_id, user_id)
);

CREATE TABLE IF NOT EXISTS chat_message_reports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id BIGINT NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
    reporter_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    reason TEXT NOT NULL,
    details TEXT,
    status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'reviewing', 'resolved', 'dismissed')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (message_id, reporter_id)
);

CREATE TABLE IF NOT EXISTS chat_spaces (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kind TEXT NOT NULL CHECK (kind IN ('group', 'channel')),
    name TEXT NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 80),
    description TEXT,
    owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS chat_space_members (
    space_id UUID NOT NULL REFERENCES chat_spaces(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member', 'banned')),
    unread_count INTEGER NOT NULL DEFAULT 0 CHECK (unread_count >= 0),
    last_read_message_id BIGINT,
    joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (space_id, user_id)
);

CREATE TABLE IF NOT EXISTS chat_space_messages (
    id BIGSERIAL PRIMARY KEY,
    space_id UUID NOT NULL REFERENCES chat_spaces(id) ON DELETE CASCADE,
    client_message_id UUID NOT NULL,
    sender_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    content TEXT NOT NULL CHECK (char_length(btrim(content)) BETWEEN 1 AND 4000),
    reply_to_message_id BIGINT REFERENCES chat_space_messages(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (space_id, sender_id, client_message_id)
);

CREATE TABLE IF NOT EXISTS chat_calls (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
    caller_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    callee_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    media TEXT NOT NULL CHECK (media IN ('audio', 'video')),
    state TEXT NOT NULL DEFAULT 'ringing' CHECK (state IN ('ringing', 'accepted', 'ended', 'declined')),
    offer_sdp TEXT NOT NULL,
    answer_sdp TEXT,
    ended_reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    answered_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS chat_call_ice_candidates (
    id BIGSERIAL PRIMARY KEY,
    call_id UUID NOT NULL REFERENCES chat_calls(id) ON DELETE CASCADE,
    sender_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    candidate JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS chat_secret_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    initiator_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    recipient_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    initiator_key_fingerprint TEXT NOT NULL,
    recipient_key_fingerprint TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'closed')),
    expires_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    closed_at TIMESTAMPTZ,
    CONSTRAINT chat_secret_sessions_no_self CHECK (initiator_id <> recipient_id)
);

CREATE TABLE IF NOT EXISTS chat_secret_messages (
    id BIGSERIAL PRIMARY KEY,
    session_id UUID NOT NULL REFERENCES chat_secret_sessions(id) ON DELETE CASCADE,
    sender_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    client_message_id UUID NOT NULL,
    ciphertext TEXT NOT NULL,
    nonce TEXT NOT NULL,
    key_fingerprint TEXT NOT NULL,
    expires_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (session_id, sender_id, client_message_id)
);

CREATE INDEX IF NOT EXISTS idx_chat_messages_reply_to
    ON chat_messages(reply_to_message_id)
    WHERE reply_to_message_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_chat_hidden_members_user
    ON chat_message_hidden_members(user_id, hidden_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_reactions_message
    ON chat_message_reactions(message_id);
CREATE INDEX IF NOT EXISTS idx_chat_reports_status
    ON chat_message_reports(status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_spaces_kind
    ON chat_spaces(kind, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_space_members_user
    ON chat_space_members(user_id, space_id);
CREATE INDEX IF NOT EXISTS idx_chat_space_messages_space
    ON chat_space_messages(space_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_chat_calls_conversation
    ON chat_calls(conversation_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_secret_sessions_user
    ON chat_secret_sessions(initiator_id, recipient_id, status);
CREATE INDEX IF NOT EXISTS idx_chat_secret_messages_session
    ON chat_secret_messages(session_id, created_at DESC, id DESC);
