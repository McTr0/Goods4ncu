-- Companion relationship state (master goal §13–15).
-- One row per user; numeric familiarity/trust/affinity with daily caps so
-- affection cannot be farmed, plus an explicit stage for greeting tone.

CREATE TABLE IF NOT EXISTS companion_relationships (
    user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    familiarity REAL NOT NULL DEFAULT 0.0,
    trust REAL NOT NULL DEFAULT 0.0,
    affinity REAL NOT NULL DEFAULT 0.0,
    interaction_count INTEGER NOT NULL DEFAULT 0,
    last_interaction_at TIMESTAMPTZ,
    relationship_stage TEXT NOT NULL DEFAULT 'new',
    daily_affinity_gained REAL NOT NULL DEFAULT 0.0,
    daily_window_date DATE NOT NULL DEFAULT CURRENT_DATE,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE companion_relationships
    DROP CONSTRAINT IF EXISTS companion_relationships_stage_check;
ALTER TABLE companion_relationships
    ADD CONSTRAINT companion_relationships_stage_check
        CHECK (relationship_stage IN ('new', 'familiar', 'close'));
