-- 0017: Obsolete shadow columns removed per zero-compatibility policy
-- Drop any shadow objects if they exist so migration replay and existing dev databases stay clean.
DROP VIEW IF EXISTS uuid_shadow_divergence;
DROP TRIGGER IF EXISTS trg_sync_users_uuid_shadow ON users;
DROP TRIGGER IF EXISTS trg_sync_inventory_uuid_shadow ON inventory;
DROP TRIGGER IF EXISTS trg_sync_orders_uuid_shadow ON orders;
DROP FUNCTION IF EXISTS sync_users_uuid_shadow();
DROP FUNCTION IF EXISTS sync_inventory_uuid_shadow();
DROP FUNCTION IF EXISTS sync_orders_uuid_shadow();
ALTER TABLE IF EXISTS orders DROP COLUMN IF EXISTS new_seller_id;
ALTER TABLE IF EXISTS orders DROP COLUMN IF EXISTS new_buyer_id;
ALTER TABLE IF EXISTS orders DROP COLUMN IF EXISTS new_listing_id;
ALTER TABLE IF EXISTS orders DROP COLUMN IF EXISTS new_id;
ALTER TABLE IF EXISTS inventory DROP COLUMN IF EXISTS new_owner_id;
ALTER TABLE IF EXISTS inventory DROP COLUMN IF EXISTS new_id;
ALTER TABLE IF EXISTS users DROP COLUMN IF EXISTS new_id;
