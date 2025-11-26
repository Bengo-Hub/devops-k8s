# Multi-stage Dockerfile: build pgvector against PostgreSQL 16 and produce a clean runtime image

# ---------------------------
# Stage 1 — build pgvector
# ---------------------------
FROM postgres:16 AS builder
USER root

# Install build dependencies (minimal)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    build-essential \
    postgresql-server-dev-16 \
    && rm -rf /var/lib/apt/lists/*

# Clone the stable pgvector release that works with Postgres 16
ENV PGVECTOR_VERSION=v0.7.0
RUN git clone --depth 1 --branch ${PGVECTOR_VERSION} https://github.com/pgvector/pgvector.git /tmp/pgvector \
    && cd /tmp/pgvector \
    && make \
    && make install

# (Optional) show installed files for debugging
# RUN ls -la /usr/lib/postgresql/16/lib/ | tail -n +1
# RUN ls -la /usr/share/postgresql/16/extension/ | tail -n +1

# ---------------------------
# Stage 2 — runtime image
# ---------------------------
FROM postgres:16
USER root

# Copy only the built extension artifacts from builder
COPY --from=builder /usr/lib/postgresql/16/lib/vector.so /usr/lib/postgresql/16/lib/
COPY --from=builder /usr/share/postgresql/16/extension/vector* /usr/share/postgresql/16/extension/

# Ensure correct ownership (postgres user)
RUN chown postgres:postgres /usr/lib/postgresql/16/lib/vector.so \
    && chown postgres:postgres /usr/share/postgresql/16/extension/*

USER postgres

# Default command inherited from postgres:16
