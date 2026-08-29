\set ON_ERROR_STOP on

-- Local-only group fixtures for the messages page. Every built-in test user
-- joins both groups, so the data is visible regardless of which demo account
-- is active in the browser.

BEGIN;

INSERT INTO chat_spaces (id, campus_id, kind, name, description, owner_id, status)
VALUES
    (
        'd1000000-0000-4000-8000-000000000001',
        'c0000000-0000-0000-0000-000000000001',
        'group',
        '跳蚤市场交流群（测试）',
        '出闲置、收好物和砍价交流的本地测试群。',
        's0000000-0000-0000-0000-000000000001',
        'active'
    ),
    (
        'd1000000-0000-4000-8000-000000000002',
        'c0000000-0000-0000-0000-000000000001',
        'group',
        '考研互助小组（测试）',
        '资料互换、自习搭子和经验分享的本地测试群。',
        'b0000000-0000-0000-0000-000000000002',
        'active'
    )
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    owner_id = EXCLUDED.owner_id,
    status = EXCLUDED.status,
    updated_at = NOW();

INSERT INTO chat_space_members (space_id, user_id, role, joined_at)
VALUES
    ('d1000000-0000-4000-8000-000000000001', 's0000000-0000-0000-0000-000000000001', 'owner', NOW() - INTERVAL '30 days'),
    ('d1000000-0000-4000-8000-000000000001', 's0000000-0000-0000-0000-000000000002', 'member', NOW() - INTERVAL '30 days'),
    ('d1000000-0000-4000-8000-000000000001', 'b0000000-0000-0000-0000-000000000001', 'member', NOW() - INTERVAL '30 days'),
    ('d1000000-0000-4000-8000-000000000001', 'b0000000-0000-0000-0000-000000000002', 'member', NOW() - INTERVAL '29 days'),
    ('d1000000-0000-4000-8000-000000000002', 's0000000-0000-0000-0000-000000000001', 'member', NOW() - INTERVAL '20 days'),
    ('d1000000-0000-4000-8000-000000000002', 's0000000-0000-0000-0000-000000000002', 'member', NOW() - INTERVAL '19 days'),
    ('d1000000-0000-4000-8000-000000000002', 'b0000000-0000-0000-0000-000000000001', 'member', NOW() - INTERVAL '20 days'),
    ('d1000000-0000-4000-8000-000000000002', 'b0000000-0000-0000-0000-000000000002', 'owner', NOW() - INTERVAL '20 days')
ON CONFLICT (space_id, user_id) DO UPDATE SET
    role = EXCLUDED.role,
    joined_at = EXCLUDED.joined_at;

COMMIT;

SELECT COUNT(*) AS demo_group_count
FROM chat_spaces
WHERE id::text LIKE 'd1000000-0000-4000-8000-%';
