-- Camphor leaf currency (香樟叶), a bilibili-style coin system.
--
-- * One leaf granted per user per UTC day, lazily settled on the first
--   authenticated request that touches the service (no cron).
-- * Users fertilize (施肥) posts: -1 leaf, one fertilize per post per user,
--   irreversible; posts keep a redundant counter for cheap display.
-- * The ledger is append-only; balance = SUM(amount).

CREATE TABLE camphor_ledger (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campus_id UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    amount INT NOT NULL CHECK (amount IN (-1, 1)),
    reason TEXT NOT NULL CHECK (reason IN ('daily_grant', 'fertilize')),
    post_id UUID REFERENCES posts(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT camphor_reason_shape CHECK (
        (reason = 'daily_grant' AND amount = 1 AND post_id IS NULL)
        OR (reason = 'fertilize' AND amount = -1 AND post_id IS NOT NULL)
    )
);

CREATE INDEX idx_camphor_ledger_user ON camphor_ledger (user_id, created_at DESC);

-- Idempotency at the storage layer: these partial unique indexes make
-- double-grant and double-fertilize races impossible even under concurrency.
CREATE UNIQUE INDEX idx_camphor_daily_unique
    ON camphor_ledger (user_id, CAST(created_at AT TIME ZONE 'UTC' AS date))
    WHERE reason = 'daily_grant';
CREATE UNIQUE INDEX idx_camphor_fertilize_once
    ON camphor_ledger (post_id, user_id)
    WHERE reason = 'fertilize';

ALTER TABLE posts ADD COLUMN fertilizer_count INT NOT NULL DEFAULT 0
    CHECK (fertilizer_count >= 0);
