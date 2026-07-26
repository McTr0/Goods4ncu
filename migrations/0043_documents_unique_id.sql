-- `documents.id` had NOT NULL and a plain btree index but no unique constraint,
-- so the `ON CONFLICT (id) DO UPDATE` upsert in every provider's EmbedUpdater
-- failed with "there is no unique or exclusion constraint matching the ON
-- CONFLICT specification". The embedding write path could therefore never
-- succeed: a listing created through the agent (or any path that re-embeds)
-- rolled back its whole transaction.
--
-- Tests never caught it because they inject a NoopEmbedUpdater; it surfaced
-- only when a real provider ran against a real database.
--
-- `id` is one row per listing by construction, so a unique constraint is the
-- correct shape and also makes the existing lookup index redundant.
DELETE FROM documents d
WHERE d.ctid <> (SELECT min(x.ctid) FROM documents x WHERE x.id = d.id);

ALTER TABLE documents
    DROP CONSTRAINT IF EXISTS documents_id_key;
ALTER TABLE documents
    ADD CONSTRAINT documents_id_key UNIQUE (id);

DROP INDEX IF EXISTS documents_listing_id_idx;
