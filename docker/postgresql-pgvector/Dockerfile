# Multi-stage Dockerfile: build pgvector with official PostgreSQL + Bitnami compatibility wrapper
# This creates a Bitnami-compatible image using official postgres:17 as base

# ---------------------------
# Stage 1 — build pgvector
# ---------------------------
FROM postgres:17 AS builder
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
# Stage 2 — Bitnami-compatible runtime
# ---------------------------
FROM postgres:17

USER root

# Copy pgvector extension
COPY --from=builder /usr/lib/postgresql/17/lib/vector.so /usr/lib/postgresql/17/lib/
COPY --from=builder /usr/share/postgresql/17/extension/vector* /usr/share/postgresql/17/extension/

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

USER postgres

# Default command inherited from postgres:17
