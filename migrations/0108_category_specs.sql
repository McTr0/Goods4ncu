-- Taxonomy v4: Category = invariant + schema + state machine.
--
-- Four new categories whose posts carry their own structured payloads and
-- explicit lifecycles; the offer→listing invariant becomes a DB constraint
-- (NOT VALID: legacy rows exempt, new writes enforced); tag applicability
-- returns so pickers only offer meaningful tags per category.

-- 1. New categories ------------------------------------------------------
INSERT INTO post_categories (key, label_zh, label_en, kind, sort_order) VALUES
    ('recruit', '召集', 'Recruit', 'discussion', 6),
    ('help',    '求助', 'Help',    'discussion', 7),
    ('lost',    '寻物', 'Lost',    'discussion', 8),
    ('found',   '招领', 'Found',   'discussion', 9)
ON CONFLICT (key) DO UPDATE SET kind = EXCLUDED.kind, sort_order = EXCLUDED.sort_order;

-- 2. Explicit lifecycle (user-action states only) ------------------------
ALTER TABLE posts ADD COLUMN IF NOT EXISTS lifecycle TEXT;

-- 3. Offer requires an attached listing ---------------------------------
ALTER TABLE posts DROP CONSTRAINT IF EXISTS chk_offer_requires_listing;
ALTER TABLE posts ADD CONSTRAINT chk_offer_requires_listing
    CHECK (category <> 'offer' OR listing_id IS NOT NULL)
    NOT VALID;

-- 4. Tag applicability ---------------------------------------------------
ALTER TABLE post_tag_catalog ADD COLUMN IF NOT EXISTS allowed_categories TEXT[] NOT NULL DEFAULT '{}';

UPDATE post_tag_catalog SET allowed_categories = CASE key
    WHEN 'question'        THEN '{discussion,help}'
    WHEN 'share'           THEN '{discussion,event,recruit}'
    WHEN 'negotiable'      THEN '{offer}'
    WHEN 'pickupOnly'      THEN '{offer,wanted}'
    WHEN 'sellFast'        THEN '{offer}'
    WHEN 'budgetFlexible'  THEN '{wanted,help}'
    WHEN 'topPrice'        THEN '{wanted}'
    -- urgent / longterm: everything with a deadline or open-ended ask;
    -- event derives timing from starts_at instead.
    WHEN 'urgent'          THEN '{offer,wanted,recruit,help,lost,found,discussion}'
    WHEN 'longterm'        THEN '{offer,wanted,help,found,discussion}'
    -- location tags stay weak-semantics: not for event/lost/found where the
    -- structured place field is canonical.
    WHEN 'qianhuNorth'     THEN '{offer,wanted,recruit,help,discussion,announcement}'
    WHEN 'qianhuSouth'     THEN '{offer,wanted,recruit,help,discussion,announcement}'
    WHEN 'qingshanhu'      THEN '{offer,wanted,recruit,help,discussion,announcement}'
    WHEN 'donghu'          THEN '{offer,wanted,recruit,help,discussion,announcement}'
    ELSE allowed_categories
END;

-- 5. Retire tags superseded by categories / derived pills ----------------
DELETE FROM post_tag_catalog WHERE key IN ('free', 'found', 'lost', 'help');
UPDATE posts SET tags = tags - 'free' - 'found' - 'lost' - 'help';
