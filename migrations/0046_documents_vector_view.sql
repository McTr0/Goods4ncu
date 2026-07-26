-- A UUID-typed view over `documents`, for the rig vector store.
--
-- The bug this fixes. `rig-postgres` hard-codes `id: Uuid` in the row structs
-- it decodes search results into, while `documents.id` is TEXT because it
-- mirrors `inventory.id`, which is TEXT. Retrieval therefore fails with
-- "Rust type `uuid::Uuid` is not compatible with SQL type `TEXT`" — but only
-- once at least one row exists to decode. An empty table returns no rows, so
-- nothing ever fails, which is why this sat unnoticed: dynamic_context had
-- silently never worked, and looked exactly like "the assistant found no
-- relevant listings".
--
-- Why a view rather than changing the column. `documents.id` is joined to
-- `inventory.id` in recommendations and wanted-matching. Retyping it to UUID
-- would require casts at every one of those joins and a data migration on the
-- primary key's mirror, to satisfy one library's schema assumption. The view
-- confines the assumption to the one consumer that holds it.
--
-- Why the OFFSET 0. It is an optimisation fence. Without it the planner may
-- hoist `id::uuid` above the regex filter and evaluate the cast on rows the
-- filter would have excluded, so a single malformed id would fail every
-- retrieval — intermittently, depending on the plan chosen. Ids are generated
-- as UUIDs so the filter should never exclude anything; it is here so that a
-- bad row degrades retrieval by one document instead of taking the assistant
-- down.

CREATE OR REPLACE VIEW documents_vector AS
SELECT
    id::uuid AS id,
    document,
    embedded_text,
    embedding
FROM (
    SELECT id, document, embedded_text, embedding
    FROM documents
    WHERE id ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    OFFSET 0
) AS uuid_shaped;

COMMENT ON VIEW documents_vector IS
    'UUID-typed projection of documents for rig-postgres, which decodes result ids as Uuid. Read-only; writes go to documents directly.';
