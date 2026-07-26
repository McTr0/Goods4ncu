-- Transactional outbox for durable async side effects.
--
-- Business writes enqueue an event in the SAME transaction as their state
-- change; a worker later claims and dispatches it. This closes the gap where a
-- crash between "commit" and "in-process event handled" silently loses the
-- side effect — with an in-memory channel that loss is undetectable.
--
-- Claiming uses a lease (locked_by/locked_until) with FOR UPDATE SKIP LOCKED,
-- so multiple workers/replicas can drain the table without double-dispatching
-- while a lease is live, and a crashed worker's claims become reclaimable when
-- the lease expires.
CREATE TABLE IF NOT EXISTS outbox_events (
    id BIGSERIAL PRIMARY KEY,
    topic TEXT NOT NULL,
    payload JSONB NOT NULL,
    attempts INT NOT NULL DEFAULT 0,
    max_attempts INT NOT NULL DEFAULT 8,
    available_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    locked_by TEXT,
    locked_until TIMESTAMPTZ,
    processed_at TIMESTAMPTZ,
    dead_lettered_at TIMESTAMPTZ,
    last_error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Partial index keeps the hot claim query fast no matter how much processed
-- history is retained.
CREATE INDEX IF NOT EXISTS idx_outbox_events_pending
    ON outbox_events (available_at, id)
    WHERE processed_at IS NULL AND dead_lettered_at IS NULL;
