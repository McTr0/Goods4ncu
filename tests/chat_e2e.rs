//! End-to-end tests for user-to-user chat conversations.
//!
//! These tests exercise the public HTTP API for the TCP-style realtime
//! conversation lifecycle, message sending, editing, and explicit acknowledgement.
//!
//! Run with: `cargo test --test chat_e2e`
//! Enforce required mode: `CHAT_E2E_REQUIRED=true cargo test --test chat_e2e`
//!
//! Requires a running backend plus `TEST_BASE_URL`. The suite is optional by
//! default so normal `cargo test` can run without starting the app server.

use axum::http::{HeaderMap, StatusCode};
use goods4ncu::test_infra::db_safety;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use std::time::Duration;
use uuid::Uuid;

struct TestUser {
    user_id: String,
    token: String,
}

async fn register_user(
    client: &Client,
    base_url: &str,
    username: &str,
    password: &str,
) -> anyhow::Result<AuthResponse> {
    let response = client
        .post(format!("{}/api/auth/register", base_url))
        .json(&serde_json::json!({
            "username": username,
            "password": password
        }))
        .send()
        .await?;

    assert_eq!(
        response.status(),
        StatusCode::CREATED,
        "Registration failed: {:?}",
        response.text().await?
    );
    Ok(response.json::<AuthResponse>().await?)
}

async fn login_user(
    client: &Client,
    base_url: &str,
    username: &str,
    password: &str,
) -> anyhow::Result<AuthResponse> {
    let response = client
        .post(format!("{}/api/auth/login", base_url))
        .json(&serde_json::json!({
            "username": username,
            "password": password
        }))
        .send()
        .await?;

    assert_eq!(
        response.status(),
        StatusCode::OK,
        "Login failed: {:?}",
        response.text().await?
    );
    Ok(response.json::<AuthResponse>().await?)
}

async fn create_test_user(
    client: &Client,
    base_url: &str,
    prefix: &str,
) -> anyhow::Result<TestUser> {
    let unique_id = Uuid::new_v4().to_string();
    let unique_suffix = unique_id.split('-').next().unwrap();
    let username = format!("{}_{}", prefix, unique_suffix);
    let password = "testpass123".to_string();

    let _ = register_user(client, base_url, &username, &password).await?;
    let login_response = login_user(client, base_url, &username, &password).await?;

    let preferences = client
        .put(format!("{}/api/chat/connection-preferences", base_url))
        .headers(auth_headers(&login_response.token))
        .json(&serde_json::json!({
            "allow_strangers": true,
            "busy_until": null
        }))
        .send()
        .await?;
    assert_eq!(preferences.status(), StatusCode::OK);

    Ok(TestUser {
        user_id: login_response.user_id,
        token: login_response.token,
    })
}

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
struct AuthResponse {
    token: String,
    refresh_token: String,
    user_id: String,
    username: String,
    message: String,
}

#[derive(Debug, Serialize)]
struct CreateConversationBody {
    client_request_id: String,
    recipient_id: String,
    listing_id: Option<String>,
    mode: String,
    subject: Option<String>,
    content: String,
}

#[derive(Debug, Deserialize)]
struct CreateConversationResponse {
    conversation: ConversationEntry,
    created: bool,
    mutual_open: bool,
}

#[derive(Debug, Serialize)]
struct RespondConversationBody {
    decision: String,
}

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
struct ConversationEntry {
    id: String,
    mode: String,
    state: String,
    initiator_id: String,
    recipient_id: String,
    is_initiator: bool,
}

#[derive(Debug, Deserialize)]
struct ConversationListResponse {
    items: Vec<ConversationEntry>,
    next_cursor: Option<String>,
}

#[derive(Debug, Serialize)]
struct SendMessageBody {
    client_message_id: String,
    content: String,
    image_base64: Option<String>,
    audio_base64: Option<String>,
    image_url: Option<String>,
    audio_url: Option<String>,
}

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
struct MessageEntry {
    id: i64,
    client_message_id: Option<String>,
    conversation_id: String,
    sender: String,
    content: String,
    timestamp: String,
    image_data: Option<String>,
    audio_data: Option<String>,
    image_url: Option<String>,
    audio_url: Option<String>,
    status: String,
    kind: String,
    edited_at: Option<String>,
}

type SendMessageResponse = MessageEntry;
type EditMessageResponse = MessageEntry;

#[derive(Debug, Deserialize)]
struct MessageListResponse {
    conversation_id: String,
    messages: Vec<MessageEntry>,
    total: i64,
}

#[derive(Debug, Serialize)]
struct EditMessageBody {
    content: String,
}

fn auth_headers(token: &str) -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert(
        "Authorization",
        format!("Bearer {}", token).parse().unwrap(),
    );
    headers
}

fn should_require_chat_e2e(flag_value: Option<&str>) -> bool {
    flag_value
        .map(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            )
        })
        .unwrap_or(false)
}

fn chat_e2e_required() -> bool {
    let raw = std::env::var("CHAT_E2E_REQUIRED").ok();
    should_require_chat_e2e(raw.as_deref())
}

async fn resolve_base_url(client: &Client) -> anyhow::Result<Option<String>> {
    let required = chat_e2e_required();

    let Some(base_url) = std::env::var("TEST_BASE_URL")
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
    else {
        if required {
            return Err(anyhow::anyhow!(
                "chat_e2e is required but TEST_BASE_URL is not set; set TEST_BASE_URL or set CHAT_E2E_REQUIRED=false"
            ));
        }

        eprintln!(
            "Skipping chat_e2e: TEST_BASE_URL is not set. This suite is optional unless CHAT_E2E_REQUIRED=true."
        );
        return Ok(None);
    };

    let health_url = format!("{}/api/health", base_url);
    let health_res = client.get(&health_url).send().await;
    match health_res {
        Ok(resp) if resp.status().is_success() => Ok(Some(base_url)),
        Ok(resp) => Err(anyhow::anyhow!(
            "chat_e2e preflight failed: {} returned status {}",
            health_url,
            resp.status()
        )),
        Err(err) => Err(anyhow::anyhow!(
            "chat_e2e preflight failed: cannot reach {}: {}",
            health_url,
            err
        )),
    }
}

async fn cleanup_pair(pool: &PgPool, user_a: &str, user_b: &str) -> anyhow::Result<()> {
    sqlx::query(
        "DELETE FROM chat_blocks
         WHERE (blocker_id = $1 AND blocked_id = $2)
            OR (blocker_id = $2 AND blocked_id = $1)",
    )
    .bind(user_a)
    .bind(user_b)
    .execute(pool)
    .await?;

    sqlx::query(
        "DELETE FROM chat_conversations
         WHERE (initiator_id = $1 AND recipient_id = $2)
            OR (initiator_id = $2 AND recipient_id = $1)",
    )
    .bind(user_a)
    .bind(user_b)
    .execute(pool)
    .await?;
    Ok(())
}

async fn create_realtime_conversation(
    client: &Client,
    base_url: &str,
    initiator: &TestUser,
    recipient: &TestUser,
    content: &str,
) -> anyhow::Result<ConversationEntry> {
    let response = client
        .post(format!("{}/api/chat/conversations", base_url))
        .headers(auth_headers(&initiator.token))
        .json(&CreateConversationBody {
            client_request_id: Uuid::new_v4().to_string(),
            recipient_id: recipient.user_id.clone(),
            listing_id: None,
            mode: "realtime".to_string(),
            subject: None,
            content: content.to_string(),
        })
        .send()
        .await?;

    assert_eq!(
        response.status(),
        StatusCode::OK,
        "Create conversation failed: {:?}",
        response.text().await?
    );
    let body = response.json::<CreateConversationResponse>().await?;
    assert!(body.created);
    assert!(!body.mutual_open);
    Ok(body.conversation)
}

async fn create_active_realtime_conversation(
    client: &Client,
    base_url: &str,
    initiator: &TestUser,
    recipient: &TestUser,
) -> anyhow::Result<String> {
    let conversation = create_realtime_conversation(
        client,
        base_url,
        initiator,
        recipient,
        "你好，我想聊聊这件商品。",
    )
    .await?;
    assert_eq!(conversation.state, "syn_sent");

    let accept_response = client
        .post(format!(
            "{}/api/chat/conversations/{}/respond",
            base_url, conversation.id
        ))
        .headers(auth_headers(&recipient.token))
        .json(&RespondConversationBody {
            decision: "accept".to_string(),
        })
        .send()
        .await?;

    assert_eq!(
        accept_response.status(),
        StatusCode::OK,
        "Accept conversation failed: {:?}",
        accept_response.text().await?
    );
    let accepted = accept_response.json::<ConversationEntry>().await?;
    assert_eq!(accepted.state, "syn_ack");

    let ack_response = client
        .post(format!(
            "{}/api/chat/conversations/{}/ack",
            base_url, conversation.id
        ))
        .headers(auth_headers(&initiator.token))
        .send()
        .await?;

    assert_eq!(
        ack_response.status(),
        StatusCode::OK,
        "Ack conversation failed: {:?}",
        ack_response.text().await?
    );
    let acked = ack_response.json::<ConversationEntry>().await?;
    assert_eq!(acked.state, "active");

    Ok(conversation.id)
}

async fn send_text_message(
    client: &Client,
    base_url: &str,
    token: &str,
    conversation_id: &str,
    content: &str,
) -> anyhow::Result<SendMessageResponse> {
    let response = client
        .post(format!(
            "{}/api/chat/conversations/{}/messages",
            base_url, conversation_id
        ))
        .headers(auth_headers(token))
        .json(&SendMessageBody {
            client_message_id: Uuid::new_v4().to_string(),
            content: content.to_string(),
            image_base64: None,
            audio_base64: None,
            image_url: None,
            audio_url: None,
        })
        .send()
        .await?;

    assert_eq!(
        response.status(),
        StatusCode::OK,
        "Send message failed: {:?}",
        response.text().await?
    );
    Ok(response.json::<SendMessageResponse>().await?)
}

#[test]
fn test_should_require_chat_e2e_true_values() {
    assert!(should_require_chat_e2e(Some("1")));
    assert!(should_require_chat_e2e(Some("true")));
    assert!(should_require_chat_e2e(Some("TRUE")));
    assert!(should_require_chat_e2e(Some("yes")));
    assert!(should_require_chat_e2e(Some("on")));
}

#[test]
fn test_should_require_chat_e2e_false_values() {
    assert!(!should_require_chat_e2e(None));
    assert!(!should_require_chat_e2e(Some("")));
    assert!(!should_require_chat_e2e(Some("0")));
    assert!(!should_require_chat_e2e(Some("false")));
    assert!(!should_require_chat_e2e(Some("no")));
}

#[tokio::test]
async fn test_realtime_conversation_lifecycle() -> anyhow::Result<()> {
    let database_url = db_safety::resolve_test_database_url();
    let pool = PgPool::connect(&database_url).await?;
    let client = Client::builder().timeout(Duration::from_secs(30)).build()?;
    let Some(base_url) = resolve_base_url(&client).await? else {
        return Ok(());
    };

    let user_a = create_test_user(&client, &base_url, "user_a").await?;
    let user_b = create_test_user(&client, &base_url, "user_b").await?;
    cleanup_pair(&pool, &user_a.user_id, &user_b.user_id).await?;

    let conversation =
        create_realtime_conversation(&client, &base_url, &user_a, &user_b, "现在方便聊聊吗？")
            .await?;
    assert_eq!(conversation.mode, "realtime");
    assert_eq!(conversation.state, "syn_sent");
    assert_eq!(conversation.initiator_id, user_a.user_id);
    assert_eq!(conversation.recipient_id, user_b.user_id);

    let list_response_b = client
        .get(format!("{}/api/chat/conversations?mode=realtime", base_url))
        .headers(auth_headers(&user_b.token))
        .send()
        .await?;
    assert_eq!(list_response_b.status(), StatusCode::OK);
    let conversations_b = list_response_b.json::<ConversationListResponse>().await?;
    let found = conversations_b
        .items
        .iter()
        .find(|item| item.id == conversation.id)
        .expect("receiver should see the realtime invitation");
    assert_eq!(found.state, "syn_sent");
    assert!(!found.is_initiator);
    assert!(conversations_b.next_cursor.is_none());

    let accept_response = client
        .post(format!(
            "{}/api/chat/conversations/{}/respond",
            base_url, conversation.id
        ))
        .headers(auth_headers(&user_b.token))
        .json(&RespondConversationBody {
            decision: "accept".to_string(),
        })
        .send()
        .await?;
    assert_eq!(accept_response.status(), StatusCode::OK);
    let accepted = accept_response.json::<ConversationEntry>().await?;
    assert_eq!(accepted.state, "syn_ack");

    let ack_response = client
        .post(format!(
            "{}/api/chat/conversations/{}/ack",
            base_url, conversation.id
        ))
        .headers(auth_headers(&user_a.token))
        .send()
        .await?;
    assert_eq!(ack_response.status(), StatusCode::OK);
    let active = ack_response.json::<ConversationEntry>().await?;
    assert_eq!(active.state, "active");

    let close_response = client
        .post(format!(
            "{}/api/chat/conversations/{}/close",
            base_url, conversation.id
        ))
        .headers(auth_headers(&user_a.token))
        .send()
        .await?;
    assert_eq!(close_response.status(), StatusCode::OK);
    let closed = close_response.json::<ConversationEntry>().await?;
    assert_eq!(closed.state, "closed");

    let declined_invite =
        create_realtime_conversation(&client, &base_url, &user_a, &user_b, "不急，有空再聊。")
            .await?;
    let decline_response = client
        .post(format!(
            "{}/api/chat/conversations/{}/respond",
            base_url, declined_invite.id
        ))
        .headers(auth_headers(&user_b.token))
        .json(&RespondConversationBody {
            decision: "decline".to_string(),
        })
        .send()
        .await?;
    assert_eq!(decline_response.status(), StatusCode::OK);
    let declined = decline_response.json::<ConversationEntry>().await?;
    assert_eq!(declined.state, "declined");

    cleanup_pair(&pool, &user_a.user_id, &user_b.user_id).await?;
    Ok(())
}

#[tokio::test]
async fn test_message_sending() -> anyhow::Result<()> {
    let database_url = db_safety::resolve_test_database_url();
    let pool = PgPool::connect(&database_url).await?;
    let client = Client::builder().timeout(Duration::from_secs(30)).build()?;
    let Some(base_url) = resolve_base_url(&client).await? else {
        return Ok(());
    };

    let user_a = create_test_user(&client, &base_url, "msg_a").await?;
    let user_b = create_test_user(&client, &base_url, "msg_b").await?;
    cleanup_pair(&pool, &user_a.user_id, &user_b.user_id).await?;
    let conversation_id =
        create_active_realtime_conversation(&client, &base_url, &user_a, &user_b).await?;

    let message_content = "Hello, this is a test message!";
    let sent_message = send_text_message(
        &client,
        &base_url,
        &user_a.token,
        &conversation_id,
        message_content,
    )
    .await?;
    assert_eq!(sent_message.sender, user_a.user_id);
    assert_eq!(sent_message.content, message_content);
    assert_eq!(sent_message.conversation_id, conversation_id);
    assert_eq!(sent_message.status, "sent");
    assert_eq!(sent_message.kind, "message");

    let get_response = client
        .get(format!(
            "{}/api/chat/conversations/{}/messages",
            base_url, conversation_id
        ))
        .headers(auth_headers(&user_b.token))
        .send()
        .await?;
    assert_eq!(get_response.status(), StatusCode::OK);
    let messages_response = get_response.json::<MessageListResponse>().await?;
    assert_eq!(messages_response.conversation_id, conversation_id);
    assert!(messages_response.total >= 2);

    let received_msg = messages_response
        .messages
        .iter()
        .find(|message| message.id == sent_message.id)
        .expect("message should be retrievable");
    assert_eq!(received_msg.sender, user_a.user_id);
    assert_eq!(received_msg.content, message_content);
    assert!(!received_msg.timestamp.is_empty());

    cleanup_pair(&pool, &user_a.user_id, &user_b.user_id).await?;
    Ok(())
}

#[tokio::test]
async fn test_message_editing() -> anyhow::Result<()> {
    let database_url = db_safety::resolve_test_database_url();
    let pool = PgPool::connect(&database_url).await?;
    let client = Client::builder().timeout(Duration::from_secs(30)).build()?;
    let Some(base_url) = resolve_base_url(&client).await? else {
        return Ok(());
    };

    let user_a = create_test_user(&client, &base_url, "edit_a").await?;
    let user_b = create_test_user(&client, &base_url, "edit_b").await?;
    cleanup_pair(&pool, &user_a.user_id, &user_b.user_id).await?;
    let conversation_id =
        create_active_realtime_conversation(&client, &base_url, &user_a, &user_b).await?;

    let sent_message = send_text_message(
        &client,
        &base_url,
        &user_a.token,
        &conversation_id,
        "Original message content",
    )
    .await?;

    let edited_content = "Edited message content";
    let edit_response = client
        .patch(format!(
            "{}/api/chat/messages/{}",
            base_url, sent_message.id
        ))
        .headers(auth_headers(&user_a.token))
        .json(&EditMessageBody {
            content: edited_content.to_string(),
        })
        .send()
        .await?;
    assert_eq!(
        edit_response.status(),
        StatusCode::OK,
        "Edit failed: {:?}",
        edit_response.text().await?
    );
    let edit_result = edit_response.json::<EditMessageResponse>().await?;
    assert_eq!(edit_result.content, edited_content);
    assert!(edit_result.edited_at.is_some());

    let b_message = send_text_message(
        &client,
        &base_url,
        &user_b.token,
        &conversation_id,
        "Message from User B",
    )
    .await?;
    let edit_b_response = client
        .patch(format!("{}/api/chat/messages/{}", base_url, b_message.id))
        .headers(auth_headers(&user_a.token))
        .json(&EditMessageBody {
            content: "Trying to edit User B's message".to_string(),
        })
        .send()
        .await?;
    assert_eq!(edit_b_response.status(), StatusCode::FORBIDDEN);

    cleanup_pair(&pool, &user_a.user_id, &user_b.user_id).await?;
    Ok(())
}

#[tokio::test]
async fn test_cannot_send_to_non_active_realtime_conversation() -> anyhow::Result<()> {
    let database_url = db_safety::resolve_test_database_url();
    let pool = PgPool::connect(&database_url).await?;
    let client = Client::builder().timeout(Duration::from_secs(30)).build()?;
    let Some(base_url) = resolve_base_url(&client).await? else {
        return Ok(());
    };

    let user_a = create_test_user(&client, &base_url, "noconn_a").await?;
    let user_b = create_test_user(&client, &base_url, "noconn_b").await?;
    cleanup_pair(&pool, &user_a.user_id, &user_b.user_id).await?;
    let conversation =
        create_realtime_conversation(&client, &base_url, &user_a, &user_b, "This is still SYN.")
            .await?;

    let send_response = client
        .post(format!(
            "{}/api/chat/conversations/{}/messages",
            base_url, conversation.id
        ))
        .headers(auth_headers(&user_a.token))
        .json(&SendMessageBody {
            client_message_id: Uuid::new_v4().to_string(),
            content: "This should fail".to_string(),
            image_base64: None,
            audio_base64: None,
            image_url: None,
            audio_url: None,
        })
        .send()
        .await?;
    assert_eq!(send_response.status(), StatusCode::CONFLICT);

    cleanup_pair(&pool, &user_a.user_id, &user_b.user_id).await?;
    Ok(())
}

#[tokio::test]
async fn test_cannot_create_self_conversation() -> anyhow::Result<()> {
    let client = Client::builder().timeout(Duration::from_secs(30)).build()?;
    let Some(base_url) = resolve_base_url(&client).await? else {
        return Ok(());
    };

    let user_a = create_test_user(&client, &base_url, "self_chat").await?;
    let response = client
        .post(format!("{}/api/chat/conversations", base_url))
        .headers(auth_headers(&user_a.token))
        .json(&CreateConversationBody {
            client_request_id: Uuid::new_v4().to_string(),
            recipient_id: user_a.user_id.clone(),
            listing_id: None,
            mode: "realtime".to_string(),
            subject: None,
            content: "Trying to talk to myself".to_string(),
        })
        .send()
        .await?;

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    Ok(())
}
