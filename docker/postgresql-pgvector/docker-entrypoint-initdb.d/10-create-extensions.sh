#!/bin/bash
set -e

# Enable core extensions on the default database.
# This script runs ONLY on first init (empty PGDATA).
# For existing databases, run these CREATE EXTENSION statements manually.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS vector;
    CREATE EXTENSION IF NOT EXISTS postgis;
    CREATE EXTENSION IF NOT EXISTS postgis_topology;
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
EOSQL
# Note: this only reaches $POSTGRES_DB (the default db present at first cluster init) — every
# per-service database created afterward via create-service-database.sh gets pg_trgm from THAT
# script's own unconditional install, which is the enforcement point that actually matters.
