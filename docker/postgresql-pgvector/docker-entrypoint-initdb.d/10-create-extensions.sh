#!/bin/bash
set -e

# Enable core extensions on the default database.
# This script runs ONLY on first init (empty PGDATA).
# For existing databases, run these CREATE EXTENSION statements manually.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS vector;
    CREATE EXTENSION IF NOT EXISTS postgis;
    CREATE EXTENSION IF NOT EXISTS postgis_topology;
EOSQL
