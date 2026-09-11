#!/usr/bin/env bash
set -euo pipefail

PG_BASE_DIR="/opt/databases/postgresql"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER="postgres"
STANZA="main"

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root. It creates $PG_BASE_DIR and chowns it to the postgres container user (999)."
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "Error: .env file not found in $SCRIPT_DIR. Copy .env.example to .env and fill in the values."
    exit 1
fi

set -a
source "$SCRIPT_DIR/.env"
set +a

# Role and database names are interpolated into SQL as identifiers, which
# quote_ident cannot help with inside a heredoc. Restricting them to unquoted
# lower-case identifiers is what makes that interpolation safe.
for var in PG_APP_USER PG_APP_DB; do
    if [[ ! ${!var} =~ ^[a-z_][a-z0-9_]*$ ]]; then
        echo "Error: $var must be a lower-case identifier matching ^[a-z_][a-z0-9_]*$ (got '${!var}')."
        exit 1
    fi
done

# --- Preflight ---------------------------------------------------------------
export PG_AUTH_MODE="${PG_AUTH_MODE-tls}"
export PG_CLIENT_CRL_FILE="${PG_CLIENT_CRL_FILE-}"
case "$PG_AUTH_MODE" in
    tls|mtls) ;;
    *) echo "Error: PG_AUTH_MODE must be tls or mtls."; exit 1 ;;
esac
if [ "$PG_AUTH_MODE" = tls ] && [ -z "${PG_APP_PASSWORD:-}" ]; then
    echo "Error: PG_APP_PASSWORD is required in tls mode."
    exit 1
fi
if [ -n "$PG_CLIENT_CRL_FILE" ]; then
    if [ "$PG_AUTH_MODE" != mtls ] || [[ ! "$PG_CLIENT_CRL_FILE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        echo "Error: PG_CLIENT_CRL_FILE requires mtls mode and a filename inside PG_TLS_DIR."
        exit 1
    fi
fi
for var in PG_TLS_DIR PG_BIND_ADDRESS PG_APP_ALLOWED_CIDR PG_PORT POSTGRES_PASSWORD; do
    if [ -z "${!var:-}" ]; then
        echo "Error: $var must be set in .env."
        exit 1
    fi
done
if [ "$PG_APP_USER" = postgres ]; then
    echo "Error: PG_APP_USER must not be the postgres superuser."
    exit 1
fi
if [[ "$PG_TLS_DIR" != /* ]] || [ ! -f "$PG_TLS_DIR/fullchain.pem" ] || [ ! -f "$PG_TLS_DIR/privkey.pem" ]; then
    echo "Error: PG_TLS_DIR must be an absolute directory containing fullchain.pem and privkey.pem."
    exit 1
fi
if [ "$PG_AUTH_MODE" = mtls ] && [ ! -f "$PG_TLS_DIR/client-ca.pem" ]; then
    echo "Error: mtls mode requires PG_TLS_DIR/client-ca.pem."
    exit 1
fi
if [ -n "$PG_CLIENT_CRL_FILE" ] && [ ! -f "$PG_TLS_DIR/$PG_CLIENT_CRL_FILE" ]; then
    echo "Error: the configured client CRL file does not exist in PG_TLS_DIR."
    exit 1
fi
command -v python3 >/dev/null || { echo "Error: python3 is required for IP/CIDR validation."; exit 1; }
python3 - <<'PY'
import ipaddress
import os
import re
import sys

try:
    ipaddress.IPv4Address(os.environ['PG_BIND_ADDRESS'])
    cidrs = os.environ['PG_APP_ALLOWED_CIDR'].split()
    if not cidrs:
        raise ValueError('PG_APP_ALLOWED_CIDR must contain at least one network CIDR')
    for cidr in cidrs:
        if not re.fullmatch(r'[0-9a-fA-F:.]+/[0-9]+', cidr) or ipaddress.ip_network(cidr).prefixlen == 0:
            raise ValueError(f'PG_APP_ALLOWED_CIDR contains an invalid or unrestricted CIDR: {cidr}')
    port = os.environ['PG_PORT']
    if not port.isascii() or not port.isdecimal() or not 1 <= int(port) <= 65535:
        raise ValueError('PG_PORT must be between 1 and 65535')
except ValueError as error:
    sys.exit(f'Error: {error}')
PY

# A second PostgreSQL already on this port makes "docker compose up" fail with a
# message that does not name the culprit, and only after the directories have
# been created. Check first.
if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "Container '$CONTAINER' is already running; skipping the port check."
elif ss -ltnH "sport = :$PG_PORT" 2>/dev/null | grep -q .; then
    echo "Error: port $PG_PORT is already in use."
    echo "  Another PostgreSQL is probably already published on this port."
    echo "  Stop it, or set PG_PORT to a free port in .env."
    ss -ltnp "sport = :$PG_PORT" 2>/dev/null || true
    exit 1
fi

# Build before checking access as the actual image user. No database is started.
echo "Building the image (postgres:18.6-trixie plus pgbackrest)..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" build
docker run --rm --user postgres --entrypoint sh \
    -e PG_AUTH_MODE -e PG_CLIENT_CRL_FILE \
    --mount "type=bind,src=$PG_TLS_DIR,dst=/tls,readonly" \
    postgres-pgbackrest:18.6 \
    -c 'set -e
        test -r /tls/fullchain.pem
        test -r /tls/privkey.pem
        if [ "$PG_AUTH_MODE" = mtls ]; then
            openssl x509 -in /tls/client-ca.pem -noout -checkend 0
        fi
        if [ -n "$PG_CLIENT_CRL_FILE" ]; then
            openssl crl -in "/tls/$PG_CLIENT_CRL_FILE" -noout
        fi' || {
    echo "Error: required TLS files are unreadable or client trust files are invalid."
    exit 1
}

# --- Directories -------------------------------------------------------------
echo "Preparing directories in $PG_BASE_DIR..."
mkdir -p "$PG_BASE_DIR"/{data,backups,spool,log,conf}

# data/ is not chowned recursively: the entrypoint owns everything under PGDATA
# and its permissions are load-bearing (PostgreSQL refuses to start on a data
# directory that is group- or world-accessible).
chown 999:999 "$PG_BASE_DIR" "$PG_BASE_DIR/data"
chown -R 999:999 "$PG_BASE_DIR"/{backups,spool,log,conf}

# --- pgBackRest configuration ------------------------------------------------
# A .env predating these settings would otherwise render an empty value, which
# pgbackrest rejects, breaking archiving in exactly the silent way this setting
# exists to bound.
: "${PGBACKREST_ARCHIVE_QUEUE_MAX:=64GiB}"

echo "Rendering pgbackrest.conf to $PG_BASE_DIR/conf/pgbackrest.conf..."
sed -e "s|\${PGBACKREST_RETENTION_FULL}|${PGBACKREST_RETENTION_FULL}|g" \
    -e "s|\${PGBACKREST_RETENTION_DIFF}|${PGBACKREST_RETENTION_DIFF}|g" \
    -e "s|\${PGBACKREST_ARCHIVE_QUEUE_MAX}|${PGBACKREST_ARCHIVE_QUEUE_MAX}|g" \
    "$SCRIPT_DIR/pgbackrest.conf.template" \
    > "$PG_BASE_DIR/conf/pgbackrest.conf"
chown 999:999 "$PG_BASE_DIR/conf/pgbackrest.conf"
chmod 640 "$PG_BASE_DIR/conf/pgbackrest.conf"

# Write in place so an existing file bind mount sees the new content.
echo "Rendering pg_hba.conf..."
python3 - "$SCRIPT_DIR/pg_hba.conf.template" <<'PY' > "$PG_BASE_DIR/conf/pg_hba.conf"
import os
from pathlib import Path
import sys

template = Path(sys.argv[1]).read_text()
template = template.replace('${PG_APP_DB}', os.environ['PG_APP_DB'])
template = template.replace('${PG_APP_USER}', os.environ['PG_APP_USER'])
method = 'cert' if os.environ['PG_AUTH_MODE'] == 'mtls' else 'scram-sha-256'
template = template.replace('${PG_APP_AUTH_METHOD}', method)
for line in template.splitlines(keepends=True):
    if '${PG_APP_ALLOWED_CIDR}' in line:
        for cidr in os.environ['PG_APP_ALLOWED_CIDR'].split():
            sys.stdout.write(line.replace('${PG_APP_ALLOWED_CIDR}', cidr))
    else:
        sys.stdout.write(line)
PY
chown 999:999 "$PG_BASE_DIR/conf/pg_hba.conf"
chmod 640 "$PG_BASE_DIR/conf/pg_hba.conf"

# Explicit empty values clear client trust when switching back to tls mode.
ca_file=''
crl_file=''
if [ "$PG_AUTH_MODE" = mtls ]; then
    ca_file='/etc/postgresql/tls/client-ca.pem'
    if [ -n "$PG_CLIENT_CRL_FILE" ]; then
        crl_file="/etc/postgresql/tls/$PG_CLIENT_CRL_FILE"
    fi
fi
printf "ssl_ca_file = '%s'\nssl_crl_file = '%s'\n" "$ca_file" "$crl_file" \
    > "$PG_BASE_DIR/conf/auth.conf"
chown 999:999 "$PG_BASE_DIR/conf/auth.conf"
chmod 640 "$PG_BASE_DIR/conf/auth.conf"

# --- Start -------------------------------------------------------------------
echo "Starting PostgreSQL..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d postgres

# The shared socket probe rejects the temporary server with listen_addresses=''.
echo "Waiting for PostgreSQL readiness..."
attempts=0
until docker exec -u postgres "$CONTAINER" /usr/local/bin/postgres-healthcheck >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 60 ]; then
        echo "Error: PostgreSQL did not become ready after 60 checks. Check docker compose logs postgres."
        exit 1
    fi
    echo "Waiting..."
    sleep 2
done

# Every command runs as the postgres user. The image sets no USER, so a bare
# "docker exec" is root, and pgbackrest run as root writes root-owned files into
# the repository that archive-push (which runs as postgres) then cannot touch.
pg_exec() {
    docker exec -u postgres "$CONTAINER" "$@"
}

# Passwords reach psql on stdin rather than in arguments, because "docker exec"
# arguments are visible in host ps. Single quotes in a value are doubled so a
# password containing one cannot break out of the SQL literal.
psql_stdin() {
    docker exec -i -u postgres "$CONTAINER" \
        psql -v ON_ERROR_STOP=1 --no-psqlrc -d "${1:-postgres}"
}

sql_literal() {
    printf "'%s'" "${1//\'/\'\'}"
}

# Apply the rendered HBA policy when up -d reuses an existing container.
psql_stdin postgres <<'SQL'
SELECT pg_reload_conf();
SQL

# --- pgBackRest stanza -------------------------------------------------------
# archive_mode is on from the first boot, so the WAL written during initdb has
# nowhere to go until this runs. PostgreSQL retries archive_command
# indefinitely and keeps the segments, so they are pushed as soon as the stanza
# exists; the log lines from that window are expected and nothing is lost.
echo "Creating the pgBackRest stanza '$STANZA' (if not exists)..."
pg_exec pgbackrest --stanza="$STANZA" stanza-create

echo "Verifying the archive and repository end to end..."
pg_exec pgbackrest --stanza="$STANZA" check

# --- Roles and databases -----------------------------------------------------
echo "Setting the superuser password..."
psql_stdin postgres <<SQL
ALTER ROLE postgres PASSWORD $(sql_literal "$POSTGRES_PASSWORD");
SQL

echo "Creating application role '$PG_APP_USER' (if not exists)..."
app_password_sql=NULL
if [ "$PG_AUTH_MODE" = tls ]; then
    app_password_sql=$(sql_literal "$PG_APP_PASSWORD")
fi
psql_stdin postgres <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$PG_APP_USER') THEN
    CREATE ROLE $PG_APP_USER LOGIN PASSWORD $app_password_sql;
    RAISE NOTICE 'Created role $PG_APP_USER.';
  ELSE
    ALTER ROLE $PG_APP_USER LOGIN PASSWORD $app_password_sql;
    RAISE NOTICE 'Role $PG_APP_USER already exists; authentication credentials applied.';
  END IF;
END
\$\$;
SQL

# CREATE DATABASE cannot run inside a transaction block, so it cannot go in the
# DO block above. \gexec runs the generated statement only when the SELECT
# returns a row.
echo "Creating database '$PG_APP_DB' owned by '$PG_APP_USER' (if not exists)..."
psql_stdin postgres <<SQL
SELECT 'CREATE DATABASE $PG_APP_DB OWNER $PG_APP_USER'
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$PG_APP_DB')
\gexec
SQL

# Ownership is what grants the role the public schema. PostgreSQL 15 revoked
# CREATE on public from PUBLIC, and public is owned by pg_database_owner, so the
# database owner gets it and nobody else does.
psql_stdin postgres <<SQL
ALTER DATABASE $PG_APP_DB OWNER TO $PG_APP_USER;
SQL

echo "Enabling pg_stat_statements..."
for db in postgres "$PG_APP_DB"; do
    psql_stdin "$db" <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL
done

# --- Baseline backup ---------------------------------------------------------
if pg_exec pgbackrest --stanza="$STANZA" info | grep -q 'full backup:'; then
    echo "Repository already holds a full backup; skipping the baseline."
else
    echo "Taking the baseline full backup (this is the only one init.sh takes)..."
    pg_exec pgbackrest --stanza="$STANZA" backup --type=full
fi

echo
echo "PostgreSQL 18 setup complete."
echo "  Connect using the DNS hostname in the certificate SAN and sslmode=verify-full."
echo "  Database: $PG_APP_DB; user: $PG_APP_USER; published port: $PG_PORT"
echo "  Authentication mode: $PG_AUTH_MODE"
echo
echo "Install the backup timers next; see the Backups section of README.md."
