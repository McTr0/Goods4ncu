//! Integration tests for ChatService.
//! Run with `--test-threads=1` for proper serial execution.

use goods4ncu::test_infra::with_test_pool;
use sqlx::Row;

#[tokio::test]
async fn test_log_message() {
    with_test_pool(|pool| async move {
        sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
            .bind("user-1").bind("user1")
            .execute(&pool).await.unwrap();
        sqlx::query(
            "INSERT INTO inventory (id, title, category, brand, condition_score, suggested_price_cny, defects, owner_id) \
             VALUES ($1, 'Item', 'misc', 'Brand', 8, 10000, '[]', $2)")
            .bind("listing-1").bind("user-1")
            .execute(&pool).await.unwrap();
        sqlx::query(
            "INSERT INTO chat_messages (conversation_id, listing_id, sender, is_agent, content) \
             VALUES ($1, $2, $3, $4, $5)")
            .bind("conv-1").bind("listing-1").bind("user-1").bind(false).bind("Hello!")
            .execute(&pool).await.unwrap();

        let row = sqlx::query("SELECT sender, content FROM chat_messages WHERE listing_id = 'listing-1'")
            .fetch_one(&pool).await.unwrap();
        assert_eq!(Row::get::<String, _>(&row, "sender"), "user-1");
        assert_eq!(Row::get::<String, _>(&row, "content"), "Hello!");
    }).await;
}

#[tokio::test]
async fn test_get_conversation_history() {
    with_test_pool(|pool| async move {
        sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
            .bind("user-1").bind("user1")
            .execute(&pool).await.unwrap();
        sqlx::query(
            "INSERT INTO inventory (id, title, category, brand, condition_score, suggested_price_cny, defects, owner_id) \
             VALUES ($1, 'Item', 'misc', 'Brand', 8, 10000, '[]', $2)")
            .bind("listing-1").bind("user-1")
            .execute(&pool).await.unwrap();

        for (content, is_agent) in [("First message", false), ("Agent reply", true), ("Third message", false)] {
            sqlx::query(
                "INSERT INTO chat_messages (conversation_id, listing_id, sender, is_agent, content) \
                 VALUES ('conv-test', 'listing-1', 'user-1', $1, $2)")
                .bind(is_agent).bind(content)
                .execute(&pool).await.unwrap();
        }

        let rows = sqlx::query(
            "SELECT sender, content, is_agent FROM chat_messages \
             WHERE conversation_id = 'conv-test' ORDER BY id ASC LIMIT 10")
            .fetch_all(&pool).await.unwrap();

        assert_eq!(rows.len(), 3);
        assert_eq!(Row::get::<String, _>(&rows[0], "content"), "First message");
        assert!(!Row::get::<bool, _>(&rows[0], "is_agent"));
        assert_eq!(Row::get::<String, _>(&rows[1], "content"), "Agent reply");
        assert!(Row::get::<bool, _>(&rows[1], "is_agent"));
        assert_eq!(Row::get::<String, _>(&rows[2], "content"), "Third message");
        assert!(!Row::get::<bool, _>(&rows[2], "is_agent"));
    }).await;
}

#[tokio::test]
async fn test_get_conversation_history_empty() {
    with_test_pool(|pool| async move {
        sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
            .bind("user-1")
            .bind("user1")
            .execute(&pool)
            .await
            .unwrap();

        let rows =
            sqlx::query("SELECT * FROM chat_messages WHERE conversation_id = 'nonexistent-conv'")
                .fetch_all(&pool)
                .await
                .unwrap();
        assert!(rows.is_empty());
    })
    .await;
}

#[tokio::test]
async fn test_list_conversations() {
    with_test_pool(|pool| async move {
        for (id, username) in [("user-1", "user1"), ("user-2", "user2")] {
            sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
                .bind(id).bind(username)
                .execute(&pool).await.unwrap();
        }
        sqlx::query(
            "INSERT INTO inventory (id, title, category, brand, condition_score, suggested_price_cny, defects, owner_id) \
             VALUES ($1, 'Item', 'misc', 'Brand', 8, 10000, '[]', $2)")
            .bind("listing-1").bind("user-1")
            .execute(&pool).await.unwrap();

        for (conv_id, sender, msg) in [
            ("conv-1", "user-1", "Message in conv 1"),
            ("conv-2", "user-1", "Message in conv 2"),
            ("conv-3", "user-2", "User-2 message"),
        ] {
            sqlx::query(
                "INSERT INTO chat_messages (conversation_id, listing_id, sender, is_agent, content) \
                 VALUES ($1, 'listing-1', $2, false, $3)")
                .bind(conv_id).bind(sender).bind(msg)
                .execute(&pool).await.unwrap();
        }

        let rows = sqlx::query(
            "SELECT DISTINCT ON (conversation_id) conversation_id \
             FROM chat_messages WHERE sender = 'user-1' OR receiver = 'user-1' \
             ORDER BY conversation_id")
            .fetch_all(&pool).await.unwrap();

        assert_eq!(rows.len(), 2);
    }).await;
}

#[tokio::test]
async fn test_list_conversations_with_listing_title() {
    with_test_pool(|pool| async move {
        sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
            .bind("user-1").bind("user1")
            .execute(&pool).await.unwrap();
        sqlx::query(
            "INSERT INTO inventory (id, title, category, brand, condition_score, suggested_price_cny, defects, owner_id) \
             VALUES ($1, 'Item', 'misc', 'Brand', 8, 10000, '[]', $2)")
            .bind("listing-1").bind("user-1")
            .execute(&pool).await.unwrap();
        sqlx::query(
            "INSERT INTO chat_messages (conversation_id, listing_id, sender, is_agent, content) \
             VALUES ('conv-1', 'listing-1', 'user-1', false, 'Hello')")
            .execute(&pool).await.unwrap();

        let rows = sqlx::query(
            "SELECT cm.conversation_id, i.title as listing_title \
             FROM chat_messages cm \
             LEFT JOIN inventory i ON cm.listing_id = i.id \
             WHERE cm.sender = 'user-1' LIMIT 1")
            .fetch_all(&pool).await.unwrap();

        assert_eq!(rows.len(), 1);
        assert_eq!(Row::get::<String, _>(&rows[0], "listing_title"), "Item");
    }).await;
}
