-- Remove the demo seed accounts and their data (migrations/0005_seed_data.sql).
--
-- Those rows exist in every database because 0005 lives in migrations/ despite
-- being labelled "run manually". They share the published password 'Test1234'
-- and include a platform administrator, so production must not keep them —
-- src/db.rs refuses to start in production while they are present.
--
-- Safe to run repeatedly. Child rows go first; FK cascades cover the rest.
BEGIN;

CREATE TEMP TABLE demo_seed_users(id TEXT PRIMARY KEY);
INSERT INTO demo_seed_users VALUES
    ('a0000000-0000-0000-0000-000000000001'),
    ('b0000000-0000-0000-0000-000000000001'),
    ('b0000000-0000-0000-0000-000000000002'),
    ('s0000000-0000-0000-0000-000000000001'),
    ('s0000000-0000-0000-0000-000000000002'),
    ('banned00-0000-0000-0000-000000000001');

DELETE FROM documents WHERE id IN (
    SELECT id FROM inventory WHERE owner_id IN (SELECT id FROM demo_seed_users)
);
DELETE FROM orders WHERE buyer_id IN (SELECT id FROM demo_seed_users)
                      OR seller_id IN (SELECT id FROM demo_seed_users);
DELETE FROM inventory WHERE owner_id IN (SELECT id FROM demo_seed_users);
DELETE FROM notifications WHERE user_id IN (SELECT id FROM demo_seed_users);
DELETE FROM campus_memberships WHERE user_id IN (SELECT id FROM demo_seed_users);
DELETE FROM users WHERE id IN (SELECT id FROM demo_seed_users);

COMMIT;
