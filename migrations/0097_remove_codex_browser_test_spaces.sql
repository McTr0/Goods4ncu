-- Remove integration-test spaces created by scripts/codex_browser_api_driver.mjs.
--
-- The driver stamps each run's permission-check channel with a timestamp
-- suffix; those rows accumulate in the inbox forever. Delete the spaces and
-- their messages/members/presence. campus_map_nodes references were checked
-- to be empty for this pattern; notifications are nulled defensively.
BEGIN;

CREATE TEMP TABLE _codex_test_spaces ON COMMIT DROP AS
SELECT id FROM chat_spaces WHERE name LIKE 'Codex Browser channel %';

UPDATE notifications
SET related_space_id = NULL
WHERE related_space_id IN (SELECT id FROM _codex_test_spaces);

DELETE FROM chat_space_messages
WHERE space_id IN (SELECT id FROM _codex_test_spaces);

DELETE FROM chat_space_members
WHERE space_id IN (SELECT id FROM _codex_test_spaces);

DELETE FROM chat_space_presence
WHERE space_id IN (SELECT id FROM _codex_test_spaces);

DELETE FROM space_formation_sources
WHERE space_id IN (SELECT id FROM _codex_test_spaces);

DELETE FROM chat_spaces
WHERE id IN (SELECT id FROM _codex_test_spaces);

COMMIT;
