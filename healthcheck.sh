#!/usr/bin/env bash
set -euo pipefail

# Docker healthchecks run as root; peer authentication requires the postgres UID.
if [ "$(id -u)" -eq 0 ]; then
    exec gosu postgres "$0" "$@"
fi

# The image's temporary initialization server uses listen_addresses=''.
# Use a socket query to distinguish it without rejected TCP authentication attempts.
export PGCONNECT_TIMEOUT=3
export PGOPTIONS='-c statement_timeout=3000'
ready=$(psql --no-psqlrc --no-password --tuples-only --no-align \
    -h /var/run/postgresql -p 5432 -U postgres -d postgres \
    -v ON_ERROR_STOP=1 \
    -c "SELECT current_setting('listen_addresses') <> '';")
[ "$ready" = t ]
