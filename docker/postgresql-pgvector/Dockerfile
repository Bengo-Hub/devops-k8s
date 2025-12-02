# Multi-stage Dockerfile: build pgvector on top of Bitnami PostgreSQL
# This ensures compatibility with Bitnami Helm charts

# ---------------------------
# Stage 1 — build pgvector
# ---------------------------
FROM bitnami/postgresql:16 AS builder
USER root

# Install build dependencies
RUN install_packages \
    git \
    ca-certificates \
    build-essential \
    postgresql-server-dev-16 \
    || apt-get update && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    build-essential \
    postgresql-server-dev-16 \
    && rm -rf /var/lib/apt/lists/*

# Clone pgvector
ENV PGVECTOR_VERSION=v0.7.0
RUN git clone --depth 1 --branch ${PGVECTOR_VERSION} https://github.com/pgvector/pgvector.git /tmp/pgvector \
    && cd /tmp/pgvector \
    && make \
    && make install

# ---------------------------
# Stage 2 — runtime image (Bitnami base)
# ---------------------------
FROM bitnami/postgresql:16

USER root

# Copy pgvector extension from builder
COPY --from=builder /opt/bitnami/postgresql/lib/vector.so /opt/bitnami/postgresql/lib/
COPY --from=builder /opt/bitnami/postgresql/share/extension/vector* /opt/bitnami/postgresql/share/extension/

# Ensure correct ownership
RUN chown -R 1001:1001 /opt/bitnami/postgresql/lib/vector.so && \
    chown -R 1001:1001 /opt/bitnami/postgresql/share/extension/vector* && \
    chmod 755 /opt/bitnami/postgresql/lib/vector.so

USER 1001

# Use Bitnami entrypoint (inherited)
