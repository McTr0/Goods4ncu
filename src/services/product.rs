use anyhow::Result;
use sqlx::PgPool;

#[derive(Clone)]
#[allow(dead_code)]
pub struct ProductService {
    db: PgPool,
}

impl ProductService {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    /// Mark a listing as sold (DISABLED - called from disabled DealReached event)
    #[allow(dead_code)]
    pub async fn mark_as_sold(&self, listing_id: &str) -> Result<()> {
        tracing::info!(listing_id, "Marking listing as sold");
        sqlx::query(
            "UPDATE inventory SET status = 'sold'
             WHERE id = $1 AND status = 'active'
               AND NOT listing_has_active_restriction(id)",
        )
        .bind(listing_id)
        .execute(&self.db)
        .await?;

        // Delete vector embeddings so sold items don't appear in RAG results.
        // pgvector stores documents in the same 'documents' table as relational data.
        sqlx::query("DELETE FROM documents WHERE id = $1")
            .bind(listing_id)
            .execute(&self.db)
            .await
            .ok(); // Non-fatal if vector cleanup fails

        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Unit tests (no DB required)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod unit_tests {
    use super::*;

    #[test]
    fn test_product_service_clone() {
        // ProductService is Clone, verify it compiles
        fn assert_clone<T: Clone>() {}
        assert_clone::<ProductService>();
    }
}
