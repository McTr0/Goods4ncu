#!/usr/bin/env bash
# One-time database provisioning for a deployment (staging or production).
#
# Creates the dedicated application role and database with the two properties
# production requires:
#
#   1. The app role is NOT a superuser. Superusers bypass Row-Level Security
#      entirely, which would silently disable the tenant policies from
#      migration 0042 — the app would look fine while tenant isolation was off.
#   2. The pgvector extension is installed by an administrator, once, up front.
#      Creating an extension needs superuser, so the app must never have to do
#      it (see src/db.rs, which skips creation when the extension exists and
#      otherwise fails with this script's instructions).
#
# Run as a Postgres superuser. Idempotent.
#
# Usage:
#   DB_NAME=goods4ncu APP_PASSWORD=... ./scripts/provision_app_role.sh
#   (optional: DB_SUPERUSER=postgres PGHOST=... PGPORT=...)

set -euo pipefail

DB_NAME="${DB_NAME:?set DB_NAME}"
APP_ROLE="${APP_ROLE:-goods4ncu_app}"
APP_PASSWORD="${APP_PASSWORD:?set APP_PASSWORD}"
ADMIN_DB="${ADMIN_DB:-postgres}"

say() { printf '[provision] %s\n' "$*"; }

say "creating role $APP_ROLE (NOSUPERUSER) and database $DB_NAME"
psql -d "$ADMIN_DB" -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$APP_ROLE') THEN
        CREATE ROLE $APP_ROLE LOGIN PASSWORD '$APP_PASSWORD'
            NOSUPERUSER NOCREATEDB NOCREATEROLE;
    ELSE
        ALTER ROLE $APP_ROLE LOGIN PASSWORD '$APP_PASSWORD'
            NOSUPERUSER NOCREATEDB NOCREATEROLE;
    END IF;
END
\$\$;
SQL

if ! psql -d "$ADMIN_DB" -qtA -c \
    "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME';" | grep -q 1; then
    psql -d "$ADMIN_DB" -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE $DB_NAME OWNER $APP_ROLE;"
    say "  created database $DB_NAME owned by $APP_ROLE"
else
    psql -d "$ADMIN_DB" -v ON_ERROR_STOP=1 \
        -c "ALTER DATABASE $DB_NAME OWNER TO $APP_ROLE;"
    say "  database $DB_NAME already existed; ownership confirmed"
fi

say "installing pgvector as administrator (the app role cannot and must not)"
psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null
psql -d "$DB_NAME" -v ON_ERROR_STOP=1 \
    -c "GRANT ALL ON SCHEMA public TO $APP_ROLE;" >/dev/null

# Verify the two invariants rather than assuming them.
is_super=$(psql -d "$ADMIN_DB" -qtA \
    -c "SELECT rolsuper FROM pg_roles WHERE rolname = '$APP_ROLE';")
[ "$is_super" = "f" ] || { echo "[provision] FAIL: $APP_ROLE is a superuser — RLS would be bypassed" >&2; exit 1; }
has_vector=$(psql -d "$DB_NAME" -qtA \
    -c "SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector');")
[ "$has_vector" = "t" ] || { echo "[provision] FAIL: pgvector not installed in $DB_NAME" >&2; exit 1; }

say "  ✓ $APP_ROLE is not a superuser (RLS will apply to it)"
say "  ✓ pgvector installed in $DB_NAME"
say "PROVISIONED — point DATABASE_URL at:"
say "  postgres://$APP_ROLE:<password>@<host>:<port>/$DB_NAME"
