-- Let the existing per-user feed controls address discussion/listing posts by
-- their stable post UUID. Legacy `listing` feedback remains valid and is also
-- consumed by the unified post ranker, so clients can migrate gradually.

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'feed_feedback'::regclass
          AND conname = 'feed_feedback_resource_type_check'
    ) THEN
        ALTER TABLE feed_feedback DROP CONSTRAINT feed_feedback_resource_type_check;
    END IF;
    ALTER TABLE feed_feedback
        ADD CONSTRAINT feed_feedback_resource_type_check
        CHECK (resource_type IN ('listing', 'intent', 'post'));
EXCEPTION WHEN duplicate_object THEN
    -- A rolling deploy may already have installed the compatible constraint.
    NULL;
END;
$$;

COMMENT ON COLUMN feed_feedback.resource_type IS
    'listing and intent are legacy feed resources; post addresses unified discussion/listing topics.';
