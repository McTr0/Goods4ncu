#!/usr/bin/env bash
# Production rehearsal: boots the real production topology on one machine and
# proves the operational properties the roadmap requires, in one pass:
#
#   * production mode ON (APP_ENV=production): secret hygiene, explicit CORS
#     and the campus-verification delivery webhook are all enforced at boot
#   * the app runs as a NON-SUPERUSER role, so Row-Level Security actually
#     applies to it (a superuser would silently bypass every tenant policy)
#   * empty-database bootstrap: migrations run against a fresh rehearsal DB
#   * two replicas sharing Postgres + Redis (WS fan-out + distributed limits)
#   * SLO load smoke against a replica
#   * rolling restart: one replica drains and returns while the other serves
#     load with zero failures
#   * private object storage: real S3 (MinIO) with a private bucket, proving
#     anonymous direct access is refused and presigned serving works
#   * point-in-time-recovery drill
#
# Everything runs against throwaway resources (rehearsal DB, scratch Redis,
# mock webhook) and cleans up after itself. Exit 0 = all checks passed.
#
# Requires: built binary (cargo build), postgres tools, redis-server, minio, mc, python3.

set -euo pipefail

# Local drills must not route through any HTTP(S) proxy: proxied loopback
# requests fail or return proxy errors (502) that masquerade as app failures.
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY 2>/dev/null || true
export NO_PROXY='*' no_proxy='*'

cd "$(dirname "$0")/.."
BIN="target/debug/good4ncu"
[ -x "$BIN" ] || { echo "[rehearsal] build first: cargo build" >&2; exit 2; }

DB_NAME="goods4ncu_rehearsal_$$"
REDIS_PORT=6398
S3_PORT=9102
S3_BUCKET=rehearsal-media
WEBHOOK_PORT=4299
PORT_A=4201
PORT_B=4202
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/goods4ncu_rehearsal.XXXXXX")"

PIDS=()
cleanup() {
    for pid in "${PIDS[@]:-}"; do kill -TERM "$pid" >/dev/null 2>&1 || true; done
    sleep 2
    for pid in "${PIDS[@]:-}"; do kill -KILL "$pid" >/dev/null 2>&1 || true; done
    redis-cli -p "$REDIS_PORT" shutdown nosave >/dev/null 2>&1 || true
    dropdb "$DB_NAME" >/dev/null 2>&1 || true
    psql -d postgres -c "DROP ROLE IF EXISTS $APP_ROLE" >/dev/null 2>&1 || true
    if [ "${KEEP_SCRATCH:-0}" = "1" ]; then echo "[rehearsal] scratch kept: $SCRATCH"; else rm -rf "$SCRATCH"; fi
}
trap cleanup EXIT

say()  { printf '[rehearsal] %s\n' "$*"; }
fail() { printf '[rehearsal] FAIL: %s\n' "$*" >&2; exit 1; }

# --- Throwaway infrastructure -------------------------------------------------
# Pre-flight: refuse to run over stale listeners — a leftover instance on these
# ports would answer probes meant for the fresh replicas.
for port in "$PORT_A" "$PORT_B"; do
    if curl -sf -o /dev/null --max-time 1 "http://127.0.0.1:$port/api/livez"; then
        fail "port :$port is already serving; stop the stale instance first"
    fi
done

say "provisioning rehearsal infrastructure"
# Provision like production: dedicated non-superuser role, DBA-installed
# pgvector. Running the app as a superuser would bypass RLS entirely.
APP_ROLE="rehearsal_app_$$"
APP_PASSWORD="rehearsal-app-secret"
DB_NAME="$DB_NAME" APP_ROLE="$APP_ROLE" APP_PASSWORD="$APP_PASSWORD" \
    ./scripts/provision_app_role.sh >/dev/null || fail "database provisioning failed"
redis-server --port "$REDIS_PORT" --daemonize yes --save '' >/dev/null
redis-cli -p "$REDIS_PORT" ping >/dev/null || fail "redis did not start"

# Real S3-compatible object storage with a PRIVATE bucket.
mkdir -p "$SCRATCH/minio"
MINIO_ROOT_USER=rehearsal MINIO_ROOT_PASSWORD=rehearsal-secret-key \
    minio server "$SCRATCH/minio" --address "127.0.0.1:$S3_PORT" \
    --console-address "127.0.0.1:$((S3_PORT + 1))" > "$SCRATCH/minio.log" 2>&1 &
PIDS+=($!)
disown %% 2>/dev/null || true
for _ in $(seq 1 60); do
    curl -sf -o /dev/null "http://127.0.0.1:$S3_PORT/minio/health/live" && break
    sleep 0.5
done
curl -sf -o /dev/null "http://127.0.0.1:$S3_PORT/minio/health/live" || fail "minio did not start"
export MC_CONFIG_DIR="$SCRATCH/mc"
mc alias set rehearsal "http://127.0.0.1:$S3_PORT" rehearsal rehearsal-secret-key >/dev/null
mc mb --ignore-existing "rehearsal/$S3_BUCKET" >/dev/null
echo "rehearsal media object" > "$SCRATCH/media-probe.txt"
mc cp "$SCRATCH/media-probe.txt" "rehearsal/$S3_BUCKET/media-probe.txt" >/dev/null
[ "$(mc anonymous get "rehearsal/$S3_BUCKET" 2>&1 | grep -c private)" -ge 1 ] \
    || fail "rehearsal bucket is not private"

# Mock campus-verification delivery webhook (production boot requires it).
python3 - "$WEBHOOK_PORT" >/dev/null 2>&1 <<'PY' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        self.send_response(200); self.end_headers(); self.wfile.write(b'{}')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY
PIDS+=($!)
disown %% 2>/dev/null || true

# --- Production-mode environment ---------------------------------------------
PROD_ENV=(
    "APP_ENV=production"
    "JWT_SECRET=$(openssl rand -base64 48 | tr -d '\n')"
    "DATABASE_URL=postgres://$APP_ROLE:$APP_PASSWORD@127.0.0.1:5432/$DB_NAME"
    "REDIS_URL=redis://127.0.0.1:$REDIS_PORT"
    "CORS_ORIGINS=https://app.example.edu"
    "CAMPUS_VERIFICATION_DELIVERY_URL=http://127.0.0.1:$WEBHOOK_PORT/deliver"
    "CAMPUS_VERIFICATION_DELIVERY_TOKEN=rehearsal-delivery-token-0123456789"
    "RATE_LIMIT_MAX_REQUESTS=100000"
    "MEDIA_PRIVATE_BUCKET=true"
    "MEDIA_PATH_STYLE=true"
    "MEDIA_URL_TTL_SECS=300"
    "OSS_ENDPOINT=http://127.0.0.1:$S3_PORT"
    "OSS_BUCKET=$S3_BUCKET"
    "OSS_ACCESS_KEY_ID=rehearsal"
    "OSS_ACCESS_KEY_SECRET=rehearsal-secret-key"
    "SHUTDOWN_DRAIN_SECS=2"
    "SHUTDOWN_TIMEOUT_SECS=15"
)

# Starts a replica and reports its PID via the STARTED_PID global. Deliberately
# NOT `$(...)`-style: command substitution runs in a subshell, so `PIDS+=` there
# never reaches the cleanup trap and replicas would orphan across runs — the
# stale instance then answers readiness probes while the fresh one dies on
# EADDRINUSE, which is exactly the confusing failure this comment is from.
start_replica() {
    local port="$1" log="$2"
    env "${PROD_ENV[@]}" SERVER_PORT="$port" "$BIN" > "$log" 2>&1 &
    STARTED_PID=$!
    PIDS+=("$STARTED_PID")
}

wait_ready() {
    local port="$1"
    for _ in $(seq 1 60); do
        if curl -sf -o /dev/null "http://127.0.0.1:$port/api/readyz"; then return 0; fi
        sleep 0.5
    done
    return 1
}

# --- Check 0: production guards actually guard --------------------------------
say "check 0: production mode refuses a development-grade secret"
if env "${PROD_ENV[@]}" JWT_SECRET="test_jwt_secret_at_least_32_characters_long" \
    SERVER_PORT=4290 "$BIN" > "$SCRATCH/badboot.log" 2>&1; then
    fail "production boot accepted a dev-marker JWT secret"
fi
grep -q "development marker" "$SCRATCH/badboot.log" \
    || fail "expected secret-hygiene rejection, got: $(tail -1 "$SCRATCH/badboot.log")"
say "  ✓ dev-grade secret rejected at boot"

# --- Check 1: empty-DB production bootstrap, two replicas ---------------------
say "check 1: two production-mode replicas boot an empty database"
start_replica "$PORT_A" "$SCRATCH/a.log"; PID_A=$STARTED_PID
wait_ready "$PORT_A" || { tail -5 "$SCRATCH/a.log" >&2; fail "replica A never became ready"; }
start_replica "$PORT_B" "$SCRATCH/b.log"; PID_B=$STARTED_PID
wait_ready "$PORT_B" || { tail -5 "$SCRATCH/b.log" >&2; fail "replica B never became ready"; }
say "  ✓ replicas ready on :$PORT_A and :$PORT_B (migrations applied to fresh DB)"
grep -q "Distributed rate limiting enabled" "$SCRATCH/a.log" \
    || fail "replica A did not enable Redis rate limiting"
grep -q "WS fanout subscribed" "$SCRATCH/a.log" \
    || fail "replica A did not subscribe to WS fanout"
say "  ✓ Redis-backed rate limiting and WS fanout active"

# --- Check 2: SLO smoke on replica A -----------------------------------------
say "check 2: SLO load smoke against replica A"
BASE_URL="http://127.0.0.1:$PORT_A" ./scripts/load_smoke.sh 200 16 \
    || fail "SLO smoke failed"

# --- Check 2b: object-storage ACL boundary ------------------------------------
say "check 2b: private bucket refuses anonymous access; presigned serving works"
grep -q "Private media bucket enabled" "$SCRATCH/a.log" \
    || fail "replica A did not enable private-bucket media serving"
raw_code=$(curl -s -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:$S3_PORT/$S3_BUCKET/media-probe.txt")
[ "$raw_code" = "403" ] || fail "anonymous object GET returned $raw_code, expected 403"
say "  ✓ anonymous direct object access refused (403)"
S3_TEST_ENDPOINT="http://127.0.0.1:$S3_PORT" S3_TEST_BUCKET="$S3_BUCKET" \
    S3_TEST_ACCESS_KEY=rehearsal S3_TEST_SECRET_KEY=rehearsal-secret-key \
    S3_TEST_OBJECT=media-probe.txt \
    cargo test --test storage_acl_integration -- --test-threads=1 >/dev/null 2>&1 \
    || fail "storage ACL integration tests failed against the rehearsal bucket"
say "  ✓ presigned serving verified against the live bucket"

# --- Check 2c: RLS is live for the application role ---------------------------
say "check 2c: RLS applies to the non-superuser app role"
is_super=$(psql -d postgres -qtA -c "SELECT rolsuper FROM pg_roles WHERE rolname='$APP_ROLE';")
[ "$is_super" = "f" ] || fail "app role is a superuser — RLS would be bypassed"
armed=$(PGPASSWORD="$APP_PASSWORD" psql -h 127.0.0.1 -U "$APP_ROLE" -d "$DB_NAME" -qtA <<'SQL'
BEGIN;
SET LOCAL app.campus_id = '00000000-0000-0000-0000-0000000000ff';
SELECT count(*) FROM campus_memberships;
ROLLBACK;
SQL
)
[ "$armed" = "0" ] || fail "armed tenant context still saw $armed rows — RLS not enforced"
say "  ✓ app role is not a superuser and an armed context sees zero foreign rows"

# --- Check 3: rolling restart of B while A serves load ------------------------
say "check 3: rolling restart of replica B under load on A"
(
    for _ in $(seq 1 200); do
        curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:$PORT_A/api/listings?limit=5"
    done > "$SCRATCH/rolling.codes"
) &
LOAD_PID=$!
kill -TERM "$PID_B"
# `wait` cannot observe a grandchild; poll until the old process is fully gone
# so the restarted replica does not race it for the port.
for _ in $(seq 1 40); do
    kill -0 "$PID_B" 2>/dev/null || break
    sleep 0.5
done
kill -0 "$PID_B" 2>/dev/null && fail "replica B did not drain in time"
say "  replica B drained"
start_replica "$PORT_B" "$SCRATCH/b2.log"; PID_B=$STARTED_PID
wait_ready "$PORT_B" || fail "replica B did not return after rolling restart"
wait "$LOAD_PID"
NON_2XX=$(awk '$1 !~ /^2/ { n++ } END { print n+0 }' "$SCRATCH/rolling.codes")
[ "$NON_2XX" -eq 0 ] || fail "$NON_2XX requests failed during the rolling restart"
say "  ✓ zero failed requests during rolling restart; B back in service"

# --- Check 4: PITR drill -------------------------------------------------------
say "check 4: point-in-time recovery drill"
DRILL_PRIMARY_PORT=5546 DRILL_RESTORE_PORT=5547 ./scripts/backup_pitr_drill.sh >/dev/null \
    || fail "PITR drill failed"
say "  ✓ PITR drill passed"

# --- Check 5: both replicas drain cleanly -------------------------------------
say "check 5: orderly drain of both replicas"
kill -0 "$PID_A" 2>/dev/null || { tail -20 "$SCRATCH/a.log" >&2; fail "replica A died prematurely"; }
kill -TERM "$PID_A" "$PID_B"
for pid in "$PID_A" "$PID_B"; do
    for _ in $(seq 1 40); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    kill -0 "$pid" 2>/dev/null && fail "replica $pid did not drain in time"
done
grep -q "Shutdown complete" "$SCRATCH/a.log" || { tail -20 "$SCRATCH/a.log" >&2; fail "replica A did not log clean shutdown"; }
say "  ✓ both replicas drained cleanly"

say "PRODUCTION REHEARSAL PASSED"
