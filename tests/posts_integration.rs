//! Integration coverage for discussion topics, threaded replies and the
//! inventory-to-post projection.

use goods4ncu::api::error::ApiError;
use goods4ncu::config::AppConfig;
use goods4ncu::repositories::{PostFilter, PostSort};
use goods4ncu::services::feed::{FeedFeedbackAction, FeedResourceType, FeedService};
use goods4ncu::services::moderation::ModerationService;
use goods4ncu::services::post::{CreateDiscussion, EditDiscussion, PostService};
use goods4ncu::test_infra::with_test_pool;
use uuid::Uuid;

async fn campus(pool: &sqlx::PgPool) -> Uuid {
    sqlx::query_scalar("SELECT id FROM campuses WHERE slug = 'ncu'")
        .fetch_one(pool)
        .await
        .expect("default campus")
}

async fn user(pool: &sqlx::PgPool, tag: &str) -> String {
    let id = format!("post-{tag}-{}", Uuid::new_v4().simple());
    sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
        .bind(&id)
        .bind(format!("post_{tag}_{}", Uuid::new_v4().simple()))
        .execute(pool)
        .await
        .expect("insert post test user");
    id
}

fn service(pool: &sqlx::PgPool) -> PostService {
    PostService::new(pool.clone(), ModerationService::new_for_test(false))
}

#[tokio::test]
async fn discussion_policy_rejection_happens_before_persistence() {
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let owner = user(&pool, "policy-owner").await;
        let mut config = AppConfig::test_defaults();
        config.blocked_keywords = vec!["campuspolicytoken".to_string()];
        config.moderation_image_enabled = false;
        let service = PostService::new(pool.clone(), ModerationService::new(&config));
        let before: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM posts WHERE campus_id = $1 AND author_id = $2",
        )
        .bind(campus_id)
        .bind(&owner)
        .fetch_one(&pool)
        .await
        .expect("count posts before policy rejection");

        let result = service
            .create(CreateDiscussion {
                campus_id,
                author_id: owner.clone(),
                title: "campusp0licytoken".to_string(),
                body: "用于验证发布入口在写库前执行统一审查。".to_string(),
                category: Some("campus-life".to_string()),
                tags: vec![],
                cover_image_url: None,
            })
            .await;
        assert!(matches!(result, Err(ApiError::ContentViolation(_))));

        let after: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM posts WHERE campus_id = $1 AND author_id = $2",
        )
        .bind(campus_id)
        .bind(&owner)
        .fetch_one(&pool)
        .await
        .expect("count posts after policy rejection");
        assert_eq!(after, before, "rejected discussion must not be persisted");
    })
    .await;
}

#[tokio::test]
async fn discussions_support_threaded_replies_locking_and_author_boundaries() {
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let owner = user(&pool, "owner").await;
        let other = user(&pool, "other").await;
        let service = service(&pool);

        let first = service
            .create(CreateDiscussion {
                campus_id,
                author_id: owner.clone(),
                title: "毕业季宿舍整理经验".to_string(),
                body: "把同类物品放在一起，标题写清楚楼栋和取货时间。".to_string(),
                category: Some("campus-life".to_string()),
                tags: vec!["毕业季".to_string(), "经验".to_string()],
                cover_image_url: None,
            })
            .await
            .expect("create discussion");
        let second = service
            .create(CreateDiscussion {
                campus_id,
                author_id: owner.clone(),
                title: "另一个主题".to_string(),
                body: "用于验证跨主题引用会被拒绝。".to_string(),
                category: None,
                tags: vec![],
                cover_image_url: None,
            })
            .await
            .expect("create second discussion");

        let root_reply = service
            .create_reply(
                campus_id,
                first.id,
                &other,
                "这个方法很实用。".to_string(),
                None,
            )
            .await
            .expect("create root reply");
        service
            .create_reply(
                campus_id,
                first.id,
                &owner,
                "谢谢，我再补充一条。".to_string(),
                Some(root_reply.id),
            )
            .await
            .expect("create nested reply");

        let cross_post_parent = service
            .create_reply(
                campus_id,
                second.id,
                &other,
                "不应该接受这个父回复。".to_string(),
                Some(root_reply.id),
            )
            .await;
        assert!(matches!(cross_post_parent, Err(ApiError::BadRequest(_))));
        assert_eq!(
            service.get(campus_id, first.id).await.unwrap().reply_count,
            2
        );

        let foreign_edit = service
            .update(
                campus_id,
                first.id,
                &other,
                EditDiscussion {
                    title: Some("越权编辑".to_string()),
                    ..Default::default()
                },
            )
            .await;
        assert!(matches!(foreign_edit, Err(ApiError::Forbidden)));

        let locked = service
            .update(
                campus_id,
                first.id,
                &owner,
                EditDiscussion {
                    locked: Some(true),
                    ..Default::default()
                },
            )
            .await
            .expect("lock own topic");
        assert_eq!(locked.status, "locked");
        let locked_reply = service
            .create_reply(
                campus_id,
                first.id,
                &other,
                "锁定后不能回复。".to_string(),
                None,
            )
            .await;
        assert!(matches!(locked_reply, Err(ApiError::Conflict(_))));

        let foreign_reply_delete = service
            .delete_reply(campus_id, first.id, root_reply.id, &owner)
            .await;
        assert!(matches!(foreign_reply_delete, Err(ApiError::Forbidden)));
        service
            .delete_reply(campus_id, first.id, root_reply.id, &other)
            .await
            .expect("reply author can delete");
        assert_eq!(
            service.get(campus_id, first.id).await.unwrap().reply_count,
            1
        );

        let (items, total) = service
            .list(
                campus_id,
                &PostFilter {
                    post_type: Some("discussion".to_string()),
                    direction: None,
                    category: Some("campus-life".to_string()),
                    search: Some("宿舍".to_string()),
                    sort: PostSort::Replies,
                },
                20,
                0,
            )
            .await
            .expect("filtered discussion list");
        assert_eq!(total, 1);
        assert_eq!(items[0].id, first.id);
    })
    .await;
}

#[tokio::test]
async fn discussion_images_stay_private_until_moderation_approval() {
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let owner = user(&pool, "image-owner").await;
        let service = PostService::new(pool.clone(), ModerationService::new_for_test(true));
        let image_url = "https://cdn.example.test/campus-night-market.jpg";

        let created = service
            .create(CreateDiscussion {
                campus_id,
                author_id: owner,
                title: "夜市摊位位置分享".to_string(),
                body: "把今晚的摊位分布图放在封面，方便大家在首页先看到。".to_string(),
                category: Some("campus-life".to_string()),
                tags: vec!["夜市".to_string()],
                cover_image_url: Some(image_url.to_string()),
            })
            .await
            .expect("create discussion with image");

        assert_eq!(created.cover_image_url, None, "pending media stays private");
        let moderation_status: String =
            sqlx::query_scalar("SELECT images_moderation_status FROM posts WHERE id = $1")
                .bind(created.id)
                .fetch_one(&pool)
                .await
                .expect("read post moderation status");
        assert_eq!(moderation_status, "pending");
        let queued_jobs: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM moderation_jobs
             WHERE resource_type = 'post_image' AND resource_id = $1",
        )
        .bind(created.id.to_string())
        .fetch_one(&pool)
        .await
        .expect("count post image jobs");
        assert_eq!(queued_jobs, 1);

        sqlx::query("UPDATE posts SET images_moderation_status = 'approved' WHERE id = $1")
            .bind(created.id)
            .execute(&pool)
            .await
            .expect("approve post image");
        let approved = service
            .get(campus_id, created.id)
            .await
            .expect("fetch approved post image");
        assert_eq!(approved.cover_image_url.as_deref(), Some(image_url));
    })
    .await;
}

#[tokio::test]
async fn every_listing_is_a_synced_post_and_visibility_follows_listing_policy() {
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let owner = user(&pool, "seller").await;
        let service = service(&pool);
        let listing_id = format!("listing-post-{}", Uuid::new_v4().simple());

        sqlx::query(
            "INSERT INTO inventory (
                 id, campus_id, title, category, brand, direction,
                 condition_score, suggested_price_cny, defects, description,
                 image_url, images_moderation_status, owner_id, status
             ) VALUES ($1, $2, '旧标题', 'electronics', 'Brand', 'offer',
                       8, 10000, '[]', '旧正文', 'https://example.invalid/item.jpg',
                       'pending', $3, 'active')",
        )
        .bind(&listing_id)
        .bind(campus_id)
        .bind(&owner)
        .execute(&pool)
        .await
        .expect("insert legacy-compatible listing");

        let projected = service
            .get_by_listing(campus_id, &listing_id)
            .await
            .expect("listing post projection");
        assert_eq!(projected.post_type, "listing");
        assert_eq!(projected.listing_id.as_deref(), Some(listing_id.as_str()));
        assert_eq!(projected.title, "旧标题");
        assert_eq!(projected.body, "旧正文");
        assert_eq!(
            projected.cover_image_url, None,
            "pending media stays private"
        );
        let listing_preview = projected.listing.as_ref().expect("listing preview");
        assert_eq!(listing_preview.suggested_price_cny, 10_000);
        assert_eq!(listing_preview.direction, "offer");
        assert_eq!(listing_preview.condition_score, 8);

        let (offered, total) = service
            .list(
                campus_id,
                &PostFilter {
                    post_type: Some("listing".to_string()),
                    direction: Some("offer".to_string()),
                    ..Default::default()
                },
                20,
                0,
            )
            .await
            .expect("offer direction filter");
        assert_eq!(total, 1);
        assert_eq!(offered[0].id, projected.id);

        let (_, wanted_total) = service
            .list(
                campus_id,
                &PostFilter {
                    post_type: Some("listing".to_string()),
                    direction: Some("wanted".to_string()),
                    ..Default::default()
                },
                20,
                0,
            )
            .await
            .expect("wanted direction filter");
        assert_eq!(wanted_total, 0);

        sqlx::query(
            "UPDATE inventory
             SET title = '新标题', description = '新正文', category = 'appliances',
                 images_moderation_status = 'approved'
             WHERE id = $1",
        )
        .bind(&listing_id)
        .execute(&pool)
        .await
        .expect("update listing");
        let synced = service
            .get_by_listing(campus_id, &listing_id)
            .await
            .expect("synced listing post");
        assert_eq!(synced.title, "新标题");
        assert_eq!(synced.body, "新正文");
        assert_eq!(synced.category, "appliances");
        assert!(
            synced.cover_image_url.is_some(),
            "approved media is eligible"
        );

        sqlx::query("UPDATE inventory SET status = 'sold' WHERE id = $1")
            .bind(&listing_id)
            .execute(&pool)
            .await
            .expect("archive listing");
        assert!(matches!(
            service.get_by_listing(campus_id, &listing_id).await,
            Err(ApiError::NotFound)
        ));

        sqlx::query("UPDATE inventory SET status = 'active' WHERE id = $1")
            .bind(&listing_id)
            .execute(&pool)
            .await
            .expect("relist");
        let case_id: Uuid = sqlx::query_scalar(
            "INSERT INTO moderation_cases (
                 campus_id, subject_user_id, resource_type, resource_id,
                 source_type, source_ref_id, status, reason_category,
                 public_reason, resolution
             ) VALUES ($1, $2, 'listing', $3, 'manual', $4, 'actioned',
                       'test', '测试限制', 'content_restricted')
             RETURNING id",
        )
        .bind(campus_id)
        .bind(&owner)
        .bind(&listing_id)
        .bind(format!("post-test:{listing_id}"))
        .fetch_one(&pool)
        .await
        .expect("create moderation case");
        sqlx::query(
            "INSERT INTO listing_restriction_effects (
                 campus_id, listing_id, case_id, source_kind
             ) VALUES ($1, $2, $3, 'moderation_case')",
        )
        .bind(campus_id)
        .bind(&listing_id)
        .bind(case_id)
        .execute(&pool)
        .await
        .expect("restrict listing");

        assert!(matches!(
            service.get_by_listing(campus_id, &listing_id).await,
            Err(ApiError::NotFound)
        ));
    })
    .await;
}

#[tokio::test]
async fn for_you_ranker_uses_post_interactions_and_keeps_total_consistent() {
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let author = user(&pool, "rank-author").await;
        let viewer = user(&pool, "rank-viewer").await;
        let service = service(&pool);

        let relevant = service
            .create(CreateDiscussion {
                campus_id,
                author_id: author.clone(),
                title: "二手教材交换".to_string(),
                body: "本学期教材可以在校内交换。".to_string(),
                category: Some("Books".to_string()),
                tags: vec!["教材".to_string()],
                cover_image_url: None,
            })
            .await
            .expect("relevant post");
        let unrelated = service
            .create(CreateDiscussion {
                campus_id,
                author_id: author.clone(),
                title: "周末球局".to_string(),
                body: "周末一起打球。".to_string(),
                category: Some("sports".to_string()),
                tags: vec![],
                cover_image_url: None,
            })
            .await
            .expect("unrelated post");
        let similar_sports = service
            .create(CreateDiscussion {
                campus_id,
                author_id: author.clone(),
                title: "校园跑步路线".to_string(),
                body: "分享一条适合夜跑的路线。".to_string(),
                category: Some("Sports".to_string()),
                tags: vec![],
                cover_image_url: None,
            })
            .await
            .expect("same category post");
        let viewer_own = service
            .create(CreateDiscussion {
                campus_id,
                author_id: viewer.clone(),
                title: "我的校园日记".to_string(),
                body: "这条不应出现在自己的 for_you 流。".to_string(),
                category: Some("books".to_string()),
                tags: vec![],
                cover_image_url: None,
            })
            .await
            .expect("viewer post");

        service
            .create_reply(
                campus_id,
                relevant.id,
                &viewer,
                "我正在找这类教材。".to_string(),
                None,
            )
            .await
            .expect("viewer interaction");

        let filter = PostFilter {
            sort: PostSort::ForYou,
            ..Default::default()
        };
        let (items, total) = service
            .list_for_viewer(campus_id, Some(&viewer), &filter, 50, 0)
            .await
            .expect("personalized posts");
        assert_eq!(total, items.len() as i64, "total follows exclusions");
        assert!(!items.iter().any(|post| post.id == viewer_own.id));
        assert_eq!(items.first().map(|post| post.id), Some(relevant.id));
        assert_eq!(
            items.first().map(|post| post.rank_source.as_str()),
            Some("category_affinity")
        );
        assert!(items.first().and_then(|post| post.ranking_score).is_some());

        let search_filter = PostFilter {
            search: Some("教材".to_string()),
            sort: PostSort::ForYou,
            ..Default::default()
        };
        let (search_items, search_total) = service
            .list_for_viewer(campus_id, Some(&viewer), &search_filter, 50, 0)
            .await
            .expect("personalized search");
        assert_eq!(search_total, search_items.len() as i64);
        assert!(search_items.iter().any(|post| post.id == relevant.id));

        let escaped_search_filter = PostFilter {
            search: Some("%".to_string()),
            sort: PostSort::ForYou,
            ..Default::default()
        };
        let (escaped_items, escaped_total) = service
            .list_for_viewer(campus_id, Some(&viewer), &escaped_search_filter, 50, 0)
            .await
            .expect("personalized search escapes wildcard input");
        assert_eq!(escaped_total, 0);
        assert!(escaped_items.is_empty());

        FeedService::new(pool.clone())
            .submit_feedback(
                campus_id,
                &viewer,
                FeedResourceType::Post,
                &relevant.id.to_string(),
                FeedFeedbackAction::Hide,
            )
            .await
            .expect("post feedback");
        let (after_hide, hidden_total) = service
            .list_for_viewer(campus_id, Some(&viewer), &filter, 50, 0)
            .await
            .expect("personalized posts after hide");
        assert_eq!(hidden_total, after_hide.len() as i64);
        assert!(!after_hide.iter().any(|post| post.id == relevant.id));
        assert!(!after_hide.iter().any(|post| post.id == viewer_own.id));
        assert!(after_hide.iter().any(|post| post.id == unrelated.id));

        FeedService::new(pool.clone())
            .submit_feedback(
                campus_id,
                &viewer,
                FeedResourceType::Post,
                &unrelated.id.to_string(),
                FeedFeedbackAction::LessLikeThis,
            )
            .await
            .expect("category downrank feedback");
        let (after_downrank, _) = service
            .list_for_viewer(campus_id, Some(&viewer), &filter, 50, 0)
            .await
            .expect("personalized posts after downrank");
        let downranked = after_downrank
            .iter()
            .find(|post| post.id == similar_sports.id)
            .and_then(|post| post.ranking_score)
            .expect("downranked score");
        assert!(downranked < 0.0, "less_like should lower category score");

        FeedService::new(pool.clone())
            .update_preferences(campus_id, &viewer, false)
            .await
            .expect("disable personalization");
        let (disabled_items, disabled_total) = service
            .list_for_viewer(campus_id, Some(&viewer), &filter, 50, 0)
            .await
            .expect("non-personalized posts");
        assert_eq!(disabled_total, disabled_items.len() as i64);
        assert!(disabled_items
            .iter()
            .all(|post| post.rank_source == "recency" || post.rank_source == "engagement"));
        let disabled_unrelated_score = disabled_items
            .iter()
            .find(|post| post.id == similar_sports.id)
            .and_then(|post| post.ranking_score)
            .expect("disabled score");
        assert!(disabled_unrelated_score > 0.0);
    })
    .await;
}
