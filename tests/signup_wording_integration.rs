//! What a student is told when they get it wrong.
//!
//! Registration is the single step every real user must pass, and the messages
//! here are the ones that decide whether someone keeps going or closes the app.
//! "Your address is not allowed" without naming the allowed one asks them to
//! guess; most will not.
//!
//! These assert the wording carries the answer, not just the verdict.

use goods4ncu::services::campus::CampusService;
use goods4ncu::test_infra::with_test_pool;
use uuid::Uuid;

async fn member_pending_verification(pool: &sqlx::PgPool) -> (String, Uuid) {
    let id = format!("wording-{}", Uuid::new_v4().simple());
    sqlx::query(
        "INSERT INTO users (id, username, password_hash, email)
         VALUES ($1, $2, 'hash', $3)",
    )
    .bind(&id)
    .bind(format!("wording_{}", Uuid::new_v4().simple()))
    // Deliberately a personal address, which is what people actually type.
    .bind(format!("{id}@qq.com"))
    .execute(pool)
    .await
    .expect("insert user");

    let membership: Uuid = sqlx::query_scalar(
        "INSERT INTO campus_memberships (campus_id, user_id, status, verification_method)
         SELECT id, $1, 'pending', 'registration' FROM campuses WHERE slug = 'ncu'
         RETURNING id",
    )
    .bind(&id)
    .fetch_one(pool)
    .await
    .expect("insert membership");
    (id, membership)
}

#[tokio::test]
async fn a_wrong_email_domain_is_told_which_one_to_use() {
    // The wall every student hits first. Naming the domain is the difference
    // between a two-second correction and closing the app.
    with_test_pool(|pool| async move {
        let (user_id, membership) = member_pending_verification(&pool).await;

        let error = CampusService::new(pool.clone())
            .request_email_verification(&user_id, membership, "test-secret")
            .await
            .expect_err("a qq.com address is not an NCU address");

        let message = error.to_string();
        assert!(
            message.contains("email.ncu.edu.cn"),
            "the message must name the address to use, got: {message}",
        );
        // And it should read as an instruction rather than a rejection.
        assert!(
            !message.contains("不属于"),
            "phrased as what to do, not what is wrong: {message}",
        );
    })
    .await;
}

#[tokio::test]
async fn the_verification_mail_says_what_it_is_for() {
    // A message reading "your code is 123456" with nothing else is
    // indistinguishable from phishing, and an unsure student will not type it
    // in. The gateway renders the mail but can only say what it is handed.
    let source = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/src/services/campus.rs"
    ))
    .expect("read campus service");

    let payload_start = source
        .find("\"template\": \"campus_email_verification\"")
        .expect("verification payload");
    let payload = &source[payload_start..payload_start + 400];

    assert!(
        payload.contains("app_name"),
        "the mail must be able to name the product",
    );
    assert!(payload.contains("purpose"), "and say what the code is for",);
}
