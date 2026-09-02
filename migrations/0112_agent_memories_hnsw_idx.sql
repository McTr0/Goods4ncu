-- Migration 0112: HNSW vector index on agent_memories embedding
--
-- Speeds up episodic and preference memory semantic similarity retrieval (pgvector cosine distance <=>)
-- for the AI companion runtime.
CREATE INDEX IF NOT EXISTS idx_agent_memories_embedding ON agent_memories USING hnsw(embedding vector_cosine_ops);
