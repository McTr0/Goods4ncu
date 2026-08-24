-- Unified posts: one structure for 出(offer) / 收(wanted) / 讨论(discussion).
--
-- Replaces the legacy 0081/0083/0092 shape. Key changes versus the old
-- posts table:
--   * `category` IS the kind: CHECK IN ('offer','wanted','discussion').
--     post_type / post_kind are gone.
--   * Listings are references, not projections. `listing_id` is an optional
--     pointer into inventory (SET NULL on listing delete); no sync trigger,
--     no UNIQUE, no mirrored rows.
--   * `space_id` scopes a post to one chat space (group); NULL = campus-wide.
--   * Errand (跑腿互助) is a catalog tag on offer/wanted posts; its payload
--     lives in `errand_metadata` and the resolution lifecycle only applies
--     to posts carrying that tag.

CREATE TABLE posts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campus_id UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    author_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    category TEXT NOT NULL
        CHECK (category IN ('offer', 'wanted', 'discussion')),
    -- Optional reference to a marketplace item. Offers/wants usually create
    -- their inventory row in the same transaction; discussions may attach any
    -- existing listing. The listing may outlive the post.
    listing_id TEXT REFERENCES inventory(id) ON DELETE SET NULL,
    space_id UUID REFERENCES chat_spaces(id) ON DELETE CASCADE,
    title TEXT NOT NULL CHECK (char_length(btrim(title)) BETWEEN 1 AND 300),
    body TEXT NOT NULL CHECK (char_length(body) <= 50000),
    tags JSONB NOT NULL DEFAULT '[]'::jsonb
        CHECK (jsonb_typeof(tags) = 'array' AND jsonb_array_length(tags) <= 5),
    image_url TEXT,
    images_moderation_status TEXT NOT NULL DEFAULT 'pending'
        CHECK (images_moderation_status IN ('pending', 'approved', 'rejected', 'failed')),
    errand_metadata JSONB NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(errand_metadata) = 'object'),
    resolution_status TEXT NOT NULL DEFAULT 'open'
        CHECK (resolution_status IN ('open', 'resolved', 'closed')),
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'locked', 'archived', 'deleted')),
    reply_count INTEGER NOT NULL DEFAULT 0 CHECK (reply_count >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_activity_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (id, campus_id),
    CONSTRAINT post_space_campus_fk
        FOREIGN KEY (space_id, campus_id) REFERENCES chat_spaces(id, campus_id)
            ON DELETE CASCADE,
    CONSTRAINT posts_errand_payload_shape CHECK (
        errand_metadata = '{}'::jsonb OR tags @> '"errand"'::jsonb
    ),
    CONSTRAINT posts_resolution_shape CHECK (
        tags @> '"errand"'::jsonb OR resolution_status = 'open'
    )
);

CREATE INDEX idx_posts_campus_activity
    ON posts(campus_id, last_activity_at DESC, id DESC)
    WHERE status IN ('active', 'locked');
CREATE INDEX idx_posts_campus_category_activity
    ON posts(campus_id, category, last_activity_at DESC, id DESC)
    WHERE status IN ('active', 'locked');
CREATE INDEX idx_posts_space_activity
    ON posts(space_id, last_activity_at DESC, id DESC)
    WHERE status IN ('active', 'locked') AND space_id IS NOT NULL;
CREATE INDEX idx_posts_author_created
    ON posts(author_id, created_at DESC);
CREATE INDEX idx_posts_listing_ref
    ON posts(listing_id)
    WHERE listing_id IS NOT NULL;

CREATE TABLE post_replies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campus_id UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    post_id UUID NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    author_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    body TEXT NOT NULL CHECK (char_length(btrim(body)) BETWEEN 1 AND 20000),
    reply_to_id UUID,
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'deleted')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (id, post_id, campus_id),
    CONSTRAINT post_replies_post_campus_fk
        FOREIGN KEY (post_id, campus_id) REFERENCES posts(id, campus_id)
            ON DELETE CASCADE,
    CONSTRAINT post_replies_parent_fk
        FOREIGN KEY (reply_to_id) REFERENCES post_replies(id) ON DELETE SET NULL
);

CREATE INDEX idx_post_replies_post_created
    ON post_replies(post_id, created_at ASC, id ASC)
    WHERE status = 'active';
CREATE INDEX idx_post_replies_author_created
    ON post_replies(author_id, created_at DESC);

CREATE OR REPLACE FUNCTION validate_post_reply_parent()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.reply_to_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM post_replies parent
        WHERE parent.id = NEW.reply_to_id
          AND parent.post_id = NEW.post_id
          AND parent.campus_id = NEW.campus_id
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'reply parent must belong to the same post and campus';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS post_replies_parent_validate ON post_replies;
CREATE TRIGGER post_replies_parent_validate
    BEFORE INSERT OR UPDATE OF reply_to_id, post_id, campus_id ON post_replies
    FOR EACH ROW EXECUTE FUNCTION validate_post_reply_parent();

ALTER TABLE posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE posts FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON posts;
CREATE POLICY tenant_isolation ON posts
    USING (
        current_setting('app.campus_id', true) IS NULL
        OR current_setting('app.campus_id', true) = ''
        OR campus_id = current_setting('app.campus_id', true)::uuid
    )
    WITH CHECK (
        current_setting('app.campus_id', true) IS NULL
        OR current_setting('app.campus_id', true) = ''
        OR campus_id = current_setting('app.campus_id', true)::uuid
    );

ALTER TABLE post_replies ENABLE ROW LEVEL SECURITY;
ALTER TABLE post_replies FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON post_replies;
CREATE POLICY tenant_isolation ON post_replies
    USING (
        current_setting('app.campus_id', true) IS NULL
        OR current_setting('app.campus_id', true) = ''
        OR campus_id = current_setting('app.campus_id', true)::uuid
    )
    WITH CHECK (
        current_setting('app.campus_id', true) IS NULL
        OR current_setting('app.campus_id', true) = ''
        OR campus_id = current_setting('app.campus_id', true)::uuid
    );

CREATE OR REPLACE FUNCTION refresh_post_reply_count()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    target_post UUID;
BEGIN
    target_post := CASE WHEN TG_OP = 'DELETE' THEN OLD.post_id ELSE NEW.post_id END;
    UPDATE posts
    SET reply_count = (
            SELECT COUNT(*)::integer FROM post_replies
            WHERE post_id = target_post AND status = 'active'
        ),
        last_activity_at = CASE
            WHEN TG_OP = 'INSERT' AND NEW.status = 'active'
                THEN GREATEST(last_activity_at, NEW.created_at)
            ELSE last_activity_at
        END,
        updated_at = NOW()
    WHERE id = target_post;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

DROP TRIGGER IF EXISTS post_replies_count_refresh ON post_replies;
CREATE TRIGGER post_replies_count_refresh
    AFTER INSERT OR UPDATE OF status OR DELETE ON post_replies
    FOR EACH ROW EXECUTE FUNCTION refresh_post_reply_count();

-- From deleted 0092: keep the trimmed intents kind set (help intents were
-- development-only and are intentionally discarded).
DELETE FROM intents WHERE kind = 'help';

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'intents'::regclass AND conname = 'intents_kind_check'
    ) THEN
        ALTER TABLE intents DROP CONSTRAINT intents_kind_check;
    END IF;
END $$;

ALTER TABLE intents
    ADD CONSTRAINT intents_kind_check
    CHECK (kind IN ('goods_offer', 'goods_seek', 'companion', 'activity'));

COMMENT ON TABLE posts IS
    'Unified campus/group posts. category IS the kind (offer/wanted/discussion); listings are optional references; space_id scopes group visibility.';
