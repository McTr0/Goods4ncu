//! The contract the rig vector store depends on.
//!
//! `rig-postgres` decodes search-result ids as `Uuid`, while `documents.id` is
//! TEXT because it mirrors `inventory.id`. Pointing the store at the base table
//! fails with a decode error — but *only once a row exists*. An empty table
//! returns no rows, so nothing decodes and nothing fails.
//!
//! That is precisely why this went unnoticed: retrieval had never worked in
//! this deployment, and a broken retrieval is indistinguishable from an honest
//! "no relevant listings found". It only surfaced when a change caused the
//! first document to be written, at which point every assistant turn started
//! returning 500.
//!
//! The gap was a test that exercised retrieval *with data present*. These fill
//! it, at the level the mismatch actually lives: the shape of the relation the
//! store reads.

use goods4ncu::services::vector::DOCUMENTS_VECTOR_VIEW;
use goods4ncu::test_infra::with_test_pool;
use uuid::Uuid;

async fn seed_document(pool: &sqlx::PgPool, id: &str) {
    // 768 dimensions, matching the configured embedding width.
    let embedding: Vec<f64> = vec![0.01; 768];
    sqlx::query(
        "INSERT INTO documents (id, document, embedded_text, embedding)
         VALUES ($1, $2::jsonb, $3, $4)
         ON CONFLICT (id) DO NOTHING",
    )
    .bind(id)
    .bind(serde_json::json!({ "id": id, "content": "台灯 九成新" }))
    .bind("台灯 九成新")
    .bind(&embedding)
    .execute(pool)
    .await
    .expect("insert document");
}

#[tokio::test]
async fn retrieval_view_presents_ids_as_uuid() {
    // The decode that fails against the base table must succeed here. Reading
    // the id as `Uuid` is exactly what rig does, so this test fails in the same
    // way the assistant did.
    with_test_pool(|pool| async move {
        let listing_id = Uuid::new_v4().to_string();
        seed_document(&pool, &listing_id).await;

        let decoded: Uuid = sqlx::query_scalar(&format!(
            "SELECT id FROM {DOCUMENTS_VECTOR_VIEW} WHERE id = $1::uuid"
        ))
        .bind(&listing_id)
        .fetch_one(&pool)
        .await
        .expect("the view must decode ids as Uuid");
        assert_eq!(decoded.to_string(), listing_id);

        // And the round trip is exact: rig hands the id back as a string, and
        // it has to match the listing id it came from, or retrieved context
        // would point at nothing.
        assert_eq!(
            decoded.to_string(),
            listing_id,
            "the id rig returns must address the same listing"
        );
    })
    .await;
}

#[tokio::test]
async fn base_table_still_rejects_the_uuid_decode() {
    // Pins the reason the view exists. If `documents.id` is ever retyped to
    // UUID this test fails, which is the signal to delete the view rather than
    // leave it as unexplained indirection.
    with_test_pool(|pool| async move {
        let listing_id = Uuid::new_v4().to_string();
        seed_document(&pool, &listing_id).await;

        let attempt: Result<Uuid, _> = sqlx::query_scalar("SELECT id FROM documents WHERE id = $1")
            .bind(&listing_id)
            .fetch_one(&pool)
            .await;
        assert!(
            attempt.is_err(),
            "documents.id is TEXT; decoding it as Uuid should fail — if this \
             now succeeds, the column was retyped and documents_vector is \
             redundant"
        );
    })
    .await;
}

#[tokio::test]
async fn a_malformed_id_costs_one_document_not_the_whole_index() {
    // The failure mode this guards is severe out of proportion to its cause:
    // without the filter (and its optimisation fence) one bad id makes every
    // retrieval throw, taking the assistant down entirely.
    with_test_pool(|pool| async move {
        let good_id = Uuid::new_v4().to_string();
        seed_document(&pool, &good_id).await;
        seed_document(&pool, "not-a-uuid-at-all").await;

        let ids: Vec<Uuid> = sqlx::query_scalar(&format!("SELECT id FROM {DOCUMENTS_VECTOR_VIEW}"))
            .fetch_all(&pool)
            .await
            .expect("a malformed id must not break the whole view");

        assert!(ids.iter().any(|id| id.to_string() == good_id));
        assert_eq!(ids.len(), 1, "only the well-formed document participates");
    })
    .await;
}

#[tokio::test]
async fn the_view_carries_every_column_the_store_selects() {
    // rig's query selects id, document and embedding, and orders by distance.
    // A view missing any of them fails at query time rather than compile time,
    // so the shape is asserted here.
    with_test_pool(|pool| async move {
        let listing_id = Uuid::new_v4().to_string();
        seed_document(&pool, &listing_id).await;

        let probe: Vec<f64> = vec![0.01; 768];
        let row: (Uuid, serde_json::Value, f64) = sqlx::query_as(&format!(
            "SELECT id, document, embedding <=> $1 AS distance
             FROM {DOCUMENTS_VECTOR_VIEW}
             ORDER BY distance
             LIMIT 1"
        ))
        .bind(pgvector::Vector::from(
            probe.iter().map(|&x| x as f32).collect::<Vec<f32>>(),
        ))
        .fetch_one(&pool)
        .await
        .expect("the view must support the store's query shape");

        assert_eq!(row.0.to_string(), listing_id);
        assert_eq!(row.1["content"], "台灯 九成新");
    })
    .await;
}
