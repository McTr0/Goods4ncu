-- Expand the NCU location directory with common facilities and entrances.
-- These entries are intentionally manual-only until an operator verifies a
-- public geofence. They are still real chat destinations and can host
-- one-level child rooms, but recommendation never treats missing coordinates
-- as a match.

ALTER TABLE chat_spaces
    DROP CONSTRAINT IF EXISTS chat_spaces_location_shape_check;

ALTER TABLE chat_spaces
    ADD CONSTRAINT chat_spaces_location_shape_check CHECK (
        (
            origin = 'campus_location'
            AND owner_id IS NULL
            AND location_slug IS NOT NULL
            AND (
                (
                    location_kind IN ('campus', 'area', 'landmark')
                    AND latitude BETWEEN -90 AND 90
                    AND longitude BETWEEN -180 AND 180
                    AND radius_meters BETWEEN 100 AND 5000
                )
                OR (
                    location_kind = 'facility'
                    AND latitude IS NULL
                    AND longitude IS NULL
                    AND radius_meters IS NULL
                )
            )
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

-- Keep this migration self-contained. Local/test environments may preserve
-- migration versions while truncating chat data between runs.
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
    'c1000000-0000-4000-8000-000000000007',
    'c0000000-0000-0000-0000-000000000001',
    'group', '青山湖校区', '青山湖校区公共地点聊天室', NULL, 'active',
    'campus_location', '围绕青山湖校区当下的人和事交流',
    NULL, 'qingshanhu-campus', 'campus', 28.6845, 115.9325, 1200, FALSE, 20
),
(
    'c1000000-0000-4000-8000-000000000008',
    'c0000000-0000-0000-0000-000000000001',
    'group', '东湖校区', '东湖校区公共地点聊天室', NULL, 'active',
    'campus_location', '围绕东湖校区当下的人和事交流',
    NULL, 'donghu-campus', 'campus', 28.6820, 115.8950, 950, FALSE, 30
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
    parent_space_id = NULL,
    location_slug = EXCLUDED.location_slug,
    location_kind = EXCLUDED.location_kind,
    latitude = EXCLUDED.latitude,
    longitude = EXCLUDED.longitude,
    radius_meters = EXCLUDED.radius_meters,
    allows_child_spaces = FALSE,
    location_sort_order = EXCLUDED.location_sort_order,
    updated_at = NOW();

INSERT INTO chat_spaces (
    id, campus_id, kind, name, description, owner_id, status, origin, purpose,
    parent_space_id, location_slug, location_kind, latitude, longitude,
    radius_meters, allows_child_spaces, location_sort_order
) VALUES
(
    'c1000000-0000-4000-8000-000000000101',
    'c0000000-0000-0000-0000-000000000001',
    'group', '前湖校区北门', '前湖校区北门及周边接驳、集合和失物信息', NULL, 'active',
    'campus_location', '围绕前湖校区北门的即时信息',
    'c1000000-0000-4000-8000-000000000001',
    'qianhu-north-gate', 'facility', NULL, NULL, NULL, TRUE, 60
),
(
    'c1000000-0000-4000-8000-000000000102',
    'c0000000-0000-0000-0000-000000000001',
    'group', '前湖校区南门', '前湖校区南门及周边接驳、集合和失物信息', NULL, 'active',
    'campus_location', '围绕前湖校区南门的即时信息',
    'c1000000-0000-4000-8000-000000000001',
    'qianhu-south-gate', 'facility', NULL, NULL, NULL, TRUE, 61
),
(
    'c1000000-0000-4000-8000-000000000103',
    'c0000000-0000-0000-0000-000000000001',
    'group', '前湖校区图书馆', '前湖校区图书馆自习、借阅和失物信息', NULL, 'active',
    'campus_location', '围绕前湖校区图书馆的即时信息',
    'c1000000-0000-4000-8000-000000000001',
    'qianhu-library', 'facility', NULL, NULL, NULL, TRUE, 62
),
(
    'c1000000-0000-4000-8000-000000000104',
    'c0000000-0000-0000-0000-000000000001',
    'group', '前湖校区体育馆', '前湖校区体育馆及场馆预约、球友信息', NULL, 'active',
    'campus_location', '围绕前湖校区体育馆的即时信息',
    'c1000000-0000-4000-8000-000000000001',
    'qianhu-gymnasium', 'facility', NULL, NULL, NULL, TRUE, 63
),
(
    'c1000000-0000-4000-8000-000000000105',
    'c0000000-0000-0000-0000-000000000001',
    'group', '前湖校区校医院', '前湖校区校医院就诊、排队和互助信息', NULL, 'active',
    'campus_location', '围绕前湖校区校医院的即时信息',
    'c1000000-0000-4000-8000-000000000001',
    'qianhu-clinic', 'facility', NULL, NULL, NULL, TRUE, 64
),
(
    'c1000000-0000-4000-8000-000000000106',
    'c0000000-0000-0000-0000-000000000001',
    'group', '青山湖校区图书馆', '青山湖校区图书馆自习、借阅和失物信息', NULL, 'active',
    'campus_location', '围绕青山湖校区图书馆的即时信息',
    'c1000000-0000-4000-8000-000000000007',
    'qingshanhu-library', 'facility', NULL, NULL, NULL, TRUE, 60
),
(
    'c1000000-0000-4000-8000-000000000107',
    'c0000000-0000-0000-0000-000000000001',
    'group', '东湖校区图书馆', '东湖校区图书馆自习、借阅和失物信息', NULL, 'active',
    'campus_location', '围绕东湖校区图书馆的即时信息',
    'c1000000-0000-4000-8000-000000000008',
    'donghu-library', 'facility', NULL, NULL, NULL, TRUE, 60
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
    latitude = NULL,
    longitude = NULL,
    radius_meters = NULL,
    allows_child_spaces = EXCLUDED.allows_child_spaces,
    location_sort_order = EXCLUDED.location_sort_order,
    updated_at = NOW();

UPDATE chat_spaces
   SET allows_child_spaces = FALSE,
       updated_at = NOW()
 WHERE id IN (
     'c1000000-0000-4000-8000-000000000007',
     'c1000000-0000-4000-8000-000000000008'
 );
