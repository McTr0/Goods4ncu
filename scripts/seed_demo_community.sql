\set ON_ERROR_STOP on

-- Local-only fixtures for the unified campus feed.
-- Run from the repository root:
--   psql "$DATABASE_URL" -f scripts/seed_demo_community.sql
--
-- Fixed IDs make the script repeatable. It updates only the rows declared
-- below and never deletes user-created content. The fixtures intentionally
-- form small connected scenarios: offer <-> wanted responses, listing posts,
-- discussion topics, replies, and reply-to references.

BEGIN;

-- Two idle offers and four wanted listings. Inventory remains authoritative;
-- the inventory_listing_post_sync trigger creates their listing posts.
INSERT INTO inventory (
    id,
    title,
    category,
    brand,
    condition_score,
    suggested_price_cny,
    defects,
    description,
    image_url,
    images_moderation_status,
    owner_id,
    status,
    direction,
    campus_id,
    created_at
) VALUES
(
    'e1000000-0000-4000-8000-000000000001',
    '毕业季出宿舍台灯，晚十点前可自提',
    'dailyGoods',
    'Home Studio',
    7,
    5500,
    '["灯罩边缘有一处小磕碰"]',
    '用了两个学期，亮度正常。前湖校区北区宿舍自提，适合书桌或床头。',
    '/assets/assets/test_product_images/good4ncu-demo-04.webp',
    'approved',
    's0000000-0000-0000-0000-000000000002',
    'active',
    'offer',
    'c0000000-0000-0000-0000-000000000001',
    NOW() - INTERVAL '85 minutes'
),
(
    'e1000000-0000-4000-8000-000000000002',
    '出数据结构与算法教材，有少量课堂笔记',
    'books',
    '高等教育出版社',
    7,
    3000,
    '["前两章有荧光笔标记"]',
    '数据结构课程用书，笔记主要是老师强调的考点。教学楼或图书馆都可以交接。',
    NULL,
    'approved',
    's0000000-0000-0000-0000-000000000001',
    'active',
    'offer',
    'c0000000-0000-0000-0000-000000000001',
    NOW() - INTERVAL '70 minutes'
),
(
    'e1000000-0000-4000-8000-000000000101',
    '求收宿舍台灯，预算 80 元以内',
    'dailyGoods',
    '不限',
    6,
    8000,
    '[]',
    '新学期搬到北区，想收一盏亮度正常的书桌台灯。工作日晚上方便自提。',
    NULL,
    'approved',
    'b0000000-0000-0000-0000-000000000001',
    'active',
    'wanted',
    'c0000000-0000-0000-0000-000000000001',
    NOW() - INTERVAL '75 minutes'
),
(
    'e1000000-0000-4000-8000-000000000102',
    '求购数据结构与算法教材',
    'books',
    '不限出版社',
    6,
    5000,
    '[]',
    '下周开始上课，版本接近即可；有少量笔记没关系，希望在校内面交。',
    NULL,
    'approved',
    'b0000000-0000-0000-0000-000000000002',
    'active',
    'wanted',
    'c0000000-0000-0000-0000-000000000001',
    NOW() - INTERVAL '65 minutes'
),
(
    'e1000000-0000-4000-8000-000000000103',
    '求一辆校内通勤自行车',
    'other',
    '不限',
    5,
    45000,
    '[]',
    '主要往返宿舍和教学楼，刹车可靠即可。预算 450 元，最好能在周末试骑。',
    NULL,
    'approved',
    'b0000000-0000-0000-0000-000000000001',
    'active',
    'wanted',
    'c0000000-0000-0000-0000-000000000001',
    NOW() - INTERVAL '55 minutes'
),
(
    'e1000000-0000-4000-8000-000000000104',
    '求 AirPods 2 或 3 代，预算 850 元',
    'digitalAccessories',
    'Apple',
    7,
    85000,
    '[]',
    '充电和左右耳功能正常即可，希望能现场连接手机确认序列号与电池情况。',
    NULL,
    'approved',
    'b0000000-0000-0000-0000-000000000002',
    'active',
    'wanted',
    'c0000000-0000-0000-0000-000000000001',
    NOW() - INTERVAL '45 minutes'
)
ON CONFLICT (id) DO UPDATE SET
    title = EXCLUDED.title,
    category = EXCLUDED.category,
    brand = EXCLUDED.brand,
    condition_score = EXCLUDED.condition_score,
    suggested_price_cny = EXCLUDED.suggested_price_cny,
    defects = EXCLUDED.defects,
    description = EXCLUDED.description,
    image_url = EXCLUDED.image_url,
    images_moderation_status = EXCLUDED.images_moderation_status,
    owner_id = EXCLUDED.owner_id,
    status = EXCLUDED.status,
    direction = EXCLUDED.direction,
    campus_id = EXCLUDED.campus_id,
    created_at = EXCLUDED.created_at;

-- Discussion posts cover common campus jobs without introducing a new table
-- per category. The first fixture includes an approved cover image so local
-- homepage testing exercises the discussion-card media path.
INSERT INTO posts (
    id,
    campus_id,
    author_id,
    listing_id,
    category,
    title,
    body,
    tags,
    image_url,
    images_moderation_status,
    status,
    created_at,
    updated_at,
    last_activity_at
) VALUES
(
    'e2000000-0000-4000-8000-000000000001',
    'c0000000-0000-0000-0000-000000000001',
    'b0000000-0000-0000-0000-000000000002',
    NULL,
    'discussion',
    '毕业搬寝：大件闲置怎么交接最省事？',
    '最近准备搬离宿舍，台灯、小桌子和收纳架都要处理。大家一般会在帖子里写哪些信息，才能少来回确认？也想听听约在宿舍楼下交接的经验。',
    '["毕业季", "搬寝", "闲置"]',
    '/assets/assets/test_product_images/good4ncu-demo-04.webp',
    'approved',
    'active',
    NOW() - INTERVAL '42 minutes',
    NOW() - INTERVAL '18 minutes',
    NOW() - INTERVAL '18 minutes'
),
(
    'e2000000-0000-4000-8000-000000000002',
    'c0000000-0000-0000-0000-000000000001',
    'b0000000-0000-0000-0000-000000000001',
    NULL,
    'question',
    '二手教材一般什么时候收最划算？',
    '刚选完课，担心现在买早了会换教材版本。是等老师第一次课确认，还是先在校园里收一本比较稳？有数据结构课程的同学也欢迎分享版本信息。',
    '["教材", "选课", "经验"]',
    NULL,
    'approved',
    'active',
    NOW() - INTERVAL '36 minutes',
    NOW() - INTERVAL '22 minutes',
    NOW() - INTERVAL '22 minutes'
),
(
    'e2000000-0000-4000-8000-000000000003',
    'c0000000-0000-0000-0000-000000000001',
    's0000000-0000-0000-0000-000000000002',
    NULL,
    'recruit',
    '周六下午搬寝，求借手推车半小时',
    '周六 15:00 左右从北区 7 栋搬两箱书到校门口，想借一辆折叠手推车，用完马上送回。可以请一杯奶茶表示感谢。',
    '["互助", "搬寝", "手推车"]',
    NULL,
    'approved',
    'active',
    NOW() - INTERVAL '31 minutes',
    NOW() - INTERVAL '16 minutes',
    NOW() - INTERVAL '16 minutes'
),
(
    'e2000000-0000-4000-8000-000000000004',
    'c0000000-0000-0000-0000-000000000001',
    's0000000-0000-0000-0000-000000000001',
    NULL,
    'announcement',
    '图书馆一楼捡到蓝色校园卡套',
    '今天 16:20 在图书馆一楼打印机旁捡到蓝色卡套。为保护隐私不公开姓名，失主可以说出卡套背面的贴纸图案，我再约地点归还。',
    '["失物招领", "图书馆", "校园卡"]',
    NULL,
    'approved',
    'active',
    NOW() - INTERVAL '24 minutes',
    NOW() - INTERVAL '12 minutes',
    NOW() - INTERVAL '12 minutes'
),
(
    'e2000000-0000-4000-8000-000000000005',
    'c0000000-0000-0000-0000-000000000001',
    'b0000000-0000-0000-0000-000000000002',
    NULL,
    'team_up',
    '今晚 7 点青山湖慢跑，缺两位搭子',
    '从北门集合，计划慢跑 5 公里，配速大约 7 分钟。新手友好，下雨就改到明晚，想来的直接在楼里回复。',
    '["运动", "跑步", "搭子"]',
    NULL,
    'approved',
    'active',
    NOW() - INTERVAL '19 minutes',
    NOW() - INTERVAL '8 minutes',
    NOW() - INTERVAL '8 minutes'
)
ON CONFLICT (id) DO UPDATE SET
    campus_id = EXCLUDED.campus_id,
    author_id = EXCLUDED.author_id,
    category = EXCLUDED.category,
    title = EXCLUDED.title,
    body = EXCLUDED.body,
    tags = EXCLUDED.tags,
    image_url = EXCLUDED.image_url,
    images_moderation_status = EXCLUDED.images_moderation_status,
    status = EXCLUDED.status,
    created_at = EXCLUDED.created_at,
    updated_at = EXCLUDED.updated_at,
    last_activity_at = EXCLUDED.last_activity_at;

-- A short, realistic thread on each discussion. One reply-to edge verifies
-- that a conversation can branch without becoming a separate post.
INSERT INTO post_replies (
    id, campus_id, post_id, author_id, body, reply_to_id, status, created_at, updated_at
) VALUES
(
    'e3000000-0000-4000-8000-000000000001',
    'c0000000-0000-0000-0000-000000000001',
    'e2000000-0000-4000-8000-000000000001',
    's0000000-0000-0000-0000-000000000001',
    '我会写清楚楼栋、可取时间、尺寸和有没有电梯。大件最好再说明需不需要买家自己搬下楼。',
    NULL,
    'active',
    NOW() - INTERVAL '27 minutes',
    NOW() - INTERVAL '27 minutes'
),
(
    'e3000000-0000-4000-8000-000000000002',
    'c0000000-0000-0000-0000-000000000001',
    'e2000000-0000-4000-8000-000000000001',
    'b0000000-0000-0000-0000-000000000001',
    '再补一个：交接时间确认后可以在商品详情里继续聊，攻略楼里不用公开手机号。',
    'e3000000-0000-4000-8000-000000000001',
    'active',
    NOW() - INTERVAL '18 minutes',
    NOW() - INTERVAL '18 minutes'
),
(
    'e3000000-0000-4000-8000-000000000003',
    'c0000000-0000-0000-0000-000000000001',
    'e2000000-0000-4000-8000-000000000002',
    's0000000-0000-0000-0000-000000000001',
    '建议先等第一次课确认版次，但可以提前收藏求购帖。开课一周后通常会有更多学长学姐发布。',
    NULL,
    'active',
    NOW() - INTERVAL '22 minutes',
    NOW() - INTERVAL '22 minutes'
),
(
    'e3000000-0000-4000-8000-000000000004',
    'c0000000-0000-0000-0000-000000000001',
    'e2000000-0000-4000-8000-000000000003',
    'b0000000-0000-0000-0000-000000000001',
    '我有一辆折叠手推车，周六下午可以借。你确认时间后回复我就行。',
    NULL,
    'active',
    NOW() - INTERVAL '16 minutes',
    NOW() - INTERVAL '16 minutes'
),
(
    'e3000000-0000-4000-8000-000000000005',
    'c0000000-0000-0000-0000-000000000001',
    'e2000000-0000-4000-8000-000000000004',
    'b0000000-0000-0000-0000-000000000002',
    '可以同步交给图书馆服务台，帖子里只保留辨认线索会更安全。',
    NULL,
    'active',
    NOW() - INTERVAL '12 minutes',
    NOW() - INTERVAL '12 minutes'
),
(
    'e3000000-0000-4000-8000-000000000006',
    'c0000000-0000-0000-0000-000000000001',
    'e2000000-0000-4000-8000-000000000005',
    's0000000-0000-0000-0000-000000000002',
    '我参加，7 点北门见。如果下雨我也可以明晚。',
    NULL,
    'active',
    NOW() - INTERVAL '8 minutes',
    NOW() - INTERVAL '8 minutes'
)
ON CONFLICT (id) DO UPDATE SET
    campus_id = EXCLUDED.campus_id,
    post_id = EXCLUDED.post_id,
    author_id = EXCLUDED.author_id,
    body = EXCLUDED.body,
    reply_to_id = EXCLUDED.reply_to_id,
    status = EXCLUDED.status,
    created_at = EXCLUDED.created_at,
    updated_at = EXCLUDED.updated_at;

-- Explicit marketplace relations. These are stronger than tags: a response
-- records who is offering which active item to which active wanted listing.
INSERT INTO wanted_responses (
    id,
    wanted_listing_id,
    offer_listing_id,
    responder_id,
    requester_id,
    message,
    status,
    campus_id,
    created_at,
    responded_at
) VALUES
(
    'e4000000-0000-4000-8000-000000000001',
    'e1000000-0000-4000-8000-000000000101',
    'e1000000-0000-4000-8000-000000000001',
    's0000000-0000-0000-0000-000000000002',
    'b0000000-0000-0000-0000-000000000001',
    '我这盏台灯符合预算，周六晚上可以在北区楼下试灯。',
    'pending',
    'c0000000-0000-0000-0000-000000000001',
    NOW() - INTERVAL '20 minutes',
    NULL
),
(
    'e4000000-0000-4000-8000-000000000002',
    'e1000000-0000-4000-8000-000000000102',
    'e1000000-0000-4000-8000-000000000002',
    's0000000-0000-0000-0000-000000000001',
    'b0000000-0000-0000-0000-000000000002',
    '这本就是上学期数据结构课程用书，可以先看目录确认版次。',
    'accepted',
    'c0000000-0000-0000-0000-000000000001',
    NOW() - INTERVAL '17 minutes',
    NOW() - INTERVAL '13 minutes'
),
(
    'e4000000-0000-4000-8000-000000000003',
    'e1000000-0000-4000-8000-000000000104',
    'd0000000-0000-4000-8000-000000000012',
    's0000000-0000-0000-0000-000000000002',
    'b0000000-0000-0000-0000-000000000002',
    '我发布的 AirPods 在预算内，可以当面连接手机检查。',
    'pending',
    'c0000000-0000-0000-0000-000000000001',
    NOW() - INTERVAL '9 minutes',
    NULL
)
ON CONFLICT (id) DO UPDATE SET
    message = EXCLUDED.message,
    status = EXCLUDED.status,
    created_at = EXCLUDED.created_at,
    responded_at = EXCLUDED.responded_at;

-- Keep listing post feed times aligned with their inventory fixtures. Keep a
-- later real reply if somebody has interacted with a fixture after seeding.
UPDATE posts post
SET created_at = listing.created_at,
    updated_at = GREATEST(post.updated_at, listing.updated_at),
    last_activity_at = GREATEST(
        listing.created_at,
        COALESCE((
            SELECT MAX(reply.created_at)
            FROM post_replies reply
            WHERE reply.post_id = post.id AND reply.status = 'active'
        ), listing.created_at)
    )
FROM inventory listing
WHERE post.listing_id = listing.id
  AND listing.id LIKE 'e1000000-0000-4000-8000-%';

COMMIT;

SELECT
    (SELECT COUNT(*) FROM inventory WHERE id LIKE 'e1000000-0000-4000-8000-%')
        AS demo_listing_count,
    (SELECT COUNT(*) FROM posts WHERE id::text LIKE 'e2000000-0000-4000-8000-%')
        AS demo_discussion_count,
    (SELECT COUNT(*) FROM post_replies WHERE id::text LIKE 'e3000000-0000-4000-8000-%')
        AS demo_reply_count,
    (SELECT COUNT(*) FROM wanted_responses WHERE id::text LIKE 'e4000000-0000-4000-8000-%')
        AS demo_wanted_response_count;
