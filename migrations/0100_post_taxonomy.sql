-- Predefined post tag catalog.
--
-- Tags are curated, never user-invented. `categories` lists the post
-- categories a tag may be used on; an empty array means the tag is valid
-- everywhere. The special `errand` tag unlocks the structured errand payload
-- and resolution lifecycle on offer/wanted posts.

CREATE TABLE post_tag_catalog (
    key TEXT PRIMARY KEY,
    label_zh TEXT NOT NULL,
    label_en TEXT NOT NULL,
    categories TEXT[] NOT NULL DEFAULT '{}'
        CHECK (array_position(categories, 'offer') IS NOT NULL
            OR array_position(categories, 'wanted') IS NOT NULL
            OR array_position(categories, 'discussion') IS NOT NULL
            OR array_length(categories, 1) = 0)
);

INSERT INTO post_tag_catalog (key, label_zh, label_en, categories) VALUES
    -- global
    ('question',   '提问',     'Question',      '{}'),
    ('share',      '分享',     'Share',         '{}'),
    ('help',       '求助',     'Help',          '{}'),
    ('urgent',     '急',       'Urgent',        '{}'),
    ('longterm',   '长期有效', 'Long-term',     '{}'),
    ('event',      '活动',     'Event',         '{}'),
    -- offer suggestions
    ('negotiable',   '可议价',   'Negotiable',   '{offer}'),
    ('freeShipping', '包邮',     'Free shipping', '{offer}'),
    ('pickupOnly',   '仅自提',   'Pickup only',  '{offer}'),
    ('brandNew',     '全新',     'Brand new',    '{offer}'),
    ('likeNew',      '九成新',   'Like new',     '{offer}'),
    ('sellFast',     '急出',     'Must go',      '{offer}'),
    -- wanted suggestions
    ('budgetFlexible', '预算可议', 'Flexible budget', '{wanted}'),
    ('topPrice',       '高价收',   'Top price',       '{wanted}'),
    ('usedOk',         '接受二手', 'Used ok',         '{wanted}'),
    -- errand: special tag, offer/wanted only
    ('errand',       '跑腿互助', 'Errand',           '{offer,wanted}');

CREATE INDEX idx_post_tag_catalog_category ON post_tag_catalog USING gin (categories);
