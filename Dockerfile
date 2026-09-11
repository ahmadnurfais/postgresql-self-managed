FROM postgres:18.6-trixie

# archive_command is executed by the postgres process itself, so pgbackrest has
# to be in this image rather than a sidecar container. The PGDG apt source is
# already configured by the base image, so pgbackrest comes from the same
# repository as the server.
ARG PGBACKREST_VERSION=2.59.1-1.pgdg13+1

RUN apt-get update \
    && apt-get install -y --no-install-recommends "pgbackrest=${PGBACKREST_VERSION}" \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=755 healthcheck.sh /usr/local/bin/postgres-healthcheck
