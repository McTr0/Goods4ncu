-- Seed data for the unified posts system (migration 0099/0100).
--
-- Covers every shape the feed must render:
--   * offer with a listing reference / offer without one
--   * wanted incl. long-term and urgent
--   * errand offers + errand wanteds (metadata + resolution lifecycle)
--   * plain discussions, Q&A, events
--   * group-scoped posts (space_id, member visibility)
--   * status variety: active / locked / archived / deleted
--
-- Idempotent: keyed inserts via fixed UUIDs, safe to re-run.
-- Usage: psql "$DATABASE_URL" -f scripts/seed_posts_data.sql

BEGIN;

-- Group memberships so space-scoped posts are actually visible to the
-- seeded users (feed/detail enforce member visibility).
INSERT INTO chat_space_members (space_id, user_id, role, joined_at) VALUES
  ('c1000000-0000-4000-8000-000000000002', 'b0000000-0000-0000-0000-000000000001', 'owner',  now() - interval '30 days'),
  ('c1000000-0000-4000-8000-000000000002', 'b0000000-0000-0000-0000-000000000002', 'member', now() - interval '30 days'),
  ('c1000000-0000-4000-8000-000000000005', 's0000000-0000-0000-0000-000000000001', 'owner',  now() - interval '60 days'),
  ('c1000000-0000-4000-8000-000000000005', 'b0000000-0000-0000-0000-000000000001', 'member', now() - interval '60 days'),
  ('c1000000-0000-4000-8000-000000000007', 'b0000000-0000-0000-0000-000000000001', 'member', now() - interval '45 days'),
  ('c1000000-0000-4000-8000-000000000008', 'b0000000-0000-0000-0000-000000000002', 'member', now() - interval '45 days')
ON CONFLICT (space_id, user_id) DO NOTHING;


INSERT INTO posts (
  id, campus_id, author_id, category, listing_id, space_id,
  title, body, tags, errand_metadata, resolution_status, status,
  reply_count, created_at, updated_at, last_activity_at
) VALUES

-- ===== Offers bound to real listings =====
('d0000000-0000-4000-8000-000000000001',
 'c0000000-0000-0000-0000-000000000001',
 's0000000-0000-0000-0000-000000000001', 'offer',
 'l0000000-0000-0000-0000-000000000001', NULL,
 '出 iPhone 14 Pro Max 256G 深空黑',
 '去年十月购入，电池效率 91%，全程贴膜带壳。毕业回老家急出，可小刀，支持前湖校区内面交。',
 '["negotiable","freeShipping"]'::jsonb, '{}', 'open', 'active', 3,
 now() - interval '2 days', now() - interval '5 hours', now() - interval '5 hours'),

('d0000000-0000-4000-8000-000000000002',
 'c0000000-0000-0000-0000-000000000001',
 's0000000-0000-0000-0000-000000000001', 'offer',
 'l0000000-0000-0000-0000-000000000002', NULL,
 '高等数学第七版上下册 同济版',
 '大一大二用完九成新，笔记都在便签上没写在书里。45 两本打包，天健操场附近可自取。',
 '["likeNew","pickupOnly"]'::jsonb, '{}', 'open', 'active', 1,
 now() - interval '4 days', now() - interval '1 day', now() - interval '1 day'),

('d0000000-0000-4000-8000-000000000003',
 'c0000000-0000-0000-0000-000000000001',
 's0000000-0000-0000-0000-000000000001', 'offer',
 'l0000000-0000-0000-0000-000000000003', NULL,
 '小米手环8 NFC 版 199 出',
 '买来两个月，戴着睡觉不太习惯就闲置了。盒子和备用腕带都在，功能一切正常。',
 '["sellFast"]'::jsonb, '{}', 'open', 'active', 0,
 now() - interval '26 hours', now() - interval '26 hours', now() - interval '26 hours'),

('d0000000-0000-4000-8000-000000000004',
 'c0000000-0000-0000-0000-000000000001',
 's0000000-0000-0000-0000-000000000002', 'offer',
 'l0000000-0000-0000-0000-000000000004', NULL,
 '联想拯救者 Y7000 R7000P 毕业甩卖',
 'R7-5800H + RTX3060，加了 16G 内存条共 32G。打游戏剪视频都很稳，风扇已清灰。价格可谈。',
 '["negotiable"]'::jsonb, '{}', 'open', 'active', 2,
 now() - interval '3 days', now() - interval '10 hours', now() - interval '10 hours'),

-- ===== Offers without listings =====
('d0000000-0000-4000-8000-000000000005',
 'c0000000-0000-0000-0000-000000000001',
 'b0000000-0000-0000-0000-000000000002', 'offer',
 NULL, NULL,
 '宿舍神器：懒人小桌板+床上支架 15 元',
 '退宿清仓，两张一起 15 块拿走，单张 9 块。润溪湖畔楼下交易。',
 '["pickupOnly"]'::jsonb, '{}', 'open', 'active', 0,
 now() - interval '8 hours', now() - interval '8 hours', now() - interval '8 hours'),

('d0000000-0000-4000-8000-000000000006',
 'c0000000-0000-0000-0000-000000000001',
 'b0000000-0000-0000-0000-000000000002', 'offer',
 NULL, NULL,
 '全新未拆封蓝牙键盘（多买了一个）',
 '双十一凑单手滑买了两个，全新未拆。原价 89 现在 55 出。',
 '["brandNew","freeShipping"]'::jsonb, '{}', 'open', 'archived', 0,
 now() - interval '6 days', now() - interval '2 days', now() - interval '2 days'),

-- ===== Wanted =====
('d0000000-0000-4000-8000-000000000007',
 'c0000000-0000-0000-0000-000000000001',
 'b0000000-0000-0000-0000-000000000001', 'wanted',
 NULL, NULL,
 '收一辆二手自行车 预算 150 内',
 '代步上课用，刹车灵就行，不追求外观。前湖校区内自取。',
 '["usedOk","budgetFlexible"]'::jsonb, '{}', 'open', 'active', 2,
 now() - interval '30 hours', now() - interval '3 hours', now() - interval '3 hours'),

('d0000000-0000-4000-8000-000000000008',
 'c0000000-0000-0000-0000-000000000001',
 'b0000000-0000-0000-0000-000000000002', 'wanted',
 NULL, NULL,
 '长期收考研数学一资料（张宇/李永乐系列）',
 '准备明年考研，全套或单本都行，有笔记更好。长期有效，价格合理直接私信。',
 '["longterm"]'::jsonb, '{}', 'open', 'active', 1,
 now() - interval '5 days', now() - interval '2 days', now() - interval '2 days'),

('d0000000-0000-4000-8000-000000000009',
 'c0000000-0000-0000-0000-000000000001',
 'b0000000-0000-0000-0000-000000000001', 'wanted',
 NULL, NULL,
 '急收 Type-C 快充线 今晚就要',
 '充电器落在教室被人拿走了，明早要赶高铁。有的同学速度联系，20 以内随便挑！',
 '["urgent","topPrice"]'::jsonb, '{}', 'open', 'active', 4,
 now() - interval '7 hours', now() - interval '40 minutes', now() - interval '40 minutes'),

('d0000000-0000-4000-8000-000000000010',
 'c0000000-0000-0000-0000-000000000001',
 'b0000000-0000-0000-0000-000000000002', 'wanted',
 NULL, NULL,
 '收一把羽毛球拍 新手入门级',
 '想约同学打球但自己没拍，尤尼克斯或者胜利的入门款都可以，100 左右。',
 '["usedOk"]'::jsonb, '{}', 'open', 'active', 0,
 now() - interval '14 hours', now() - interval '14 hours', now() - interval '14 hours'),

-- ===== Errand: offered help =====
('d0000000-0000-4000-8000-000000000011',
 'c0000000-0000-0000-0000-000000000001',
 's0000000-0000-0000-0000-000000000001', 'offer',
 NULL, NULL,
 '每天下午代取快递 北门菜鸟驿站',
 '课少时间多，每天 16:00 和 18:30 两趟统一去北门取件送到各宿舍楼楼下，5 元一件，大件加 2 元。',
 '["errand"]'::jsonb,
 '{"service_mode":"pickup_delivery","pickup_place":"前湖校区北门菜鸟驿站","dropoff_place":"校内各宿舍楼","time_hint":"工作日 16:00 / 18:30 两趟","reward_cents":500,"notes":"易碎品请提前备注"}'::jsonb,
 'open', 'active', 2,
 now() - interval '2 days', now() - interval '9 hours', now() - interval '9 hours'),

('d0000000-0000-4000-8000-000000000012',
 'c0000000-0000-0000-0000-000000000001',
 's0000000-0000-0000-0000-000000000002', 'offer',
 NULL, NULL,
 '周末代打热水 代买食堂饭菜',
 '周末在校区，可以帮忙打热水、带饭。热水 2 元/壶，带饭跑腿费 3 元+餐费实报实销。',
 '["errand"]'::jsonb,
 '{"service_mode":"errand_run","pickup_place":"天健园食堂","dropoff_place":"修贤广场周边","time_hint":"周六周日 10:00-19:00","reward_cents":300,"notes":"餐费另算，先转餐费再跑单"}'::jsonb,
 'resolved', 'active', 1,
 now() - interval '9 days', now() - interval '3 days', now() - interval '3 days'),

-- ===== Errand: requesting help (wanted) =====
('d0000000-0000-4000-8000-000000000013',
 'c0000000-0000-0000-0000-000000000001',
 'b0000000-0000-0000-0000-000000000001', 'wanted',
 NULL, NULL,
 '求帮取校医院体检报告 并送到北院',
 '这周实习没空跑，报告在校医院一楼自助机，凭姓名学号可打印。报酬 8 元，感谢！',
 '["errand"]'::jsonb,
 '{"service_mode":"pickup_delivery","pickup_place":"前湖校区校医院一楼大厅","dropoff_place":"前湖北院门口","time_hint":"本周五之前任意时间","reward_cents":800,"notes":"自助机输学号即可"}'::jsonb,
 'closed', 'active', 1,
 now() - interval '20 hours', now() - interval '4 hours', now() - interval '4 hours'),

('d0000000-0000-4000-8000-000000000014',
 'c0000000-0000-0000-0000-000000000001',
 'b0000000-0000-0000-0000-000000000002', 'wanted',
 NULL, NULL,
 '求人帮忙还图书馆的书 明天到期',
 '《算法导论》一本，明天到期怕逾期。可以在前湖南院门口交接，报酬一杯奶茶！',
 '["errand","urgent"]'::jsonb,
 '{"service_mode":"errand_run","pickup_place":"前湖南院门口","dropoff_place":"前湖校区图书馆还书处","time_hint":"明天 21:00 闭馆前","reward_cents":1500,"notes":"书就在我宿舍，交接很快"}'::jsonb,
 'resolved', 'active', 3,
 now() - interval '11 days', now() - interval '10 days', now() - interval '10 days'),

-- ===== Discussions =====
('d0000000-0000-4000-8000-000000000015',
 'c0000000-0000-0000-0000-000000000001',
 'b0000000-0000-0000-0000-000000000001', 'discussion',
 NULL, NULL,
 '前湖校区食堂天花板到底是哪一家？',
 '吃了三年还是觉得天健园二楼的麻辣香锅最稳，但最近涨价了。大家心中第一是哪家？',
 '[]'::jsonb, '{}', 'open', 'locked', 12,
 now() - interval '8 days', now() - interval '1 day', now() - interval '1 day'),

('d0000000-0000-4000-8000-000000000016',
 'c0000000-0000-0000-0000-000000000001',
 's0000000-0000-0000-0000-000000000001', 'discussion',
 NULL, NULL,
 '四六级一次过的经验贴：听力从 120 到 200',
 '核心就三点：每天精听一篇真题、背熟场景词、考前两周刷完近五年。附我的时间表，需要的自取。',
 '["share"]'::jsonb, '{}', 'open', 'active', 6,
 now() - interval '4 days', now() - interval '16 hours', now() - interval '16 hours'),

('d0000000-0000-4000-8000-000000000017',
 'c0000000-0000-0000-0000-000000000001',
 'b0000000-0000-0000-0000-000000000002', 'discussion',
 NULL, NULL,
 '校园卡丢了补办全流程（亲测 10 分钟搞定）',
 '先在 APP 上挂失→带身份证到卡务中心→交 15 元工本费→当场拿新卡。旧卡余额三个工作日原路退回。',
 '["help"]'::jsonb, '{}', 'open', 'active', 5,
 now() - interval '6 days', now() - interval '2 days', now() - interval '2 days'),

('d0000000-0000-4000-8000-000000000018',
 'c0000000-0000-0000-0000-000000000001',
 'a0000000-0000-0000-0000-000000000001', 'discussion',
 NULL, NULL,
 '关于期末季图书馆占座现象的讨论',
 '近期收到不少反馈。想听听大家的声音：你更接受"离座超 30 分钟可收走物品"这种规则吗？理性发言。',
 '["event","question"]'::jsonb, '{}', 'open', 'active', 9,
 now() - interval '3 days', now() - interval '7 hours', now() - interval '7 hours'),

('d0000000-0000-4000-8000-000000000019',
 'c0000000-0000-0000-0000-000000000001',
 'b0000000-0000-0000-0000-000000000002', 'discussion',
 NULL, NULL,
 '考研自习室哪家强？求真实体验',
 '听说修贤广场和图书馆都有考研专区，想问问插座多不多、空调给力吗？',
 '["question"]'::jsonb, '{}', 'open', 'active', 3,
 now() - interval '36 hours', now() - interval '5 hours', now() - interval '5 hours'),

('d0000000-0000-4000-8000-000000000020',
 'c0000000-0000-0000-0000-000000000001',
 's0000000-0000-0000-0000-000000000002', 'discussion',
 NULL, NULL,
 '百团大战社团招新时间线整理',
 '下周一开始主摊位招新，整理了各热门社团的面试安排，滑到图里看完整表格。',
 '["event","share"]'::jsonb, '{}', 'open', 'active', 4,
 now() - interval '2 days', now() - interval '12 hours', now() - interval '12 hours'),

('d0000000-0000-4000-8000-000000000021',
 'c0000000-0000-0000-0000-000000000001',
 's0000000-0000-0000-0000-000000000001', 'discussion',
 NULL, NULL,
 '润溪湖日落最佳机位分享（附时间）',
 '傍晚 18:40 前到湖西侧长椅，逆光拍剪影绝了。上周拍的片子回头发评论区。',
 '["share"]'::jsonb, '{}', 'open', 'active', 2,
 now() - interval '22 hours', now() - interval '2 hours', now() - interval '2 hours'),

-- ===== Group-scoped posts (space member visibility) =====
('d0000000-0000-4000-8000-000000000022',
 'c0000000-0000-0000-0000-000000000001',
 'b0000000-0000-0000-0000-000000000001', 'discussion',
 NULL, 'c1000000-0000-4000-8000-000000000002',
 '北院三楼热水机又罢工了',
 '今天早上的水只有温温的，报修了吗？有没有同楼的同学一起催一下后勤。',
 '[]'::jsonb, '{}', 'open', 'active', 2,
 now() - interval '9 hours', now() - interval '1 hour', now() - interval '1 hour'),

('d0000000-0000-4000-8000-000000000023',
 'c0000000-0000-0000-0000-000000000001',
 'b0000000-0000-0000-0000-000000000002', 'offer',
 NULL, 'c1000000-0000-4000-8000-000000000008',
 '东湖校区桌游局装备低价转（狼人杀+UNO）',
 '搬校区带不走了，两套一起 25 元，群里自提。周日晚之前都方便。',
 '["pickupOnly"]'::jsonb, '{}', 'open', 'active', 1,
 now() - interval '28 hours', now() - interval '6 hours', now() - interval '6 hours'),

('d0000000-0000-4000-8000-000000000024',
 'c0000000-0000-0000-0000-000000000001',
 'b0000000-0000-0000-0000-000000000001', 'wanted',
 NULL, 'c1000000-0000-4000-8000-000000000007',
 '青山湖校区收一个小台灯 护眼款',
 '实验室赶论文需要，插电款最好，30 以内。在群里看到直接私我。',
 '["budgetFlexible"]'::jsonb, '{}', 'open', 'active', 0,
 now() - interval '18 hours', now() - interval '18 hours', now() - interval '18 hours'),

('d0000000-0000-4000-8000-000000000025',
 'c0000000-0000-0000-0000-000000000001',
 's0000000-0000-0000-0000-000000000001', 'discussion',
 NULL, 'c1000000-0000-4000-8000-000000000005',
 '润溪湖畔晨跑搭子征集（配速 6 分）',
 '每天早上 6:50 湖边集合绕湖三圈，配速 600 左右，下雨顺延。想加入的接龙。',
 '["event"]'::jsonb, '{}', 'open', 'active', 3,
 now() - interval '32 hours', now() - interval '90 minutes', now() - interval '90 minutes'),

-- ===== Deleted (soft-delete visibility test) =====
('d0000000-0000-4000-8000-000000000026',
 'c0000000-0000-0000-0000-000000000001',
 'b0000000-0000-0000-0000-000000000001', 'offer',
 NULL, NULL,
 '【已删除】测试误发的帖子',
 '这条帖子应只出现在作者本人的"我的发布（已删除）"里。',
 '[]'::jsonb, '{}', 'open', 'deleted', 0,
 now() - interval '3 days', now() - interval '3 days', now() - interval '3 days')
ON CONFLICT (id) DO UPDATE SET
  title = EXCLUDED.title,
  body = EXCLUDED.body,
  tags = EXCLUDED.tags,
  errand_metadata = EXCLUDED.errand_metadata,
  resolution_status = EXCLUDED.resolution_status,
  status = EXCLUDED.status,
  reply_count = EXCLUDED.reply_count,
  updated_at = now();

COMMIT;
