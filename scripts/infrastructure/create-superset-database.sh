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

# Check if PostgreSQL pod is running (custom manifests use app=postgresql label)
if ! kubectl get pod -n "${NAMESPACE}" -l app=postgresql | grep -q Running; then
    log_error "PostgreSQL pod is not running in namespace ${NAMESPACE}"
    log_info "Checking alternative label..."
    # Fallback: check with Helm label
    if ! kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql | grep -q Running; then
        log_error "PostgreSQL is not available. Please ensure PostgreSQL is deployed first."
        exit 1
    fi
fi

# Get PostgreSQL credentials
log_info "Retrieving PostgreSQL credentials..."
PG_PASSWORD=$(kubectl get secret "${PG_SERVICE}" -n "${NAMESPACE}" \
    -o jsonpath="{.data.postgres-password}" | base64 -d)

if [ -z "${PG_PASSWORD}" ]; then
    log_error "Failed to retrieve PostgreSQL password"
    exit 1
fi

# Get Superset DB password - Priority: POSTGRES_PASSWORD env > cluster secret > generate
SUPERSET_NAMESPACE=${SUPERSET_NAMESPACE:-default}
if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
    log_info "Using POSTGRES_PASSWORD from environment (GitHub secret)"
    SUPERSET_DB_PASSWORD="${POSTGRES_PASSWORD}"
elif kubectl get secret superset-secrets -n "${SUPERSET_NAMESPACE}" >/dev/null 2>&1; then
    SUPERSET_DB_PASSWORD=$(kubectl get secret superset-secrets -n "${SUPERSET_NAMESPACE}" \
        -o jsonpath="{.data.DATABASE_PASSWORD}" | base64 -d)
    log_info "Using password from superset-secrets in namespace ${SUPERSET_NAMESPACE}"
else
    log_warn "POSTGRES_PASSWORD not set and superset-secrets not found. Generating random password..."
    log_warn "Run ./create-superset-secrets.sh first or set POSTGRES_PASSWORD"
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

# Get PostgreSQL pod name (custom manifests use app=postgresql label)
PG_POD=$(kubectl get pod -n "${NAMESPACE}" -l app=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "${PG_POD}" ]]; then
    # Fallback: try Helm label
    PG_POD=$(kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
fi

if [[ -z "${PG_POD}" ]]; then
    log_error "Could not find PostgreSQL pod in namespace ${NAMESPACE}"
    exit 1
fi

log_info "Using PostgreSQL pod: ${PG_POD}"

# Copy SQL script to pod and execute
log_info "Copying SQL script to pod..."
kubectl cp "${SQL_FILE}" "${NAMESPACE}/${PG_POD}:/tmp/superset-setup.sql" -c postgresql

log_info "Executing SQL script..."
kubectl exec -n "${NAMESPACE}" -c postgresql "${PG_POD}" \
    -- psql -U admin_user -d postgres -f /tmp/superset-setup.sql || {
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
if kubectl get secret superset-secrets -n "${SUPERSET_NAMESPACE}" >/dev/null 2>&1; then
    log_info "Updating Superset secrets with database password..."
    kubectl patch secret superset-secrets -n "${SUPERSET_NAMESPACE}" --type='json' \
        -p="[{\"op\": \"replace\", \"path\": \"/data/DATABASE_PASSWORD\", \"value\": \"$(echo -n "${SUPERSET_DB_PASSWORD}" | base64 -w 0)\"}]" 2>/dev/null || \
    kubectl patch secret superset-secrets -n "${SUPERSET_NAMESPACE}" --type='json' \
        -p="[{\"op\": \"replace\", \"path\": \"/data/DATABASE_PASSWORD\", \"value\": \"$(echo -n "${SUPERSET_DB_PASSWORD}" | base64)\"}]" || \
    log_warn "Failed to update Superset secrets. Please update manually."
else
    log_warn "Superset secrets not found in namespace ${SUPERSET_NAMESPACE}"
    log_info "Run ./create-superset-secrets.sh to create the secrets"
fi

