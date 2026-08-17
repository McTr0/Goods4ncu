-- Logical campus map directory and routing graph.
--
-- The photographed Qianhu map is a visual reference, not survey data. Rows
-- derived from it stay unverified and non-routable until an operator checks
-- the place, entrance and connecting path. User coordinates are never stored
-- in these tables.

-- Keep this migration self-contained. Test environments can preserve applied
-- migration versions while truncating chat data, so 0084/0085 seeds may be
-- absent when this migration is first applied.
INSERT INTO chat_spaces (
    id, campus_id, kind, name, description, owner_id, status, origin, purpose,
    parent_space_id, location_slug, location_kind, latitude, longitude,
    radius_meters, allows_child_spaces, location_sort_order
) VALUES
(
    'c1000000-0000-4000-8000-000000000001',
    'c0000000-0000-0000-0000-000000000001',
    'group', '前湖校区', '前湖校区公共地点聊天室', NULL, 'archived',
    'campus_location', '前湖校区旧目录兼容入口',
    NULL, 'qianhu-campus', 'campus', 28.6572190, 115.7931408, 1800,
    FALSE, 900
),
(
    'c1000000-0000-4000-8000-000000000002',
    'c0000000-0000-0000-0000-000000000001',
    'group', '前湖北院', '前湖北院公共地点聊天室', NULL, 'active',
    'campus_location', '连接前湖北院附近的同学',
    NULL, 'qianhu-north', 'area', 28.6700, 115.7965, 650, TRUE, 10
),
(
    'c1000000-0000-4000-8000-000000000003',
    'c0000000-0000-0000-0000-000000000001',
    'group', '前湖南院', '前湖南院公共地点聊天室', NULL, 'active',
    'campus_location', '连接前湖南院附近的同学',
    NULL, 'qianhu-south', 'area', 28.6555, 115.7960, 700, TRUE, 20
),
(
    'c1000000-0000-4000-8000-000000000004',
    'c0000000-0000-0000-0000-000000000001',
    'group', '修贤广场', '修贤广场公共地点聊天室', NULL, 'active',
    'campus_location', '分享修贤广场附近的即时信息和活动',
    'c1000000-0000-4000-8000-000000000003',
    'xiuxian-square', 'landmark', 28.6622, 115.8011, 320, TRUE, 30
),
(
    'c1000000-0000-4000-8000-000000000005',
    'c0000000-0000-0000-0000-000000000001',
    'group', '润溪湖畔', '润溪湖畔公共地点聊天室', NULL, 'active',
    'campus_location', '连接润溪湖畔附近的同学',
    'c1000000-0000-4000-8000-000000000002',
    'runxi-lake', 'landmark', 28.6635, 115.8060, 450, TRUE, 30
),
(
    'c1000000-0000-4000-8000-000000000006',
    'c0000000-0000-0000-0000-000000000001',
    'group', '天健操场', '天健操场公共地点聊天室', NULL, 'active',
    'campus_location', '找球友、约跑步并分享操场动态',
    'c1000000-0000-4000-8000-000000000003',
    'tianjian-field', 'landmark', 28.6562, 115.8035, 480, TRUE, 40
),
(
    'c1000000-0000-4000-8000-000000000007',
    'c0000000-0000-0000-0000-000000000001',
    'group', '青山湖校区', '青山湖校区公共地点聊天室', NULL, 'active',
    'campus_location', '围绕青山湖校区当下的人和事交流',
    NULL, 'qingshanhu-campus', 'campus', 28.6845, 115.9325, 1200,
    FALSE, 30
),
(
    'c1000000-0000-4000-8000-000000000008',
    'c0000000-0000-0000-0000-000000000001',
    'group', '东湖校区', '东湖校区公共地点聊天室', NULL, 'active',
    'campus_location', '围绕东湖校区当下的人和事交流',
    NULL, 'donghu-campus', 'campus', 28.6820, 115.8950, 950,
    FALSE, 40
),
(
    'c1000000-0000-4000-8000-000000000101',
    'c0000000-0000-0000-0000-000000000001',
    'group', '前湖校区北门', '前湖校区北门及周边接驳、集合和失物信息',
    NULL, 'active', 'campus_location', '围绕前湖校区北门的即时信息',
    'c1000000-0000-4000-8000-000000000002',
    'qianhu-north-gate', 'facility', NULL, NULL, NULL, TRUE, 20
),
(
    'c1000000-0000-4000-8000-000000000102',
    'c0000000-0000-0000-0000-000000000001',
    'group', '前湖校区南门', '前湖校区南门及周边接驳、集合和失物信息',
    NULL, 'active', 'campus_location', '围绕前湖校区南门的即时信息',
    'c1000000-0000-4000-8000-000000000003',
    'qianhu-south-gate', 'facility', NULL, NULL, NULL, TRUE, 10
),
(
    'c1000000-0000-4000-8000-000000000103',
    'c0000000-0000-0000-0000-000000000001',
    'group', '前湖校区图书馆', '前湖校区图书馆自习、借阅和失物信息',
    NULL, 'active', 'campus_location', '围绕前湖校区图书馆的即时信息',
    'c1000000-0000-4000-8000-000000000002',
    'qianhu-library', 'facility', NULL, NULL, NULL, TRUE, 40
),
(
    'c1000000-0000-4000-8000-000000000104',
    'c0000000-0000-0000-0000-000000000001',
    'group', '前湖校区体育馆', '前湖校区体育馆及场馆预约、球友信息',
    NULL, 'active', 'campus_location', '围绕前湖校区体育馆的即时信息',
    'c1000000-0000-4000-8000-000000000003',
    'qianhu-gymnasium', 'facility', NULL, NULL, NULL, TRUE, 50
),
(
    'c1000000-0000-4000-8000-000000000105',
    'c0000000-0000-0000-0000-000000000001',
    'group', '前湖校区校医院', '前湖校区校医院就诊、排队和互助信息',
    NULL, 'active', 'campus_location', '围绕前湖校区校医院的即时信息',
    'c1000000-0000-4000-8000-000000000003',
    'qianhu-clinic', 'facility', NULL, NULL, NULL, TRUE, 60
),
(
    'c1000000-0000-4000-8000-000000000106',
    'c0000000-0000-0000-0000-000000000001',
    'group', '青山湖校区图书馆', '青山湖校区图书馆自习、借阅和失物信息',
    NULL, 'active', 'campus_location', '围绕青山湖校区图书馆的即时信息',
    'c1000000-0000-4000-8000-000000000007',
    'qingshanhu-library', 'facility', NULL, NULL, NULL, TRUE, 10
),
(
    'c1000000-0000-4000-8000-000000000107',
    'c0000000-0000-0000-0000-000000000001',
    'group', '东湖校区图书馆', '东湖校区图书馆自习、借阅和失物信息',
    NULL, 'active', 'campus_location', '围绕东湖校区图书馆的即时信息',
    'c1000000-0000-4000-8000-000000000008',
    'donghu-library', 'facility', NULL, NULL, NULL, TRUE, 10
),
(
    'c1000000-0000-4000-8000-000000000108',
    'c0000000-0000-0000-0000-000000000001',
    'group', '先骕园', '先骕园公共地点聊天室', NULL, 'active',
    'campus_location', '围绕先骕园当下的人和事交流',
    'c1000000-0000-4000-8000-000000000002',
    'xian-su-yuan', 'facility', NULL, NULL, NULL, FALSE, 10
)
ON CONFLICT (id) DO UPDATE SET
    campus_id = EXCLUDED.campus_id,
    kind = EXCLUDED.kind,
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    owner_id = NULL,
    status = EXCLUDED.status,
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

-- Expose exactly the four requested first-level location directories. Stable
-- chat-space IDs and historical messages remain intact; only directory
-- parents change. Assignments below are manual and remain non-routable.
UPDATE chat_spaces
   SET parent_space_id = NULL,
       location_sort_order = CASE id
           WHEN 'c1000000-0000-4000-8000-000000000002'::UUID THEN 10
           WHEN 'c1000000-0000-4000-8000-000000000003'::UUID THEN 20
           WHEN 'c1000000-0000-4000-8000-000000000007'::UUID THEN 30
           WHEN 'c1000000-0000-4000-8000-000000000008'::UUID THEN 40
       END,
       updated_at = NOW()
 WHERE id IN (
     'c1000000-0000-4000-8000-000000000002',
     'c1000000-0000-4000-8000-000000000003',
     'c1000000-0000-4000-8000-000000000007',
     'c1000000-0000-4000-8000-000000000008'
 )
   AND origin = 'campus_location';

UPDATE chat_spaces
   SET parent_space_id = 'c1000000-0000-4000-8000-000000000002',
       updated_at = NOW()
 WHERE id IN (
     'c1000000-0000-4000-8000-000000000005', -- 润溪湖畔
     'c1000000-0000-4000-8000-000000000101', -- 北门
     'c1000000-0000-4000-8000-000000000103'  -- 图书馆
 )
   AND origin = 'campus_location';

UPDATE chat_spaces
   SET parent_space_id = 'c1000000-0000-4000-8000-000000000003',
       updated_at = NOW()
 WHERE id IN (
     'c1000000-0000-4000-8000-000000000004', -- 修贤广场
     'c1000000-0000-4000-8000-000000000006', -- 天健操场
     'c1000000-0000-4000-8000-000000000102', -- 南门
     'c1000000-0000-4000-8000-000000000104', -- 体育馆
     'c1000000-0000-4000-8000-000000000105'  -- 校医院
 )
   AND origin = 'campus_location';

-- Preserve any active rooms created under the retired combined Qianhu root.
-- Known facilities are assigned above; unknown legacy leaves and location
-- child rooms go under the north directory so they remain discoverable while
-- their exact sub-area is reviewed by an operator.
UPDATE chat_spaces
   SET parent_space_id = 'c1000000-0000-4000-8000-000000000002',
       updated_at = NOW()
 WHERE parent_space_id = 'c1000000-0000-4000-8000-000000000001'
   AND status = 'active';

UPDATE chat_spaces
   SET status = 'archived',
       allows_child_spaces = FALSE,
       updated_at = NOW()
 WHERE id = 'c1000000-0000-4000-8000-000000000001'
   AND origin = 'campus_location';

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM chat_spaces
         WHERE parent_space_id = 'c1000000-0000-4000-8000-000000000001'
           AND status = 'active'
    ) THEN
        RAISE EXCEPTION
            'active location space still points at the archived Qianhu root';
    END IF;
END;
$$;

CREATE TABLE campus_map_nodes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campus_id UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    parent_node_id UUID,
    route_anchor_node_id UUID,
    chat_space_id UUID,
    slug TEXT NOT NULL,
    name_zh TEXT NOT NULL,
    name_en TEXT,
    node_kind TEXT NOT NULL,
    map_key TEXT,
    logical_x NUMERIC(8, 3),
    logical_y NUMERIC(8, 3),
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    floor_code TEXT,
    verification_status TEXT NOT NULL DEFAULT 'unverified',
    data_source TEXT NOT NULL DEFAULT 'operator',
    source_reference TEXT,
    is_routable BOOLEAN NOT NULL DEFAULT FALSE,
    status TEXT NOT NULL DEFAULT 'active',
    sort_order INTEGER NOT NULL DEFAULT 0,
    metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT campus_map_nodes_id_campus_unique UNIQUE (id, campus_id),
    CONSTRAINT campus_map_nodes_slug_nonempty
        CHECK (slug = lower(btrim(slug)) AND slug ~ '^[a-z0-9][a-z0-9-]*$'),
    CONSTRAINT campus_map_nodes_name_nonempty
        CHECK (char_length(btrim(name_zh)) BETWEEN 1 AND 120),
    CONSTRAINT campus_map_nodes_kind_check CHECK (node_kind IN (
        'directory', 'area', 'landmark', 'building', 'entrance',
        'floor', 'classroom', 'junction', 'transit_stop'
    )),
    CONSTRAINT campus_map_nodes_verification_check CHECK (
        verification_status IN (
            'unverified', 'manual', 'operator_verified', 'official'
        )
    ),
    CONSTRAINT campus_map_nodes_source_check CHECK (
        data_source IN (
            'user_request', 'map_photo', 'public_map', 'operator', 'official'
        )
    ),
    CONSTRAINT campus_map_nodes_status_check
        CHECK (status IN ('active', 'inactive', 'temporarily_closed')),
    CONSTRAINT campus_map_nodes_logical_pair_check CHECK (
        (logical_x IS NULL AND logical_y IS NULL)
        OR (
            logical_x IS NOT NULL
            AND logical_y IS NOT NULL
            AND logical_x BETWEEN 0 AND 1000
            AND logical_y BETWEEN 0 AND 1000
            AND map_key IS NOT NULL
        )
    ),
    CONSTRAINT campus_map_nodes_coordinate_pair_check CHECK (
        (latitude IS NULL AND longitude IS NULL)
        OR (
            latitude IS NOT NULL
            AND longitude IS NOT NULL
            AND latitude BETWEEN -90 AND 90
            AND longitude BETWEEN -180 AND 180
        )
    ),
    CONSTRAINT campus_map_nodes_routable_check CHECK (
        is_routable = FALSE
        OR (
            verification_status IN ('operator_verified', 'official')
            AND status = 'active'
            AND (
                (logical_x IS NOT NULL AND logical_y IS NOT NULL)
                OR (latitude IS NOT NULL AND longitude IS NOT NULL)
            )
        )
    ),
    CONSTRAINT campus_map_nodes_metadata_object_check
        CHECK (jsonb_typeof(metadata) = 'object'),
    CONSTRAINT campus_map_nodes_parent_fk
        FOREIGN KEY (parent_node_id, campus_id)
        REFERENCES campus_map_nodes(id, campus_id) ON DELETE RESTRICT,
    CONSTRAINT campus_map_nodes_route_anchor_fk
        FOREIGN KEY (route_anchor_node_id, campus_id)
        REFERENCES campus_map_nodes(id, campus_id) ON DELETE RESTRICT,
    CONSTRAINT campus_map_nodes_chat_space_fk
        FOREIGN KEY (chat_space_id, campus_id)
        REFERENCES chat_spaces(id, campus_id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX campus_map_nodes_slug_unique
    ON campus_map_nodes(campus_id, slug);
CREATE UNIQUE INDEX campus_map_nodes_chat_space_unique
    ON campus_map_nodes(chat_space_id)
    WHERE chat_space_id IS NOT NULL;
CREATE INDEX idx_campus_map_nodes_tree
    ON campus_map_nodes(campus_id, parent_node_id, status, sort_order, name_zh);
CREATE INDEX idx_campus_map_nodes_route_anchor
    ON campus_map_nodes(campus_id, route_anchor_node_id)
    WHERE route_anchor_node_id IS NOT NULL;

CREATE OR REPLACE FUNCTION validate_campus_map_node_parent()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    creates_cycle BOOLEAN;
BEGIN
    IF NEW.parent_node_id IS NULL THEN
        RETURN NEW;
    END IF;
    IF NEW.parent_node_id = NEW.id THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'campus map node cannot be its own parent';
    END IF;

    WITH RECURSIVE ancestors AS (
        SELECT node.id, node.parent_node_id
          FROM campus_map_nodes node
         WHERE node.id = NEW.parent_node_id
           AND node.campus_id = NEW.campus_id
        UNION ALL
        SELECT node.id, node.parent_node_id
          FROM campus_map_nodes node
          JOIN ancestors parent ON node.id = parent.parent_node_id
         WHERE node.campus_id = NEW.campus_id
    )
    SELECT EXISTS(SELECT 1 FROM ancestors WHERE id = NEW.id)
      INTO creates_cycle;

    IF creates_cycle THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'campus map node hierarchy cannot contain a cycle';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER campus_map_nodes_parent_validate
    BEFORE INSERT OR UPDATE OF parent_node_id, campus_id ON campus_map_nodes
    FOR EACH ROW EXECUTE FUNCTION validate_campus_map_node_parent();

CREATE TABLE campus_map_edges (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campus_id UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    slug TEXT NOT NULL,
    from_node_id UUID NOT NULL,
    to_node_id UUID NOT NULL,
    edge_kind TEXT NOT NULL DEFAULT 'walkway',
    direction TEXT NOT NULL DEFAULT 'both',
    distance_meters NUMERIC(10, 2),
    estimated_seconds INTEGER,
    accessibility TEXT NOT NULL DEFAULT 'unknown',
    verification_status TEXT NOT NULL DEFAULT 'unverified',
    is_routable BOOLEAN NOT NULL DEFAULT FALSE,
    status TEXT NOT NULL DEFAULT 'active',
    metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT campus_map_edges_slug_nonempty
        CHECK (slug = lower(btrim(slug)) AND slug ~ '^[a-z0-9][a-z0-9-]*$'),
    CONSTRAINT campus_map_edges_distinct_endpoints
        CHECK (from_node_id <> to_node_id),
    CONSTRAINT campus_map_edges_kind_check CHECK (edge_kind IN (
        'walkway', 'crosswalk', 'door', 'stairs', 'ramp', 'elevator',
        'shuttle'
    )),
    CONSTRAINT campus_map_edges_direction_check
        CHECK (direction IN ('both', 'forward')),
    CONSTRAINT campus_map_edges_distance_check
        CHECK (distance_meters IS NULL OR distance_meters > 0),
    CONSTRAINT campus_map_edges_duration_check
        CHECK (estimated_seconds IS NULL OR estimated_seconds > 0),
    CONSTRAINT campus_map_edges_accessibility_check
        CHECK (accessibility IN ('unknown', 'accessible', 'not_accessible')),
    CONSTRAINT campus_map_edges_verification_check CHECK (
        verification_status IN (
            'unverified', 'manual', 'operator_verified', 'official'
        )
    ),
    CONSTRAINT campus_map_edges_status_check
        CHECK (status IN ('active', 'inactive', 'temporarily_closed')),
    CONSTRAINT campus_map_edges_routable_check CHECK (
        is_routable = FALSE
        OR (
            verification_status IN ('operator_verified', 'official')
            AND status = 'active'
            AND distance_meters IS NOT NULL
        )
    ),
    CONSTRAINT campus_map_edges_metadata_object_check
        CHECK (jsonb_typeof(metadata) = 'object'),
    CONSTRAINT campus_map_edges_from_fk
        FOREIGN KEY (from_node_id, campus_id)
        REFERENCES campus_map_nodes(id, campus_id) ON DELETE CASCADE,
    CONSTRAINT campus_map_edges_to_fk
        FOREIGN KEY (to_node_id, campus_id)
        REFERENCES campus_map_nodes(id, campus_id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX campus_map_edges_slug_unique
    ON campus_map_edges(campus_id, slug);
CREATE INDEX idx_campus_map_edges_from
    ON campus_map_edges(campus_id, from_node_id, status, is_routable);
CREATE INDEX idx_campus_map_edges_to
    ON campus_map_edges(campus_id, to_node_id, status, is_routable);

CREATE TABLE campus_map_aliases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campus_id UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    node_id UUID NOT NULL,
    alias TEXT NOT NULL,
    locale TEXT,
    alias_kind TEXT NOT NULL DEFAULT 'alternate',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT campus_map_aliases_text_nonempty
        CHECK (char_length(btrim(alias)) BETWEEN 1 AND 120),
    CONSTRAINT campus_map_aliases_kind_check
        CHECK (alias_kind IN ('alternate', 'legacy', 'abbreviation')),
    CONSTRAINT campus_map_aliases_node_fk
        FOREIGN KEY (node_id, campus_id)
        REFERENCES campus_map_nodes(id, campus_id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX campus_map_aliases_name_unique
    ON campus_map_aliases(campus_id, lower(btrim(alias)));
CREATE INDEX idx_campus_map_aliases_node
    ON campus_map_aliases(node_id);

CREATE TABLE campus_map_classrooms (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campus_id UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    building_node_id UUID NOT NULL,
    destination_node_id UUID,
    route_anchor_node_id UUID,
    room_code TEXT NOT NULL,
    display_name_zh TEXT NOT NULL,
    display_name_en TEXT,
    floor_code TEXT NOT NULL,
    verification_status TEXT NOT NULL DEFAULT 'unverified',
    status TEXT NOT NULL DEFAULT 'active',
    sort_order INTEGER NOT NULL DEFAULT 0,
    metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT campus_map_classrooms_code_nonempty
        CHECK (char_length(btrim(room_code)) BETWEEN 1 AND 40),
    CONSTRAINT campus_map_classrooms_name_nonempty
        CHECK (char_length(btrim(display_name_zh)) BETWEEN 1 AND 120),
    CONSTRAINT campus_map_classrooms_floor_nonempty
        CHECK (char_length(btrim(floor_code)) BETWEEN 1 AND 24),
    CONSTRAINT campus_map_classrooms_verification_check CHECK (
        verification_status IN (
            'unverified', 'manual', 'operator_verified', 'official'
        )
    ),
    CONSTRAINT campus_map_classrooms_status_check
        CHECK (status IN ('active', 'inactive', 'temporarily_closed')),
    CONSTRAINT campus_map_classrooms_metadata_object_check
        CHECK (jsonb_typeof(metadata) = 'object'),
    CONSTRAINT campus_map_classrooms_building_fk
        FOREIGN KEY (building_node_id, campus_id)
        REFERENCES campus_map_nodes(id, campus_id) ON DELETE CASCADE,
    CONSTRAINT campus_map_classrooms_destination_fk
        FOREIGN KEY (destination_node_id, campus_id)
        REFERENCES campus_map_nodes(id, campus_id) ON DELETE RESTRICT,
    CONSTRAINT campus_map_classrooms_route_anchor_fk
        FOREIGN KEY (route_anchor_node_id, campus_id)
        REFERENCES campus_map_nodes(id, campus_id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX campus_map_classrooms_code_unique
    ON campus_map_classrooms(
        campus_id, building_node_id, floor_code, lower(btrim(room_code))
    );
CREATE INDEX idx_campus_map_classrooms_lookup
    ON campus_map_classrooms(campus_id, lower(btrim(room_code)), status);

CREATE OR REPLACE FUNCTION validate_campus_map_classroom_nodes()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    building_kind TEXT;
    destination_kind TEXT;
BEGIN
    SELECT node_kind INTO building_kind
      FROM campus_map_nodes
     WHERE id = NEW.building_node_id AND campus_id = NEW.campus_id;
    IF building_kind IS DISTINCT FROM 'building' THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'classroom building_node_id must reference a building';
    END IF;

    IF NEW.destination_node_id IS NOT NULL THEN
        SELECT node_kind INTO destination_kind
          FROM campus_map_nodes
         WHERE id = NEW.destination_node_id AND campus_id = NEW.campus_id;
        IF destination_kind IS DISTINCT FROM 'classroom' THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'classroom destination_node_id must reference a classroom node';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER campus_map_classrooms_nodes_validate
    BEFORE INSERT OR UPDATE OF building_node_id, destination_node_id, campus_id
    ON campus_map_classrooms
    FOR EACH ROW EXECUTE FUNCTION validate_campus_map_classroom_nodes();

-- Four active first-level directories. Qianhu is intentionally split into
-- north and south; the old combined root remains below as an inactive resolver.
INSERT INTO campus_map_nodes (
    id, campus_id, parent_node_id, chat_space_id, slug, name_zh, name_en,
    node_kind, verification_status, data_source, is_routable, status,
    sort_order, metadata
) VALUES
(
    'd1000000-0000-4000-8000-000000000001',
    'c0000000-0000-0000-0000-000000000001', NULL,
    'c1000000-0000-4000-8000-000000000002',
    'qianhu-north', '前湖北院', 'Qianhu North Campus', 'directory',
    'manual', 'user_request', FALSE, 'active', 10,
    '{"directory_level":1,"coordinate_status":"pending_verification"}'::JSONB
),
(
    'd1000000-0000-4000-8000-000000000002',
    'c0000000-0000-0000-0000-000000000001', NULL,
    'c1000000-0000-4000-8000-000000000003',
    'qianhu-south', '前湖南院', 'Qianhu South Campus', 'directory',
    'manual', 'user_request', FALSE, 'active', 20,
    '{"directory_level":1,"coordinate_status":"pending_verification"}'::JSONB
),
(
    'd1000000-0000-4000-8000-000000000003',
    'c0000000-0000-0000-0000-000000000001', NULL,
    'c1000000-0000-4000-8000-000000000007',
    'qingshanhu-campus', '青山湖校区', 'Qingshanhu Campus', 'directory',
    'manual', 'user_request', FALSE, 'active', 30,
    '{"directory_level":1,"coordinate_status":"pending_verification"}'::JSONB
),
(
    'd1000000-0000-4000-8000-000000000004',
    'c0000000-0000-0000-0000-000000000001', NULL,
    'c1000000-0000-4000-8000-000000000008',
    'donghu-campus', '东湖校区', 'Donghu Campus', 'directory',
    'manual', 'user_request', FALSE, 'active', 40,
    '{"directory_level":1,"coordinate_status":"pending_verification"}'::JSONB
),
(
    'd1000000-0000-4000-8000-000000000000',
    'c0000000-0000-0000-0000-000000000001', NULL,
    'c1000000-0000-4000-8000-000000000001',
    'qianhu-campus', '前湖校区（旧目录）', 'Qianhu Campus (legacy)',
    'directory', 'manual', 'operator', FALSE, 'inactive', 900,
    '{"directory_level":1,"replacement_slugs":["qianhu-north","qianhu-south"]}'::JSONB
)
ON CONFLICT (campus_id, slug) DO UPDATE SET
    parent_node_id = EXCLUDED.parent_node_id,
    chat_space_id = EXCLUDED.chat_space_id,
    name_zh = EXCLUDED.name_zh,
    name_en = EXCLUDED.name_en,
    node_kind = EXCLUDED.node_kind,
    verification_status = EXCLUDED.verification_status,
    data_source = EXCLUDED.data_source,
    is_routable = EXCLUDED.is_routable,
    status = EXCLUDED.status,
    sort_order = EXCLUDED.sort_order,
    metadata = EXCLUDED.metadata,
    updated_at = NOW();

-- Directory-only Qianhu places. Their precise building/entrance positions and
-- route edges are deliberately absent until checked against an authoritative
-- source. The traditional spelling remains a search alias only.
INSERT INTO campus_map_nodes (
    id, campus_id, parent_node_id, chat_space_id, slug, name_zh, name_en,
    node_kind, verification_status, data_source, source_reference,
    is_routable, status, sort_order, metadata
) VALUES
(
    'd1000000-0000-4000-8000-000000000101',
    'c0000000-0000-0000-0000-000000000001',
    'd1000000-0000-4000-8000-000000000001',
    'c1000000-0000-4000-8000-000000000108',
    'xian-su-yuan', '先骕园', NULL, 'area', 'unverified', 'user_request',
    'User supplied the photographed Qianhu campus map on 2026-08-16',
    FALSE, 'active', 10,
    '{"coordinate_status":"pending_verification","parent_assignment":"provisional"}'::JSONB
),
(
    'd1000000-0000-4000-8000-000000000102',
    'c0000000-0000-0000-0000-000000000001',
    'd1000000-0000-4000-8000-000000000001',
    'c1000000-0000-4000-8000-000000000101',
    'qianhu-north-gate', '前湖校区北门', 'Qianhu North Gate',
    'entrance', 'manual', 'operator', NULL, FALSE, 'active', 20,
    '{"coordinate_status":"pending_verification"}'::JSONB
),
(
    'd1000000-0000-4000-8000-000000000103',
    'c0000000-0000-0000-0000-000000000001',
    'd1000000-0000-4000-8000-000000000002',
    'c1000000-0000-4000-8000-000000000102',
    'qianhu-south-gate', '前湖校区南门', 'Qianhu South Gate',
    'entrance', 'manual', 'operator', NULL, FALSE, 'active', 10,
    '{"coordinate_status":"pending_verification"}'::JSONB
),
(
    'd1000000-0000-4000-8000-000000000104',
    'c0000000-0000-0000-0000-000000000001',
    'd1000000-0000-4000-8000-000000000001',
    'c1000000-0000-4000-8000-000000000005',
    'runxi-lake', '润溪湖畔', 'Runxi Lake', 'landmark',
    'manual', 'operator', 'migrations/0084_campus_location_spaces.sql',
    FALSE, 'active', 30,
    '{"coordinate_status":"pending_verification","parent_assignment":"provisional"}'::JSONB
),
(
    'd1000000-0000-4000-8000-000000000105',
    'c0000000-0000-0000-0000-000000000001',
    'd1000000-0000-4000-8000-000000000001',
    'c1000000-0000-4000-8000-000000000103',
    'qianhu-library', '前湖校区图书馆', 'Qianhu Library', 'building',
    'manual', 'operator', 'migrations/0085_expand_ncu_location_directory.sql',
    FALSE, 'active', 40,
    '{"coordinate_status":"pending_verification","parent_assignment":"provisional"}'::JSONB
),
(
    'd1000000-0000-4000-8000-000000000201',
    'c0000000-0000-0000-0000-000000000001',
    'd1000000-0000-4000-8000-000000000002',
    'c1000000-0000-4000-8000-000000000004',
    'xiuxian-square', '修贤广场', 'Xiuxian Square', 'landmark',
    'manual', 'operator', 'migrations/0084_campus_location_spaces.sql',
    FALSE, 'active', 20,
    '{"coordinate_status":"pending_verification","parent_assignment":"provisional"}'::JSONB
),
(
    'd1000000-0000-4000-8000-000000000202',
    'c0000000-0000-0000-0000-000000000001',
    'd1000000-0000-4000-8000-000000000002',
    'c1000000-0000-4000-8000-000000000006',
    'tianjian-field', '天健操场', 'Tianjian Field', 'landmark',
    'manual', 'operator', 'migrations/0084_campus_location_spaces.sql',
    FALSE, 'active', 30,
    '{"coordinate_status":"pending_verification","parent_assignment":"provisional"}'::JSONB
),
(
    'd1000000-0000-4000-8000-000000000203',
    'c0000000-0000-0000-0000-000000000001',
    'd1000000-0000-4000-8000-000000000002',
    'c1000000-0000-4000-8000-000000000104',
    'qianhu-gymnasium', '前湖校区体育馆', 'Qianhu Gymnasium', 'building',
    'manual', 'operator', 'migrations/0085_expand_ncu_location_directory.sql',
    FALSE, 'active', 40,
    '{"coordinate_status":"pending_verification","parent_assignment":"provisional"}'::JSONB
),
(
    'd1000000-0000-4000-8000-000000000204',
    'c0000000-0000-0000-0000-000000000001',
    'd1000000-0000-4000-8000-000000000002',
    'c1000000-0000-4000-8000-000000000105',
    'qianhu-clinic', '前湖校区校医院', 'Qianhu Campus Clinic', 'building',
    'manual', 'operator', 'migrations/0085_expand_ncu_location_directory.sql',
    FALSE, 'active', 50,
    '{"coordinate_status":"pending_verification","parent_assignment":"provisional"}'::JSONB
),
(
    'd1000000-0000-4000-8000-000000000301',
    'c0000000-0000-0000-0000-000000000001',
    'd1000000-0000-4000-8000-000000000003',
    'c1000000-0000-4000-8000-000000000106',
    'qingshanhu-library', '青山湖校区图书馆', 'Qingshanhu Library',
    'building', 'manual', 'operator',
    'migrations/0085_expand_ncu_location_directory.sql', FALSE, 'active', 10,
    '{"coordinate_status":"pending_verification"}'::JSONB
),
(
    'd1000000-0000-4000-8000-000000000401',
    'c0000000-0000-0000-0000-000000000001',
    'd1000000-0000-4000-8000-000000000004',
    'c1000000-0000-4000-8000-000000000107',
    'donghu-library', '东湖校区图书馆', 'Donghu Library', 'building',
    'manual', 'operator',
    'migrations/0085_expand_ncu_location_directory.sql', FALSE, 'active', 10,
    '{"coordinate_status":"pending_verification"}'::JSONB
)
ON CONFLICT (campus_id, slug) DO UPDATE SET
    parent_node_id = EXCLUDED.parent_node_id,
    chat_space_id = EXCLUDED.chat_space_id,
    name_zh = EXCLUDED.name_zh,
    name_en = EXCLUDED.name_en,
    node_kind = EXCLUDED.node_kind,
    verification_status = EXCLUDED.verification_status,
    data_source = EXCLUDED.data_source,
    source_reference = EXCLUDED.source_reference,
    is_routable = EXCLUDED.is_routable,
    status = EXCLUDED.status,
    sort_order = EXCLUDED.sort_order,
    metadata = EXCLUDED.metadata,
    updated_at = NOW();

INSERT INTO campus_map_aliases (
    id, campus_id, node_id, alias, locale, alias_kind
) VALUES
(
    'd2000000-0000-4000-8000-000000000001',
    'c0000000-0000-0000-0000-000000000001',
    'd1000000-0000-4000-8000-000000000101',
    '先驌园', 'zh-Hant', 'legacy'
),
(
    'd2000000-0000-4000-8000-000000000002',
    'c0000000-0000-0000-0000-000000000001',
    'd1000000-0000-4000-8000-000000000000',
    '前湖校区', 'zh-Hans', 'legacy'
)
ON CONFLICT (campus_id, (lower(btrim(alias)))) DO UPDATE SET
    node_id = EXCLUDED.node_id,
    locale = EXCLUDED.locale,
    alias_kind = EXCLUDED.alias_kind;

-- Defense-in-depth tenant isolation follows the existing fail-open GUC model:
-- repositories remain the primary boundary, while an armed app.campus_id
-- context makes cross-campus reads and writes impossible for every role.
DO $$
DECLARE
    table_name TEXT;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'campus_map_nodes', 'campus_map_edges',
        'campus_map_aliases', 'campus_map_classrooms'
    ] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', table_name);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', table_name);
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %I', table_name);
        EXECUTE format(
            'CREATE POLICY tenant_isolation ON %I
             USING (
                 current_setting(''app.campus_id'', true) IS NULL
                 OR current_setting(''app.campus_id'', true) = ''''
                 OR campus_id = current_setting(''app.campus_id'', true)::uuid
             )
             WITH CHECK (
                 current_setting(''app.campus_id'', true) IS NULL
                 OR current_setting(''app.campus_id'', true) = ''''
                 OR campus_id = current_setting(''app.campus_id'', true)::uuid
             )',
            table_name
        );
    END LOOP;
END;
$$;

-- Migration-time invariants make accidental fifth roots or a broken legacy
-- resolver fail before the application can expose an ambiguous directory.
DO $$
DECLARE
    active_chat_roots INTEGER;
    active_map_roots INTEGER;
BEGIN
    SELECT COUNT(*) INTO active_chat_roots
      FROM chat_spaces
     WHERE campus_id = 'c0000000-0000-0000-0000-000000000001'
       AND origin = 'campus_location'
       AND status = 'active'
       AND parent_space_id IS NULL;
    IF active_chat_roots <> 4 THEN
        RAISE EXCEPTION
            'expected four active NCU location chat roots, found %',
            active_chat_roots;
    END IF;

    SELECT COUNT(*) INTO active_map_roots
      FROM campus_map_nodes
     WHERE campus_id = 'c0000000-0000-0000-0000-000000000001'
       AND status = 'active'
       AND parent_node_id IS NULL;
    IF active_map_roots <> 4 THEN
        RAISE EXCEPTION
            'expected four active NCU map roots, found %', active_map_roots;
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM campus_map_nodes node
          JOIN chat_spaces space ON space.id = node.chat_space_id
         WHERE node.slug = 'xian-su-yuan'
           AND node.name_zh = '先骕园'
           AND space.location_slug = 'xian-su-yuan'
           AND space.status = 'active'
    ) THEN
        RAISE EXCEPTION '先骕园 map-to-chat binding is missing';
    END IF;
END;
$$;

COMMENT ON TABLE campus_map_nodes IS
    'Public campus directory and navigation anchors; never stores user observations.';
COMMENT ON COLUMN campus_map_nodes.logical_x IS
    'Normalized 0..1000 coordinate within map_key, not a geographic coordinate.';
COMMENT ON COLUMN campus_map_nodes.verification_status IS
    'Data provenance gate. Unverified/manual rows must not power automatic routes.';
COMMENT ON TABLE campus_map_edges IS
    'Directed or bidirectional route segments. Only verified, active, routable edges may be searched.';
COMMENT ON TABLE campus_map_classrooms IS
    'Curated classroom directory. Empty until a building/floor source is verified.';
