-- Wanted lifecycle (Phase 2): a wanted item can be marked fulfilled by its
-- owner and later reopened. Fulfilled items leave all matching/feed surfaces
-- (which filter status = 'active') while existing threads, responses and deal
-- records stay untouched.
--
-- Also pins the status vocabulary with a CHECK — until now the column was
-- free text and a typo in application code could invent a state no reader
-- understands.

-- Upgrade compatibility: older builds wrote 'takedown' for admin-removed
-- listings; current code and readers use 'deleted' for that state. Normalize
-- before constraining so the CHECK holds on upgraded databases.
UPDATE inventory SET status = 'deleted' WHERE status = 'takedown';
-- Any other unknown legacy value is conservatively hidden rather than
-- resurfaced: 'deleted' keeps it out of feeds/search while remaining
-- owner-recoverable via relist.
UPDATE inventory SET status = 'deleted'
WHERE status NOT IN ('active', 'sold', 'deleted', 'fulfilled');

ALTER TABLE inventory
    DROP CONSTRAINT IF EXISTS inventory_status_check;
ALTER TABLE inventory
    ADD CONSTRAINT inventory_status_check
    CHECK (status IN ('active', 'sold', 'deleted', 'fulfilled'));
