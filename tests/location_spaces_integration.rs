//! Integration coverage for campus location chat-space hierarchy and privacy.

use goods4ncu::api::error::ApiError;
use goods4ncu::services::location_space::LocationSpaceService;
use goods4ncu::test_infra::with_test_pool;
use uuid::Uuid;

const NCU_ID: &str = "c0000000-0000-0000-0000-000000000001";

async fn insert_verified_user(pool: &sqlx::PgPool, tag: &str) -> String {
    let id = format!("location-{tag}-{}", Uuid::new_v4().simple());
    sqlx::query("INSERT INTO users (id, username, password_hash) VALUES ($1, $2, 'hash')")
        .bind(&id)
        .bind(format!("location_{tag}_{}", Uuid::new_v4().simple()))
        .execute(pool)
        .await
        .expect("insert user");
    sqlx::query(
        "INSERT INTO campus_memberships (
             campus_id, user_id, status, role, verification_method, verified_at
         ) VALUES ($1, $2, 'verified', 'member', 'test_fixture', NOW())",
    )
    .bind(Uuid::parse_str(NCU_ID).unwrap())
    .bind(&id)
    .execute(pool)
    .await
    .expect("insert verified membership");
    id
}

async fn insert_location_fixture(pool: &sqlx::PgPool) -> (Uuid, Uuid) {
    let campus_id = Uuid::parse_str(NCU_ID).unwrap();
    let root_id = Uuid::new_v4();
    let leaf_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO chat_spaces (
             id, campus_id, kind, name, owner_id, status, origin,
             parent_space_id, location_slug, location_kind,
             latitude, longitude, radius_meters, allows_child_spaces,
             location_sort_order
         ) VALUES
         ($1, $3, 'group', '测试主校区', NULL, 'active', 'campus_location',
          NULL, 'test-campus', 'campus', 28.660, 115.800, 1800, FALSE, 10),
         ($2, $3, 'group', '测试叶地点', NULL, 'active', 'campus_location',
          $1, 'test-leaf', 'landmark', 28.660, 115.800, 300, TRUE, 10)",
    )
    .bind(root_id)
    .bind(leaf_id)
    .bind(campus_id)
    .execute(pool)
    .await
    .expect("insert location hierarchy");
    (root_id, leaf_id)
}

#[tokio::test]
async fn recommendation_prefers_the_smallest_geofence_and_never_persists_coordinates() {
    with_test_pool(|pool| async move {
        let campus_id = Uuid::parse_str(NCU_ID).unwrap();
        let user_id = insert_verified_user(&pool, "nearby").await;
        let (root_id, leaf_id) = insert_location_fixture(&pool).await;
        let directory_id = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO chat_spaces (
                 id, campus_id, kind, name, owner_id, status, origin,
                 parent_space_id, location_slug, location_kind,
                 latitude, longitude, radius_meters, allows_child_spaces,
                 location_sort_order
             ) VALUES (
                 $1, $2, 'group', '测试手动地点', NULL, 'active',
                 'campus_location', $3, 'test-directory', 'facility',
                 NULL, NULL, NULL, TRUE, 20
             )",
        )
        .bind(directory_id)
        .bind(campus_id)
        .bind(root_id)
        .execute(&pool)
        .await
        .expect("insert manual-only directory place");
        let service = LocationSpaceService::new(pool.clone());

        let before_spaces: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM chat_spaces")
            .fetch_one(&pool)
            .await
            .unwrap();
        let before_members: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM chat_space_members")
            .fetch_one(&pool)
            .await
            .unwrap();
        let recommendation = service
            .recommend(campus_id, &user_id, 28.6601, 115.8001)
            .await
            .expect("recommend location");
        assert!(recommendation.matched);
        assert_eq!(recommendation.space.unwrap().id, leaf_id);
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM chat_spaces")
                .fetch_one(&pool)
                .await
                .unwrap(),
            before_spaces
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM chat_space_members")
                .fetch_one(&pool)
                .await
                .unwrap(),
            before_members
        );

        let tree = service
            .tree(campus_id, &user_id)
            .await
            .expect("location tree");
        assert_eq!(tree.items.len(), 1);
        assert_eq!(tree.items[0].children.len(), 2);
        let leaf = tree.items[0]
            .children
            .iter()
            .find(|space| space.id == leaf_id)
            .expect("geofenced leaf in tree");
        assert!(!leaf.is_member);
        assert_eq!(leaf.location_slug.as_deref(), Some("test-leaf"));
        assert_eq!(leaf.online_count, 0);
        assert!(leaf.location_matchable);
        let directory = tree.items[0]
            .children
            .iter()
            .find(|space| space.id == directory_id)
            .expect("manual-only directory place in tree");
        assert!(!directory.location_matchable);

        service
            .join(campus_id, &user_id, leaf_id)
            .await
            .expect("join official leaf");
        let joined_tree = service.tree(campus_id, &user_id).await.unwrap();
        assert!(
            joined_tree.items[0]
                .children
                .iter()
                .find(|space| space.id == leaf_id)
                .unwrap()
                .is_member
        );
    })
    .await;
}

#[tokio::test]
async fn location_chat_presence_is_ephemeral_and_does_not_require_membership() {
    with_test_pool(|pool| async move {
        let campus_id = Uuid::parse_str(NCU_ID).unwrap();
        let first_user = insert_verified_user(&pool, "presence-first").await;
        let second_user = insert_verified_user(&pool, "presence-second").await;
        let (_, leaf_id) = insert_location_fixture(&pool).await;
        let service = LocationSpaceService::new(pool.clone());

        let ordinary_space_id = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO chat_spaces (
                 id, campus_id, kind, name, owner_id, status, origin
             ) VALUES ($1, $2, 'group', '普通群组', $3, 'active', 'manual')",
        )
        .bind(ordinary_space_id)
        .bind(campus_id)
        .bind(&first_user)
        .execute(&pool)
        .await
        .unwrap();
        assert!(!service
            .has_transient_chat_access(campus_id, &second_user, ordinary_space_id)
            .await
            .expect("ordinary groups keep membership access"));

        assert!(service
            .has_transient_chat_access(campus_id, &first_user, leaf_id)
            .await
            .expect("location visitor access"));

        let first = service
            .heartbeat_presence(campus_id, &first_user, leaf_id, true)
            .await
            .expect("first heartbeat");
        assert!(first.active);
        assert_eq!(first.online_count, 1);
        assert_eq!(first.ttl_seconds, 90);
        assert!(first.expires_at.is_some());

        let second = service
            .heartbeat_presence(campus_id, &second_user, leaf_id, true)
            .await
            .expect("second heartbeat");
        assert_eq!(second.online_count, 2);

        let durable_members: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM chat_space_members WHERE space_id = $1")
                .bind(leaf_id)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(durable_members, 0, "heartbeats must not join the room");

        let tree = service.tree(campus_id, &first_user).await.unwrap();
        assert_eq!(tree.items[0].children[0].online_count, 2);

        let departed = service
            .heartbeat_presence(campus_id, &first_user, leaf_id, false)
            .await
            .expect("explicit departure");
        assert!(!departed.active);
        assert_eq!(departed.online_count, 1);

        sqlx::query(
            "UPDATE chat_space_presence
                SET expires_at = NOW() - INTERVAL '1 second'
              WHERE space_id = $1 AND user_id = $2",
        )
        .bind(leaf_id)
        .bind(&second_user)
        .execute(&pool)
        .await
        .unwrap();
        let expired = service
            .presence(campus_id, &first_user, leaf_id)
            .await
            .expect("expired count");
        assert!(!expired.active);
        assert_eq!(expired.online_count, 0);

        sqlx::query(
            "INSERT INTO chat_space_members (space_id, user_id, role)
             VALUES ($1, $2, 'banned')",
        )
        .bind(leaf_id)
        .bind(&first_user)
        .execute(&pool)
        .await
        .unwrap();
        assert!(matches!(
            service
                .has_transient_chat_access(campus_id, &first_user, leaf_id)
                .await,
            Err(ApiError::Forbidden)
        ));
    })
    .await;
}

#[tokio::test]
async fn child_rooms_require_joined_official_leaves_and_stay_in_the_active_campus() {
    with_test_pool(|pool| async move {
        let campus_id = Uuid::parse_str(NCU_ID).unwrap();
        let owner_id = insert_verified_user(&pool, "owner").await;
        let other_id = insert_verified_user(&pool, "other").await;
        let (root_id, leaf_id) = insert_location_fixture(&pool).await;
        let service = LocationSpaceService::new(pool.clone());

        assert!(matches!(
            service
                .create_child(campus_id, &owner_id, leaf_id, "未加入不能创建", None)
                .await,
            Err(ApiError::Forbidden)
        ));
        service.join(campus_id, &owner_id, leaf_id).await.unwrap();
        assert!(matches!(
            service
                .create_child(campus_id, &owner_id, root_id, "主节点子群", None)
                .await,
            Err(ApiError::CodedConflict {
                code: "location_parent_not_leaf",
                ..
            })
        ));

        let child_id = service
            .create_child(
                campus_id,
                &owner_id,
                leaf_id,
                "今晚八点跑步",
                Some("天健操场集合"),
            )
            .await
            .expect("create child room");
        let role: String = sqlx::query_scalar(
            "SELECT role FROM chat_space_members WHERE space_id = $1 AND user_id = $2",
        )
        .bind(child_id)
        .bind(&owner_id)
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(role, "owner");
        assert!(matches!(
            service
                .create_child(campus_id, &owner_id, child_id, "不能继续嵌套", None)
                .await,
            Err(ApiError::CodedConflict {
                code: "location_parent_not_leaf",
                ..
            })
        ));
        assert!(matches!(
            service
                .create_child(campus_id, &owner_id, leaf_id, "今晚八点跑步", None)
                .await,
            Err(ApiError::CodedConflict {
                code: "location_child_name_taken",
                ..
            })
        ));

        let other_campus_id = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO campuses (id, slug, name_zh, name_en)
             VALUES ($1, $2, '测试校区', 'Test Campus')",
        )
        .bind(other_campus_id)
        .bind(format!("test-campus-{}", Uuid::new_v4().simple()))
        .execute(&pool)
        .await
        .unwrap();
        assert!(matches!(
            service.join(other_campus_id, &other_id, leaf_id).await,
            Err(ApiError::NotFound)
        ));
    })
    .await;
}
