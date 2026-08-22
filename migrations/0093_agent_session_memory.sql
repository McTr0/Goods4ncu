-- Session-scoped agent memory (goal §36): the topic and listings the user is
-- currently exploring, so follow-up turns like “最近发的” resolve without the
-- user restating the query. Ephemeral working context, not a stored profile.

CREATE TABLE IF NOT EXISTS agent_session_memory (
    user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    current_topic TEXT NOT NULL DEFAULT '',
    recent_listing_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
