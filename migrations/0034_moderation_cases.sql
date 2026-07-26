-- Unify machine moderation decisions, user reports, manual review, and appeals
-- under a campus-scoped case model. Public case responses intentionally omit
-- internal_details and actor identities.

CREATE TABLE IF NOT EXISTS moderation_cases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campus_id UUID NOT NULL REFERENCES campuses(id) ON DELETE RESTRICT,
    subject_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
    resource_type TEXT NOT NULL CHECK (char_length(btrim(resource_type)) BETWEEN 1 AND 64),
    resource_id TEXT NOT NULL CHECK (char_length(btrim(resource_id)) BETWEEN 1 AND 255),
    source_type TEXT NOT NULL CHECK (source_type IN ('machine', 'user_report', 'manual')),
    source_ref_id TEXT NOT NULL CHECK (char_length(btrim(source_ref_id)) BETWEEN 1 AND 255),
    status TEXT NOT NULL DEFAULT 'open'
        CHECK (status IN ('open', 'reviewing', 'actioned', 'dismissed', 'appealed', 'resolved')),
    reason_category TEXT NOT NULL CHECK (char_length(btrim(reason_category)) BETWEEN 1 AND 80),
    public_reason TEXT NOT NULL CHECK (char_length(btrim(public_reason)) BETWEEN 1 AND 500),
    internal_details JSONB NOT NULL DEFAULT '{}'::jsonb,
    resolution TEXT CHECK (
        resolution IS NULL OR resolution IN (
            'content_restricted', 'no_violation', 'restored', 'warning', 'account_action'
        )
    ),
    opened_by TEXT REFERENCES users(id) ON DELETE SET NULL,
    assigned_to TEXT REFERENCES users(id) ON DELETE SET NULL,
    decided_by TEXT REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    decided_at TIMESTAMPTZ,
    UNIQUE (source_type, source_ref_id)
);

CREATE TABLE IF NOT EXISTS moderation_case_events (
    id BIGSERIAL PRIMARY KEY,
    case_id UUID NOT NULL REFERENCES moderation_cases(id) ON DELETE CASCADE,
    actor_id TEXT REFERENCES users(id) ON DELETE SET NULL,
    event_type TEXT NOT NULL CHECK (char_length(btrim(event_type)) BETWEEN 1 AND 64),
    from_status TEXT,
    to_status TEXT,
    note TEXT CHECK (note IS NULL OR char_length(note) <= 2000),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS moderation_appeals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id UUID NOT NULL REFERENCES moderation_cases(id) ON DELETE CASCADE,
    campus_id UUID NOT NULL REFERENCES campuses(id) ON DELETE RESTRICT,
    appellant_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    reason TEXT NOT NULL CHECK (char_length(btrim(reason)) BETWEEN 10 AND 2000),
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'upheld', 'overturned')),
    reviewed_by TEXT REFERENCES users(id) ON DELETE SET NULL,
    decision_note TEXT CHECK (decision_note IS NULL OR char_length(btrim(decision_note)) BETWEEN 1 AND 2000),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    decided_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_moderation_appeals_one_per_user
    ON moderation_appeals(case_id, appellant_id);
CREATE INDEX IF NOT EXISTS idx_moderation_cases_campus_status_created
    ON moderation_cases(campus_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_moderation_cases_subject_created
    ON moderation_cases(subject_user_id, campus_id, created_at DESC)
    WHERE subject_user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_moderation_case_events_case_created
    ON moderation_case_events(case_id, created_at ASC, id ASC);
CREATE INDEX IF NOT EXISTS idx_moderation_appeals_campus_status_created
    ON moderation_appeals(campus_id, status, created_at DESC);

ALTER TABLE moderation_jobs
    ADD COLUMN IF NOT EXISTS case_id UUID REFERENCES moderation_cases(id) ON DELETE SET NULL;
ALTER TABLE chat_message_reports
    ADD COLUMN IF NOT EXISTS case_id UUID REFERENCES moderation_cases(id) ON DELETE SET NULL;

-- A provider failure is an operational incident, not evidence that a user
-- violated policy. Only rejected jobs become user-visible moderation cases.
INSERT INTO moderation_cases (
    campus_id, subject_user_id, resource_type, resource_id,
    source_type, source_ref_id, status, reason_category, public_reason,
    internal_details, resolution, decided_at, created_at, updated_at
)
SELECT
    job.campus_id,
    CASE
        WHEN job.resource_type = 'listing_image' THEN listing.owner_id
        WHEN job.resource_type = 'chat_image' THEN message.sender
        WHEN job.resource_type = 'avatar' THEN job.resource_id
        ELSE NULL
    END,
    job.resource_type,
    job.resource_id,
    'machine',
    job.id,
    'actioned',
    'image_policy',
    COALESCE(NULLIF(btrim(job.reject_reason), ''), '图片未通过内容安全审核'),
    jsonb_build_object('moderation_job_id', job.id),
    'content_restricted',
    job.processed_at,
    job.created_at,
    COALESCE(job.processed_at, job.created_at)
FROM moderation_jobs job
LEFT JOIN inventory listing
    ON job.resource_type = 'listing_image' AND listing.id = job.resource_id
LEFT JOIN chat_messages message
    ON job.resource_type = 'chat_image' AND message.id::text = job.resource_id
WHERE job.status = 'rejected'
ON CONFLICT (source_type, source_ref_id) DO NOTHING;

UPDATE moderation_jobs job
SET case_id = moderation_case.id
FROM moderation_cases moderation_case
WHERE moderation_case.source_type = 'machine'
  AND moderation_case.source_ref_id = job.id
  AND job.case_id IS NULL;

INSERT INTO moderation_cases (
    campus_id, subject_user_id, resource_type, resource_id,
    source_type, source_ref_id, status, reason_category, public_reason,
    internal_details, opened_by, created_at, updated_at, resolution
)
SELECT
    conversation.campus_id,
    message.sender,
    'chat_message',
    report.message_id::text,
    'user_report',
    report.id::text,
    CASE report.status
        WHEN 'reviewing' THEN 'reviewing'
        WHEN 'dismissed' THEN 'dismissed'
        WHEN 'resolved' THEN 'resolved'
        ELSE 'open'
    END,
    'message_report',
    '一条聊天消息已进入内容审核流程',
    jsonb_build_object(
        'reported_reason', report.reason,
        'details', report.details,
        'report_id', report.id
    ),
    report.reporter_id,
    report.created_at,
    report.created_at,
    CASE WHEN report.status = 'dismissed' THEN 'no_violation' ELSE NULL END
FROM chat_message_reports report
JOIN chat_messages message ON message.id = report.message_id
JOIN chat_conversations conversation ON conversation.id = message.direct_conversation_id
ON CONFLICT (source_type, source_ref_id) DO NOTHING;

UPDATE chat_message_reports report
SET case_id = moderation_case.id
FROM moderation_cases moderation_case
WHERE moderation_case.source_type = 'user_report'
  AND moderation_case.source_ref_id = report.id::text
  AND report.case_id IS NULL;

INSERT INTO moderation_case_events (
    case_id, actor_id, event_type, from_status, to_status, note, created_at
)
SELECT
    moderation_case.id,
    moderation_case.opened_by,
    'case_created',
    NULL,
    moderation_case.status,
    NULL,
    moderation_case.created_at
FROM moderation_cases moderation_case
WHERE NOT EXISTS (
    SELECT 1 FROM moderation_case_events event
    WHERE event.case_id = moderation_case.id
);

COMMENT ON COLUMN moderation_cases.public_reason IS
    'Safe explanation shown to the affected user; never include reporter identity, matched keywords, or internal thresholds.';
COMMENT ON COLUMN moderation_cases.internal_details IS
    'Restricted evidence for authorized moderation workflows only.';
