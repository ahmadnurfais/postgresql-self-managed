#!/usr/bin/env bash
#
# Detects a stuck WAL archive before it fills the filesystem, and reports how
# long that would take at the cluster's current write rate.
#
# PostgreSQL retains every WAL segment until archive_command succeeds, so a
# broken archive turns into unbounded growth of pg_wal, and takes down whatever
# else shares that filesystem when it fills. Exit 1 marks the systemd unit
# failed, so a stuck archive shows up in "systemctl --failed".
set -euo pipefail

PG_BASE_DIR="/opt/databases/postgresql"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER="postgres"
STANZA="main"
STATE_FILE="$PG_BASE_DIR/guard.state"
PGDATA_IN_CONTAINER="/var/lib/postgresql/18/docker"

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root (needs docker access)."
    exit 1
fi

[ -f "$SCRIPT_DIR/.env" ] || { echo "Error: .env not found in $SCRIPT_DIR."; exit 1; }
set -a; source "$SCRIPT_DIR/.env"; set +a

: "${PG_GUARD_READY_WARN:=20}"
: "${PG_GUARD_READY_CRIT:=200}"
: "${PG_GUARD_DISK_WARN_PCT:=85}"
: "${PG_GUARD_DISK_CRIT_PCT:=92}"
: "${PG_GUARD_BACKUP_MAX_AGE_HOURS:=36}"

STATUS=0
note() { echo "OK       $*"; }
warn() { echo "WARNING  $*"; }
crit() { echo "CRITICAL $*"; STATUS=1; }

psql_at() { docker exec -u postgres "$CONTAINER" psql -Atc "$1"; }

# --- Is the server even up? --------------------------------------------------
if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
    crit "container '$CONTAINER' is not running"
    exit "$STATUS"
fi

# --- Archive backlog ---------------------------------------------------------
# .ready files are segments PostgreSQL has finished and is waiting to archive.
# A healthy cluster sits at 0 to 2. Anything sustained above that is the archive
# falling behind, and each file is a 16MB segment that cannot be recycled.
READY=$(docker exec -u postgres "$CONTAINER" sh -c \
    "ls -1 $PGDATA_IN_CONTAINER/pg_wal/archive_status/*.ready 2>/dev/null | wc -l")

read -r FAILED LAST_FAIL_AGE LAST_ARCH_AGE <<<"$(psql_at "
  SELECT failed_count,
         coalesce(extract(epoch FROM now() - last_failed_time)::bigint, -1),
         coalesce(extract(epoch FROM now() - last_archived_time)::bigint, -1)
    FROM pg_stat_archiver" | tr '|' ' ')"

if [ "$READY" -ge "$PG_GUARD_READY_CRIT" ]; then
    crit "archive backlog ${READY} segments (~$((READY * 16))MB unarchived)"
elif [ "$READY" -ge "$PG_GUARD_READY_WARN" ]; then
    warn "archive backlog ${READY} segments (~$((READY * 16))MB unarchived)"
else
    note "archive backlog ${READY} segments"
fi

# A failure older than the last success is history, not an incident. Only a
# failure more recent than the last success means archiving is stuck now.
if [ "$LAST_FAIL_AGE" -ge 0 ] && { [ "$LAST_ARCH_AGE" -lt 0 ] || [ "$LAST_FAIL_AGE" -lt "$LAST_ARCH_AGE" ]; }; then
    crit "archive_command failing now (${FAILED} total failures, last ${LAST_FAIL_AGE}s ago)"
else
    note "archive_command healthy (${FAILED} historical failures)"
fi

# --- WAL write rate, measured across runs ------------------------------------
# pg_wal only grows without bound while archiving is broken, so this rate is what
# converts free space into time remaining.
NOW=$(date +%s)
LSN=$(psql_at "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')::bigint")
RATE=""
if [ -f "$STATE_FILE" ]; then
    read -r PREV_T PREV_LSN < "$STATE_FILE" || true
    DT=$((NOW - ${PREV_T:-NOW}))
    DL=$((LSN - ${PREV_LSN:-LSN}))
    if [ "$DT" -gt 0 ] && [ "$DL" -ge 0 ]; then
        RATE=$((DL / DT))    # bytes per second
    fi
fi
printf '%s %s\n' "$NOW" "$LSN" > "$STATE_FILE"

# --- Filesystem --------------------------------------------------------------
# POSIX -P output, not GNU --output, so this runs on any df.
# Fields: Filesystem 1024-blocks Used Available Capacity Mounted-on
read -r USED_PCT AVAIL_KB <<<"$(df -Pk "$PG_BASE_DIR" | awk 'END {gsub(/%/,"",$5); print $5, $4}')"
AVAIL_GB=$((AVAIL_KB / 1024 / 1024))
WAL_MB=$(docker exec -u postgres "$CONTAINER" du -sm "$PGDATA_IN_CONTAINER/pg_wal" | cut -f1)

if [ "$USED_PCT" -ge "$PG_GUARD_DISK_CRIT_PCT" ]; then
    crit "filesystem ${USED_PCT}% used, ${AVAIL_GB}GB free, pg_wal ${WAL_MB}MB"
elif [ "$USED_PCT" -ge "$PG_GUARD_DISK_WARN_PCT" ]; then
    warn "filesystem ${USED_PCT}% used, ${AVAIL_GB}GB free, pg_wal ${WAL_MB}MB"
else
    note "filesystem ${USED_PCT}% used, ${AVAIL_GB}GB free, pg_wal ${WAL_MB}MB"
fi

if [ -n "$RATE" ] && [ "$RATE" -gt 0 ]; then
    PER_DAY_GB=$(( RATE * 86400 / 1024 / 1024 / 1024 ))
    if [ "$PER_DAY_GB" -gt 0 ]; then
        # Integer hours, so a headroom of under a day does not round to "0 days".
        HOURS_LEFT=$(( AVAIL_GB * 24 / PER_DAY_GB ))
        MSG="WAL rate ~${PER_DAY_GB}GB/day; if archiving stops, the filesystem fills in ~${HOURS_LEFT}h"
        if [ "$HOURS_LEFT" -lt 48 ]; then
            crit "$MSG"
        elif [ "$HOURS_LEFT" -lt 168 ]; then
            warn "$MSG"
        else
            note "$MSG"
        fi
    else
        note "WAL rate <1GB/day"
    fi
fi

# --- Backup freshness --------------------------------------------------------
# A timer that silently stopped firing looks identical to a healthy system until
# a restore is needed.
# "pgbackrest info" exits 0 even when the repository is broken, reporting the
# problem in status.code with an empty backup list. Reading only the list turns
# a damaged repository into a false "no backups exist", which points at the
# wrong incident. Codes: 0 ok, 2 no valid backups, anything else an error.
INFO_JSON=$(docker exec -u postgres "$CONTAINER" \
    pgbackrest --stanza="$STANZA" info --output=json 2>/dev/null) || INFO_JSON=""
if [ -z "$INFO_JSON" ]; then
    INFO_CODE=99; INFO_MSG="info command failed"; LAST_BACKUP=0
else
    read -r INFO_CODE LAST_BACKUP INFO_MSG <<<"$(printf '%s' "$INFO_JSON" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)[0]
    b = d.get("backup") or []
    ts = int(b[-1]["timestamp"]["stop"]) if b else 0
    print(d["status"]["code"], ts, d["status"].get("message", ""))
except Exception as e:
    print(99, 0, "unparseable info output")')"
fi

if [ "$INFO_CODE" -ne 0 ] && [ "$INFO_CODE" -ne 2 ]; then
    crit "repository problem for stanza '$STANZA': ${INFO_MSG} (status ${INFO_CODE})"
elif [ "$LAST_BACKUP" -eq 0 ]; then
    crit "no backup found in stanza '$STANZA'"
else
    AGE_H=$(( (NOW - LAST_BACKUP) / 3600 ))
    if [ "$AGE_H" -ge "$PG_GUARD_BACKUP_MAX_AGE_HOURS" ]; then
        crit "last backup finished ${AGE_H}h ago (limit ${PG_GUARD_BACKUP_MAX_AGE_HOURS}h)"
    else
        note "last backup finished ${AGE_H}h ago"
    fi
fi

exit "$STATUS"
