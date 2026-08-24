-- Data cleanup for taxonomy v3: posts created before the `event` tag was
-- promoted to a category may still carry it; strip it everywhere.

UPDATE posts SET tags = tags - 'event'
WHERE tags @> '"event"'::jsonb;

DELETE FROM post_tag_catalog WHERE key = 'event';
