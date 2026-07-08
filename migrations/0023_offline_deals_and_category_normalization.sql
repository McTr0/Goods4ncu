-- Move orders away from platform payment/logistics semantics and normalize
-- marketplace categories to canonical keys.

ALTER TABLE orders
    ADD COLUMN IF NOT EXISTS confirmed_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS confirmed_by TEXT REFERENCES users(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS auto_delist BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS auto_delisted_at TIMESTAMPTZ;

UPDATE orders
SET status = CASE
    WHEN status = 'pending' THEN 'intent_pending'
    WHEN status IN ('paid', 'shipped', 'completed') THEN 'confirmed'
    WHEN status = 'cancelled' THEN 'cancelled'
    ELSE status
END,
confirmed_at = CASE
    WHEN status IN ('paid', 'shipped', 'completed') THEN COALESCE(completed_at, shipped_at, paid_at, created_at)
    ELSE confirmed_at
END
WHERE status IN ('pending', 'paid', 'shipped', 'completed', 'cancelled');

UPDATE orders
SET auto_delisted_at = COALESCE(auto_delisted_at, confirmed_at)
WHERE status = 'confirmed'
  AND auto_delist = TRUE
  AND auto_delisted_at IS NULL;

UPDATE inventory
SET category = CASE
    WHEN category IN ('electronics', '电子产品', '电子', '数码产品') THEN 'electronics'
    WHEN category IN ('books', '书籍', '图书', '教材') THEN 'books'
    WHEN category IN ('digitalAccessories', 'digital_accessories', '数码配件', '配件') THEN 'digitalAccessories'
    WHEN category IN ('dailyGoods', 'daily_goods', '生活用品', '日用品', '宿舍用品') THEN 'dailyGoods'
    WHEN category IN ('clothingShoes', 'clothing_shoes', '服装', '服饰', '服饰鞋包', '鞋包') THEN 'clothingShoes'
    WHEN category IN ('other', '其他', '其它', 'misc') THEN 'other'
    ELSE 'other'
END;

CREATE INDEX IF NOT EXISTS idx_orders_status_created_at ON orders(status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_orders_listing_buyer_open
    ON orders(listing_id, buyer_id)
    WHERE status = 'intent_pending';
