-- Taxonomy v3: grouped tags, per-category structured attributes, and the
-- two-tier permission model (member/operator, owner/member).
--
-- Decisions baked in here:
--   * No category restrictions on tags (low coupling); groups handle
--     exclusivity instead (location / ttl), one pick max per group.
--   * 送 = offer + `free` tag; 失物招领 = found/lost tags on offer/wanted.
--   * Per-post structured fields live in a single validated JSONB column.
--   * Campus roles collapse to member|operator; space roles to
--     owner|member (+ banned as a moderation state).

-- 1. Categories: announcement + event -----------------------------------
INSERT INTO post_categories (key, label_zh, label_en, kind, sort_order) VALUES
    ('event',        '活动', 'Event',        'discussion', 4),
    ('announcement', '公告', 'Announcement', 'discussion', 5)
ON CONFLICT (key) DO UPDATE SET
    kind = EXCLUDED.kind,
    sort_order = EXCLUDED.sort_order;

-- 2. Tags: grouping, new entries, drop category scoping -----------------
ALTER TABLE post_tag_catalog ADD COLUMN IF NOT EXISTS group_key TEXT;

DELETE FROM post_tag_catalog WHERE key = 'event';

UPDATE post_tag_catalog SET label_en = 'Urgent help (paid)'
WHERE key = 'help';

UPDATE post_tag_catalog SET group_key = 'ttl'
WHERE key IN ('urgent', 'longterm');

INSERT INTO post_tag_catalog (key, label_zh, label_en, categories, group_key) VALUES
    ('free',         '免费送',   'Free',          '{}', NULL),
    ('found',        '招领',     'Found item',    '{}', NULL),
    ('lost',         '寻物',     'Lost item',     '{}', NULL),
    ('qianhuNorth',  '前湖北院', 'Qianhu North',  '{}', 'location'),
    ('qianhuSouth',  '前湖南院', 'Qianhu South',  '{}', 'location'),
    ('qingshanhu',   '青山湖',   'Qingshanhu',    '{}', 'location'),
    ('donghu',       '东湖',     'Donghu',        '{}', 'location')
ON CONFLICT (key) DO UPDATE SET
    label_zh = EXCLUDED.label_zh,
    label_en = EXCLUDED.label_en,
    group_key = EXCLUDED.group_key;

ALTER TABLE post_tag_catalog DROP COLUMN categories;

-- 3. Structured attributes ---------------------------------------------
ALTER TABLE posts ADD COLUMN IF NOT EXISTS attributes JSONB NOT NULL DEFAULT '{}'
    CHECK (jsonb_typeof(attributes) = 'object');

-- 4. Two-tier roles -----------------------------------------------------
UPDATE campus_memberships SET role = 'operator' WHERE role = 'admin';
ALTER TABLE campus_memberships DROP CONSTRAINT campus_memberships_role_check;
ALTER TABLE campus_memberships
    ADD CONSTRAINT campus_memberships_role_check
    CHECK (role IN ('member', 'operator'));

UPDATE chat_space_members SET role = 'member' WHERE role = 'admin';
ALTER TABLE chat_space_members DROP CONSTRAINT chat_space_members_role_check;
ALTER TABLE chat_space_members
    ADD CONSTRAINT chat_space_members_role_check
    CHECK (role IN ('owner', 'member', 'banned'));
