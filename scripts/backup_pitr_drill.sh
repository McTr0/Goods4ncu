#!/usr/bin/env bash
# Point-in-time-recovery drill (roadmap: 备份、PITR 与恢复演练).
#
# Rehearses the full recovery runbook on a THROWAWAY PostgreSQL cluster so the
# procedure is executable and timed, without touching any real database:
#
#   1. initdb a scratch cluster with WAL archiving enabled
#   2. take a base backup (pg_basebackup)
#   3. write a "good" marker row, record T1
#   4. write a "disaster" row after T1 (simulating the bad deploy/deletion)
#   5. restore the base backup with recovery_target_time = T1
#   6. verify: the marker row exists, the disaster row does not
#
# Exit code 0 = drill passed. All artifacts live under a temp dir and are
# removed on exit. Requires: initdb, pg_ctl, psql, pg_basebackup on PATH.
#
# Production mapping (see docs/operations.md):
#   step 1-2  -> continuous archiving + scheduled base backups
#   step 5    -> restore_command from the WAL archive, recovery target from
#                the incident timeline
#   step 6    -> the acceptance checks before reopening traffic

set -euo pipefail

PRIMARY_PORT="${DRILL_PRIMARY_PORT:-5544}"
RESTORE_PORT="${DRILL_RESTORE_PORT:-5545}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pitr_drill.XXXXXX")"
PRIMARY="$WORK/primary"
ARCHIVE="$WORK/wal_archive"
BASEBACKUP="$WORK/basebackup"
RESTORE="$WORK/restore"
LOG="$WORK/log"
mkdir -p "$ARCHIVE" "$LOG"

started=""
cleanup() {
    for dir in $started; do
        pg_ctl -D "$dir" stop -m immediate >/dev/null 2>&1 || true
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

say() { printf '[drill] %s\n' "$*"; }

t_start=$(date +%s)

# --- 1. Scratch primary with archiving --------------------------------------
say "initdb scratch primary"
initdb -D "$PRIMARY" --auth=trust --no-sync >/dev/null
cat >> "$PRIMARY/postgresql.conf" <<CONF
port = $PRIMARY_PORT
listen_addresses = '127.0.0.1'
archive_mode = on
archive_command = 'cp %p "$ARCHIVE/%f"'
wal_level = replica
max_wal_senders = 3
CONF
pg_ctl -D "$PRIMARY" -l "$LOG/primary.log" start >/dev/null
started="$PRIMARY"
say "primary up on :$PRIMARY_PORT"

PSQL_P=(psql -h 127.0.0.1 -p "$PRIMARY_PORT" -d postgres -qtA -c)

"${PSQL_P[@]}" "CREATE TABLE drill_facts (id serial PRIMARY KEY, label text, at timestamptz DEFAULT now());" >/dev/null

# --- 2. Base backup ----------------------------------------------------------
say "taking base backup"
pg_basebackup -h 127.0.0.1 -p "$PRIMARY_PORT" -D "$BASEBACKUP" -Fp -Xs --no-sync >/dev/null

# --- 3. Good state at T1 ------------------------------------------------------
"${PSQL_P[@]}" "INSERT INTO drill_facts (label) VALUES ('good-state');" >/dev/null
sleep 1.5
T1="$("${PSQL_P[@]}" "SELECT now();")"
say "T1 recorded: $T1"
sleep 1.5

# --- 4. Disaster after T1 -----------------------------------------------------
"${PSQL_P[@]}" "INSERT INTO drill_facts (label) VALUES ('disaster-row');" >/dev/null
say "disaster written after T1"
# Force the WAL containing both writes into the archive.
"${PSQL_P[@]}" "SELECT pg_switch_wal();" >/dev/null

# --- 5. Restore to T1 ---------------------------------------------------------
say "restoring base backup to recovery_target_time = T1"
cp -R "$BASEBACKUP" "$RESTORE"
rm -rf "$RESTORE/pg_wal"; mkdir "$RESTORE/pg_wal"
chmod 700 "$RESTORE"
cat >> "$RESTORE/postgresql.conf" <<CONF
port = $RESTORE_PORT
listen_addresses = '127.0.0.1'
archive_mode = off
restore_command = 'cp "$ARCHIVE/%f" %p'
recovery_target_time = '$T1'
recovery_target_action = 'promote'
CONF
touch "$RESTORE/recovery.signal"
pg_ctl -D "$RESTORE" -l "$LOG/restore.log" start >/dev/null
started="$started $RESTORE"

# Wait for recovery to finish (promotion).
for _ in $(seq 1 30); do
    if [ "$(psql -h 127.0.0.1 -p "$RESTORE_PORT" -d postgres -qtA -c 'SELECT pg_is_in_recovery();' 2>/dev/null)" = "f" ]; then
        break
    fi
    sleep 1
done

PSQL_R=(psql -h 127.0.0.1 -p "$RESTORE_PORT" -d postgres -qtA -c)

# --- 6. Acceptance ------------------------------------------------------------
good="$("${PSQL_R[@]}" "SELECT COUNT(*) FROM drill_facts WHERE label = 'good-state';")"
bad="$("${PSQL_R[@]}" "SELECT COUNT(*) FROM drill_facts WHERE label = 'disaster-row';")"
t_end=$(date +%s)

say "restored instance: good-state rows=$good disaster rows=$bad"
say "elapsed: $((t_end - t_start))s"

if [ "$good" = "1" ] && [ "$bad" = "0" ]; then
    say "PITR DRILL PASSED — recovered to T1 with the disaster excluded"
    exit 0
else
    say "PITR DRILL FAILED"
    exit 1
fi
