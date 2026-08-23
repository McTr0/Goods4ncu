-- Normalize legacy persona character tokens to the only shipped model.
--
-- The client and backend allow-lists collapsed to `doro`; rows still holding
-- gugugaga / phoebe_chupi / ncu_*-prefixed ids would surface those raw ids in
-- avatar_interaction payloads and fail validation on the next persona save.
UPDATE social_personas
SET appearance_config = jsonb_set(
    appearance_config,
    '{character}',
    '"doro"'::jsonb,
    true
)
WHERE appearance_config->>'character' IS DISTINCT FROM 'doro';
