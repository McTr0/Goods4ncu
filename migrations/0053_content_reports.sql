-- Reporting a listing or a person.
--
-- Until now the only report route was `POST /api/chat/messages/{id}/report`, so
-- the single way to flag a scam listing was to open a conversation with the
-- scammer first and report something they said. The marketplace is where the
-- money is and therefore where the fraud is; leaving it with no report path put
-- the burden of contacting a bad actor on the person trying to avoid them.
--
-- Deliberately generic in `resource_type` rather than one table per surface:
-- `moderation_cases` already keys on (resource_type, resource_id), and a
-- reviewer wants one queue, not three.

CREATE TABLE IF NOT EXISTS content_reports (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campus_id       UUID NOT NULL REFERENCES campuses(id) ON DELETE RESTRICT,
    resource_type   TEXT NOT NULL CHECK (resource_type IN ('listing', 'user')),
    resource_id     TEXT NOT NULL CHECK (char_length(btrim(resource_id)) BETWEEN 1 AND 255),
    -- Who the report is about. Kept alongside resource_id so a reviewer can see
    -- a person's history without resolving every listing id by hand.
    subject_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
    reporter_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    reason          TEXT NOT NULL CHECK (char_length(btrim(reason)) BETWEEN 1 AND 80),
    details         TEXT CHECK (details IS NULL OR char_length(details) <= 1000),
    status          TEXT NOT NULL DEFAULT 'open'
        CHECK (status IN ('open', 'reviewing', 'resolved', 'dismissed')),
    case_id         UUID REFERENCES moderation_cases(id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT content_reports_not_self
        CHECK (subject_user_id IS NULL OR subject_user_id <> reporter_id)
);

-- One *standing* report per person per thing. Re-submitting while it is open
-- edits the evidence instead of inflating the queue. Once a report has been
-- dismissed or resolved, genuinely new conduct can be reported as a new case.
CREATE UNIQUE INDEX IF NOT EXISTS idx_content_reports_one_standing_per_reporter
    ON content_reports (campus_id, resource_type, resource_id, reporter_id)
    WHERE status IN ('open', 'reviewing');

-- Serves the reviewer's "what else has been said about this" lookup.
CREATE INDEX IF NOT EXISTS idx_content_reports_resource
    ON content_reports (resource_type, resource_id, created_at DESC);
-- Serves rate limiting: how much has this person filed lately.
CREATE INDEX IF NOT EXISTS idx_content_reports_reporter
    ON content_reports (reporter_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_content_reports_campus_status
    ON content_reports (campus_id, status, created_at DESC);

ALTER TABLE content_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE content_reports FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON content_reports;
CREATE POLICY tenant_isolation ON content_reports
    USING (
        current_setting('app.campus_id', true) IS NULL
        OR current_setting('app.campus_id', true) = ''
        OR campus_id = current_setting('app.campus_id', true)::uuid
    )
    WITH CHECK (
        current_setting('app.campus_id', true) IS NULL
        OR current_setting('app.campus_id', true) = ''
        OR campus_id = current_setting('app.campus_id', true)::uuid
    );
