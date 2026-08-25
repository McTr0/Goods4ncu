-- Short category labels for pills (商品出/商品收 → 出/收).

UPDATE post_categories SET label_zh = '出', label_en = 'Offer'
WHERE key = 'offer';
UPDATE post_categories SET label_zh = '收', label_en = 'Wanted'
WHERE key = 'wanted';
UPDATE post_categories SET label_zh = '讨论', label_en = 'Discussion'
WHERE key = 'discussion';
