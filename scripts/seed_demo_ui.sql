\set ON_ERROR_STOP on

-- Complete local UI fixture set: image-backed listings, campus feed posts,
-- and the test groups that contain group-scoped discussions.
-- Run from the repository root:
--   psql "$DATABASE_URL" -f scripts/seed_demo_ui.sql
--
-- Each imported script is idempotent and uses fixed IDs, so this entry point
-- can be rerun without touching user-created data.

\ir seed_demo_products.sql
\ir seed_demo_community.sql
\ir seed_demo_groups.sql
