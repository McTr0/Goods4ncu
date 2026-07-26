-- TOTP MFA enrollment for platform administrators.
--
-- One row per user. A row without confirmed_at is a pending enrollment (the
-- admin has been shown the secret but has not yet proven possession of the
-- authenticator); only confirmed rows are enforced at re-authentication.
--
-- last_used_step is the high-water mark of consumed TOTP time steps: a code is
-- only accepted for steps strictly greater than it, which makes each 30-second
-- code single-use and closes the replay window within a step.
CREATE TABLE IF NOT EXISTS admin_totp_secrets (
    user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    secret_base32 TEXT NOT NULL,
    confirmed_at TIMESTAMPTZ,
    last_used_step BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
