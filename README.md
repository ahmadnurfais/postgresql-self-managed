# PostgreSQL Docker Self-Managed

A single-node PostgreSQL 18 cluster in Docker with pgBackRest point-in-time recovery, for a
self-managed Linux server.

A single node provides no redundancy and no failover. Recovery depends entirely on the backup
repository, so the timers described below are part of the setup, not an extra.

The image is the official `postgres:18.6-trixie` with `pgbackrest` layered on from the same PGDG
apt repository the base image already configures. pgBackRest has to live in that image rather
than a sidecar container because `archive_command` is executed by the `postgres` process itself.

Guides: [Self-managed client CA and mTLS setup](MTLS-SETUP.md),
[TLS and mTLS explained](TLS-MTLS-EXPLAINED.md).

## Table of contents

- [Layout](#layout)
- [Setup](#setup)
  - [Roles](#roles)
- [Configuration](#configuration)
  - [Authentication modes](#authentication-modes)
  - [Collation](#collation)
- [Connecting](#connecting)
  - [From another compose project on the same host](#from-another-compose-project-on-the-same-host)
  - [From a container using host networking](#from-a-container-using-network_mode-host)
  - [ASP.NET Core / Npgsql](#aspnet-core--npgsql)
  - [Verify application connections](#verify-application-connections)
- [TLS files and renewal](#tls-files-and-renewal)
  - [Additional mTLS prerequisites](#additional-mtls-prerequisites)
  - [Permissions and renewal](#permissions-and-renewal)
  - [Percent-encode credentials](#percent-encode-credentials)
- [Sizing](#sizing)
  - [Asynchronous I/O](#asynchronous-io)
- [Huge pages](#huge-pages)
  - [Transparent huge pages](#transparent-huge-pages)
- [Backups](#backups)
  - [Why a stuck archive is dangerous here](#why-a-stuck-archive-is-dangerous-here)
  - [What actually breaks the archive](#what-actually-breaks-the-archive)
  - [The guard](#the-guard)
  - [The backstop](#the-backstop)
  - [Manual checks](#manual-checks)
- [Restore](#restore)
  - [Verifying without touching the live cluster](#verifying-without-touching-the-live-cluster)
- [Upgrades](#upgrades)
  - [Minor version](#minor-version)
  - [Major version](#major-version)
- [Monitoring](#monitoring)
- [Connection pooling](#connection-pooling)

## Layout

| Path | Contents |
| --- | --- |
| `/opt/databases/postgresql/data` | Cluster. `PGDATA` is `data/18/docker` underneath it |
| `/opt/databases/postgresql/backups` | pgBackRest repository: backups and archived WAL |
| `/opt/databases/postgresql/spool` | Spool for asynchronous WAL archiving |
| `/opt/databases/postgresql/log` | pgBackRest logs |
| `/opt/databases/postgresql/conf/pgbackrest.conf` | Rendered from `pgbackrest.conf.template` by `init.sh` |
| `./postgresql.conf` | Server configuration, mounted read-only into the container |
| `/opt/databases/postgresql/conf/pg_hba.conf` | Authentication policy rendered from `pg_hba.conf.template` |
| `/opt/databases/postgresql/conf/auth.conf` | Generated client CA and CRL settings, included by `postgresql.conf` |
| `PG_TLS_DIR` | Externally provisioned TLS directory, mounted read-only at `/etc/postgresql/tls` |

PostgreSQL 18 changed the image's data directory to `/var/lib/postgresql/18/docker` and moved the
declared volume from `/var/lib/postgresql/data` to `/var/lib/postgresql`, so that `pg_upgrade
--link` can hard-link between two major versions inside one volume. A compose file carried over
from 17 that mounts `/var/lib/postgresql/data` gets an ignored mount and a database that
disappears with the container.

## Setup

Requirements: Docker Engine with Compose v2, Bash, Python 3 for address validation,
and externally provisioned TLS files as described in **TLS files and renewal**.
The host directory ownership in `init.sh` assumes rootful Docker without user-namespace
remapping and image UID/GID `999:999`.

```sh
cp .env.example .env
nano .env          # set mode, credentials, TLS directory, bind address, allowed CIDRs
sudo ./init.sh
```

Run `init.sh` before any `docker compose up`. It renders `pgbackrest.conf` before starting the
container, and Docker creates a **directory** at a bind-mount source that does not exist. Starting
the stack first therefore produces a root-owned directory where that config belongs, and every
`archive-push` then fails with `Is a directory` while PostgreSQL itself looks perfectly healthy.
Recovering means `docker compose down`, `rm -rf` that directory as root, then `init.sh`.

`init.sh` requires root: it creates `/opt/databases/postgresql` and chowns it to uid 999, the
postgres container user. It is idempotent. Re-running it against a live instance renders the
configuration again, resets the superuser password, and applies application credentials
for the selected mode. It reports existing objects and skips the baseline backup.

What it does:

1. Validates required settings, IP addresses, CIDR, port, and TLS file presence; checks port availability.
2. Builds the image and checks TLS file readability as its PostgreSQL user.
3. Prepares directories, renders pgBackRest and authentication configuration, and starts the container.
4. Creates the pgBackRest stanza and runs `pgbackrest check`, which proves the archive works
   end to end rather than merely that the config parses.
5. Creates the application role, and the application database with that role as `OWNER`.
6. Creates the `pg_stat_statements` extension in `postgres` and the application database.
7. Takes a baseline full backup.

`archive_mode` is on from the first boot, so the WAL written by `initdb` has nowhere to go for the
few seconds before the stanza exists. PostgreSQL retries `archive_command` indefinitely and
retains those segments, so they are archived as soon as the stanza is created. The failure lines
in the log during that window are expected.

### Roles

| Role | Purpose |
| --- | --- |
| `postgres` | Superuser. Created by the image entrypoint from `POSTGRES_PASSWORD` |
| `PG_APP_USER` | Owns `PG_APP_DB` and nothing else |

Ownership of the database is what grants the application role the `public` schema. PostgreSQL 15
revoked `CREATE` on `public` from `PUBLIC` and made the schema owned by `pg_database_owner`, so
the database owner has it and no other role does.

pgBackRest and administrative `psql` commands connect over the Unix socket using
`local all postgres peer`. Commands must run as the `postgres` operating-system user:
`docker exec -u postgres postgres psql -d postgres`. `POSTGRES_USER` stays `postgres`
so the image entrypoint can initialize the database through the same rule.

## Configuration

`postgresql.conf` in this repository is the server's configuration file, selected with
`postgres -c config_file=/etc/postgresql/postgresql.conf`. The image entrypoint never writes to
`postgresql.conf`, so nothing competes with it. Applying an edit:

```sh
docker compose restart postgres
```

A config file outside the data directory has to name `data_directory`, `hba_file` and
`ident_file` explicitly. Without `hba_file`, PostgreSQL looks for `pg_hba.conf` in the directory
holding the config file and refuses to start.

`init.sh` renders `pg_hba.conf.template` to the host configuration directory. PostgreSQL
uses its read-only mount at `/etc/postgresql/pg_hba.conf`. The active rules permit local
`peer` administration, reject plaintext TCP, and permit the selected TLS authentication for `PG_APP_USER`
to `PG_APP_DB` from `PG_APP_ALLOWED_CIDR`. Unmatched connections are rejected.

`PG_APP_ALLOWED_CIDR` accepts one explicit IPv4 or IPv6 network, or a quoted,
space-separated list. `init.sh` generates one application rule per entry. Empty lists,
malformed CIDRs, and `/0` are rejected.

```dotenv
PG_APP_ALLOWED_CIDR=192.0.2.10/32
# Multiple clients, including IPv6:
# PG_APP_ALLOWED_CIDR='192.0.2.10/32 192.0.2.11/32 2001:db8::10/128'
```

Names in the HBA rule are quoted to prevent interpretation as special HBA keywords.
Re-running `init.sh` renders and reloads the policy from `.env` and the template,
overwriting manual edits to `/opt/databases/postgresql/conf/pg_hba.conf`.
It also builds the image and applies credentials as described in Setup.

For temporary testing, edit the host-mounted authentication file, check
`pg_hba_file_rules` for errors, and run `SELECT pg_reload_conf();` through the local
administrative socket. Authentication changes govern new connections without a restart;
existing sessions remain connected. Persist intended deployment changes in `.env` or
the template before the next initialization run.

`healthcheck.sh`, installed in the image as `postgres-healthcheck`, queries PostgreSQL
through the Unix socket as the `postgres` OS user using `peer` authentication. It requires
nonempty `listen_addresses`, so the image's temporary initialization server is not ready.
Docker and the initialization wait use the same probe. It checks local query readiness
and TCP configuration, not remote reachability or TLS validation. Use the connection
checks below for those purposes.

`postgresql.auto.conf` in `PGDATA` is read after `postgresql.conf`, so `ALTER SYSTEM` still works
and still wins. A setting that appears not to take effect after a restart is usually one that
`ALTER SYSTEM` set at some point; `ALTER SYSTEM ... RESET` clears it.

### Authentication modes

`PG_AUTH_MODE` accepts `tls` or `mtls`. An omitted setting defaults to `tls`;
an empty or unknown value fails initialization. Both modes require server TLS and
restrict application access to `PG_APP_ALLOWED_CIDR`.

| Mode | HBA method | Application credential | Required server files under `PG_TLS_DIR` |
| --- | --- | --- | --- |
| `tls` | `scram-sha-256` | `PG_APP_PASSWORD` | `fullchain.pem`, `privkey.pem` |
| `mtls` | `cert` | Client certificate with CN equal to `PG_APP_USER`, and its private key | Server files plus `client-ca.pem` |

`init.sh` requires an application password in `tls` mode. In `mtls` mode it ignores
`PG_APP_PASSWORD` and sets the role's password to `NULL`. The application still supplies
a username and receives that role's permissions. `POSTGRES_PASSWORD` remains required
in both modes for the image's superuser initialization and administrative credential setup.

`init.sh` renders `/opt/databases/postgresql/conf/auth.conf` with `ssl_ca_file` and
`ssl_crl_file`. In `tls` mode both are empty. In `mtls` mode `ssl_ca_file` points to
`/etc/postgresql/tls/client-ca.pem`. Keep these settings out of `ALTER SYSTEM` overrides.

Optional client revocation checking:

```dotenv
PG_AUTH_MODE=mtls
PG_CLIENT_CRL_FILE=client-ca.crl.pem
```

`PG_CLIENT_CRL_FILE` is a filename inside `PG_TLS_DIR`, not an absolute path. It accepts
letters, digits, dots, underscores, and hyphens, starting with a letter or digit.
A nonempty value requires `mtls` mode and an existing readable PEM CRL file.
An empty value disables CRL checking; certificate trust, identity, and expiry checks remain.

To switch modes, prepare the external prerequisites, edit `.env`, and run `sudo ./init.sh`.
Returning to `tls` requires a nonempty `PG_APP_PASSWORD` and an empty `PG_CLIENT_CRL_FILE`.
The script clears client trust settings in `tls` mode and regenerates the HBA rules.
The role and database retain their ownership and data.

Authentication and trust settings support reload. A deployment update that adds mounts,
changes the image, or changes the published port can recreate the container and interrupt
connections. Existing sessions otherwise remain authenticated until disconnected; use fresh
connections or recycle application pools to verify a mode change. Removing a password or
revoking a certificate does not terminate existing sessions.

### Collation

The cluster is initialised with the builtin `C.UTF-8` locale
(`--locale-provider=builtin --builtin-locale=C.UTF-8`), fixed at `initdb` time and changeable only
by dump and reload.

Text sorts by Unicode code point, so `'Z' < 'a'`. Natural-language ordering is available per
query or per column:

```sql
SELECT name FROM people ORDER BY name COLLATE "en-US-x-icu";
```

The reason for the builtin provider over libc is that libc collations come from glibc, which
changes its collation data between releases. A rebuilt image on a newer Debian can therefore
change the sort order that existing text indexes were built with, which corrupts index lookups
silently until a `REINDEX`. The builtin provider is part of PostgreSQL and never changes.

Data checksums are on. PostgreSQL 18 enables them by `initdb` default.

```sh
docker exec -u postgres postgres psql -Atc 'SHOW data_checksums'
docker exec -u postgres postgres psql -Atc \
  "SELECT datlocprovider, datlocale FROM pg_database WHERE datname = 'postgres'"
# b|C.UTF-8
```

`datlocale` is the column to read, not `datcollate`. Under the builtin provider `datcollate` and
`datctype` still hold the libc locale the environment supplied (`en_US.utf8`) and are unused, so
reading them suggests the setting did not apply when it did. `datlocprovider` of `b` is the
builtin provider.

## Connecting

`PG_BIND_ADDRESS` selects the host IPv4 interface for the published `PG_PORT`.
The default `127.0.0.1` permits host-local access. Remote deployments set an address
assigned to the host, or `0.0.0.0` with ingress restricted to approved sources.
The database DNS hostname must resolve to a reachable endpoint and match the server
certificate SAN. Examples use `db.example.com`; each deployment supplies its own name.

Set `PG_APP_ALLOWED_CIDR` to the backend source as PostgreSQL sees it. A backend behind
NAT normally arrives from its public egress IP. Host-local published-port connections
can arrive from the Docker bridge gateway. Container clients arrive from their bridge
addresses. Confirm the source in the deployed network before choosing the allow rule.

Restrict the published port at the provider firewall and Docker-aware host firewall.
Docker-published traffic can bypass ordinary UFW rules. Verify access from both an
allowed and a denied source; a UFW status listing alone is insufficient.

For Cloudflare DNS, use **DNS only** for the database record. The standard HTTP proxy
does not proxy PostgreSQL on port 5432. PostgreSQL handles TLS itself.

```sh
psql "host=db.example.com port=5432 dbname=app_db user=app_user sslmode=verify-full sslrootcert=/path/to/ca-bundle.pem" -W
```

The command above uses `tls` mode. For passwordless `mtls`:

```sh
psql "host=db.example.com port=5432 dbname=app_db user=app_user sslmode=verify-full sslrootcert=/path/to/server-ca-bundle.pem sslcert=/path/to/client.crt sslkey=/path/to/client.key" -w
```

The CA bundle must trust the server certificate issuer. It is a client-side file,
not the server private key. `psql` trust configuration differs from Npgsql's OS trust store.

### From another compose project on the same host

`pg-net` is declared with a fixed name, so other projects attach to it as an external network:

```yaml
services:
  my-app:
    image: my-app:latest
    environment:
      ConnectionStrings__DefaultConnection: "Host=db.example.com;Port=5432;Database=app_db;Username=app_user;Password=<secret>;SSL Mode=VerifyFull"
    networks:
      - pg-net

networks:
  pg-net:
    external: true
```

`external: true` attaches to the existing network instead of creating one. Start the PostgreSQL
stack first; a project that comes up before `pg-net` exists fails rather than quietly building a
network of its own.

Container traffic on `pg-net` uses port 5432 without the host port mapping. Configure a
network alias matching the certificate SAN on the database service, for example in a
deployment-specific Compose override:

```yaml
services:
  postgres:
    networks:
      pg-net:
        aliases:
          - db.example.com
```

The application must resolve that alias and its source must match the HBA allow rule.
The network itself does not provide TLS or database authorization.

```sh
docker exec my-app getent hosts db.example.com
docker inspect -f '{{json .NetworkSettings.Networks}}' my-app | jq keys
```

`getent` printing an address means DNS resolves across the network. Empty output with a nonzero
exit means the container is not on `pg-net`, and `jq keys` then shows which networks it did join.

### From a container using `network_mode: host`

A host-network container shares the host network namespace and uses the published
port. Configure DNS or a host entry so the certificate hostname resolves to the intended
host interface:

```yaml
services:
  my-api:
    image: my-api:latest
    network_mode: host
    environment:
      ConnectionStrings__DefaultConnection: "Host=db.example.com;Port=5432;Database=app_db;Username=app_user;Password=<secret>;SSL Mode=VerifyFull"
```

No `networks:` block. The two are mutually exclusive and declaring both fails at
`docker compose config`. A host-network container therefore cannot join `pg-net` and cannot
resolve Docker network aliases. The HBA allow rule must cover its observed source address.

### ASP.NET Core / Npgsql

Supply the connection string through deployment secrets or ASP.NET Core configuration.
For `tls` mode (also used in the Compose examples above):

```text
Host=db.example.com;Port=5432;Database=app_db;Username=app_user;Password=<secret>;SSL Mode=VerifyFull
```

`VerifyFull` requires TLS, validates certificate trust, and checks the hostname.
For a private CA absent from the backend OS trust store, append
`Root Certificate=/app/certs/database-ca.pem`. In `tls` mode the backend needs no client certificate.
`Prefer`, `Require`, and certificate-validation bypasses do not provide this verification.

For passwordless `mtls` with Npgsql 6 or later and PEM credentials:

```text
Host=db.example.com;Port=5432;Database=app_db;Username=app_user;SSL Mode=VerifyFull;SSL Certificate=/app/certs/client.crt;SSL Key=/app/certs/client.key
```

The certificate CN must match `Username`. The paths must be accessible in the backend's
runtime environment; containerized backends mount the files into their own containers.
Protect the client key and limit access to the application identity. An encrypted client
key additionally requires `SSL Password`, which is a key passphrase, not a database password.
`Root Certificate` trusts the server issuer; `client-ca.pem` on PostgreSQL trusts client
issuers. The two trust chains can use different CAs.

### Verify application connections

Run through the application's database connection:

```sql
SELECT ssl, version, cipher FROM pg_stat_ssl WHERE pid = pg_backend_pid();
```

Expect `ssl = true` and TLS 1.2 or TLS 1.3. From the approved backend source, check
that `psql` with `sslmode=disable` fails. With `sslmode=verify-full`, check that an
untrusted CA fails, and that a mismatched `host` with `hostaddr` set to the same server
IP fails hostname verification. A connection from a denied source must fail even with
valid credentials and TLS. In Npgsql, repeat the valid connection and rejection checks
with `SSL Mode=VerifyFull` and `SSL Mode=Disable`.

In `mtls` mode, a valid client certificate and matching role must connect without a
database password. Repeat with no client certificate, an untrusted client certificate,
and a trusted certificate with a different CN: each must fail. Supplying a database
password must not bypass certificate authentication. With CRL checking enabled, a revoked
certificate must fail while a non-revoked certificate from the same CA still succeeds.

Inspect the client identity on the application's connection:

```sql
SELECT ssl, version, client_dn, client_serial, issuer_dn
FROM pg_stat_ssl WHERE pid = pg_backend_pid();
```

Inspect the active HBA configuration through the local administrative socket:

```sh
docker exec -u postgres postgres psql -d postgres -c \
  'SELECT line_number, type, database, user_name, address, auth_method, error FROM pg_hba_file_rules;'
```

The `error` column must be empty. After any reload, check server logs for configuration
errors. Existing connections retain their sessions; changed HBA rules govern new connections.

## TLS files and renewal

The host administrator provisions `PG_TLS_DIR` before `init.sh` runs:

```text
/opt/databases/tls/db.example.com/
  fullchain.pem
  privkey.pem
```

`fullchain.pem` contains the server certificate followed by intermediate certificates.
Its SAN must cover the connection hostname. Use an approved public or private CA.
Public ACME certificates can use DNS-01 validation without opening database or HTTP ports.
Certificate issuance and deployment are external to this repository.

### Additional mTLS prerequisites

Before `init.sh` runs in `mtls` mode, the administrator supplies:

| Location | Files and requirements |
| --- | --- |
| Database TLS directory | `client-ca.pem`: trusted client CA certificate or PEM CA bundle; no private signing key |
| Database TLS directory, if CRL checking is enabled | The PEM CRL bundle named by `PG_CLIENT_CRL_FILE`, with valid issuer signatures and unexpired CRLs for the client chain |
| Each backend | Its own client certificate and private key; certificate CN equal to `PG_APP_USER`, `CA:FALSE`, and TLS client-authentication usage |
| CA administration environment | Protected CA signing keys, issuance/revocation records, and backups |

The PostgreSQL user must be able to read the CA and CRL files; root ownership with mode
`0644` is suitable for these public files. Backend keys remain on the backend. CA signing
keys remain outside database and backend deployments. With intermediate client CAs, the
client presents its intermediate chain after the leaf certificate and PostgreSQL trusts
the appropriate root CA. Inspect certificates, chain validity, and matching client keys
before deployment. The init preflight checks readability and basic CA/CRL parsing; successful
fresh client connections prove the complete configuration.

An external private CA, organizational PKI, or managed issuance service can provision client
credentials. No CA service, certificate-generation command, or provider-specific account is
required by this repository. DNS resolution and a trusted server certificate must already
exist, independent of how the deployment obtains them.

### Permissions and renewal

Confirm the image identity before assigning file ownership:

```sh
docker run --rm --entrypoint id postgres:18.6-trixie postgres
docker info --format '{{json .SecurityOptions}}'
```

For image UID/GID `999:999` with rootful Docker and no user-namespace remapping,
use owner `999:999` and mode `0600` for `privkey.pem`. The directory can be root-owned
with mode `0755`, and the certificate root-owned with mode `0644`. Remapped or rootless
Docker needs corresponding host IDs and directory access, including for the database
directories managed by `init.sh`.

Verify access through the mount:

```sh
docker run --rm --user postgres \
  --mount type=bind,src=/opt/databases/tls/db.example.com,dst=/tls,readonly \
  --entrypoint sh postgres:18.6-trixie \
  -c 'test -r /tls/fullchain.pem && test -r /tls/privkey.pem'
```

Certbot renews its own files; separate copies under `PG_TLS_DIR` require a host-managed
deployment hook. Scope that hook to the database certificate lineage. Stage the renewed
certificate and key with correct permissions, verify they match, replace both files in
the mounted directory, then reload PostgreSQL after both replacements finish:

```sh
docker exec -u postgres postgres psql -d postgres -c 'SELECT pg_reload_conf();'
docker compose logs --since=2m postgres
```

Mount the directory, not individual certificate files, so file replacement is visible
inside the container. Keep CA signing keys and DNS API credentials outside the TLS mount.
PostgreSQL retains its previous TLS configuration if reloading invalid files fails;
`pg_reload_conf()` only confirms the reload signal. Check logs and a new TLS connection
to confirm the renewed certificate is served. Monitor the served certificate's expiry.
Certbot's renewal dry-run alone does not prove deployment hooks work.

Client certificate renewal uses the deployment's client CA, independently of server
certificate renewal. Deploy the replacement client certificate and key to the backend,
then open new connections with the new credentials. Some application runtimes require
recreating their data source or restarting the application to load replacement credentials.

For revocation, revoke the certificate in the issuing CA, generate a new CRL, deploy it
under the configured filename, and reload PostgreSQL. PostgreSQL reads the local CRL;
it does not fetch updates from the CA. Refresh CRLs before `nextUpdate`, even when no
certificates have been revoked. An expired CRL can reject otherwise valid client connections.
For a CA hierarchy, supply the required CRLs for the chain. Verify both revoked-client
rejection and non-revoked-client success on new connections. Plan CA rotation with a trust
overlap and remove the old CA after its client certificates have been replaced.

### Percent-encode credentials

Characters that carry meaning in a URI have to be encoded in the username and password, not in
the rest of the string: `: / ? # [ ] @ %`. An unencoded `@` is the common one, since it splits
credentials from the host and turns part of the password into a hostname.

```sh
jq -rR @uri <<< 'p@ss:w/ord#1'
# p%40ss%3Aw%2Ford%231
```

## Sizing

`PG_MEM_LIMIT` in `.env` is the container's cgroup limit. PostgreSQL cannot read that limit, so
the memory settings in `postgresql.conf` are derived from it by hand and the two have to change
together.

| Setting | Rule | Value at 8g |
| --- | --- | --- |
| `shared_buffers` | 25% of the limit | `2GB` |
| `effective_cache_size` | 75% of the limit, a planner hint that allocates nothing | `6GB` |
| `work_mem` | Per sort or hash node | `32MB` |
| `maintenance_work_mem` | `VACUUM`, `CREATE INDEX`, `ALTER TABLE` | `512MB` |
| `max_wal_size` | Half the limit | `4GB` |

`work_mem` is the one that misleads. It is charged per sort or hash node, so one query with
several of them running across several parallel workers can consume many multiples of it.
`log_temp_files = 0` logs every spill to disk, which is the evidence for raising it.

`effective_cache_size` describes the page cache PostgreSQL can expect to benefit from, which is
not the whole of the host's free memory when other services share it. Setting it optimistically
makes the planner favour index scans that the cache cannot actually service.

### Asynchronous I/O

PostgreSQL 18 added an asynchronous I/O subsystem. `io_method` is `worker` here, with
`io_workers = 4` against the default 3, which is low for modern core counts. Current guidance is
roughly a quarter of the host's cores; the value here assumes 8.

`io_uring` is the faster method on paper but needs syscalls that container seccomp profiles
restrict, so it is a benchmark-and-then-decide change rather than a default. `pg_aios` shows the
in-flight I/O handles.

```sql
SELECT * FROM pg_aios;
```

`effective_io_concurrency` and `maintenance_io_concurrency` both default to 16 in 18, which
already suits SSD, and are left alone.

## Huge pages

Optional, and safe to defer. `huge_pages = try` uses explicit huge pages when the host has them
reserved and falls back to normal pages when it does not, so the server starts either way.

PostgreSQL computes the exact requirement from the running configuration:

```sh
docker exec -u postgres postgres postgres -C shared_memory_size_in_huge_pages \
  -c config_file=/etc/postgresql/postgresql.conf
```

Reserve that many, persistently:

```sh
echo 'vm.nr_hugepages = <that number>' | sudo tee /etc/sysctl.d/60-postgresql-hugepages.conf
sudo sysctl --system
docker compose restart postgres
docker exec -u postgres postgres psql -Atc 'SHOW huge_pages_status'
grep Huge /proc/meminfo
```

`huge_pages_status` reports `on` when the allocation actually used huge pages and `off` when
`try` fell back, which `huge_pages` itself cannot tell apart. `HugePages_Free` well below
`HugePages_Total` in `/proc/meminfo` corroborates it. Reserved huge pages leave the host's general-purpose memory pool for as long
as the reservation stands, and they are accounted outside the container's `mem_limit`, so the
reservation has to fit alongside everything else running on the host.

### Transparent huge pages

THP is left at the distribution default, which is `madvise` on Ubuntu 24.04. Check it:

```sh
cat /sys/kernel/mm/transparent_hugepage/enabled
# always [madvise] never
```

The PostgreSQL documentation discourages THP, and `madvise` already satisfies that: THP is applied
only to regions a process explicitly requests with `madvise(MADV_HUGEPAGE)`, and PostgreSQL never
requests it. `always` is the setting that would hand THP to PostgreSQL unasked. Nothing here
changes the system-wide value, because it applies to every process on the host, not only to
PostgreSQL.

Explicit huge pages and THP are separate mechanisms. The `vm.nr_hugepages` pool above is
unaffected by either THP setting, so the optional step is an independent choice, not a workaround.

## Backups

pgBackRest keeps one repository holding both backups and archived WAL, which together give
point-in-time recovery to any moment inside the retention window.

`backup.sh` takes the backup type:

| Type | Contents |
| --- | --- |
| `full` | Every file in the cluster. The base the other two build on |
| `diff` | Files changed since the last full backup |
| `incr` | Files changed since the last backup of any type |

Install the timers, editing the paths in the unit file to match where this repository lives:

```sh
sudo cp systemd/postgres-backup@* /etc/systemd/system/
sudo nano /etc/systemd/system/postgres-backup@.service   # WorkingDirectory and ExecStart
sudo systemctl daemon-reload
sudo systemctl enable --now postgres-backup@diff.timer postgres-backup@full.timer
```

Weekly full on Sunday at 01:00, daily differential at 03:00. Check them:

```sh
systemctl list-timers 'postgres-backup@*'
sudo systemctl start postgres-backup@diff        # run one now
journalctl -u 'postgres-backup@diff' -n 50
```

Retention is counted in backups, not days, and is set by `PGBACKREST_RETENTION_FULL` and
`PGBACKREST_RETENTION_DIFF` in `.env`. Expiry happens as part of each backup, and pgBackRest drops
the WAL that only an expired backup needed along with it.

Retention is the reason there is no `find -mtime -delete` here. Deleting a backup's files by age
without expiring them through pgBackRest leaves WAL
that no longer has a base to replay onto, and the recovery window silently shortens.

```sh
docker exec -u postgres postgres pgbackrest --stanza=main info
```

`info` prints the timestamp range each backup covers, which is the actual point-in-time recovery
window.

### Why a stuck archive is dangerous here

PostgreSQL will not recycle or delete a WAL segment until `archive_command` has succeeded for it.
That is correct behaviour, and it means a broken archive converts directly into disk growth:

1. `archive_command` starts failing.
2. Segments accumulate in `pg_wal`, at up to one 16MB segment per `archive_timeout` (60s), so a
   ceiling of about 23GB/day and in practice whatever the write rate is.
3. `pg_wal` is inside `PGDATA`, which shares a filesystem with the pgBackRest repository and with
   anything else stored on it.
4. At 100% full, PostgreSQL PANICs on a WAL write and stops, and every other service writing to
   that filesystem fails at the same moment. An archiving misconfiguration becomes an outage for
   things that have nothing to do with archiving.

### What actually breaks the archive

| Cause | How it happens | Notice |
| --- | --- | --- |
| `pgbackrest.conf` missing when the container starts | Docker creates a **directory** at a bind-mount source that does not exist. The container starts normally and every `archive-push` fails with `Is a directory` | Running `docker compose up -d` before `init.sh` on a fresh host, or deleting the rendered config |
| Repository filling | The repo shares the filesystem, so it fills, archiving fails, `pg_wal` grows and fills it faster | Retention too generous for the database size |
| Root-owned files in the repository | `docker exec` without `-u postgres` runs pgBackRest as root; `archive-push` then runs as postgres and cannot write | Running a pgBackRest command by hand |
| Stanza does not match the cluster | `pg1-path` still names the old major version, or the repo was restored from elsewhere | A major version upgrade without `stanza-upgrade` |
| Spool not writable | `/var/spool/pgbackrest` lost its `999:999` ownership | Recreating the directory by hand |

The first one is the most likely, and it is silent: PostgreSQL is healthy, queries work, and only
the archive is broken.

### The guard

`archive-guard.sh` runs every 10 minutes and exits nonzero on anything critical, so a problem
appears in `systemctl --failed` rather than only in a log nobody reads.

```sh
sudo cp systemd/postgres-archive-guard.* /etc/systemd/system/
sudo nano /etc/systemd/system/postgres-archive-guard.service   # WorkingDirectory and ExecStart
sudo systemctl daemon-reload
sudo systemctl enable --now postgres-archive-guard.timer
sudo ./archive-guard.sh          # run it once by hand
```

Healthy output:

```text
OK       archive backlog 0 segments
OK       archive_command healthy (13 historical failures)
OK       filesystem 60% used, 175GB free, pg_wal 369MB
OK       WAL rate <1GB/day
OK       last backup finished 0h ago
```

Stuck archive:

```text
CRITICAL archive_command failing now (16 total failures, last 6s ago)
CRITICAL WAL rate ~168GB/day; if archiving stops, the filesystem fills in ~25h
CRITICAL repository problem for stanza 'main': other (status 99)
```

What it checks:

| Check | Why |
| --- | --- |
| `.ready` files in `pg_wal/archive_status` | Segments waiting to archive. Healthy is 0 to 2; each one is 16MB that cannot be recycled |
| `pg_stat_archiver` | A failure newer than the last success means archiving is stuck **now**, rather than a historical failure such as the one during `initdb` |
| Filesystem percent and free space | The resource that actually runs out |
| WAL write rate | Measured from `pg_current_wal_lsn()` across runs, held in `guard.state`. Converts free space into hours remaining, and escalates under 48h |
| Age of the newest backup | A timer that silently stopped firing looks identical to a healthy system until a restore is needed |

The backup check reads pgBackRest's `status.code`, not just the backup list. `pgbackrest info`
exits 0 on a damaged repository and returns an empty list, which read naively becomes a false
"no backups exist" pointing at the wrong incident.

Thresholds are the `PG_GUARD_*` values in `.env`.

### The backstop

`archive-push-queue-max` (`PGBACKREST_ARCHIVE_QUEUE_MAX`, 64GiB) caps the unarchived queue. Past
that, pgBackRest reports success to PostgreSQL and discards WAL, which bounds `pg_wal` and keeps
the filesystem alive for whatever else depends on it, at the cost of a gap in the recovery
chain.

It is a backstop, not the defence. The guard catches a stuck archive within ten minutes; reaching
64GiB takes days of unnoticed failure. If it does fire, pgBackRest logs `dropped WAL file`, PITR
across that window is gone, and the fix is to repair archiving and take a full backup, which
starts a fresh chain.

Sizing it is a judgement about how much of the filesystem can be spent before other services are
at risk. Check the headroom:

```sh
df -h /opt/databases
```

### Manual checks

```sql
SELECT archived_count, last_archived_wal, last_archived_time,
       failed_count, last_failed_wal, last_failed_time
  FROM pg_stat_archiver;
```

```sh
docker exec -u postgres postgres pgbackrest --stanza=main check
docker exec -u postgres postgres du -sh /var/lib/postgresql/18/docker/pg_wal
```

## Restore

Recovery to a point in time. This overwrites the live cluster:

```sh
docker compose stop postgres

docker compose run --rm --no-deps --user postgres --entrypoint pgbackrest postgres \
  --stanza=main restore --delta \
  --type=time --target="2026-09-09 14:31:00+00" --target-action=promote

docker compose up -d postgres
docker compose logs -f postgres
```

`--delta` compares checksums and rewrites only the files that differ, which is much faster than a
full copy on a cluster that is mostly intact. `--target-action=promote` ends recovery at the
target and makes the cluster writable; without it recovery pauses at the target and waits for
`pg_wal_replay_resume()`.

pgBackRest writes the recovery settings into `postgresql.auto.conf` and creates `recovery.signal`
in `PGDATA`. Both are read even though the main configuration file lives outside `PGDATA`.

Promotion starts a new timeline, and the next backup reports
`a timeline switch has occurred since the <name> backup, enabling delta checksum` and succeeds.
Take a full backup once the restored cluster is confirmed good, so later backups no longer depend
on a set that spans the switch:

```sh
sudo ./backup.sh full
```

Other targets: `--type=immediate` stops as soon as the backup is consistent, `--type=lsn`,
`--type=xid`, `--type=name` for a label set with `pg_create_restore_point()`, and `--type=default`
replays all available WAL.

`--type=time` is the only one where pgBackRest can pick the backup itself, and the log line to
look for is `restore backup set <name>, recovery will start at <time>`. For `name`, `xid` and
`lsn` it cannot compare the target against backup timestamps, so it restores the most recent
backup. When that backup began after the target, recovery fails with `recovery ended before
configured recovery target was reached`. Those three need the backup named explicitly:

```sh
docker exec -u postgres postgres pgbackrest --stanza=main info    # list backup names
# ... restore --set=20260909-101216F --type=name --target=RP1
```

### Verifying without touching the live cluster

A backup that has never been restored is not a backup.

Repository integrity, which reads and checksums every file:

```sh
docker exec -u postgres postgres pgbackrest --stanza=main verify
```

A rehearsal restore into a scratch directory, which is the part that proves the WAL replays:

```sh
sudo mkdir -p /opt/databases/postgresql/restore-test /opt/databases/postgresql/restore-spool
sudo chown 999:999 /opt/databases/postgresql/restore-test /opt/databases/postgresql/restore-spool
sudo chmod 700 /opt/databases/postgresql/restore-test

docker run --rm --user postgres \
  -v /opt/databases/postgresql/backups:/var/lib/pgbackrest \
  -v /opt/databases/postgresql/log:/var/log/pgbackrest \
  -v /opt/databases/postgresql/conf/pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro \
  -v /opt/databases/postgresql/restore-test:/restore \
  postgres-pgbackrest:18.6 \
  pgbackrest --stanza=main --pg1-path=/restore restore \
    --type=time --target="2026-09-09 14:31:00+00" --target-action=promote
```

Start it and read the data back. The recovering cluster runs `restore_command`, so it needs the
repository and the pgBackRest config as well as the restored data directory. Mounting the
repository read-only and giving it a scratch spool keeps it from touching the real one:

```sh
docker run --rm -d --name pg-restore-test --init --user postgres \
  -e PGDATA=/restore \
  -v /opt/databases/postgresql/restore-test:/restore \
  -v /opt/databases/postgresql/backups:/var/lib/pgbackrest:ro \
  -v /opt/databases/postgresql/conf/pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro \
  -v /opt/databases/postgresql/restore-spool:/var/spool/pgbackrest \
  postgres-pgbackrest:18.6 \
  postgres -p 5433

docker logs pg-restore-test 2>&1 | grep -E 'recovery stopping|selected new timeline|ready to accept'
docker exec -u postgres pg-restore-test psql -p 5433 -U postgres -Atc \
  'SELECT datname FROM pg_database ORDER BY 1'
docker exec -u postgres pg-restore-test psql -p 5433 -U postgres -d app_db -Atc \
  'SELECT count(*) FROM some_table'

docker rm -f pg-restore-test
sudo rm -rf /opt/databases/postgresql/restore-test /opt/databases/postgresql/restore-spool
```

Omitting the repository mount fails with `could not locate required checkpoint record`, because
recovery cannot fetch the WAL that carries it.

`PGDATA` is passed as an environment variable rather than as `-D`, because the entrypoint reads it
from the environment and would otherwise try to initialise a new cluster at the image's default
path. No port is published: `psql` reaches it over the container's own socket.

The restored cluster uses the `postgresql.conf` that `initdb` left inside `PGDATA`, not the one
this repository mounts, so `archive_mode` is `off` and `archive_command` is disabled and it cannot
write anything into the real repository. That is what makes the rehearsal safe to run against a
live backup set.

A successful rehearsal ends with `recovery stopping before commit of transaction ...` at the
target, `selected new timeline ID: 2`, and `database system is ready to accept connections`.

## Upgrades

### Minor version

A minor release replaces the binaries and needs no dump and no `pg_upgrade`. Read the release
notes first, since a few minor releases have required a `REINDEX` of specific index types.

```sh
nano Dockerfile                 # bump the FROM tag and PGBACKREST_VERSION
docker compose build --pull
docker compose up -d postgres
docker exec -u postgres postgres psql -Atc 'SELECT version()'
```

Both versions are pinned rather than tracking `postgres:18`, so an upgrade is a commit that can
be read and reverted, not something a `docker compose pull` does on its own.

### Major version

Out of scope here, but the layout supports it. `PGDATA` is version-qualified
(`/var/lib/postgresql/18/docker`) inside a single volume mounted at `/var/lib/postgresql`, which
is what lets `pg_upgrade --link` hard-link relations from the old directory to the new one instead
of copying them. Take a full backup and create a new stanza afterwards, because a major upgrade
resets the cluster identity the existing stanza refers to.

## Monitoring

`pg_stat_statements` is preloaded and the extension is created. `track_io_timing` is on, without
which its block read and write times are always zero.

```sql
SELECT calls, round(mean_exec_time::numeric, 1) AS ms, round(total_exec_time::numeric) AS total_ms,
       left(query, 90) AS query
  FROM pg_stat_statements
 ORDER BY total_exec_time DESC
 LIMIT 20;
```

```sql
SELECT pg_size_pretty(pg_database_size(datname)) AS size, datname
  FROM pg_database ORDER BY pg_database_size(datname) DESC;

SELECT relname, n_dead_tup, last_autovacuum
  FROM pg_stat_user_tables WHERE n_dead_tup > 10000 ORDER BY n_dead_tup DESC;
```

`SELECT pg_stat_statements_reset()` clears the accumulated statistics.

Autovacuum is left at its defaults. Aggressiveness is a property of individual tables, better set
where it is needed than globally:

```sql
ALTER TABLE busy_table SET (autovacuum_vacuum_scale_factor = 0.02);
```

## Connection pooling

`max_connections` is 100. Each connection is a process with its own memory, so raising it is a
worse answer than pooling when an application needs more. PgBouncer in transaction mode on
`pg-net` is the usual addition and is not part of this stack.
