-- Tag catalog slimming: drop shipping/condition tags (same-campus trade
-- makes 包邮 meaningless and condition belongs on the listing, not tags).

DELETE FROM post_tag_catalog WHERE key IN (
    'freeShipping', 'brandNew', 'likeNew', 'usedOk'
);

UPDATE posts SET tags = tags - 'freeShipping' - 'brandNew' - 'likeNew' - 'usedOk';
