-- Older development/upgrade databases may still have INT4 money columns even
-- though the current baseline schema uses BIGINT. Normalize them so repository
-- decoding and large-value bounds behave identically on fresh and upgraded DBs.

ALTER TABLE inventory
    ALTER COLUMN suggested_price_cny TYPE BIGINT
    USING suggested_price_cny::BIGINT;

ALTER TABLE orders
    ALTER COLUMN final_price TYPE BIGINT
    USING final_price::BIGINT;

ALTER TABLE hitl_requests
    ALTER COLUMN proposed_price TYPE BIGINT
    USING proposed_price::BIGINT,
    ALTER COLUMN counter_price TYPE BIGINT
    USING counter_price::BIGINT;
