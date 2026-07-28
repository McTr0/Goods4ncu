use goods4ncu::api::error::ApiError;
use goods4ncu::services::content_report::ContentReportService;
use goods4ncu::services::moderation_case::{CaseReviewAction, ModerationCaseService};
use goods4ncu::test_infra::with_test_pool;
use sqlx::Row;
use uuid::Uuid;

async fn ncu_campus(pool: &sqlx::PgPool) -> Uuid {
    sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
        .fetch_one(pool)
        .await
        .expect("NCU campus")
}

async fn insert_campus(pool: &sqlx::PgPool) -> Uuid {
    let campus_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO campuses (id, slug, name_zh, name_en, email_domains)
         VALUES ($1, $2, '举报测试大学', 'Report Test University', ARRAY['report.test'])",
    )
    .bind(campus_id)
    .bind(format!("report-{}", &campus_id.to_string()[..8]))
    .execute(pool)
    .await
    .expect("insert campus");
    campus_id
}

async fn insert_member(pool: &sqlx::PgPool, campus_id: Uuid, label: &str) -> String {
    let user_id = Uuid::new_v4().to_string();
    sqlx::query(
        "INSERT INTO users (id, username, password_hash, status)
         VALUES ($1, $2, 'hash', 'active')",
    )
    .bind(&user_id)
    .bind(format!("{label}_{}", Uuid::new_v4().simple()))
    .execute(pool)
    .await
    .expect("insert user");
    sqlx::query(
        "INSERT INTO campus_memberships (
             campus_id, user_id, status, verification_method, verified_at
         ) VALUES ($1, $2, 'verified', 'test_fixture', NOW())",
    )
    .bind(campus_id)
    .bind(&user_id)
    .execute(pool)
    .await
    .expect("insert membership");
    user_id
}

async fn insert_listing(
    pool: &sqlx::PgPool,
    campus_id: Uuid,
    owner_id: &str,
    label: &str,
) -> String {
    let listing_id = Uuid::new_v4().to_string();
    sqlx::query(
        "INSERT INTO inventory (
             id, campus_id, title, category, brand, condition_score,
             suggested_price_cny, defects, owner_id, status, direction
         ) VALUES ($1, $2, $3, 'other', 'Test', 8, 10000, '[]', $4, 'active', 'offer')",
    )
    .bind(&listing_id)
    .bind(campus_id)
    .bind(label)
    .bind(owner_id)
    .execute(pool)
    .await
    .expect("insert listing");
    listing_id
}

#[tokio::test]
async fn duplicate_report_updates_one_report_and_one_case() {
    with_test_pool(|pool| async move {
        let campus_id = ncu_campus(&pool).await;
        let reporter_id = insert_member(&pool, campus_id, "reporter").await;
        let owner_id = insert_member(&pool, campus_id, "owner").await;
        let reviewer_id = insert_member(&pool, campus_id, "reviewer").await;
        let listing_id = insert_listing(&pool, campus_id, &owner_id, "Reported listing").await;
        let service = ContentReportService::new(pool.clone());

        let report_id = service
            .report_listing(
                campus_id,
                &reporter_id,
                &listing_id,
                "  疑似诈骗  ",
                Some("第一次说明"),
            )
            .await
            .expect("create report");
        let duplicate_id = service
            .report_listing(
                campus_id,
                &reporter_id,
                &listing_id,
                "描述不实",
                Some("更新后的说明"),
            )
            .await
            .expect("update report");
        assert_eq!(duplicate_id, report_id);

        let report = sqlx::query(
            "SELECT reason, details, status, case_id, subject_user_id,
                    created_at, updated_at
             FROM content_reports WHERE id = $1",
        )
        .bind(report_id)
        .fetch_one(&pool)
        .await
        .expect("content report");
        assert_eq!(report.get::<String, _>("reason"), "描述不实");
        assert_eq!(
            report.get::<Option<String>, _>("details").as_deref(),
            Some("更新后的说明")
        );
        assert_eq!(report.get::<String, _>("status"), "open");
        assert_eq!(
            report
                .get::<Option<String>, _>("subject_user_id")
                .as_deref(),
            Some(owner_id.as_str())
        );
        assert!(
            report.get::<chrono::DateTime<chrono::Utc>, _>("updated_at")
                >= report.get::<chrono::DateTime<chrono::Utc>, _>("created_at")
        );
        let case_id = report
            .get::<Option<Uuid>, _>("case_id")
            .expect("linked case");

        let moderation_case = sqlx::query(
            "SELECT campus_id, subject_user_id, resource_type, resource_id,
                    source_type, source_ref_id,
                    internal_details->>'details' AS details
             FROM moderation_cases WHERE id = $1",
        )
        .bind(case_id)
        .fetch_one(&pool)
        .await
        .expect("moderation case");
        assert_eq!(moderation_case.get::<Uuid, _>("campus_id"), campus_id);
        assert_eq!(
            moderation_case
                .get::<Option<String>, _>("subject_user_id")
                .as_deref(),
            Some(owner_id.as_str())
        );
        assert_eq!(moderation_case.get::<String, _>("resource_type"), "listing");
        assert_eq!(moderation_case.get::<String, _>("resource_id"), listing_id);
        assert_eq!(
            moderation_case.get::<String, _>("source_type"),
            "user_report"
        );
        assert_eq!(
            moderation_case.get::<String, _>("source_ref_id"),
            format!("content_report:{report_id}")
        );
        assert_eq!(
            moderation_case
                .get::<Option<String>, _>("details")
                .as_deref(),
            Some("更新后的说明")
        );

        let created_events: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM moderation_case_events
             WHERE case_id = $1 AND event_type = 'case_created'",
        )
        .bind(case_id)
        .fetch_one(&pool)
        .await
        .expect("case event count");
        assert_eq!(created_events, 1);

        let moderation = ModerationCaseService::new(pool.clone());
        moderation
            .review_case(
                case_id,
                campus_id,
                &reviewer_id,
                CaseReviewAction::StartReview,
                None,
                None,
            )
            .await
            .expect("start review");
        let report_status: String =
            sqlx::query_scalar("SELECT status FROM content_reports WHERE id = $1")
                .bind(report_id)
                .fetch_one(&pool)
                .await
                .expect("reviewing report");
        assert_eq!(report_status, "reviewing");

        let unsupported = moderation
            .review_case(
                case_id,
                campus_id,
                &reviewer_id,
                CaseReviewAction::Restrict,
                None,
                None,
            )
            .await;
        assert!(matches!(unsupported, Err(ApiError::Conflict(_))));
        let (case_status, report_status): (String, String) = sqlx::query_as(
            "SELECT moderation_case.status, report.status
             FROM moderation_cases moderation_case
             JOIN content_reports report ON report.case_id = moderation_case.id
             WHERE moderation_case.id = $1",
        )
        .bind(case_id)
        .fetch_one(&pool)
        .await
        .expect("unchanged review state");
        assert_eq!(case_status, "reviewing");
        assert_eq!(report_status, "reviewing");

        moderation
            .review_case(
                case_id,
                campus_id,
                &reviewer_id,
                CaseReviewAction::Dismiss,
                None,
                None,
            )
            .await
            .expect("dismiss report");
        let report_status: String =
            sqlx::query_scalar("SELECT status FROM content_reports WHERE id = $1")
                .bind(report_id)
                .fetch_one(&pool)
                .await
                .expect("dismissed report");
        assert_eq!(report_status, "dismissed");

        let new_report_id = service
            .report_listing(campus_id, &reporter_id, &listing_id, "出现了新的问题", None)
            .await
            .expect("new report after dismissal");
        assert_ne!(new_report_id, report_id);
        let (report_count, case_count): (i64, i64) = sqlx::query_as(
            "SELECT
                 (SELECT COUNT(*) FROM content_reports
                  WHERE campus_id = $1 AND resource_type = 'listing'
                    AND resource_id = $2 AND reporter_id = $3),
                 (SELECT COUNT(*) FROM moderation_cases
                  WHERE source_type = 'user_report'
                    AND source_ref_id LIKE 'content_report:%'
                    AND resource_type = 'listing' AND resource_id = $2)",
        )
        .bind(campus_id)
        .bind(&listing_id)
        .bind(&reporter_id)
        .fetch_one(&pool)
        .await
        .expect("renewed report counts");
        assert_eq!(report_count, 2);
        assert_eq!(case_count, 2);

        let new_case_id: Uuid =
            sqlx::query_scalar("SELECT case_id FROM content_reports WHERE id = $1")
                .bind(new_report_id)
                .fetch_one(&pool)
                .await
                .expect("new case id");
        sqlx::query(
            "UPDATE moderation_cases
             SET status = 'actioned', resolution = 'content_restricted'
             WHERE id = $1",
        )
        .bind(new_case_id)
        .execute(&pool)
        .await
        .expect("simulate legacy actioned case");
        let unsupported_appeal = moderation
            .submit_appeal(
                new_case_id,
                &owner_id,
                campus_id,
                "这是一个足够长但不应被受理的申诉说明",
            )
            .await;
        assert!(matches!(unsupported_appeal, Err(ApiError::Conflict(_))));
        let appeal_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM moderation_appeals WHERE case_id = $1")
                .bind(new_case_id)
                .fetch_one(&pool)
                .await
                .expect("appeal count");
        assert_eq!(appeal_count, 0);
    })
    .await;
}

#[tokio::test]
async fn self_cross_campus_and_invalid_reports_are_rejected() {
    with_test_pool(|pool| async move {
        let campus_id = ncu_campus(&pool).await;
        let reporter_id = insert_member(&pool, campus_id, "reporter").await;
        let owner_id = insert_member(&pool, campus_id, "owner").await;
        let own_listing = insert_listing(&pool, campus_id, &reporter_id, "Own listing").await;
        let listing_id = insert_listing(&pool, campus_id, &owner_id, "Valid listing").await;
        let other_campus_id = insert_campus(&pool).await;
        let other_user_id = insert_member(&pool, other_campus_id, "outsider").await;
        let other_listing =
            insert_listing(&pool, other_campus_id, &other_user_id, "Other campus").await;
        let service = ContentReportService::new(pool.clone());

        assert!(matches!(
            service
                .report_user(campus_id, &reporter_id, &reporter_id, "测试", None)
                .await,
            Err(ApiError::BadRequest(_))
        ));
        assert!(matches!(
            service
                .report_listing(campus_id, &reporter_id, &own_listing, "测试", None)
                .await,
            Err(ApiError::BadRequest(_))
        ));
        assert!(matches!(
            service
                .report_user(campus_id, &reporter_id, &other_user_id, "测试", None)
                .await,
            Err(ApiError::NotFound)
        ));
        assert!(matches!(
            service
                .report_listing(campus_id, &reporter_id, &other_listing, "测试", None)
                .await,
            Err(ApiError::NotFound)
        ));
        assert!(matches!(
            service
                .report_listing(campus_id, &reporter_id, &listing_id, "   ", None)
                .await,
            Err(ApiError::BadRequest(_))
        ));
        assert!(matches!(
            service
                .report_listing(campus_id, &reporter_id, &listing_id, &"原".repeat(81), None,)
                .await,
            Err(ApiError::BadRequest(_))
        ));
        assert!(matches!(
            service
                .report_listing(
                    campus_id,
                    &reporter_id,
                    &listing_id,
                    "测试",
                    Some(&"详".repeat(1001)),
                )
                .await,
            Err(ApiError::BadRequest(_))
        ));

        let report_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM content_reports")
            .fetch_one(&pool)
            .await
            .expect("report count");
        assert_eq!(report_count, 0);
    })
    .await;
}

#[tokio::test]
async fn hourly_limit_counts_only_new_reports_and_allows_duplicate_edits() {
    with_test_pool(|pool| async move {
        let campus_id = ncu_campus(&pool).await;
        let reporter_id = insert_member(&pool, campus_id, "reporter").await;
        let service = ContentReportService::new(pool.clone());
        let mut targets = Vec::new();
        for index in 0..11 {
            targets.push(insert_member(&pool, campus_id, &format!("target_{index}")).await);
        }

        let mut first_report_id = None;
        for target_id in targets.iter().take(10) {
            let report_id = service
                .report_user(campus_id, &reporter_id, target_id, "疑似骚扰", None)
                .await
                .expect("within hourly limit");
            first_report_id.get_or_insert(report_id);
        }

        let over_limit = service
            .report_user(
                campus_id,
                &reporter_id,
                &targets[10],
                "第十一条新举报",
                None,
            )
            .await;
        assert!(matches!(over_limit, Err(ApiError::RateLimitExceeded)));

        let duplicate_id = service
            .report_user(
                campus_id,
                &reporter_id,
                &targets[0],
                "更新已有举报",
                Some("重复编辑不应占用新额度"),
            )
            .await
            .expect("duplicate edit after reaching limit");
        assert_eq!(Some(duplicate_id), first_report_id);

        let report_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM content_reports WHERE reporter_id = $1")
                .bind(&reporter_id)
                .fetch_one(&pool)
                .await
                .expect("report count");
        assert_eq!(report_count, 10);
    })
    .await;
}
