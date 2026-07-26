#!/usr/bin/env bash
# Multi-tenant infrastructure isolation drill (roadmap Phase 4).
#
# The other drills share one Postgres and one bucket. This one provisions the
# genuinely separated topology a multi-campus production deployment uses and
# proves the separation holds against real services:
#
#   * TWO independent PostgreSQL clusters (separate data directories, ports and
#     superusers) standing in for staging and production — not two databases in
#     one instance
#   * per-campus object-storage buckets with SCOPED IAM credentials in a real
#     S3 implementation (MinIO)
#
# Assertions:
#   1. staging and production clusters are independent (a write in one is
#      absent in the other; each app instance sees only its own)
#   2. the production app boots against its own cluster and serves
#   3. a campus-scoped storage credential CAN read its own bucket
#   4. the same credential CANNOT read another campus's bucket (403)
#   5. a presigned URL signed with campus A's credential for campus B's object
#      is refused by the server — signing does not confer authority
#   6. an anonymous read of either bucket is refused
#
# Everything is throwaway and cleaned up. Exit 0 = isolation verified.
# Requires: initdb/pg_ctl/psql, minio, mc, built binary.

set -euo pipefail

# Local drills must not route through a proxy (see operations.md).
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY 2>/dev/null || true
export NO_PROXY='*' no_proxy='*'

cd "$(dirname "$0")/.."
BIN="target/debug/goods4ncu"
[ -x "$BIN" ] || { echo "[tenant] build first: cargo build" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tenant_drill.XXXXXX")"
PROD_PG_PORT=5561
STAGING_PG_PORT=5562
S3_PORT=9120
APP_PORT=4401
PIDS=()
CLUSTERS=()

cleanup() {
    for pid in "${PIDS[@]:-}"; do kill -TERM "$pid" >/dev/null 2>&1 || true; done
    sleep 2
    for pid in "${PIDS[@]:-}"; do kill -KILL "$pid" >/dev/null 2>&1 || true; done
    for dir in "${CLUSTERS[@]:-}"; do pg_ctl -D "$dir" stop -m immediate >/dev/null 2>&1 || true; done
    rm -rf "$WORK"
}
trap cleanup EXIT

say()  { printf '[tenant] %s\n' "$*"; }
fail() { printf '[tenant] FAIL: %s\n' "$*" >&2; exit 1; }

export MC_CONFIG_DIR="$WORK/mc"

# --- Two independent PostgreSQL clusters --------------------------------------
start_cluster() {
    local dir="$1" port="$2"
    initdb -D "$dir" --auth=trust --no-sync >/dev/null
    # listen_addresses is a string setting — unquoted values are a syntax error.
    printf "port = %s\nlisten_addresses = '127.0.0.1'\n" "$port" >> "$dir/postgresql.conf"
    if ! pg_ctl -D "$dir" -l "$dir/server.log" start >/dev/null; then
        tail -10 "$dir/server.log" >&2
        return 1
    fi
    CLUSTERS+=("$dir")
    for _ in $(seq 1 40); do
        pg_isready -h 127.0.0.1 -p "$port" >/dev/null 2>&1 && return 0
        sleep 0.5
    done
    return 1
}

say "provisioning two independent PostgreSQL clusters (production + staging)"
start_cluster "$WORK/pg_prod" "$PROD_PG_PORT" || fail "production cluster did not start"
start_cluster "$WORK/pg_staging" "$STAGING_PG_PORT" || fail "staging cluster did not start"
createdb -h 127.0.0.1 -p "$PROD_PG_PORT" goods4ncu
createdb -h 127.0.0.1 -p "$STAGING_PG_PORT" goods4ncu
say "  ✓ clusters up on :$PROD_PG_PORT (prod) and :$STAGING_PG_PORT (staging)"

# --- Real object storage with per-campus buckets + scoped credentials ---------
say "provisioning per-campus buckets with scoped IAM credentials"
mkdir -p "$WORK/minio"
MINIO_ROOT_USER=root MINIO_ROOT_PASSWORD=root-secret-key \
    minio server "$WORK/minio" --address "127.0.0.1:$S3_PORT" \
    --console-address "127.0.0.1:$((S3_PORT + 1))" > "$WORK/minio.log" 2>&1 &
PIDS+=($!)
disown %% 2>/dev/null || true
for _ in $(seq 1 60); do
    curl -sf -o /dev/null "http://127.0.0.1:$S3_PORT/minio/health/live" && break
    sleep 0.5
done
curl -sf -o /dev/null "http://127.0.0.1:$S3_PORT/minio/health/live" || fail "minio did not start"

mc alias set root "http://127.0.0.1:$S3_PORT" root root-secret-key >/dev/null
mc mb --ignore-existing root/media-ncu root/media-campusb >/dev/null
echo "ncu tenant media" > "$WORK/ncu.txt"
echo "campus-b tenant media" > "$WORK/b.txt"
mc cp "$WORK/ncu.txt" root/media-ncu/probe.txt >/dev/null
mc cp "$WORK/b.txt" root/media-campusb/probe.txt >/dev/null

# Campus-scoped credential: NCU's bucket only.
mc admin user add root campus-ncu ncu-scoped-secret-key >/dev/null
cat > "$WORK/ncu-policy.json" <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Action":["s3:GetObject","s3:PutObject"],
 "Resource":["arn:aws:s3:::media-ncu/*"]}]}
JSON
mc admin policy create root ncu-only "$WORK/ncu-policy.json" >/dev/null
mc admin policy attach root ncu-only --user campus-ncu >/dev/null
mc alias set ncu "http://127.0.0.1:$S3_PORT" campus-ncu ncu-scoped-secret-key >/dev/null
say "  ✓ media-ncu and media-campusb created; campus-ncu scoped to its own bucket"

# --- Check 1: the two clusters are genuinely independent -----------------------
say "check 1: production and staging clusters are independent"
psql -h 127.0.0.1 -p "$PROD_PG_PORT" -d goods4ncu -qtA \
    -c "CREATE TABLE isolation_probe(env text); INSERT INTO isolation_probe VALUES ('production');" >/dev/null
prod_rows=$(psql -h 127.0.0.1 -p "$PROD_PG_PORT" -d goods4ncu -qtA \
    -c "SELECT count(*) FROM isolation_probe WHERE env='production';")
staging_sees=$(psql -h 127.0.0.1 -p "$STAGING_PG_PORT" -d goods4ncu -qtA \
    -c "SELECT count(*) FROM information_schema.tables WHERE table_name='isolation_probe';")
[ "$prod_rows" = "1" ] || fail "production write missing"
[ "$staging_sees" = "0" ] || fail "staging cluster can see production's table — not isolated"
say "  ✓ a production write is invisible to the staging cluster"

# --- Check 2: the app boots against its own cluster and serves ----------------
say "check 2: production app boots against the production cluster"
env APP_ENV=production \
    JWT_SECRET="$(openssl rand -base64 48 | tr -d '\n')" \
    DATABASE_URL="postgres://$(whoami)@127.0.0.1:$PROD_PG_PORT/goods4ncu" \
    CORS_ORIGINS=https://app.example.edu \
    CAMPUS_VERIFICATION_DELIVERY_URL=http://127.0.0.1:1/deliver \
    CAMPUS_VERIFICATION_DELIVERY_TOKEN=tenant-drill-token-0123456789 \
    MEDIA_PRIVATE_BUCKET=true MEDIA_PATH_STYLE=true MEDIA_URL_TTL_SECS=300 \
    OSS_ENDPOINT="http://127.0.0.1:$S3_PORT" OSS_BUCKET=media-ncu \
    OSS_ACCESS_KEY_ID=campus-ncu OSS_ACCESS_KEY_SECRET=ncu-scoped-secret-key \
    SERVER_PORT="$APP_PORT" SHUTDOWN_DRAIN_SECS=0 \
    "$BIN" > "$WORK/app.log" 2>&1 &
APP_PID=$!
PIDS+=("$APP_PID")
for _ in $(seq 1 120); do
    curl -sf -o /dev/null "http://127.0.0.1:$APP_PORT/api/readyz" && break
    sleep 0.5
done
curl -sf -o /dev/null "http://127.0.0.1:$APP_PORT/api/readyz" \
    || { tail -5 "$WORK/app.log" >&2; fail "app did not become ready"; }
grep -q "Private media bucket enabled" "$WORK/app.log" \
    || fail "app did not enable private-bucket media serving"
# Its migrations landed in production, not staging.
prod_tables=$(psql -h 127.0.0.1 -p "$PROD_PG_PORT" -d goods4ncu -qtA \
    -c "SELECT count(*) FROM information_schema.tables WHERE table_name='inventory';")
staging_tables=$(psql -h 127.0.0.1 -p "$STAGING_PG_PORT" -d goods4ncu -qtA \
    -c "SELECT count(*) FROM information_schema.tables WHERE table_name='inventory';")
[ "$prod_tables" = "1" ] || fail "production cluster missing app schema"
[ "$staging_tables" = "0" ] || fail "app schema leaked into the staging cluster"
say "  ✓ app serves from its own cluster; staging untouched"

# --- Checks 3-5: per-campus bucket isolation ----------------------------------
say "check 3: campus credential reads its OWN bucket"
mc cat ncu/media-ncu/probe.txt 2>/dev/null | grep -q "ncu tenant media" \
    || fail "campus credential cannot read its own bucket"
say "  ✓ own-bucket read allowed"

say "check 4: campus credential CANNOT read another campus's bucket"
if mc cat ncu/media-campusb/probe.txt >/dev/null 2>&1; then
    fail "cross-tenant bucket read succeeded — buckets are not isolated"
fi
say "  ✓ cross-tenant bucket read refused"

say "check 5: presigning with campus A's credential does not grant campus B's object"
# `mc share download` presigns with the aliased credential; scoped policy must
# make the resulting URL unusable (or refuse to produce it at all).
if signed=$(mc share download --expire 5m ncu/media-campusb/probe.txt 2>/dev/null | grep -o 'http[^ ]*'); then
    code=$(curl -s -o /dev/null -w '%{http_code}' "$signed")
    [ "$code" = "200" ] && fail "a presigned URL from campus A fetched campus B's object ($code)"
    say "  ✓ presigned cross-tenant URL refused by the server ($code)"
else
    say "  ✓ credential could not even presign another campus's object"
fi

say "check 6: anonymous reads of both buckets are refused"
for bucket in media-ncu media-campusb; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$S3_PORT/$bucket/probe.txt")
    [ "$code" = "403" ] || fail "anonymous read of $bucket returned $code, expected 403"
done
say "  ✓ both buckets deny anonymous access"

kill -TERM "$APP_PID" >/dev/null 2>&1 || true
say "TENANT ISOLATION DRILL PASSED"
