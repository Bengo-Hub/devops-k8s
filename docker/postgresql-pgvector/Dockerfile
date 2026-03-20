# Multi-stage Dockerfile: build pgvector + PostGIS with official PostgreSQL + Bitnami compatibility wrapper
# This creates a Bitnami-compatible image using official postgres:17 as base
# Extensions: pgvector (vector similarity), PostGIS (geospatial)

# ---------------------------
# Stage 1 — build pgvector
# ---------------------------
FROM postgres:17 AS pgvector-builder
USER root

# Install build dependencies
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    build-essential \
    postgresql-server-dev-17 \
    && rm -rf /var/lib/apt/lists/*

# Clone and build pgvector
ENV PGVECTOR_VERSION=v0.7.0
RUN git clone --depth 1 --branch ${PGVECTOR_VERSION} https://github.com/pgvector/pgvector.git /tmp/pgvector \
    && cd /tmp/pgvector \
    && make \
    && make install

# ---------------------------
# Stage 2 — Bitnami-compatible runtime with pgvector + PostGIS
# ---------------------------
FROM postgres:17

USER root

# Install PostGIS from Debian packages (matches postgres:17 base)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    postgresql-17-postgis-3 \
    postgresql-17-postgis-3-scripts \
    && rm -rf /var/lib/apt/lists/*

# Copy pgvector extension from builder
COPY --from=pgvector-builder /usr/lib/postgresql/17/lib/vector.so /usr/lib/postgresql/17/lib/
COPY --from=pgvector-builder /usr/share/postgresql/17/extension/vector* /usr/share/postgresql/17/extension/

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

# Create writable /var/run/postgresql for lock files
RUN mkdir -p /var/run/postgresql \
    && chown -R postgres:postgres /var/run/postgresql \
    && chmod 2777 /var/run/postgresql

# Ensure pgvector is properly owned
RUN chown postgres:postgres /usr/lib/postgresql/17/lib/vector.so \
    && chown postgres:postgres /usr/share/postgresql/17/extension/vector*

# Create init script to auto-enable extensions on new databases
RUN echo '#!/bin/bash\nset -e\npsql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL\n    CREATE EXTENSION IF NOT EXISTS vector;\n    CREATE EXTENSION IF NOT EXISTS postgis;\nEOSQL' \
    > /docker-entrypoint-initdb.d/10-create-extensions.sh \
    && chmod +x /docker-entrypoint-initdb.d/10-create-extensions.sh

USER postgres

# Default command inherited from postgres:17
