//! Integration coverage for unified posts (offer/wanted/discussion),
//! curated tags, category taxonomy, group visibility and threaded replies.

use goods4ncu::api::error::ApiError;
use goods4ncu::config::AppConfig;
use goods4ncu::repositories::{PostFilter, PostSort};
use goods4ncu::services::feed::{FeedFeedbackAction, FeedResourceType, FeedService};
use goods4ncu::services::moderation::ModerationService;
use goods4ncu::services::post::{CreatePost, EditPost, PostService};
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

async fn create_group(pool: &sqlx::PgPool, campus_id: Uuid, owner: &str, name: &str) -> Uuid {
    sqlx::query_scalar(
        "INSERT INTO chat_spaces (campus_id, kind, name, owner_id)
         VALUES ($1, 'group', $2, $3) RETURNING id",
    )
    .bind(campus_id)
    .bind(name)
    .bind(owner)
    .fetch_one(pool)
    .await
    .expect("create group space")
}

async fn join_group(pool: &sqlx::PgPool, space_id: Uuid, user_id: &str) {
    sqlx::query(
        "INSERT INTO chat_space_members (space_id, user_id, role) VALUES ($1, $2, 'member')",
    )
    .bind(space_id)
    .bind(user_id)
    .execute(pool)
    .await
    .expect("join group");
}

#[tokio::test]
async fn tags_must_come_from_the_catalog_and_respect_groups() {
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let author = user(&pool, "tag-author").await;
        let service = service(&pool);

        // Unknown tag rejected.
        let unknown = service
            .create(CreatePost {
                campus_id,
                author_id: author.clone(),
                category: "discussion".to_string(),
                title: "自造标签不允许".to_string(),
                body: "正文".to_string(),
                tags: vec!["我的自制标签".to_string()],
                cover_image_url: None,
                listing_id: None,
                space_id: None,
                attributes: serde_json::json!({}),
            })
            .await;
        assert!(matches!(unknown, Err(ApiError::BadRequest(_))));

        // Two tags from the same exclusive group are rejected.
        let duplicate_group = service
            .create(CreatePost {
                campus_id,
                author_id: author.clone(),
                category: "wanted".to_string(),
                title: "地点标签只能选一个".to_string(),
                body: "正文".to_string(),
                tags: vec!["qianhuNorth".to_string(), "qianhuSouth".to_string()],
                cover_image_url: None,
                listing_id: None,
                space_id: None,
                attributes: serde_json::json!({}),
            })
            .await;
        assert!(matches!(duplicate_group, Err(ApiError::BadRequest(_))));

        // Structured attributes on a category that has none are rejected.
        let stray_attributes = service
            .create(CreatePost {
                campus_id,
                author_id: author.clone(),
                category: "discussion".to_string(),
                title: "讨论帖不带结构化属性".to_string(),
                body: "正文".to_string(),
                tags: vec![],
                cover_image_url: None,
                listing_id: None,
                space_id: None,
                attributes: serde_json::json!({"starts_at": "2026-09-01T10:00:00Z"}),
            })
            .await;
        assert!(matches!(stray_attributes, Err(ApiError::BadRequest(_))));

        // Valid global tag passes.
        let ok = service
            .create(CreatePost {
                campus_id,
                author_id: author,
                category: "discussion".to_string(),
                title: "提问：期末复习资料哪里找".to_string(),
                body: "欢迎分享经验。".to_string(),
                tags: vec!["question".to_string(), "share".to_string()],
                cover_image_url: None,
                listing_id: None,
                space_id: None,
                attributes: serde_json::json!({}),
            })
            .await
            .expect("catalog tags accepted");
        assert_eq!(ok.tags, vec!["question", "share"]);
    })
    .await;
}

#[tokio::test]
async fn group_posts_are_hidden_from_non_members_and_feeds() {
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let owner = user(&pool, "group-owner").await;
        let member = user(&pool, "group-member").await;
        let outsider = user(&pool, "group-outsider").await;
        let service = service(&pool);

        let space_id = create_group(&pool, campus_id, &owner, "宿舍六栋群").await;
        join_group(&pool, space_id, &owner).await;
        join_group(&pool, space_id, &member).await;

        let group_post = service
            .create(CreatePost {
                campus_id,
                author_id: owner.clone(),
                category: "discussion".to_string(),
                title: "本群内部公告".to_string(),
                body: "只有群成员可以看到这条。".to_string(),
                tags: vec!["share".to_string()],
                cover_image_url: None,
                listing_id: None,
                space_id: Some(space_id),
                attributes: serde_json::json!({}),
            })
            .await
            .expect("create group post");

        // Anonymous / outsider feeds never include it.
        for viewer in [None, Some(outsider.as_str())] {
            let (items, _) = service
                .list_for_viewer(campus_id, viewer, &PostFilter::default(), 50, 0)
                .await
                .expect("public feed");
            assert!(!items.iter().any(|post| post.id == group_post.id));
        }

        // Direct detail access is member-gated too.
        assert!(matches!(
            service
                .get_for_viewer(campus_id, group_post.id, Some(outsider.as_str()))
                .await,
            Err(ApiError::NotFound)
        ));
        let visible_to_member = service
            .get_for_viewer(campus_id, group_post.id, Some(member.as_str()))
            .await
            .expect("member reads group post");
        assert_eq!(visible_to_member.space_id, Some(space_id));

        // Member feed includes it; space filter narrows to the group.
        let (member_items, _) = service
            .list_for_viewer(
                campus_id,
                Some(member.as_str()),
                &PostFilter {
                    space_id: Some(space_id),
                    ..Default::default()
                },
                50,
                0,
            )
            .await
            .expect("space-filtered feed");
        assert_eq!(member_items.len(), 1);
        assert_eq!(member_items[0].id, group_post.id);
    })
    .await;
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
            .create(CreatePost {
                campus_id,
                author_id: owner.clone(),
                category: "discussion".to_string(),
                title: "campusp0licytoken".to_string(),
                body: "用于验证发布入口在写库前执行统一审查。".to_string(),
                tags: vec![],
                cover_image_url: None,
                listing_id: None,
                space_id: None,
                attributes: serde_json::json!({}),
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
            .create(CreatePost {
                campus_id,
                author_id: owner.clone(),
                category: "discussion".to_string(),
                title: "毕业季宿舍整理经验".to_string(),
                body: "把同类物品放在一起，标题写清楚楼栋和取货时间。".to_string(),
                tags: vec!["share".to_string()],
                cover_image_url: None,
                listing_id: None,
                space_id: None,
                attributes: serde_json::json!({}),
            })
            .await
            .expect("create discussion");
        let second = service
            .create(CreatePost {
                campus_id,
                author_id: owner.clone(),
                category: "discussion".to_string(),
                title: "另一个主题".to_string(),
                body: "用于验证跨主题引用会被拒绝。".to_string(),
                tags: vec![],
                cover_image_url: None,
                listing_id: None,
                space_id: None,
                attributes: serde_json::json!({}),
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
            service
                .get_for_viewer(campus_id, first.id, None)
                .await
                .unwrap()
                .reply_count,
            2
        );

        let foreign_edit = service
            .update(
                campus_id,
                first.id,
                &other,
                EditPost {
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
                EditPost {
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
            service
                .get_for_viewer(campus_id, first.id, None)
                .await
                .unwrap()
                .reply_count,
            1
        );

        let (items, total) = service
            .list_for_viewer(
                campus_id,
                None,
                &PostFilter {
                    search: Some("宿舍".to_string()),
                    sort: PostSort::Replies,
                    ..Default::default()
                },
                20,
                0,
            )
            .await
            .expect("filtered search list");
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
            .create(CreatePost {
                campus_id,
                author_id: owner,
                category: "discussion".to_string(),
                title: "夜市摊位位置分享".to_string(),
                body: "把今晚的摊位分布图放在封面，方便大家在首页先看到。".to_string(),
                tags: vec![],
                cover_image_url: Some(image_url.to_string()),
                listing_id: None,
                space_id: None,
                attributes: serde_json::json!({}),
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
async fn listings_are_references_and_marketplace_filters_follow_category() {
    with_test_pool(|pool| async move {
        let campus_id = campus(&pool).await;
        let owner = user(&pool, "seller").await;
        let service = service(&pool);
        let listing_id = format!("listing-ref-{}", Uuid::new_v4().simple());

        sqlx::query(
            "INSERT INTO inventory (
                 id, campus_id, title, category, brand, direction,
                 condition_score, suggested_price_cny, defects, description,
                 image_url, images_moderation_status, owner_id, status
             ) VALUES ($1, $2, '二手显示器', 'electronics', 'Brand', 'offer',
                       8, 10000, '[]', '九成新显示器', NULL,
                       'approved', $3, 'active')",
        )
        .bind(&listing_id)
        .bind(campus_id)
        .bind(&owner)
        .execute(&pool)
        .await
        .expect("insert referenced listing");

        // No mirrored post exists until someone writes one referencing it.
        let pre_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM posts WHERE listing_id = $1")
            .bind(&listing_id)
            .fetch_one(&pool)
            .await
            .expect("count referencing posts");
        assert_eq!(pre_count, 0, "listings are no longer auto-projected");

        let offer_post = service
            .create(CreatePost {
                campus_id,
                author_id: owner.clone(),
                category: "offer".to_string(),
                title: "出二手显示器，可小刀".to_string(),
                body: "自提优先，宿舍楼下交易。".to_string(),
                tags: vec!["likeNew".to_string(), "negotiable".to_string()],
                cover_image_url: None,
                listing_id: Some(listing_id.clone()),
                space_id: None,
                attributes: serde_json::json!({}),
            })
            .await
            .expect("create offer post with reference");
        assert_eq!(offer_post.listing_id.as_deref(), Some(listing_id.as_str()));
        let preview = offer_post.listing.as_ref().expect("listing preview");
        assert_eq!(preview.suggested_price_cny, 10_000);
        assert_eq!(preview.direction, "offer");

        let (offered, _) = service
            .list_for_viewer(
                campus_id,
                None,
                &PostFilter {
                    category: Some("offer".to_string()),
                    ..Default::default()
                },
                20,
                0,
            )
            .await
            .expect("offer category filter");
        assert!(offered.iter().any(|post| post.id == offer_post.id));

        let (_, wanted_total) = service
            .list_for_viewer(
                campus_id,
                None,
                &PostFilter {
                    category: Some("wanted".to_string()),
                    ..Default::default()
                },
                20,
                0,
            )
            .await
            .expect("wanted category filter");
        assert_eq!(wanted_total, 0);

        // Restricting the referenced listing hides the post from feeds/detail.
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

        let hidden = service
            .list_for_viewer(
                campus_id,
                None,
                &PostFilter {
                    category: Some("offer".to_string()),
                    search: Some("显示器".to_string()),
                    ..Default::default()
                },
                20,
                0,
            )
            .await
            .expect("search after restriction");
        assert!(
            !hidden.0.iter().any(|post| post.id == offer_post.id),
            "restricted listing reference hides the post"
        );
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
            .create(CreatePost {
                campus_id,
                author_id: author.clone(),
                category: "discussion".to_string(),
                title: "二手教材交换".to_string(),
                body: "本学期教材可以在校内交换。".to_string(),
                tags: vec!["share".to_string()],
                cover_image_url: None,
                listing_id: None,
                space_id: None,
                attributes: serde_json::json!({}),
            })
            .await
            .expect("relevant post");
        let unrelated = service
            .create(CreatePost {
                campus_id,
                author_id: author.clone(),
                category: "discussion".to_string(),
                title: "周末球局".to_string(),
                body: "周末一起打球。".to_string(),
                tags: vec!["share".to_string()],
                cover_image_url: None,
                listing_id: None,
                space_id: None,
                attributes: serde_json::json!({}),
            })
            .await
            .expect("unrelated post");
        let similar_share = service
            .create(CreatePost {
                campus_id,
                author_id: author.clone(),
                category: "discussion".to_string(),
                title: "校园跑步路线".to_string(),
                body: "分享一条适合夜跑的路线。".to_string(),
                tags: vec!["share".to_string()],
                cover_image_url: None,
                listing_id: None,
                space_id: None,
                attributes: serde_json::json!({}),
            })
            .await
            .expect("same tag post");
        let viewer_own = service
            .create(CreatePost {
                campus_id,
                author_id: viewer.clone(),
                category: "discussion".to_string(),
                title: "我的校园日记".to_string(),
                body: "这条不应出现在自己的 for_you 流。".to_string(),
                tags: vec![],
                cover_image_url: None,
                listing_id: None,
                space_id: None,
                attributes: serde_json::json!({}),
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
        assert!(after_hide.iter().any(|post| post.id == unrelated.id));

        // All discussion posts share one category now, so capture the score
        // first and assert the less_like event strictly lowers it.
        let before_downrank = service
            .list_for_viewer(campus_id, Some(&viewer), &filter, 50, 0)
            .await
            .expect("posts before downrank");
        let score_before = before_downrank
            .0
            .iter()
            .find(|post| post.id == similar_share.id)
            .and_then(|post| post.ranking_score)
            .expect("score before downrank");

        FeedService::new(pool.clone())
            .submit_feedback(
                campus_id,
                &viewer,
                FeedResourceType::Post,
                &unrelated.id.to_string(),
                FeedFeedbackAction::LessLikeThis,
            )
            .await
            .expect("downrank feedback");
        let (after_downrank, _) = service
            .list_for_viewer(campus_id, Some(&viewer), &filter, 50, 0)
            .await
            .expect("posts after downrank");
        let score_after = after_downrank
            .iter()
            .find(|post| post.id == similar_share.id)
            .and_then(|post| post.ranking_score)
            .expect("score after downrank");
        assert!(
            score_after < score_before,
            "less_like should lower the score: {score_before} -> {score_after}"
        );
    })
    .await;
}
