-- Retire the campus location-space experiment (0084/0085).
--
-- The seeded public "location" rooms and the geo-recommendation surface
-- never shipped in the app; this removes the data, the columns, the
-- child-validation trigger, and the related indexes.

DROP INDEX IF EXISTS idx_chat_spaces_location_tree;
DROP INDEX IF EXISTS chat_spaces_location_slug_unique;
DROP INDEX IF EXISTS chat_spaces_location_child_name_unique;

DROP TRIGGER IF EXISTS chat_spaces_location_child_parent_validate ON chat_spaces;
DROP FUNCTION IF EXISTS validate_location_child_parent();

DELETE FROM chat_spaces WHERE origin IN ('campus_location', 'location_child');

ALTER TABLE chat_spaces
    DROP COLUMN IF EXISTS location_kind,
    DROP COLUMN IF EXISTS location_slug,
    DROP COLUMN IF EXISTS latitude,
    DROP COLUMN IF EXISTS longitude,
    DROP COLUMN IF EXISTS radius_meters,
    DROP COLUMN IF EXISTS allows_child_spaces,
    DROP COLUMN IF EXISTS location_sort_order;
