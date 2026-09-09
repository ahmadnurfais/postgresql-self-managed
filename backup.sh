#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER="postgres"
STANZA="main"

TYPE="${1:-}"
case "$TYPE" in
    full|diff|incr) ;;
    *)
        echo "Usage: $0 full|diff|incr"
        echo
        echo "  full  every file in the cluster; the base every other type builds on"
        echo "  diff  files changed since the last full backup"
        echo "  incr  files changed since the last backup of any type"
        exit 1
        ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root (needs docker access)."
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "Error: .env file not found in $SCRIPT_DIR."
    exit 1
fi

# Retention lives in the rendered pgbackrest.conf, not here. Expiry is part of
# the backup command: pgBackRest drops expired backups together with the WAL
# that only they needed. Pruning the repository by file age instead would orphan
# WAL from a still-referenced backup and break point-in-time recovery.
echo "Taking a $TYPE backup of stanza '$STANZA'..."
docker exec -u postgres "$CONTAINER" \
    pgbackrest --stanza="$STANZA" backup --type="$TYPE"

echo
docker exec -u postgres "$CONTAINER" pgbackrest --stanza="$STANZA" info
