# Multi-stage build for pgvector extension
# Stage 1: Build pgvector
FROM bitnami/postgresql:latest AS builder

USER root

# Install build dependencies - Bitnami PostgreSQL already includes pg_config and dev headers
# build-essential includes gcc, make, and libc6-dev (standard C headers)
RUN install_packages git build-essential

# Clone and build pgvector
RUN git clone --branch v0.7.0 https://github.com/pgvector/pgvector.git \
    && cd pgvector \
    && make \
    && make install

# Stage 2: Final image
FROM bitnami/postgresql:latest

USER root

# Copy the compiled pgvector extension from builder
COPY --from=builder /opt/bitnami/postgresql/lib/vector.so /opt/bitnami/postgresql/lib/
COPY --from=builder /opt/bitnami/postgresql/share/extension/vector* /opt/bitnami/postgresql/share/extension/

USER 1001
