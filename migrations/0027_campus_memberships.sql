-- Establish the tenant identity boundary without enforcing it on business writes yet.
-- Existing accounts are backfilled for compatibility; new registrations start pending
-- until a real campus-email verification flow promotes the membership.

CREATE TABLE IF NOT EXISTS campuses (
    id UUID PRIMARY KEY,
    slug TEXT NOT NULL UNIQUE,
    name_zh TEXT NOT NULL,
    name_en TEXT NOT NULL,
    email_domains TEXT[] NOT NULL DEFAULT '{}',
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'inactive')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (slug = lower(slug)),
    CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,62}$')
);

INSERT INTO campuses (id, slug, name_zh, name_en, email_domains)
VALUES (
    'c0000000-0000-0000-0000-000000000001',
    'ncu',
    '南昌大学',
    'Nanchang University',
    ARRAY['email.ncu.edu.cn']::TEXT[]
)
ON CONFLICT (slug) DO UPDATE SET
    name_zh = EXCLUDED.name_zh,
    name_en = EXCLUDED.name_en,
    email_domains = EXCLUDED.email_domains,
    updated_at = NOW();

CREATE TABLE IF NOT EXISTS campus_memberships (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campus_id UUID NOT NULL REFERENCES campuses(id) ON DELETE RESTRICT,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'verified', 'suspended', 'revoked')),
    role TEXT NOT NULL DEFAULT 'member'
        CHECK (role IN ('member', 'operator', 'admin')),
    verification_method TEXT,
    verified_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (campus_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_campus_memberships_user_status
    ON campus_memberships(user_id, status);
CREATE INDEX IF NOT EXISTS idx_campus_memberships_campus_status
    ON campus_memberships(campus_id, status);

INSERT INTO campus_memberships (
    campus_id,
    user_id,
    status,
    role,
    verification_method,
    verified_at
)
SELECT
    c.id,
    u.id,
    CASE WHEN u.status = 'banned' THEN 'suspended' ELSE 'verified' END,
    'member',
    'legacy_backfill',
    CASE WHEN u.status = 'banned' THEN NULL ELSE NOW() END
FROM users u
CROSS JOIN campuses c
WHERE c.slug = 'ncu'
ON CONFLICT (campus_id, user_id) DO NOTHING;

COMMENT ON TABLE campuses IS
    'Campus tenants. Business data will adopt campus_id in later Phase 1 migrations.';
COMMENT ON TABLE campus_memberships IS
    'User qualification within one campus; pending is not sufficient for protected actions.';
COMMENT ON COLUMN campus_memberships.verification_method IS
    'Audit label only. legacy_backfill is compatibility, not proof of email ownership.';
