-- Fold campus help requests into the unified post stream.
-- Existing help intents are intentionally discarded in this development
-- migration; goods, companion, and activity intents remain intact.

ALTER TABLE posts
    ADD COLUMN IF NOT EXISTS post_kind TEXT NOT NULL DEFAULT 'discussion',
    ADD COLUMN IF NOT EXISTS mutual_aid_metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS resolution_status TEXT NOT NULL DEFAULT 'open';

ALTER TABLE posts
    DROP CONSTRAINT IF EXISTS posts_post_kind_check,
    DROP CONSTRAINT IF EXISTS posts_resolution_status_check,
    DROP CONSTRAINT IF EXISTS posts_mutual_aid_metadata_check;

ALTER TABLE posts
    ADD CONSTRAINT posts_post_kind_check
        CHECK (post_kind IN ('discussion', 'mutual_aid')),
    ADD CONSTRAINT posts_resolution_status_check
        CHECK (resolution_status IN ('open', 'resolved', 'closed')),
    ADD CONSTRAINT posts_mutual_aid_metadata_check
        CHECK (jsonb_typeof(mutual_aid_metadata) = 'object');

CREATE INDEX IF NOT EXISTS idx_posts_campus_kind_activity
    ON posts(campus_id, post_kind, resolution_status, last_activity_at DESC, id DESC)
    WHERE status IN ('active', 'locked');

DO $$
BEGIN
    DELETE FROM intents WHERE kind = 'help';
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'intents'::regclass AND conname = 'intents_kind_check'
    ) THEN
        ALTER TABLE intents DROP CONSTRAINT intents_kind_check;
    END IF;
    ALTER TABLE intents
        ADD CONSTRAINT intents_kind_check
        CHECK (kind IN ('goods_offer', 'goods_seek', 'companion', 'activity'));
EXCEPTION WHEN duplicate_object THEN
    NULL;
END;
$$;
