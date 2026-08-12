//! Persistence and campus-visibility tests for the user-controlled role layer.

use goods4ncu::services::social_persona::{SocialPersonaInput, SocialPersonaService};
use goods4ncu::test_infra::with_test_pool;
use serde_json::json;
use uuid::Uuid;

async fn campus(pool: &sqlx::PgPool) -> Uuid {
    sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
        .fetch_one(pool)
        .await
        .expect("ncu campus")
}

async fn member(pool: &sqlx::PgPool, campus_id: Uuid, tag: &str) -> String {
    let id = format!("persona-{tag}-{}", Uuid::new_v4().simple());
    sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
        .bind(&id)
        .bind(format!("persona_{tag}_{}", Uuid::new_v4().simple()))
        .execute(pool)
        .await
        .expect("insert user");
    sqlx::query(
        "INSERT INTO campus_memberships
             (campus_id, user_id, status, verification_method, verified_at)
         VALUES ($1, $2, 'verified', 'test_fixture', NOW())",
    )
    .bind(campus_id)
    .bind(&id)
    .execute(pool)
    .await
    .expect("insert membership");
    id
}

fn input() -> SocialPersonaInput {
    SocialPersonaInput {
        representation_mode: "role_character".to_string(),
        style_version: None,
        appearance_config: json!({"palette": "teal", "accessory": "leaf"}),
        self_descriptions: vec!["slow_to_warm".to_string(), "meetup_friendly".to_string()],
        contact_posture: "leave_message".to_string(),
    }
}

#[tokio::test]
async fn draft_publish_archive_and_public_campus_boundary() {
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let user_id = member(&pool, campus_id, "owner").await;
        let service = SocialPersonaService::new(pool.clone());

        let draft = service
            .upsert_draft(&user_id, campus_id, input())
            .await
            .expect("draft");
        assert_eq!(draft.status, "draft");
        assert!(draft.published_at.is_none());
        assert!(service
            .get_published_for_user(&user_id, campus_id)
            .await
            .expect("draft is readable privately")
            .is_none());

        let published = service.publish(&user_id, campus_id).await.expect("publish");
        assert_eq!(published.status, "published");
        assert!(published.published_at.is_some());
        let public = service
            .get_published_for_user(&user_id, campus_id)
            .await
            .expect("public read")
            .expect("published persona");
        assert_eq!(public.representation_mode, "role_character");
        assert_eq!(public.appearance_config["accessory"], "leaf");

        let other_campus = Uuid::new_v4();
        assert!(service
            .get_published_for_user(&user_id, other_campus)
            .await
            .expect("other campus read")
            .is_none());

        let archived = service.archive(&user_id, campus_id).await.expect("archive");
        assert_eq!(archived.status, "archived");
        assert!(service
            .get_published_for_user(&user_id, campus_id)
            .await
            .expect("archived read")
            .is_none());

        let audit_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM social_persona_audits WHERE persona_id = $1")
                .bind(Uuid::parse_str(&draft.id).expect("persona uuid"))
                .fetch_one(&pool)
                .await
                .expect("audit count");
        assert_eq!(audit_count, 3, "create, publish, and archive are audited");
    })
    .await;
}
