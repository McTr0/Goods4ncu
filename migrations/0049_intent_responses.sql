-- Who answered whose intent.
--
-- The metric this exists for was measuring the wrong object. `answer_rate`
-- counted rows in `inventory` and looked for conversations joined on
-- `listing_id` — which was right while a listing was the only way to say you
-- wanted something. Intents are now the record, a seeking intent has no listing
-- projection at all, and answering one opens a conversation with no listing
-- attached. So the dashboard would have reported "0% of posts answered" however
-- well intents were actually being answered: a launch-day number that is not
-- merely imprecise but blind to the mechanism it is supposed to watch.
--
-- One row per (intent, responder): a second message from the same person is the
-- same answer continuing, not a new one, and counting it twice would flatter the
-- number exactly where a thin community needs the truth.

CREATE TABLE IF NOT EXISTS intent_responses (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campus_id       UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    intent_id       UUID NOT NULL REFERENCES intents(id) ON DELETE CASCADE,
    -- TEXT to match users.id.
    responder_id    TEXT NOT NULL,
    -- The conversation opened by the answer, so the metric can also say how long
    -- the exchange ran.
    conversation_id UUID REFERENCES chat_conversations(id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT intent_responses_one_per_responder UNIQUE (intent_id, responder_id)
);

-- Serves "was this answered, and how fast".
CREATE INDEX IF NOT EXISTS idx_intent_responses_intent
    ON intent_responses (intent_id, created_at);

ALTER TABLE intent_responses ENABLE ROW LEVEL SECURITY;
ALTER TABLE intent_responses FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON intent_responses;
CREATE POLICY tenant_isolation ON intent_responses
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
