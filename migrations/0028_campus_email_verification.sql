-- Short-lived, hashed campus email verification challenges.
-- Plaintext codes are never persisted and completed challenges remain for audit/rate limiting.

CREATE TABLE IF NOT EXISTS campus_verification_challenges (
    id UUID PRIMARY KEY,
    membership_id UUID NOT NULL REFERENCES campus_memberships(id) ON DELETE CASCADE,
    email TEXT NOT NULL,
    code_hash TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 5),
    delivery_status TEXT NOT NULL DEFAULT 'pending'
        CHECK (delivery_status IN ('pending', 'sent', 'failed')),
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (char_length(code_hash) = 64)
);

CREATE INDEX IF NOT EXISTS idx_campus_verification_membership_requested
    ON campus_verification_challenges(membership_id, requested_at DESC);
CREATE INDEX IF NOT EXISTS idx_campus_verification_expiry
    ON campus_verification_challenges(expires_at)
    WHERE consumed_at IS NULL;

COMMENT ON TABLE campus_verification_challenges IS
    'Hashed one-time campus email challenges; plaintext codes are delivered but never stored.';
