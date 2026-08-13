//! Persistence and campus-visibility tests for the user-controlled role layer.

use goods4ncu::services::moderation::ModerationService;
use goods4ncu::services::moderation_worker::{process_pending_jobs_once, ModerationApiConfig};
use goods4ncu::services::shared_object_cleanup::expire_stale_persona_uploads;
use goods4ncu::services::social_persona::{
    CompleteSocialPersonaAssetInput, CreateSocialPersonaAssetInput, SocialPersonaInput,
    SocialPersonaService,
};
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

#[tokio::test]
async fn legacy_persona_assets_are_never_projected_after_catalog_migration() {
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let user_id = member(&pool, campus_id, "asset-owner").await;
        let service = SocialPersonaService::new(pool.clone());
        service
            .upsert_draft(&user_id, campus_id, input())
            .await
            .expect("persona draft");

        let asset = service
            .create_asset(
                &user_id,
                campus_id,
                CreateSocialPersonaAssetInput {
                    asset_type: "illustration".to_string(),
                    declared_mime_type: "image/png".to_string(),
                    declared_size_bytes: 1024,
                },
            )
            .await
            .expect("create asset");
        assert_eq!(asset.status, "pending_upload");
        assert!(asset
            .upload_key
            .as_deref()
            .is_some_and(|key| key.starts_with(&format!("persona/{campus_id}/"))));
        let other_user = member(&pool, campus_id, "asset-other").await;
        assert!(service
            .get_asset(
                &other_user,
                campus_id,
                Uuid::parse_str(&asset.id).expect("asset id"),
            )
            .await
            .is_err());
        assert!(service
            .get_asset(
                &user_id,
                Uuid::new_v4(),
                Uuid::parse_str(&asset.id).expect("asset id"),
            )
            .await
            .is_err());

        let mismatch = service
            .complete_asset(
                &user_id,
                campus_id,
                Uuid::parse_str(&asset.id).expect("asset id"),
                CompleteSocialPersonaAssetInput {
                    uploaded_size_bytes: 1023,
                    uploaded_mime_type: "image/png".to_string(),
                    moderation_required: true,
                },
            )
            .await;
        assert!(mismatch.is_err(), "the server must reject a size mismatch");
        assert_eq!(
            service
                .get_asset(
                    &user_id,
                    campus_id,
                    Uuid::parse_str(&asset.id).expect("asset id"),
                )
                .await
                .expect("pending asset")
                .status,
            "pending_upload"
        );

        let completed = service
            .complete_asset(
                &user_id,
                campus_id,
                Uuid::parse_str(&asset.id).expect("asset id"),
                CompleteSocialPersonaAssetInput {
                    uploaded_size_bytes: 1024,
                    uploaded_mime_type: "image/png".to_string(),
                    moderation_required: true,
                },
            )
            .await
            .expect("complete asset");
        assert_eq!(completed.status, "pending_review");
        assert_eq!(completed.moderation_status, "pending");
        assert!(service
            .get_published_for_user(&user_id, campus_id)
            .await
            .expect("private public projection")
            .is_none());

        let moderation = ModerationService::new_for_test(true);
        let mut moderation_tx = pool.begin().await.expect("moderation transaction");
        moderation
            .submit_image_job_in_tx_with_storage_key(
                &mut moderation_tx,
                campus_id,
                &completed.id,
                "https://expired.example.test/persona.png",
                completed.upload_key.as_deref(),
                "social_persona_asset",
            )
            .await
            .expect("enqueue asset moderation");
        moderation_tx.commit().await.expect("commit moderation job");
        let stored_key: Option<String> = sqlx::query_scalar(
            "SELECT storage_key FROM moderation_jobs
             WHERE resource_type = 'social_persona_asset' AND resource_id = $1",
        )
        .bind(&completed.id)
        .fetch_one(&pool)
        .await
        .expect("stored moderation key");
        assert_eq!(stored_key, completed.upload_key);
        process_pending_jobs_once(
            &pool,
            &ModerationApiConfig::from_parts(false, None, None),
            "asset-test-worker",
        )
        .await
        .expect("approve asset with deterministic worker");

        let approved = service
            .get_asset(
                &user_id,
                campus_id,
                Uuid::parse_str(&completed.id).expect("asset id"),
            )
            .await
            .expect("approved asset");
        assert_eq!(approved.status, "active");
        assert_eq!(approved.moderation_status, "approved");

        let selected = service
            .select_asset(
                &user_id,
                campus_id,
                Uuid::parse_str(&completed.id).expect("asset id"),
            )
            .await
            .expect("select asset");
        assert_eq!(
            selected.selected_asset_id.as_deref(),
            Some(completed.id.as_str())
        );
        assert_eq!(selected.status, "draft");
        service.publish(&user_id, campus_id).await.expect("publish");
        let public = service
            .get_published_for_user(&user_id, campus_id)
            .await
            .expect("public projection")
            .expect("published persona");
        assert!(
            public.asset.is_none(),
            "legacy user-imported assets must never re-enter the public projection"
        );

        let revoked = service
            .revoke_asset(
                &user_id,
                campus_id,
                Uuid::parse_str(&completed.id).expect("asset id"),
            )
            .await
            .expect("revoke asset");
        assert_eq!(revoked.status, "revoked");
        let persona = service
            .get_for_user(&user_id, campus_id)
            .await
            .expect("persona")
            .expect("persona row");
        assert!(persona.selected_asset_id.is_none());
        assert_eq!(
            persona.status, "published",
            "publishing a catalog persona must not be downgraded by revoking a legacy asset"
        );
        let cleanup_requested: Option<chrono::DateTime<chrono::Utc>> = sqlx::query_scalar(
            "SELECT cleanup_requested_at FROM social_persona_assets WHERE id = $1",
        )
        .bind(Uuid::parse_str(&completed.id).expect("asset id"))
        .fetch_one(&pool)
        .await
        .expect("cleanup marker");
        assert!(cleanup_requested.is_some());
    })
    .await;
}

#[tokio::test]
async fn abandoned_persona_uploads_are_revoked_and_audited() {
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let user_id = member(&pool, campus_id, "asset-expiry").await;
        let service = SocialPersonaService::new(pool.clone());
        let persona = service
            .upsert_draft(&user_id, campus_id, input())
            .await
            .expect("persona draft");
        let asset = service
            .create_asset(
                &user_id,
                campus_id,
                CreateSocialPersonaAssetInput {
                    asset_type: "illustration".to_string(),
                    declared_mime_type: "image/png".to_string(),
                    declared_size_bytes: 1024,
                },
            )
            .await
            .expect("create asset");
        sqlx::query(
            "UPDATE social_persona_assets
             SET created_at = NOW() - INTERVAL '2 days'
             WHERE id = $1",
        )
        .bind(Uuid::parse_str(&asset.id).expect("asset id"))
        .execute(&pool)
        .await
        .expect("age asset");

        assert_eq!(
            expire_stale_persona_uploads(&pool).await.expect("expire"),
            1
        );
        let expired = service
            .get_asset(
                &user_id,
                campus_id,
                Uuid::parse_str(&asset.id).expect("asset id"),
            )
            .await
            .expect("expired asset");
        assert_eq!(expired.status, "revoked");
        let cleanup_requested: Option<chrono::DateTime<chrono::Utc>> = sqlx::query_scalar(
            "SELECT cleanup_requested_at FROM social_persona_assets WHERE id = $1",
        )
        .bind(Uuid::parse_str(&asset.id).expect("asset id"))
        .fetch_one(&pool)
        .await
        .expect("cleanup marker");
        assert!(cleanup_requested.is_some());
        let action: String = sqlx::query_scalar(
            "SELECT action FROM social_persona_audits
             WHERE persona_id = $1 AND action = 'asset_expired'
             ORDER BY id DESC LIMIT 1",
        )
        .bind(Uuid::parse_str(&persona.id).expect("persona id"))
        .fetch_one(&pool)
        .await
        .expect("expiry audit");
        assert_eq!(action, "asset_expired");
        assert_eq!(
            expire_stale_persona_uploads(&pool)
                .await
                .expect("idempotent expiry"),
            0
        );
    })
    .await;
}
