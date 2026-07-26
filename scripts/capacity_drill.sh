#!/usr/bin/env bash
# Capacity drill (roadmap: 以 10 万注册、1 万日活…压测的本机可执行部分).
#
# Seeds a throwaway database with production-scale volume — 100k users with
# memberships, 60k listings across two campuses, 100k notifications, watchlist
# and order activity — then boots the real server against it and runs the SLO
# load smoke. Query plans that only degrade at volume (missing indexes, seq
# scans behind the feed) fail here instead of in production.
#
# Usage: ./scripts/capacity_drill.sh [users] [listings]

set -euo pipefail

# Local drills must not route through any HTTP(S) proxy: proxied loopback
# requests fail or return proxy errors (502) that masquerade as app failures.
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY 2>/dev/null || true
export NO_PROXY='*' no_proxy='*'
cd "$(dirname "$0")/.."

BIN="target/debug/goods4ncu"
[ -x "$BIN" ] || { echo "[capacity] build first: cargo build" >&2; exit 2; }

USERS="${1:-100000}"
LISTINGS="${2:-60000}"
DB_NAME="goods4ncu_capacity_$$"
PORT=4305

APP_PID=""
cleanup() {
    [ -n "$APP_PID" ] && kill -TERM "$APP_PID" >/dev/null 2>&1 || true
    sleep 3
    [ -n "$APP_PID" ] && kill -KILL "$APP_PID" >/dev/null 2>&1 || true
    dropdb "$DB_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

say() { printf '[capacity] %s\n' "$*"; }

say "creating capacity database ($USERS users, $LISTINGS listings)"
createdb "$DB_NAME"

# Boot once to run migrations (and seed NCU), then stop.
env DATABASE_URL="postgres://$(whoami)@localhost/$DB_NAME" \
    JWT_SECRET="$(openssl rand -base64 48 | tr -d '\n')" \
    GEMINI_API_KEY=capacity-drill SERVER_PORT="$PORT" \
    RATE_LIMIT_MAX_REQUESTS=1000000 \
    SHUTDOWN_DRAIN_SECS=0 "$BIN" > /tmp/capacity_boot.log 2>&1 &
APP_PID=$!
ready=0
for _ in $(seq 1 240); do
    if curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/readyz"; then ready=1; break; fi
    sleep 0.5
done
if [ "$ready" != "1" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$PORT/api/readyz" || echo none)
    tail -5 /tmp/capacity_boot.log >&2
    echo "[capacity] boot failed (last readyz status: $code)" >&2
    exit 1
fi
kill -TERM "$APP_PID"
for _ in $(seq 1 30); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.5; done
APP_PID=""

say "seeding volume (set-based SQL)"
seed_start=$(date +%s)
psql -q -d "$DB_NAME" -v users="$USERS" -v listings="$LISTINGS" <<'SQL'
-- Second campus for cross-tenant volume.
INSERT INTO campuses (id, slug, name_zh, name_en, email_domains, status)
VALUES ('c0000000-0000-0000-0000-00000000c0b0', 'cap-b', '容量测试大学', 'Capacity University', ARRAY['cap.test'], 'active')
ON CONFLICT (slug) DO NOTHING;

-- Users + verified memberships split across the two campuses.
INSERT INTO users (id, new_id, username, password_hash, role)
SELECT 'cap-user-' || g,
       gen_random_uuid(),
       'cap_user_' || g,
       '$argon2id$v=19$m=19456,t=2,p=1$c2VlZHNlZWRzZWVk$3m0CzD1Yy4Zl4a5S3n8m6QHW4kY0FZlYQm1n8m6QHW4',
       'user'
FROM generate_series(1, :users) AS g;

INSERT INTO campus_memberships (campus_id, user_id, status, role, verification_method, verified_at)
SELECT CASE WHEN g % 2 = 0
            THEN 'c0000000-0000-0000-0000-000000000001'::uuid
            ELSE 'c0000000-0000-0000-0000-00000000c0b0'::uuid END,
       'cap-user-' || g, 'verified', 'member', 'capacity_seed', NOW()
FROM generate_series(1, :users) AS g;

-- Listings: mixed categories/directions/status across both campuses, spread
-- creation times so recency ordering is realistic.
INSERT INTO inventory (id, new_id, campus_id, title, category, brand, direction,
                       condition_score, suggested_price_cny, defects, description,
                       owner_id, new_owner_id, status, created_at)
SELECT 'cap-listing-' || g,
       gen_random_uuid(),
       CASE WHEN g % 2 = 0
            THEN 'c0000000-0000-0000-0000-000000000001'::uuid
            ELSE 'c0000000-0000-0000-0000-00000000c0b0'::uuid END,
       'Capacity item ' || g,
       (ARRAY['electronics','books','digitalAccessories','dailyGoods','clothingShoes','other'])[1 + g % 6],
       'Brand ' || (g % 50),
       CASE WHEN g % 5 = 0 THEN 'wanted' ELSE 'offer' END,
       1 + g % 10,
       1000 + (g % 900) * 100,
       '[]',
       'seeded capacity listing',
       'cap-user-' || (1 + g % :users),
       (SELECT new_id FROM users WHERE id = 'cap-user-' || (1 + g % :users)),
       CASE WHEN g % 11 = 0 THEN 'sold' ELSE 'active' END,
       NOW() - (g % 90) * INTERVAL '1 day' - (g % 86400) * INTERVAL '1 second'
FROM generate_series(1, :listings) AS g;

-- Engagement signals so the personalized feed exercises its joins.
INSERT INTO watchlist (user_id, listing_id)
SELECT 'cap-user-' || (1 + g % :users), 'cap-listing-' || (1 + (g * 7) % :listings)
FROM generate_series(1, :listings / 2) AS g
ON CONFLICT DO NOTHING;

INSERT INTO notifications (id, campus_id, user_id, event_type, title, body)
SELECT gen_random_uuid()::text,
       CASE WHEN g % 2 = 0
            THEN 'c0000000-0000-0000-0000-000000000001'::uuid
            ELSE 'c0000000-0000-0000-0000-00000000c0b0'::uuid END,
       'cap-user-' || (1 + g % :users),
       'capacity_seed', 'title', 'body'
FROM generate_series(1, :users) AS g;

ANALYZE;
SQL
seed_end=$(date +%s)
say "seeded in $((seed_end - seed_start))s"

psql -qtA -d "$DB_NAME" -c "
SELECT 'users=' || (SELECT COUNT(*) FROM users)
    || ' listings=' || (SELECT COUNT(*) FROM inventory)
    || ' notifications=' || (SELECT COUNT(*) FROM notifications)
    || ' watchlist=' || (SELECT COUNT(*) FROM watchlist);" | sed 's/^/[capacity] /'

say "booting server against the seeded volume"
env DATABASE_URL="postgres://$(whoami)@localhost/$DB_NAME" \
    JWT_SECRET="$(openssl rand -base64 48 | tr -d '\n')" \
    GEMINI_API_KEY=capacity-drill SERVER_PORT="$PORT" \
    RATE_LIMIT_MAX_REQUESTS=1000000 \
    SHUTDOWN_DRAIN_SECS=0 "$BIN" > /tmp/capacity_run.log 2>&1 &
APP_PID=$!
for _ in $(seq 1 240); do
    if curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/readyz"; then break; fi
    sleep 0.5
done

say "SLO smoke at production-scale volume"
BASE_URL="http://127.0.0.1:$PORT" ./scripts/load_smoke.sh 300 16

say "CAPACITY DRILL PASSED"
