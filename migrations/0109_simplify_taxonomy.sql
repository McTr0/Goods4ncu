-- Taxonomy v5: strip to 8 categories + 6 tags (location × 4 + ttl × 2).
-- All structured attribute payloads, lifecycle state machines, and
-- descriptive tags beyond location/ttl are removed. Camphor stays.

-- 1. Categories -----------------------------------------------------------
INSERT INTO post_categories (key, label_zh, label_en, kind, sort_order) VALUES
    ('share',    '分享', 'Share',    'discussion', 4),
    ('question', '提问', 'Question', 'discussion', 5),
    ('team_up',  '组队', 'Team Up',  'discussion', 8)
ON CONFLICT (key) DO UPDATE SET kind = EXCLUDED.kind, sort_order = EXCLUDED.sort_order;

UPDATE posts SET category = CASE category
    WHEN 'event' THEN 'discussion'
    WHEN 'help'  THEN 'wanted'
    WHEN 'lost'  THEN 'discussion'
    WHEN 'found' THEN 'offer'
    ELSE category
END;

DELETE FROM post_categories WHERE key IN ('event', 'help', 'lost', 'found');

-- 2. Drop structured payloads + lifecycle ---------------------------------
ALTER TABLE posts DROP COLUMN IF EXISTS attributes;
ALTER TABLE posts DROP COLUMN IF EXISTS lifecycle;

-- 3. Tags: keep only location + ttl groups --------------------------------
DELETE FROM post_tag_catalog
WHERE group_key IS NULL;

UPDATE posts SET tags = (
    SELECT COALESCE(jsonb_agg(t), '[]'::jsonb)
    FROM jsonb_array_elements_text(tags) t
    WHERE t IN (SELECT key FROM post_tag_catalog)
);
