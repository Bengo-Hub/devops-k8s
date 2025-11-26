FROM bitnami/postgresql:latest

USER root

# Install build dependencies
RUN install_packages git make gcc postgresql-server-dev-all

# Clone and install pgvector
RUN git clone --branch v0.7.0 https://github.com/pgvector/pgvector.git \
    && cd pgvector \
    && make \
    && make install

# Cleanup
RUN rm -rf pgvector \
    && apt-get remove -y git make gcc postgresql-server-dev-all \
    && apt-get autoremove -y

USER 1001
