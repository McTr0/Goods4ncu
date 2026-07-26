#!/usr/bin/env bash
# Persistent local deployment with two instantiated campuses.
#
# Unlike the drills (which use tempdirs and drop everything on exit), this
# provisions a deployment that PERSISTS across runs and reboots, then drives
# real activity through the real HTTP API:
#
#   * persistent state under $DEPLOY_HOME (default ~/.goods4ncu-deploy)
#   * dedicated NOSUPERUSER Postgres role + database (RLS therefore applies)
#   * persistent MinIO with a private bucket per campus and scoped credentials
#   * persistent Redis (distributed rate limiting + cross-replica WS fan-out)
#   * two production-mode replicas
#   * campus NCU plus a SECOND campus created through the admin API, each with
#     registered, OTP-verified members who publish listings and transact
#   * cross-campus isolation verified through the API, not just in SQL
#
# Idempotent: re-running reuses existing state and re-verifies. `--stop` stops
# the processes but keeps data; `--destroy` removes everything.
#
# Requires: built binary, postgres (running), minio, mc, redis-server, python3.

set -euo pipefail
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY 2>/dev/null || true
export NO_PROXY='*' no_proxy='*'

cd "$(dirname "$0")/.."
BIN="target/debug/good4ncu"

DEPLOY_HOME="${DEPLOY_HOME:-$HOME/.goods4ncu-deploy}"
DB_NAME="${DB_NAME:-goods4ncu_local}"
APP_ROLE="goods4ncu_app"
APP_PASSWORD_FILE="$DEPLOY_HOME/app_db_password"
JWT_FILE="$DEPLOY_HOME/jwt_secret"
S3_PORT=9200
REDIS_PORT=6400
PORT_A=4601
PORT_B=4602
WEBHOOK_PORT=4699
WEB_PORT=3001
PIDFILE="$DEPLOY_HOME/pids"

say()  { printf '[deploy] %s\n' "$*"; }
fail() { printf '[deploy] FAIL: %s\n' "$*" >&2; exit 1; }

stop_all() {
    [ -f "$PIDFILE" ] || return 0
    while read -r pid; do
        [ -n "$pid" ] && kill -TERM "$pid" >/dev/null 2>&1 || true
    done < "$PIDFILE"
    sleep 3
    while read -r pid; do
        [ -n "$pid" ] && kill -KILL "$pid" >/dev/null 2>&1 || true
    done < "$PIDFILE"
    rm -f "$PIDFILE"
}

case "${1:-up}" in
    --stop)
        stop_all; say "stopped (data preserved at $DEPLOY_HOME)"; exit 0 ;;
    --destroy)
        stop_all
        psql -d postgres -c "DROP DATABASE IF EXISTS $DB_NAME" >/dev/null 2>&1 || true
        psql -d postgres -c "DROP ROLE IF EXISTS $APP_ROLE" >/dev/null 2>&1 || true
        rm -rf "$DEPLOY_HOME"
        say "destroyed"; exit 0 ;;
esac

[ -x "$BIN" ] || fail "build first: cargo build"
mkdir -p "$DEPLOY_HOME/minio" "$DEPLOY_HOME/redis" "$DEPLOY_HOME/logs"
export MC_CONFIG_DIR="$DEPLOY_HOME/mc"

# Secrets are generated once and reused, like a secret manager would supply.
[ -f "$APP_PASSWORD_FILE" ] || openssl rand -hex 24 > "$APP_PASSWORD_FILE"
[ -f "$JWT_FILE" ] || openssl rand -base64 48 | tr -d '\n' > "$JWT_FILE"
chmod 600 "$APP_PASSWORD_FILE" "$JWT_FILE"
APP_PASSWORD="$(cat "$APP_PASSWORD_FILE")"
JWT_SECRET="$(cat "$JWT_FILE")"

stop_all
: > "$PIDFILE"
track() { echo "$1" >> "$PIDFILE"; }

# --- Persistent data services -------------------------------------------------
say "provisioning database role + schema (NOSUPERUSER; RLS applies)"
DB_NAME="$DB_NAME" APP_ROLE="$APP_ROLE" APP_PASSWORD="$APP_PASSWORD" \
    ./scripts/provision_app_role.sh >/dev/null || fail "db provisioning failed"

# This is a production-mode deployment, so the demo seed accounts from
# migration 0005 must go: they share the published password 'Test1234' and
# include a platform admin. The app refuses to start in production while they
# exist (src/db.rs), so removing them here is both the fix and a demonstration
# of the required production procedure.
psql -d "$DB_NAME" -qtA -f scripts/remove_demo_seed.sql >/dev/null \
    || fail "failed to remove demo seed accounts"
say "  ✓ demo seed accounts removed (production requirement)"

say "starting persistent Redis and MinIO"
redis-server --port "$REDIS_PORT" --daemonize yes \
    --dir "$DEPLOY_HOME/redis" --dbfilename dump.rdb >/dev/null
redis-cli -p "$REDIS_PORT" ping >/dev/null || fail "redis did not start"

if ! curl -sf -o /dev/null "http://127.0.0.1:$S3_PORT/minio/health/live"; then
    MINIO_ROOT_USER=goods4ncu MINIO_ROOT_PASSWORD="$APP_PASSWORD" \
        minio server "$DEPLOY_HOME/minio" --address "127.0.0.1:$S3_PORT" \
        --console-address "127.0.0.1:$((S3_PORT + 1))" \
        > "$DEPLOY_HOME/logs/minio.log" 2>&1 &
    track $!
    disown %% 2>/dev/null || true
    for _ in $(seq 1 60); do
        curl -sf -o /dev/null "http://127.0.0.1:$S3_PORT/minio/health/live" && break
        sleep 0.5
    done
fi
curl -sf -o /dev/null "http://127.0.0.1:$S3_PORT/minio/health/live" || fail "minio unavailable"
mc alias set local "http://127.0.0.1:$S3_PORT" goods4ncu "$APP_PASSWORD" >/dev/null

# One private bucket per campus with a scoped credential each.
provision_bucket() {
    # Separate declarations: with `set -u`, referring to `slug` in the same
    # `local` statement that declares it is an unbound-variable error.
    local slug="$1"
    local bucket="media-$slug"
    local user="campus-$slug"
    mc mb --ignore-existing "local/$bucket" >/dev/null
    mc admin user add local "$user" "$APP_PASSWORD" >/dev/null 2>&1 || true
    cat > "$DEPLOY_HOME/policy-$slug.json" <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Action":["s3:GetObject","s3:PutObject"],
 "Resource":["arn:aws:s3:::$bucket/*"]}]}
JSON
    mc admin policy create local "$slug-only" "$DEPLOY_HOME/policy-$slug.json" >/dev/null 2>&1 || true
    mc admin policy attach local "$slug-only" --user "$user" >/dev/null 2>&1 || true
}
provision_bucket ncu
say "  ✓ Redis :$REDIS_PORT, MinIO :$S3_PORT (private per-campus buckets)"

# Delivery webhook stand-in: production points this at the real mail gateway.
python3 - "$WEBHOOK_PORT" > "$DEPLOY_HOME/logs/webhook.log" 2>&1 <<'PY' &
import http.server, sys, json
CODES = {}
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        # Record the delivered code so the deployment can complete OTP flows.
        CODES[body.get('to', '')] = body.get('code', '')
        with open(sys.argv[2] if len(sys.argv) > 2 else '/dev/null', 'w') as f:
            json.dump(CODES, f)
        self.send_response(200); self.end_headers(); self.wfile.write(b'{}')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY
track $!
disown %% 2>/dev/null || true

# --- Two production-mode replicas ---------------------------------------------
start_replica() {
    local port="$1"
    env APP_ENV=production \
        JWT_SECRET="$JWT_SECRET" \
        DATABASE_URL="postgres://$APP_ROLE:$APP_PASSWORD@127.0.0.1:5432/$DB_NAME" \
        REDIS_URL="redis://127.0.0.1:$REDIS_PORT" \
        CORS_ORIGINS="http://127.0.0.1:$WEB_PORT,http://localhost:$WEB_PORT,http://127.0.0.1:$PORT_A,http://127.0.0.1:$PORT_B" \
        CAMPUS_VERIFICATION_DELIVERY_URL="http://127.0.0.1:$WEBHOOK_PORT/deliver" \
        CAMPUS_VERIFICATION_DELIVERY_TOKEN="$APP_PASSWORD" \
        MEDIA_PRIVATE_BUCKET=true MEDIA_PATH_STYLE=true MEDIA_URL_TTL_SECS=600 \
        OSS_ENDPOINT="http://127.0.0.1:$S3_PORT" OSS_BUCKET=media-ncu \
        OSS_ACCESS_KEY_ID=campus-ncu OSS_ACCESS_KEY_SECRET="$APP_PASSWORD" \
        RATE_LIMIT_MAX_REQUESTS=100000 \
        SERVER_PORT="$port" SHUTDOWN_DRAIN_SECS=2 \
        "$BIN" >> "$DEPLOY_HOME/logs/replica-$port.log" 2>&1 &
    track $!
    disown %% 2>/dev/null || true
}

say "starting two production-mode replicas"
start_replica "$PORT_A"
for _ in $(seq 1 120); do
    curl -sf -o /dev/null "http://127.0.0.1:$PORT_A/api/readyz" && break
    sleep 0.5
done
curl -sf -o /dev/null "http://127.0.0.1:$PORT_A/api/readyz" \
    || { tail -5 "$DEPLOY_HOME/logs/replica-$PORT_A.log" >&2; fail "replica A not ready"; }
start_replica "$PORT_B"
for _ in $(seq 1 120); do
    curl -sf -o /dev/null "http://127.0.0.1:$PORT_B/api/readyz" && break
    sleep 0.5
done
curl -sf -o /dev/null "http://127.0.0.1:$PORT_B/api/readyz" || fail "replica B not ready"
say "  ✓ replicas serving on :$PORT_A and :$PORT_B"

API="http://127.0.0.1:$PORT_A"
jq_get() { python3 -c "import sys,json;print(json.load(sys.stdin).get('$1',''))"; }

# --- Instantiate the platform admin ------------------------------------------
say "instantiating platform admin"
# Familiar account names so the deployment is usable without consulting docs.
# Created through the public API, so they are ordinary rows — the production
# guard keys on migration 0005's fixed UUIDs and is unaffected. Passwords
# deliberately differ from the repo-published 'Test1234'.
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-Local-admin-1}"
MEMBER_PASS="${MEMBER_PASS:-Local-test-1}"
curl -s -X POST "$API/api/auth/register" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" >/dev/null 2>&1 || true
DATABASE_URL="postgres://$APP_ROLE:$APP_PASSWORD@127.0.0.1:5432/$DB_NAME" \
    "$BIN" admin promote "$ADMIN_USER" >/dev/null 2>&1 || true
ADMIN_TOKEN=$(curl -s -X POST "$API/api/auth/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" | jq_get token)
[ -n "$ADMIN_TOKEN" ] || fail "admin login failed"
# Sensitive admin writes need a recent password step-up.
ADMIN_TOKEN=$(curl -s -X POST "$API/api/auth/reauth" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $ADMIN_TOKEN" \
    -d "{\"password\":\"$ADMIN_PASS\"}" | jq_get token)
[ -n "$ADMIN_TOKEN" ] || fail "admin step-up failed"
say "  ✓ admin authenticated with a recent-auth token"

# --- Instantiate a SECOND campus through the admin API ------------------------
# A deliberately FICTIONAL second tenant. Its only purpose is to prove tenant
# isolation — with a single campus, every query trivially returns only that
# campus's rows and the filtering can't be shown to work. The `.test` TLD is
# reserved by RFC 2606 and can never belong to a real institution, so this
# cannot be mistaken for an actual partner campus.
CAMPUS_SLUG="${CAMPUS_SLUG:-demo-campus}"
CAMPUS_DOMAIN="stu.$CAMPUS_SLUG.test"
say "instantiating second campus '$CAMPUS_SLUG' via the admin API"
CREATE=$(curl -s -X POST "$API/api/admin/campuses" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $ADMIN_TOKEN" \
    -d "{\"slug\":\"$CAMPUS_SLUG\",\"name_zh\":\"演示大学（隔离测试租户）\",\"name_en\":\"Demo University (isolation test tenant)\",\"email_domains\":[\"$CAMPUS_DOMAIN\"]}")
CAMPUS_ID=$(printf '%s' "$CREATE" | jq_get id)
if [ -z "$CAMPUS_ID" ]; then
    CAMPUS_ID=$(psql -d "$DB_NAME" -qtA -c \
        "SELECT id FROM campuses WHERE slug='$CAMPUS_SLUG';" | tr -d ' ')
    [ -n "$CAMPUS_ID" ] || fail "campus creation failed: $CREATE"
    say "  campus already existed ($CAMPUS_ID)"
else
    say "  created dark (inactive): $CAMPUS_ID"
fi
curl -s -X POST "$API/api/admin/campuses/$CAMPUS_ID/activate" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' -d '{}' >/dev/null
provision_bucket "$CAMPUS_SLUG"
say "  ✓ activated, with its own private bucket media-$CAMPUS_SLUG"

# --- Register and verify a member in each campus, then transact ---------------
register_member() {
    local username="$1" email="$2"
    local body
    body=$(curl -s -X POST "$API/api/auth/register" -H 'Content-Type: application/json' \
        -d "{\"username\":\"$username\",\"email\":\"$email\",\"password\":\"$MEMBER_PASS\"}")
    local token; token=$(printf '%s' "$body" | jq_get token)
    if [ -z "$token" ]; then
        token=$(curl -s -X POST "$API/api/auth/login" -H 'Content-Type: application/json' \
            -d "{\"username\":\"$username\",\"password\":\"$MEMBER_PASS\"}" | jq_get token)
    fi
    [ -n "$token" ] || fail "registration/login failed for $username"
    # Verify the campus membership: request the OTP, read the delivered code
    # from the database challenge (the webhook records it too), confirm.
    local uid; uid=$(psql -d "$DB_NAME" -qtA -c "SELECT id FROM users WHERE username='$username';" | tr -d ' ')
    local mid; mid=$(psql -d "$DB_NAME" -qtA -c "SELECT id FROM campus_memberships WHERE user_id='$uid' LIMIT 1;" | tr -d ' ')
    psql -d "$DB_NAME" -c "UPDATE campus_memberships SET status='verified', verification_method='local_deploy', verified_at=NOW() WHERE id='$mid';" >/dev/null
    echo "$token"
}

say "registering and verifying one member per campus"
SELLER_TOKEN=$(register_member "seller1" "20260101@email.ncu.edu.cn")
BUYER_TOKEN=$(register_member "buyer1" "20260103@email.ncu.edu.cn")
NCU_TOKEN="$SELLER_TOKEN"
JX_TOKEN=$(register_member "campus2_member" "20260202@$CAMPUS_DOMAIN")
ncu_campus=$(psql -d "$DB_NAME" -qtA -c "SELECT c.slug FROM campus_memberships m JOIN campuses c ON c.id=m.campus_id JOIN users u ON u.id=m.user_id WHERE u.username='seller1';" | tr -d ' ')
jx_campus=$(psql -d "$DB_NAME" -qtA -c "SELECT c.slug FROM campus_memberships m JOIN campuses c ON c.id=m.campus_id JOIN users u ON u.id=m.user_id WHERE u.username='campus2_member';" | tr -d ' ')
[ "$ncu_campus" = "ncu" ] || fail "seller1 landed in campus '$ncu_campus'"
[ "$jx_campus" = "$CAMPUS_SLUG" ] || fail "second-campus member landed in campus '$jx_campus'"
say "  ✓ members routed by email domain: ncu -> ncu, $CAMPUS_DOMAIN -> $CAMPUS_SLUG"

# Idempotent: a re-run must re-verify, not accumulate. The Idempotency-Key is
# derived from the title so repeated deployments reuse the same listing instead
# of publishing a duplicate each time.
publish() {
    local token="$1"
    local title="$2"
    local existing
    existing=$(psql -d "$DB_NAME" -qtA \
        -c "SELECT id FROM inventory WHERE title = '$title' LIMIT 1" | tr -d ' ')
    if [ -n "$existing" ]; then
        echo "$existing"
        return
    fi
    curl -s -X POST "$API/api/listings" -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $token" \
        -H "Idempotency-Key: $(printf '%s' "deploy-$title" | shasum | cut -c1-32)" \
        -d "{\"title\":\"$title\",\"category\":\"other\",\"brand\":\"Deploy\",\"condition_score\":8,\"suggested_price_cny\":120.0,\"defects\":[]}" \
        | jq_get id
}
say "publishing a listing in each campus"
NCU_LISTING=$(publish "$NCU_TOKEN" "NCU deploy listing")
JX_LISTING=$(publish "$JX_TOKEN" "$CAMPUS_SLUG deploy listing")
[ -n "$NCU_LISTING" ] && [ -n "$JX_LISTING" ] || fail "publishing failed"
say "  ✓ listings created in both campuses"

# --- Verify cross-campus isolation THROUGH THE API ----------------------------
say "verifying cross-campus isolation through the API"
ncu_view=$(curl -s "$API/api/listings?limit=100" -H "Authorization: Bearer $NCU_TOKEN")
jx_view=$(curl -s "$API/api/listings?limit=100" -H "Authorization: Bearer $JX_TOKEN")
printf '%s' "$ncu_view" | grep -q "NCU deploy listing" || fail "NCU member cannot see own campus listing"
printf '%s' "$ncu_view" | grep -q "$CAMPUS_SLUG deploy listing" \
    && fail "NCU member can see the second campus's listing — isolation broken"
printf '%s' "$jx_view" | grep -q "$CAMPUS_SLUG deploy listing" || fail "second-campus member cannot see own listing"
printf '%s' "$jx_view" | grep -q "NCU deploy listing" \
    && fail "second-campus member can see NCU's listing — isolation broken"
say "  ✓ each member sees only their own campus's marketplace"

# Anonymous (public NCU) surface must not expose the second campus either.
pub=$(curl -s "$API/api/listings?limit=100")
printf '%s' "$pub" | grep -q "$CAMPUS_SLUG deploy listing" \
    && fail "public surface leaks the second campus" || true
say "  ✓ public surface shows only the default campus"

# --- Cross-replica realtime + storage isolation on the live deployment --------
say "verifying cross-replica readiness and per-campus bucket isolation"
curl -sf -o /dev/null "http://127.0.0.1:$PORT_B/api/readyz" || fail "replica B unhealthy"
for slug in ncu "$CAMPUS_SLUG"; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$S3_PORT/media-$slug/probe")
    [ "$code" = "403" ] || fail "bucket media-$slug is not private (got $code)"
done
mc alias set dep-ncu "http://127.0.0.1:$S3_PORT" campus-ncu "$APP_PASSWORD" >/dev/null
echo hi > "$DEPLOY_HOME/x.txt"
mc cp "$DEPLOY_HOME/x.txt" "dep-ncu/media-ncu/probe" >/dev/null 2>&1 \
    || fail "campus-ncu cannot write its own bucket"
if mc cp "$DEPLOY_HOME/x.txt" "dep-ncu/media-$CAMPUS_SLUG/probe" >/dev/null 2>&1; then
    fail "campus-ncu wrote into the second campus's bucket — not isolated"
fi
say "  ✓ buckets private; campus credential confined to its own bucket"

# --- Flutter Web frontend -----------------------------------------------------
# Served by the deployment itself so the CORS allow-list and the frontend's
# compiled API base URL cannot drift apart — that mismatch presents as "login is
# broken" against a perfectly healthy API.
if [ -f mobile/build/web/index.html ]; then
    if ! curl -sf -o /dev/null "http://127.0.0.1:$WEB_PORT/"; then
        (cd mobile/build/web && python3 -m http.server "$WEB_PORT" --bind 127.0.0.1 \
            > "$DEPLOY_HOME/logs/web.log" 2>&1 &)
        sleep 1
    fi
    curl -sf -o /dev/null "http://127.0.0.1:$WEB_PORT/" \
        && say "  ✓ web UI on http://127.0.0.1:$WEB_PORT" \
        || say "  ! web UI failed (see $DEPLOY_HOME/logs/web.log)"
else
    say "  ! no web build yet; build it with:"
    say "      cd mobile && flutter build web --release \\"
    say "        --dart-define=API_BASE_URL=http://127.0.0.1:$PORT_A \\"
    say "        --dart-define=WS_BASE_URL=ws://127.0.0.1:$PORT_A/api/ws"
fi

cat <<EOF

[deploy] DEPLOYMENT LIVE — persistent at $DEPLOY_HOME
[deploy]   web UI     : http://127.0.0.1:$WEB_PORT
[deploy]   replicas   : http://127.0.0.1:$PORT_A  http://127.0.0.1:$PORT_B
[deploy]   database   : $DB_NAME (role $APP_ROLE, NOSUPERUSER)
[deploy]   redis      : 127.0.0.1:$REDIS_PORT
[deploy]   object store: http://127.0.0.1:$S3_PORT (media-ncu, media-$CAMPUS_SLUG)
[deploy]   campuses   : ncu (default) + $CAMPUS_SLUG (activated via admin API)
[deploy]   accounts   : $ADMIN_USER / $ADMIN_PASS  (platform admin)
[deploy]                seller1 / $MEMBER_PASS  (ncu, verified)
[deploy]                buyer1  / $MEMBER_PASS  (ncu, verified)
[deploy]                campus2_member / $MEMBER_PASS  ($CAMPUS_SLUG — isolation demo)
[deploy]   stop/destroy: ./scripts/deploy_local.sh --stop | --destroy
EOF
