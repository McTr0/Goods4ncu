-- Campus group discussions are topic-first. Announcement channels are folded
-- into ordinary groups so every space follows the same conversation model.
UPDATE chat_spaces
SET kind = 'group', updated_at = NOW()
WHERE kind = 'channel';

ALTER TABLE chat_spaces
    DROP CONSTRAINT IF EXISTS chat_spaces_kind_check;

ALTER TABLE chat_spaces
    ADD CONSTRAINT chat_spaces_kind_check CHECK (kind = 'group') NOT VALID;

ALTER TABLE chat_spaces
    VALIDATE CONSTRAINT chat_spaces_kind_check;

COMMENT ON TABLE chat_space_messages IS
    'Topic-first group discussion. Root rows are topics; replies point directly to a root topic in the same space.';
