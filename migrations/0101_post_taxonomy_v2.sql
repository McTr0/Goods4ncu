-- Post taxonomy v2: category catalog replaces the hardcoded CHECK, and the
-- errand experiment is fully retired (columns, catalog row, ranking boosts).
--
-- Services are not a special post kind anymore: anything one offers is a
-- normal goods listing + post, distinguished purely by tags.

-- 1. Category catalog ----------------------------------------------------
CREATE TABLE IF NOT EXISTS post_categories (
    key TEXT PRIMARY KEY,
    label_zh TEXT NOT NULL,
    label_en TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('goods', 'discussion')),
    sort_order INT NOT NULL DEFAULT 0,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO post_categories (key, label_zh, label_en, kind, sort_order) VALUES
    ('offer',      '商品出', 'Offer',      'goods',      1),
    ('wanted',     '商品收', 'Wanted',     'goods',      2),
    ('discussion', '话题讨论', 'Discussion', 'discussion', 3)
ON CONFLICT (key) DO UPDATE SET
    label_zh = EXCLUDED.label_zh,
    label_en = EXCLUDED.label_en,
    kind = EXCLUDED.kind,
    sort_order = EXCLUDED.sort_order;

ALTER TABLE posts DROP CONSTRAINT IF EXISTS posts_category_check;
ALTER TABLE posts DROP CONSTRAINT IF EXISTS posts_category_post_categories_key_fk;
ALTER TABLE posts
    ADD CONSTRAINT posts_category_post_categories_key_fk
    FOREIGN KEY (category) REFERENCES post_categories (key);

-- 2. Retire the errand experiment ---------------------------------------
DELETE FROM post_tag_catalog WHERE key = 'errand';

ALTER TABLE posts DROP COLUMN IF EXISTS errand_metadata;
ALTER TABLE posts DROP COLUMN IF EXISTS resolution_status;
