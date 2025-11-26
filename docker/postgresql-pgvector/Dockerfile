FROM bitnami/postgresql:latest

USER root

# Install build dependencies (Bitnami uses tdnf package manager with different naming)
RUN install_packages git make gcc postgresql-devel

# Clone and install pgvector
RUN git clone --branch v0.7.0 https://github.com/pgvector/pgvector.git \
    && cd pgvector \
    && make \
    && make install

# Cleanup
RUN rm -rf pgvector \
    && tdnf remove -y git make gcc postgresql-devel \
    && tdnf clean all

USER 1001
