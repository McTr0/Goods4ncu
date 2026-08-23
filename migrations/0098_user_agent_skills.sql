-- User-importable companion skills.
--
-- A skill is a named instruction module the user can author (or paste as
-- JSON from someone else) to extend 小昌's behavior. Enabled skills are
-- injected into every turn's memory context, below the system policy and
-- persona layers. chip_label optionally surfaces a quick-suggestion chip in
-- the chat composer area.
CREATE TABLE IF NOT EXISTS user_agent_skills (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id TEXT NOT NULL,
    name TEXT NOT NULL,
    instructions TEXT NOT NULL,
    chip_label TEXT,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    sort_order INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, name)
);
CREATE INDEX IF NOT EXISTS idx_user_agent_skills_user
    ON user_agent_skills (user_id, enabled, sort_order);
