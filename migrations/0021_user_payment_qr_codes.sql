-- Optional user-owned payment QR codes for offline settlement.
-- The platform stores image URLs only; it does not process, verify, escrow, or
-- mark payments through these QR codes.

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS wechat_pay_qr_url TEXT,
    ADD COLUMN IF NOT EXISTS alipay_qr_url TEXT,
    ADD COLUMN IF NOT EXISTS show_wechat_pay_qr BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS show_alipay_qr BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS idx_users_public_payment_qr
    ON users (id)
    WHERE show_wechat_pay_qr = TRUE OR show_alipay_qr = TRUE;
