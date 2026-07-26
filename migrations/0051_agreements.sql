-- The living state of an arrangement.
--
-- The problem. Two people settle a trade or a game over thirty messages, and
-- afterwards "how much, when, where" is scattered through them. IM's data model
-- is a stream of messages; the truth of an arrangement is a consensus that
-- gradually forms. Carrying the second in the first means every participant runs
-- the state machine in their own head, and re-reads the thread to check.
--
-- So the arrangement is the record and messages annotate it. A card at the top
-- of the conversation holds what/price/when/where, identical for both people.
--
-- One table for trades and meetups on purpose. "300 块，周三下午，图书馆东门" and
-- "周三五点，体育馆三号场，带球拍" are the same object: a set of terms that some
-- subset of the participants have agreed to. Two mechanisms would mean two
-- half-finished ones.

CREATE TABLE IF NOT EXISTS agreements (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campus_id       UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    -- The conversation it belongs to. Messages remain; they stop being the only
    -- place the answer lives.
    conversation_id UUID NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,

    -- deal | meetup
    kind            TEXT NOT NULL,
    -- forming | settled | abandoned
    status          TEXT NOT NULL DEFAULT 'forming',

    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT agreements_kind_check CHECK (kind IN ('deal', 'meetup')),
    CONSTRAINT agreements_status_check CHECK (
        status IN ('forming', 'settled', 'abandoned')
    ),
    -- One card per conversation. Two would recreate the problem: a second place
    -- to look.
    CONSTRAINT agreements_one_per_conversation UNIQUE (conversation_id)
);

CREATE INDEX IF NOT EXISTS idx_agreements_campus
    ON agreements (campus_id, status);

ALTER TABLE agreements ENABLE ROW LEVEL SECURITY;
ALTER TABLE agreements FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON agreements;
CREATE POLICY tenant_isolation ON agreements
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

-- One term of the arrangement.
--
-- `agreed_by` is the load-bearing column. A term proposed by the assistant lands
-- with it empty, so **nothing the model reads out of a conversation is true until
-- a person says it is**. That is the whole safety story of this feature: an
-- extraction that misreads "周三下午" cannot silently become the plan.
--
-- Changing a term resets `agreed_by` to the changer alone, because agreement was
-- to the old value. Carrying it over would let one party edit the price under
-- the other's existing consent.
CREATE TABLE IF NOT EXISTS agreement_terms (
    agreement_id UUID NOT NULL REFERENCES agreements(id) ON DELETE CASCADE,
    -- item | price | time | place | who | bring | conditions
    slot         TEXT NOT NULL,

    -- Shown back verbatim, in whoever's words it came from. A normalised value
    -- would lose "周三下午图书馆东门那边" and gain nothing.
    value        TEXT NOT NULL,
    -- Structured price, when the slot is a price and a figure was stated.
    value_cents  BIGINT,

    -- A user id, or 'assistant' for an extraction.
    proposed_by  TEXT NOT NULL,
    -- Who has said yes to *this* value. Empty means nobody yet.
    agreed_by    TEXT[] NOT NULL DEFAULT '{}',
    -- Which message it was read out of, so a member can check the AI's work.
    source_message_id BIGINT,

    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (agreement_id, slot),
    CONSTRAINT agreement_terms_slot_check CHECK (
        slot IN ('item', 'price', 'time', 'place', 'who', 'bring', 'conditions')
    ),
    CONSTRAINT agreement_terms_value_not_blank CHECK (btrim(value) <> '')
);

CREATE INDEX IF NOT EXISTS idx_agreement_terms_agreement
    ON agreement_terms (agreement_id);
