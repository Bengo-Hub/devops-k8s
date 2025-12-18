#!/usr/bin/env bash
# Create per-service database on shared PostgreSQL instance
# This script creates a database for a specific service using the common admin user
#
# Usage:
#   SERVICE_DB_NAME=cafe ./scripts/create-service-database.sh
#   APP_NAME=cafe-backend ./scripts/create-service-database.sh
#   NAMESPACE=cafe ./scripts/create-service-database.sh

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Configuration
PG_NAMESPACE=${PG_NAMESPACE:-infra}
PG_HOST=${PG_HOST:-postgresql.infra.svc.cluster.local}
PG_PORT=${PG_PORT:-5432}

# Admin user credentials (from GitHub secrets or env vars)
# Priority: POSTGRES_ADMIN_PASSWORD > POSTGRES_PASSWORD > retrieve from secret
ADMIN_USER=${POSTGRES_ADMIN_USER:-admin_user}
ADMIN_PASSWORD=${POSTGRES_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-}}

# Service-specific database configuration
SERVICE_DB_NAME=${SERVICE_DB_NAME:-}
SERVICE_DB_USER=${SERVICE_DB_USER:-}

# If SERVICE_DB_NAME is not provided, try to infer from APP_NAME or NAMESPACE
if [[ -z "$SERVICE_DB_NAME" ]]; then
    if [[ -n "${APP_NAME:-}" ]]; then
        # Extract service name from app name (e.g., cafe-backend -> cafe)
        SERVICE_DB_NAME=$(echo "$APP_NAME" | sed 's/-backend$//' | sed 's/-frontend$//' | sed 's/-api$//' | sed 's/-app$//')
    elif [[ -n "${NAMESPACE:-}" ]]; then
        SERVICE_DB_NAME="$NAMESPACE"
    else
        log_error "SERVICE_DB_NAME is required. Set it directly or via APP_NAME/NAMESPACE"
        exit 1
    fi
fi

# If SERVICE_DB_USER is not provided, use the database name
if [[ -z "$SERVICE_DB_USER" ]]; then
    SERVICE_DB_USER="${SERVICE_DB_NAME}_user"
fi

# Validate admin password - retrieve from Kubernetes secret if not provided
if [[ -z "$ADMIN_PASSWORD" ]]; then
    log_info "Retrieving PostgreSQL admin password from Kubernetes secret..."
    
    if kubectl -n "$PG_NAMESPACE" get secret postgresql >/dev/null 2>&1; then
        # Try to get admin_user password (created by chart)
        ADMIN_PASSWORD=$(kubectl -n "$PG_NAMESPACE" get secret postgresql -o jsonpath="{.data.admin-user-password}" 2>/dev/null | base64 -d || true)
        
        # Fallback to postgres superuser password if admin_user password not found
        if [[ -z "$ADMIN_PASSWORD" ]]; then
            ADMIN_PASSWORD=$(kubectl -n "$PG_NAMESPACE" get secret postgresql -o jsonpath="{.data.postgres-password}" 2>/dev/null | base64 -d || true)
            ADMIN_USER="postgres"
            log_warning "Using postgres superuser (admin_user password not found in secret)"
        fi
    fi
    
    if [[ -z "$ADMIN_PASSWORD" ]]; then
        log_error "Could not retrieve PostgreSQL admin password."
        log_error "Set POSTGRES_ADMIN_PASSWORD or POSTGRES_PASSWORD environment variable, or ensure PostgreSQL secret exists"
        exit 1
    fi
fi

log_info "Creating database for service: ${SERVICE_DB_NAME}"
log_info "Database name: ${SERVICE_DB_NAME}"
log_info "Database user: ${SERVICE_DB_USER}"
log_info "Using admin user: ${ADMIN_USER}"

# Wait for PostgreSQL to be ready
log_info "Waiting for PostgreSQL to be ready..."
MAX_RETRIES=30
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if kubectl -n "$PG_NAMESPACE" get statefulset postgresql >/dev/null 2>&1; then
        READY_REPLICAS=$(kubectl -n "$PG_NAMESPACE" get statefulset postgresql -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        if [[ "$READY_REPLICAS" == "1" ]]; then
            log_success "PostgreSQL is ready"
            break
        fi
    fi
    
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
        sleep 2
    else
        log_error "PostgreSQL is not ready after $MAX_RETRIES retries"
        exit 1
    fi
done

# Get PostgreSQL pod (custom manifests use app=postgresql label)
PG_POD=$(kubectl -n "$PG_NAMESPACE" get pod -l app=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$PG_POD" ]]; then
    # Fallback: try Helm label
    PG_POD=$(kubectl -n "$PG_NAMESPACE" get pod -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi

if [[ -z "$PG_POD" ]]; then
    log_error "Could not find PostgreSQL pod in namespace $PG_NAMESPACE"
    log_error "Checked labels: app=postgresql, app.kubernetes.io/name=postgresql"
    kubectl get pods -n "$PG_NAMESPACE" | grep -E "NAME|postgresql" || true
    exit 1
fi

log_info "Found PostgreSQL pod: ${PG_POD}"

# Create database if not exists
log_info "Creating database '${SERVICE_DB_NAME}'..."
kubectl -n "$PG_NAMESPACE" exec "$PG_POD" -c postgresql -- \
    env PGPASSWORD="$ADMIN_PASSWORD" \
    psql -h localhost -U "$ADMIN_USER" -d postgres -tc "
    SELECT 1 FROM pg_database WHERE datname = '${SERVICE_DB_NAME}'" | grep -q 1 || \
kubectl -n "$PG_NAMESPACE" exec "$PG_POD" -c postgresql -- \
    env PGPASSWORD="$ADMIN_PASSWORD" \
    psql -h localhost -U "$ADMIN_USER" -d postgres -c "CREATE DATABASE ${SERVICE_DB_NAME};" || {
    log_warning "Database '${SERVICE_DB_NAME}' may already exist"
}

# Create user if not exists (using master password for consistency)
log_info "Creating user '${SERVICE_DB_USER}' with master password..."
kubectl -n "$PG_NAMESPACE" exec "$PG_POD" -c postgresql -- \
    env PGPASSWORD="$ADMIN_PASSWORD" \
    psql -h localhost -U "$ADMIN_USER" -d postgres -c "
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_user WHERE usename = '${SERVICE_DB_USER}') THEN
            CREATE USER ${SERVICE_DB_USER} WITH PASSWORD '${ADMIN_PASSWORD}';
        ELSE
            -- Update password to match master password if user exists
            ALTER USER ${SERVICE_DB_USER} WITH PASSWORD '${ADMIN_PASSWORD}';
        END IF;
    END
    \$\$;" || {
    log_warning "User '${SERVICE_DB_USER}' may already exist"
}

# Grant privileges on database
log_info "Granting privileges on database..."
kubectl -n "$PG_NAMESPACE" exec "$PG_POD" -c postgresql -- \
    env PGPASSWORD="$ADMIN_PASSWORD" \
    psql -h localhost -U "$ADMIN_USER" -d postgres -c "
    GRANT ALL PRIVILEGES ON DATABASE ${SERVICE_DB_NAME} TO ${SERVICE_DB_USER};
    ALTER DATABASE ${SERVICE_DB_NAME} OWNER TO ${SERVICE_DB_USER};" || true

# Grant schema privileges
log_info "Granting schema privileges..."
kubectl -n "$PG_NAMESPACE" exec "$PG_POD" -c postgresql -- \
    env PGPASSWORD="$ADMIN_PASSWORD" \
    psql -h localhost -U "$ADMIN_USER" -d "${SERVICE_DB_NAME}" -c "
    GRANT ALL ON SCHEMA public TO ${SERVICE_DB_USER};
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${SERVICE_DB_USER};
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${SERVICE_DB_USER};" || true

log_success "Database '${SERVICE_DB_NAME}' and user '${SERVICE_DB_USER}' created successfully"
log_info "Connection string: postgresql://${SERVICE_DB_USER}:<POSTGRES_PASSWORD>@${PG_HOST}:${PG_PORT}/${SERVICE_DB_NAME}"
log_info "User password: Uses POSTGRES_PASSWORD (master password) for consistency"
log_info "All service database users share the master password for simplified management"

