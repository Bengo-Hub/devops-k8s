# Multi-stage Dockerfile: build pgvector + PostGIS with official PostgreSQL
# Extensions: pgvector (vector similarity), PostGIS (geospatial)
# NOTE: PG_MAJOR must match the running cluster data directory version.
# Current production: PG 17. Upgraded from PG 16 via pg_dumpall/restore (2026-03-21).

ARG PG_MAJOR=17

# ---------------------------
# Stage 1 — build pgvector
# ---------------------------
FROM postgres:${PG_MAJOR} AS pgvector-builder
ARG PG_MAJOR
USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    build-essential \
    postgresql-server-dev-${PG_MAJOR} \
    && rm -rf /var/lib/apt/lists/*

ENV PGVECTOR_VERSION=v0.8.0
RUN git clone --depth 1 --branch ${PGVECTOR_VERSION} https://github.com/pgvector/pgvector.git /tmp/pgvector \
    && cd /tmp/pgvector \
    && make \
    && make install

# ---------------------------
# Stage 2 — runtime with pgvector + PostGIS
# ---------------------------
FROM postgres:${PG_MAJOR}
ARG PG_MAJOR

USER root

# Install PostGIS from Debian packages
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    postgresql-${PG_MAJOR}-postgis-3 \
    postgresql-${PG_MAJOR}-postgis-3-scripts \
    && rm -rf /var/lib/apt/lists/*

# Copy pgvector extension from builder
COPY --from=pgvector-builder /usr/lib/postgresql/${PG_MAJOR}/lib/vector.so /usr/lib/postgresql/${PG_MAJOR}/lib/
COPY --from=pgvector-builder /usr/share/postgresql/${PG_MAJOR}/extension/vector* /usr/share/postgresql/${PG_MAJOR}/extension/

# Create Bitnami-compatible directory structure
RUN mkdir -p /bitnami/postgresql/data \
    /bitnami/postgresql/conf \
    /opt/bitnami/postgresql/conf \
    /opt/bitnami/postgresql/tmp \
    /opt/bitnami/scripts/postgresql \
    && chown -R postgres:postgres /bitnami \
    && chown -R postgres:postgres /opt/bitnami \
    && chmod -R 755 /bitnami /opt/bitnami

# Create symbolic links for Bitnami compatibility
RUN ln -s /var/lib/postgresql/data /bitnami/postgresql/data/pgdata || true \
    && ln -s /var/run/postgresql /bitnami/postgresql/run || true

RUN mkdir -p /var/run/postgresql \
    && chown -R postgres:postgres /var/run/postgresql \
    && chmod 2777 /var/run/postgresql

# Ensure extensions are properly owned
RUN chown postgres:postgres /usr/lib/postgresql/${PG_MAJOR}/lib/vector.so \
    && chown postgres:postgres /usr/share/postgresql/${PG_MAJOR}/extension/vector*

# Init script: auto-enable extensions on NEW databases (docker-entrypoint-initdb.d
# only runs when PGDATA is empty). For existing databases, run CREATE EXTENSION manually.
COPY docker-entrypoint-initdb.d/ /docker-entrypoint-initdb.d/

USER postgres