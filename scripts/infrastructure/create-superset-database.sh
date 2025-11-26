#!/usr/bin/env bash
set -euo pipefail

# Script to create Superset database and user on shared PostgreSQL instance
# This script should be run after PostgreSQL is deployed

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tools/common.sh"

# Configuration
NAMESPACE=${DB_NAMESPACE:-infra}
PG_SERVICE=${PG_SERVICE:-postgresql}
PG_PORT=${PG_PORT:-5432}
SUPERSET_DB=${SUPERSET_DB:-superset}
SUPERSET_USER=${SUPERSET_USER:-superset_user}
SUPERSET_READONLY_USER=${SUPERSET_READONLY_USER:-superset_readonly}

log_section "Creating Superset Database and Users"

# Check if PostgreSQL pod is running
if ! kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql | grep -q Running; then
    log_error "PostgreSQL pod is not running in namespace ${NAMESPACE}"
    exit 1
fi

# Get PostgreSQL credentials
log_info "Retrieving PostgreSQL credentials..."
PG_PASSWORD=$(kubectl get secret "${PG_SERVICE}" -n "${NAMESPACE}" \
    -o jsonpath="{.data.postgres-password}" | base64 -d)

if [ -z "${PG_PASSWORD}" ]; then
    log_error "Failed to retrieve PostgreSQL password"
    exit 1
fi

# Get Superset DB password from secret or generate
if kubectl get secret apache-superset-secrets -n da >/dev/null 2>&1; then
    SUPERSET_DB_PASSWORD=$(kubectl get secret apache-superset-secrets -n da \
        -o jsonpath="{.data.SUPERSET_DB_PASSWORD}" | base64 -d)
else
    log_warn "Superset secrets not found. Generating random password..."
    SUPERSET_DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
fi

# Create SQL script
SQL_FILE=$(mktemp)
cat > "${SQL_FILE}" <<EOF
-- Create Superset database
CREATE DATABASE ${SUPERSET_DB};

-- Create Superset user
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = '${SUPERSET_USER}') THEN
        CREATE USER ${SUPERSET_USER} WITH PASSWORD '${SUPERSET_DB_PASSWORD}';
    ELSE
        ALTER USER ${SUPERSET_USER} WITH PASSWORD '${SUPERSET_DB_PASSWORD}';
    END IF;
END
\$\$;

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE ${SUPERSET_DB} TO ${SUPERSET_USER};

-- Connect to Superset database and grant schema privileges
\c ${SUPERSET_DB}
GRANT ALL ON SCHEMA public TO ${SUPERSET_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${SUPERSET_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${SUPERSET_USER};

-- Create read-only user for Superset data access
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = '${SUPERSET_READONLY_USER}') THEN
        CREATE USER ${SUPERSET_READONLY_USER} WITH PASSWORD '${SUPERSET_DB_PASSWORD}_readonly';
    ELSE
        ALTER USER ${SUPERSET_READONLY_USER} WITH PASSWORD '${SUPERSET_DB_PASSWORD}_readonly';
    END IF;
END
\$\$;

-- Grant read-only privileges
GRANT CONNECT ON DATABASE ${SUPERSET_DB} TO ${SUPERSET_READONLY_USER};
GRANT USAGE ON SCHEMA public TO ${SUPERSET_READONLY_USER};
GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${SUPERSET_READONLY_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO ${SUPERSET_READONLY_USER};

-- Enable pgvector extension
CREATE EXTENSION IF NOT EXISTS vector;
EOF

# Execute SQL script
log_info "Executing SQL script..."
PGPASSWORD="${PG_PASSWORD}" kubectl exec -n "${NAMESPACE}" \
    -it "$(kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}')" \
    -- psql -U postgres -f - < "${SQL_FILE}" || {
    log_error "Failed to execute SQL script"
    rm -f "${SQL_FILE}"
    exit 1
}

# Cleanup
rm -f "${SQL_FILE}"

log_success "Superset database and users created successfully"
log_info "Database: ${SUPERSET_DB}"
log_info "User: ${SUPERSET_USER}"
log_info "Read-only User: ${SUPERSET_READONLY_USER}"

# Update Superset secrets if they exist
if kubectl get secret apache-superset-secrets -n da >/dev/null 2>&1; then
    log_info "Updating Superset secrets with database password..."
    kubectl patch secret apache-superset-secrets -n da --type='json' \
        -p="[{\"op\": \"replace\", \"path\": \"/data/SUPERSET_DB_PASSWORD\", \"value\": \"$(echo -n "${SUPERSET_DB_PASSWORD}" | base64)\"}]" || \
    log_warn "Failed to update Superset secrets. Please update manually."
fi

