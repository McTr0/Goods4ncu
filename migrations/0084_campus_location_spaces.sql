-- Campus location chat spaces.
--
-- Official location rooms reuse chat_spaces and chat_space_messages. Exact
-- user coordinates are never stored: only the public geofence catalogue lives
-- in the database, and recommendation requests are evaluated in memory.

ALTER TABLE chat_spaces
    ALTER COLUMN owner_id DROP NOT NULL,
    ADD COLUMN IF NOT EXISTS parent_space_id UUID,
    ADD COLUMN IF NOT EXISTS location_slug TEXT,
    ADD COLUMN IF NOT EXISTS location_kind TEXT,
    ADD COLUMN IF NOT EXISTS latitude DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS longitude DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS radius_meters INTEGER,
    ADD COLUMN IF NOT EXISTS allows_child_spaces BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS location_sort_order SMALLINT NOT NULL DEFAULT 0;

ALTER TABLE chat_spaces
    DROP CONSTRAINT IF EXISTS chat_spaces_origin_check;
ALTER TABLE chat_spaces
    ADD CONSTRAINT chat_spaces_origin_check
    CHECK (origin IN (
        'ai_formed', 'promoted', 'manual', 'campus_location', 'location_child'
    ));

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'chat_spaces_id_campus_unique'
    ) THEN
        ALTER TABLE chat_spaces
            ADD CONSTRAINT chat_spaces_id_campus_unique UNIQUE (id, campus_id);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'chat_spaces_parent_campus_fk'
    ) THEN
        ALTER TABLE chat_spaces
            ADD CONSTRAINT chat_spaces_parent_campus_fk
            FOREIGN KEY (parent_space_id, campus_id)
            REFERENCES chat_spaces(id, campus_id) ON DELETE CASCADE;
    END IF;
END $$;

ALTER TABLE chat_spaces
    DROP CONSTRAINT IF EXISTS chat_spaces_location_shape_check;
ALTER TABLE chat_spaces
    ADD CONSTRAINT chat_spaces_location_shape_check CHECK (
        (
            origin = 'campus_location'
            AND owner_id IS NULL
            AND location_slug IS NOT NULL
            AND location_kind IN ('campus', 'area', 'landmark')
            AND latitude BETWEEN -90 AND 90
            AND longitude BETWEEN -180 AND 180
            AND radius_meters BETWEEN 100 AND 5000
        )
        OR (
            origin = 'location_child'
            AND owner_id IS NOT NULL
            AND parent_space_id IS NOT NULL
            AND location_slug IS NULL
            AND location_kind = 'custom'
            AND latitude IS NULL
            AND longitude IS NULL
            AND radius_meters IS NULL
            AND allows_child_spaces = FALSE
        )
        OR (
            origin NOT IN ('campus_location', 'location_child')
            AND parent_space_id IS NULL
            AND location_slug IS NULL
            AND location_kind IS NULL
            AND latitude IS NULL
            AND longitude IS NULL
            AND radius_meters IS NULL
            AND allows_child_spaces = FALSE
        )
    );

CREATE UNIQUE INDEX IF NOT EXISTS chat_spaces_location_slug_unique
    ON chat_spaces(campus_id, location_slug)
    WHERE origin = 'campus_location';

CREATE UNIQUE INDEX IF NOT EXISTS chat_spaces_location_child_name_unique
    ON chat_spaces(parent_space_id, lower(btrim(name)))
    WHERE origin = 'location_child' AND status = 'active';

CREATE INDEX IF NOT EXISTS idx_chat_spaces_location_tree
    ON chat_spaces(campus_id, parent_space_id, location_sort_order, name)
    WHERE origin IN ('campus_location', 'location_child') AND status = 'active';

CREATE OR REPLACE FUNCTION validate_location_child_parent()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    parent_origin TEXT;
    parent_allows_children BOOLEAN;
BEGIN
    IF NEW.origin <> 'location_child' THEN
        RETURN NEW;
    END IF;

    SELECT origin, allows_child_spaces
      INTO parent_origin, parent_allows_children
      FROM chat_spaces
     WHERE id = NEW.parent_space_id AND campus_id = NEW.campus_id;

    IF parent_origin IS DISTINCT FROM 'campus_location'
       OR parent_allows_children IS DISTINCT FROM TRUE THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'location child parent must be an official leaf location';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS chat_spaces_location_child_parent_validate ON chat_spaces;
CREATE TRIGGER chat_spaces_location_child_parent_validate
    BEFORE INSERT OR UPDATE OF origin, parent_space_id, campus_id ON chat_spaces
    FOR EACH ROW EXECUTE FUNCTION validate_location_child_parent();

-- Stable IDs make the official NCU location tree safe to update in place.
-- Radii are intentionally coarse campus/place geofences, not building-level
-- tracking boundaries.
INSERT INTO chat_spaces (
    id, campus_id, kind, name, description, owner_id, status, origin, purpose,
    parent_space_id, location_slug, location_kind, latitude, longitude,
    radius_meters, allows_child_spaces, location_sort_order
) VALUES
(
    'c1000000-0000-4000-8000-000000000001',
    'c0000000-0000-0000-0000-000000000001',
    'group', '前湖校区', '前湖校区公共地点聊天室', NULL, 'active',
    'campus_location', '围绕前湖校区当下的人和事交流',
    NULL, 'qianhu-campus', 'campus', 28.6630, 115.8000, 1800, FALSE, 10
),
(
    'c1000000-0000-4000-8000-000000000002',
    'c0000000-0000-0000-0000-000000000001',
    'group', '前湖北院', '前湖校区北院公共地点聊天室', NULL, 'active',
    'campus_location', '连接前湖北院附近的同学',
    'c1000000-0000-4000-8000-000000000001',
    'qianhu-north', 'area', 28.6700, 115.7965, 650, TRUE, 10
),
(
    'c1000000-0000-4000-8000-000000000003',
    'c0000000-0000-0000-0000-000000000001',
    'group', '前湖南院', '前湖校区南院公共地点聊天室', NULL, 'active',
    'campus_location', '连接前湖南院附近的同学',
    'c1000000-0000-4000-8000-000000000001',
    'qianhu-south', 'area', 28.6555, 115.7960, 700, TRUE, 20
),
(
    'c1000000-0000-4000-8000-000000000004',
    'c0000000-0000-0000-0000-000000000001',
    'group', '修贤广场', '修贤广场公共地点聊天室', NULL, 'active',
    'campus_location', '分享修贤广场附近的即时信息和活动',
    'c1000000-0000-4000-8000-000000000001',
    'xiuxian-square', 'landmark', 28.6622, 115.8011, 320, TRUE, 30
),
(
    'c1000000-0000-4000-8000-000000000005',
    'c0000000-0000-0000-0000-000000000001',
    'group', '润溪湖畔', '润溪湖畔公共地点聊天室', NULL, 'active',
    'campus_location', '连接润溪湖畔附近的同学',
    'c1000000-0000-4000-8000-000000000001',
    'runxi-lake', 'landmark', 28.6635, 115.8060, 450, TRUE, 40
),
(
    'c1000000-0000-4000-8000-000000000006',
    'c0000000-0000-0000-0000-000000000001',
    'group', '天健操场', '天健操场公共地点聊天室', NULL, 'active',
    'campus_location', '找球友、约跑步并分享操场动态',
    'c1000000-0000-4000-8000-000000000001',
    'tianjian-field', 'landmark', 28.6562, 115.8035, 480, TRUE, 50
),
(
    'c1000000-0000-4000-8000-000000000007',
    'c0000000-0000-0000-0000-000000000001',
    'group', '青山湖校区', '青山湖校区公共地点聊天室', NULL, 'active',
    'campus_location', '围绕青山湖校区当下的人和事交流',
    NULL, 'qingshanhu-campus', 'campus', 28.6845, 115.9325, 1200, TRUE, 20
),
(
    'c1000000-0000-4000-8000-000000000008',
    'c0000000-0000-0000-0000-000000000001',
    'group', '东湖校区', '东湖校区公共地点聊天室', NULL, 'active',
    'campus_location', '围绕东湖校区当下的人和事交流',
    NULL, 'donghu-campus', 'campus', 28.6820, 115.8950, 950, TRUE, 30
)
ON CONFLICT (id) DO UPDATE SET
    campus_id = EXCLUDED.campus_id,
    kind = EXCLUDED.kind,
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    owner_id = NULL,
    status = 'active',
    origin = 'campus_location',
    purpose = EXCLUDED.purpose,
    parent_space_id = EXCLUDED.parent_space_id,
    location_slug = EXCLUDED.location_slug,
    location_kind = EXCLUDED.location_kind,
    latitude = EXCLUDED.latitude,
    longitude = EXCLUDED.longitude,
    radius_meters = EXCLUDED.radius_meters,
    allows_child_spaces = EXCLUDED.allows_child_spaces,
    location_sort_order = EXCLUDED.location_sort_order,
    updated_at = NOW();

COMMENT ON COLUMN chat_spaces.parent_space_id IS
    'Parent in the campus location tree. Composite FK prevents cross-campus nesting.';
COMMENT ON COLUMN chat_spaces.allows_child_spaces IS
    'True only for official taxonomy leaves where verified members may create one-level child rooms.';
COMMENT ON COLUMN chat_spaces.latitude IS
    'Public geofence centre for an official place; never a user observation.';
