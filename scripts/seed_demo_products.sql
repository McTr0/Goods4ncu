\set ON_ERROR_STOP on

-- Local-only marketplace fixtures backed by files in mobile/assets/test_product_images.
-- Run from the repository root:
--   psql "$DATABASE_URL" -f scripts/seed_demo_products.sql
--
-- The fixed IDs make this script safe to run repeatedly. It updates only these
-- demo rows and never deletes user-created listings.

BEGIN;

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
    owner_id,
    status,
    created_at
) VALUES
(
    'd0000000-0000-4000-8000-000000000001',
    'Essence 浓密睫毛膏（测试商品）',
    'dailyGoods',
    'Essence',
    9,
    4500,
    '["外包装有轻微存放痕迹"]',
    '浓密纤长型睫毛膏，适合验证低价商品、日用品分类和图片展示。仅用于本地功能测试。',
    'http://127.0.0.1:3001/assets/assets/test_product_images/good4ncu-demo-01.webp',
    's0000000-0000-0000-0000-000000000001',
    'active',
    NOW() - INTERVAL '12 minutes'
),
(
    'd0000000-0000-4000-8000-000000000002',
    '樱桃木床头柜（测试商品）',
    'dailyGoods',
    'Furniture Co.',
    8,
    28000,
    '["侧面有一道不明显划痕"]',
    '带储物空间的小型床头柜，适合宿舍或租房场景。仅用于本地功能测试。',
    'http://127.0.0.1:3001/assets/assets/test_product_images/good4ncu-demo-02.webp',
    's0000000-0000-0000-0000-000000000002',
    'active',
    NOW() - INTERVAL '11 minutes'
),
(
    'd0000000-0000-4000-8000-000000000003',
    'Nescafe 速溶咖啡（测试商品）',
    'dailyGoods',
    'Nescafe',
    10,
    3900,
    '[]',
    '未开封速溶咖啡，用于验证搜索、低价排序和无瑕疵商品展示。仅用于本地功能测试。',
    'http://127.0.0.1:3001/assets/assets/test_product_images/good4ncu-demo-03.webp',
    's0000000-0000-0000-0000-000000000001',
    'active',
    NOW() - INTERVAL '10 minutes'
),
(
    'd0000000-0000-4000-8000-000000000004',
    '现代桌面台灯（测试商品）',
    'dailyGoods',
    'Home Studio',
    8,
    6800,
    '["灯座底部有轻微使用痕迹"]',
    '适合书桌和床头使用的现代台灯，用于验证家居类商品详情。仅用于本地功能测试。',
    'http://127.0.0.1:3001/assets/assets/test_product_images/good4ncu-demo-04.webp',
    's0000000-0000-0000-0000-000000000002',
    'active',
    NOW() - INTERVAL '9 minutes'
),
(
    'd0000000-0000-4000-8000-000000000005',
    '多功能料理机（测试商品）',
    'dailyGoods',
    'Kitchen Lab',
    9,
    15900,
    '["包装盒已拆封"]',
    '可制作奶昔和果汁的小型料理机，用于验证品牌与价格筛选。仅用于本地功能测试。',
    'http://127.0.0.1:3001/assets/assets/test_product_images/good4ncu-demo-05.webp',
    's0000000-0000-0000-0000-000000000001',
    'active',
    NOW() - INTERVAL '8 minutes'
),
(
    'd0000000-0000-4000-8000-000000000006',
    '家用微波炉（测试商品）',
    'dailyGoods',
    'Kitchen Lab',
    8,
    39900,
    '["门把手有轻微划痕"]',
    '支持加热和解冻的紧凑型微波炉，用于验证中等价格商品。仅用于本地功能测试。',
    'http://127.0.0.1:3001/assets/assets/test_product_images/good4ncu-demo-06.webp',
    's0000000-0000-0000-0000-000000000002',
    'active',
    NOW() - INTERVAL '7 minutes'
),
(
    'd0000000-0000-4000-8000-000000000007',
    'MacBook Pro 14 英寸（测试商品）',
    'electronics',
    'Apple',
    9,
    899900,
    '["A 面有一处细小划痕"]',
    '深空灰色 14 英寸笔记本，用于验证高价商品、电子产品分类和降序排序。仅用于本地功能测试。',
    'http://127.0.0.1:3001/assets/assets/test_product_images/good4ncu-demo-07.webp',
    's0000000-0000-0000-0000-000000000001',
    'active',
    NOW() - INTERVAL '6 minutes'
),
(
    'd0000000-0000-4000-8000-000000000008',
    '蓝黑格纹衬衫（测试商品）',
    'clothingShoes',
    'Fashion Trends',
    9,
    9900,
    '["吊牌已拆"]',
    '休闲格纹衬衫，适合验证服装鞋帽分类和关键词搜索。仅用于本地功能测试。',
    'http://127.0.0.1:3001/assets/assets/test_product_images/good4ncu-demo-08.webp',
    's0000000-0000-0000-0000-000000000002',
    'active',
    NOW() - INTERVAL '5 minutes'
),
(
    'd0000000-0000-4000-8000-000000000009',
    'Nike Air Jordan 1 红黑（测试商品）',
    'clothingShoes',
    'Nike',
    8,
    89900,
    '["鞋底有少量正常磨损"]',
    '红黑配色篮球鞋，用于验证鞋类商品和品牌搜索。仅用于本地功能测试。',
    'http://127.0.0.1:3001/assets/assets/test_product_images/good4ncu-demo-09.webp',
    's0000000-0000-0000-0000-000000000001',
    'active',
    NOW() - INTERVAL '4 minutes'
),
(
    'd0000000-0000-4000-8000-000000000010',
    '棕色皮带腕表（测试商品）',
    'digitalAccessories',
    'Fashion Timepieces',
    9,
    29900,
    '["表带有轻微弯折痕迹"]',
    '经典棕色皮带腕表，用于验证数码配件分类与成色显示。仅用于本地功能测试。',
    'http://127.0.0.1:3001/assets/assets/test_product_images/good4ncu-demo-10.webp',
    's0000000-0000-0000-0000-000000000002',
    'active',
    NOW() - INTERVAL '3 minutes'
),
(
    'd0000000-0000-4000-8000-000000000011',
    'Amazon Echo Plus 智能音箱（测试商品）',
    'digitalAccessories',
    'Amazon',
    8,
    49900,
    '["电源线有轻微使用痕迹"]',
    '支持语音控制的智能音箱，用于验证长标题和数码配件展示。仅用于本地功能测试。',
    'http://127.0.0.1:3001/assets/assets/test_product_images/good4ncu-demo-11.webp',
    's0000000-0000-0000-0000-000000000001',
    'active',
    NOW() - INTERVAL '2 minutes'
),
(
    'd0000000-0000-4000-8000-000000000012',
    'Apple AirPods 无线耳机（测试商品）',
    'digitalAccessories',
    'Apple',
    9,
    79900,
    '["充电盒有细小划痕"]',
    '无线蓝牙耳机，用于验证收藏、详情和联系卖家等完整流程。仅用于本地功能测试。',
    'http://127.0.0.1:3001/assets/assets/test_product_images/good4ncu-demo-12.webp',
    's0000000-0000-0000-0000-000000000002',
    'active',
    NOW() - INTERVAL '1 minute'
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
    owner_id = EXCLUDED.owner_id,
    status = EXCLUDED.status,
    created_at = EXCLUDED.created_at;

COMMIT;

SELECT COUNT(*) AS demo_product_count
FROM inventory
WHERE id LIKE 'd0000000-0000-4000-8000-%';
