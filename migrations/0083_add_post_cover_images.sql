-- Optional cover images for discussion posts.
--
-- Listing posts continue to source their cover from inventory. Discussion
-- covers use the same moderation lifecycle and are exposed only after an
-- approved verdict.

ALTER TABLE posts
    ADD COLUMN IF NOT EXISTS image_url TEXT,
    ADD COLUMN IF NOT EXISTS images_moderation_status TEXT NOT NULL DEFAULT 'pending';

ALTER TABLE posts
    DROP CONSTRAINT IF EXISTS posts_images_moderation_status_check;

ALTER TABLE posts
    ADD CONSTRAINT posts_images_moderation_status_check
    CHECK (images_moderation_status IN ('pending', 'approved', 'rejected', 'failed'));

CREATE INDEX IF NOT EXISTS idx_posts_image_url
    ON posts(image_url)
    WHERE image_url IS NOT NULL;
