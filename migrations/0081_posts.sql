-- General posts (topics) and replies.
--
-- A marketplace listing is a first-class post subtype. `inventory` remains
-- the source of truth for product-specific facts (price, condition, status),
-- while this table gives every listing the same topic/reply surface as a
-- discussion. The trigger below keeps the shared title/body/category and
-- lifecycle projection in sync, including rows written by legacy workers.

CREATE TABLE IF NOT EXISTS posts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campus_id UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    author_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    post_type TEXT NOT NULL DEFAULT 'discussion'
        CHECK (post_type IN ('discussion', 'listing')),
    -- NULL for discussions; one and only one post represents a listing.
    listing_id TEXT UNIQUE REFERENCES inventory(id) ON DELETE CASCADE,
    category TEXT NOT NULL DEFAULT 'general',
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    tags JSONB NOT NULL DEFAULT '[]'::jsonb
        CHECK (jsonb_typeof(tags) = 'array' AND jsonb_array_length(tags) <= 5),
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'locked', 'archived', 'deleted')),
    reply_count INTEGER NOT NULL DEFAULT 0 CHECK (reply_count >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_activity_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (id, campus_id),
    CONSTRAINT posts_listing_shape CHECK (
        (post_type = 'discussion' AND listing_id IS NULL)
        OR (post_type = 'listing' AND listing_id IS NOT NULL)
    ),
    -- Listing writes predate this domain and historically had no equivalent
    -- character limits. Keep those writes compatible; PostService enforces
    -- the limits for new/edit discussion requests.
    CONSTRAINT posts_discussion_text_limits CHECK (
        post_type = 'listing'
        OR (
            char_length(btrim(category)) BETWEEN 1 AND 80
            AND char_length(btrim(title)) BETWEEN 1 AND 300
            AND char_length(body) <= 50000
        )
    )
);

CREATE INDEX IF NOT EXISTS idx_posts_campus_activity
    ON posts(campus_id, last_activity_at DESC, id DESC)
    WHERE status IN ('active', 'locked');
CREATE INDEX IF NOT EXISTS idx_posts_campus_type_activity
    ON posts(campus_id, post_type, last_activity_at DESC, id DESC)
    WHERE status IN ('active', 'locked');
CREATE INDEX IF NOT EXISTS idx_posts_campus_category_activity
    ON posts(campus_id, category, last_activity_at DESC, id DESC)
    WHERE status IN ('active', 'locked');
CREATE INDEX IF NOT EXISTS idx_posts_author_created
    ON posts(author_id, created_at DESC);

CREATE TABLE IF NOT EXISTS post_replies (
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

CREATE INDEX IF NOT EXISTS idx_post_replies_post_created
    ON post_replies(post_id, created_at ASC, id ASC)
    WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_post_replies_author_created
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

-- All inventory writers (including older agents and test fixtures) get a
-- corresponding listing post. Existing rows are backfilled before the trigger
-- is installed, so every listing has a stable reverse lookup immediately.
INSERT INTO posts (
    campus_id, author_id, post_type, listing_id, category, title, body, status,
    created_at, updated_at, last_activity_at
)
SELECT i.campus_id, i.owner_id, 'listing', i.id, i.category, i.title,
       COALESCE(i.description, ''),
       CASE
           WHEN i.status = 'active' THEN 'active'
           WHEN i.status = 'deleted' THEN 'deleted'
           ELSE 'archived'
       END,
       COALESCE(i.created_at, NOW()), COALESCE(i.updated_at, i.created_at, NOW()),
       COALESCE(i.updated_at, i.created_at, NOW())
FROM inventory i
WHERE NOT EXISTS (SELECT 1 FROM posts p WHERE p.listing_id = i.id);

CREATE OR REPLACE FUNCTION sync_listing_post()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO posts (
        campus_id, author_id, post_type, listing_id, category, title, body,
        status, created_at, updated_at, last_activity_at
    )
    VALUES (
        NEW.campus_id, NEW.owner_id, 'listing', NEW.id, NEW.category, NEW.title,
        COALESCE(NEW.description, ''),
        CASE
            WHEN NEW.status = 'active' THEN 'active'
            WHEN NEW.status = 'deleted' THEN 'deleted'
            ELSE 'archived'
        END,
        COALESCE(NEW.created_at, NOW()), COALESCE(NEW.updated_at, NOW()),
        COALESCE(NEW.updated_at, NOW())
    )
    ON CONFLICT (listing_id) DO UPDATE SET
        campus_id = EXCLUDED.campus_id,
        author_id = EXCLUDED.author_id,
        category = EXCLUDED.category,
        title = EXCLUDED.title,
        body = EXCLUDED.body,
        status = EXCLUDED.status,
        updated_at = EXCLUDED.updated_at;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS inventory_listing_post_sync ON inventory;
CREATE TRIGGER inventory_listing_post_sync
    AFTER INSERT OR UPDATE OF campus_id, owner_id, category, title, description, status
    ON inventory
    FOR EACH ROW EXECUTE FUNCTION sync_listing_post();

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

COMMENT ON TABLE posts IS
    'Campus-scoped topics. Listing posts are projections of inventory rows and use listing_id as their canonical association.';
COMMENT ON COLUMN posts.listing_id IS
    'Non-null only for post_type=listing; inventory remains authoritative for product-specific facts.';
COMMENT ON TABLE post_replies IS
    'Threaded replies to posts; reply_to_id is optional and must reference a reply in the same post and campus.';
