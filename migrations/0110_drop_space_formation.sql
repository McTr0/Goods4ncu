-- Drop the AI space-formation system (0048).
--
-- The formation worker, admin trigger, and explain endpoint are removed.
-- Group chats are created manually only.

DROP TABLE IF EXISTS space_formation_pairs;
DROP TABLE IF EXISTS space_formation_sources;
