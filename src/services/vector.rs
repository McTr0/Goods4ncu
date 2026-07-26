//! Vector retrieval plumbing shared by the LLM providers.

/// Relation the rig vector store reads from.
///
/// Not `documents` itself: `rig-postgres` decodes result ids as `Uuid`, while
/// `documents.id` is TEXT because it mirrors `inventory.id`. Reading the base
/// table fails to decode the moment a single row exists — and returns cleanly
/// while the table is empty, which is exactly how that mismatch stayed hidden.
/// Migration 0046 defines this view and explains the choice.
pub const DOCUMENTS_VECTOR_VIEW: &str = "documents_vector";
