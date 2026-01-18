#!/usr/bin/env bash
set -euo pipefail

# Script to create Kubernetes secrets for Apache Superset deployment
# This script generates secure random passwords and creates the necessary secrets

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tools/common.sh"

# Configuration
NAMESPACE=${SUPERSET_NAMESPACE:-default}
SECRET_NAME=${SECRET_NAME:-superset-secrets}

log_section "Creating Apache Superset Secrets"

# Function to generate secure random password
generate_password() {
    local length=${1:-32}
    openssl rand -base64 48 | tr -d "=+/" | cut -c1-${length}
}

# Function to generate secret key (for Flask)
generate_secret_key() {
    python3 -c 'import secrets; print(secrets.token_urlsafe(64))'
}

# Check if namespace exists
if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    log_warning "Namespace ${NAMESPACE} does not exist. Creating..."
    kubectl create namespace "${NAMESPACE}"
fi

# Check if secret already exists
if kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    log_warning "Secret ${SECRET_NAME} already exists in namespace ${NAMESPACE}"
    
    # Check if running in CI/CD (non-interactive)
    if [[ -n "${CI:-}${GITHUB_ACTIONS:-}${GITLAB_CI:-}" ]] || [[ ! -t 0 ]]; then
        log_info "Running in non-interactive mode - keeping existing secret"
        log_success "Secret ${SECRET_NAME} already configured"
        exit 0
    fi
    
    # Interactive mode - prompt user
    read -p "Do you want to recreate it? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Keeping existing secret"
        exit 0
    fi
    log_info "Deleting existing secret..."
    kubectl delete secret "${SECRET_NAME}" -n "${NAMESPACE}"
fi

# Generate passwords and keys
log_info "Generating secure passwords and keys..."

# Database password - use POSTGRES_PASSWORD env var (from GitHub secret) or get from cluster
if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
    log_info "Using POSTGRES_PASSWORD from environment (GitHub secret)"
    DATABASE_PASSWORD="${POSTGRES_PASSWORD}"
elif kubectl get secret postgresql -n infra >/dev/null 2>&1; then
    log_info "Using existing PostgreSQL password from cluster secret"
    DATABASE_PASSWORD=$(kubectl get secret postgresql -n infra \
        -o jsonpath="{.data.postgres-password}" | base64 -d 2>/dev/null || generate_password 32)
else
    log_warning "POSTGRES_PASSWORD not set and PostgreSQL secret not found. Generating random password."
    DATABASE_PASSWORD=$(generate_password 32)
fi

# Admin password
ADMIN_PASSWORD=$(generate_password 20)

# Superset secret key (Flask session key)
if command -v python3 >/dev/null 2>&1; then
    SECRET_KEY=$(generate_secret_key)
else
    log_warning "Python3 not found. Using OpenSSL for secret key generation."
    SECRET_KEY=$(generate_password 64)
fi

# Redis password - use POSTGRES_PASSWORD for uniformity across all infra services
# Priority: POSTGRES_PASSWORD env > Redis cluster secret > generate
if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
    log_info "Using POSTGRES_PASSWORD from environment for Redis (GitHub secret)"
    REDIS_PASSWORD="${POSTGRES_PASSWORD}"
elif kubectl get secret redis -n infra >/dev/null 2>&1; then
    log_info "Using existing Redis password from cluster secret"
    REDIS_PASSWORD=$(kubectl get secret redis -n infra \
        -o jsonpath="{.data.redis-password}" | base64 -d 2>/dev/null || echo "")
else
    log_warning "POSTGRES_PASSWORD not set and Redis secret not found. Using empty password."
    REDIS_PASSWORD=""
fi

# Admin username
ADMIN_USERNAME=${ADMIN_USERNAME:-admin}
ADMIN_FIRSTNAME=${ADMIN_FIRSTNAME:-Admin}
ADMIN_LASTNAME=${ADMIN_LASTNAME:-User}
ADMIN_EMAIL=${ADMIN_EMAIL:-admin@codevertexitsolutions.com}

# Create the secret
log_info "Creating Kubernetes secret..."

kubectl create secret generic "${SECRET_NAME}" \
    --namespace="${NAMESPACE}" \
    --from-literal=DATABASE_PASSWORD="${DATABASE_PASSWORD}" \
    --from-literal=DATABASE_USER="superset_user" \
    --from-literal=DATABASE_DB="superset" \
    --from-literal=DATABASE_HOST="postgresql.infra.svc.cluster.local" \
    --from-literal=DATABASE_PORT="5432" \
    --from-literal=SECRET_KEY="${SECRET_KEY}" \
    --from-literal=SUPERSET_SECRET_KEY="${SECRET_KEY}" \
    --from-literal=ADMIN_USERNAME="${ADMIN_USERNAME}" \
    --from-literal=ADMIN_PASSWORD="${ADMIN_PASSWORD}" \
    --from-literal=ADMIN_FIRSTNAME="${ADMIN_FIRSTNAME}" \
    --from-literal=ADMIN_LASTNAME="${ADMIN_LASTNAME}" \
    --from-literal=ADMIN_EMAIL="${ADMIN_EMAIL}" \
    --from-literal=REDIS_HOST="redis-master.infra.svc.cluster.local" \
    --from-literal=REDIS_PORT="6379" \
    --from-literal=REDIS_PASSWORD="${REDIS_PASSWORD}" \
    --from-literal=SUPERSET_DB_PASSWORD="${DATABASE_PASSWORD}" \
    --from-literal=DB_USER="superset_user" \
    --from-literal=DB_PASS="${DATABASE_PASSWORD}" \
    --from-literal=DB_HOST="postgresql.infra.svc.cluster.local" \
    --from-literal=DB_PORT="5432" \
    --from-literal=DB_NAME="superset"

if [ $? -eq 0 ]; then
    log_success "Secret ${SECRET_NAME} created successfully in namespace ${NAMESPACE}"
else
    log_error "Failed to create secret"
    exit 1
fi

# Label the secret for easier management
kubectl label secret "${SECRET_NAME}" -n "${NAMESPACE}" \
    app=superset \
    managed-by=script \
    --overwrite

# =============================================================================
# Sync superset-env from superset-secrets
# =============================================================================
# The Superset Helm chart creates a 'superset-env' secret automatically.
# We use sync-superset-env.sh to ensure it has correct external service hostnames
log_info "Syncing superset-env from superset-secrets..."
if [ -f "${SCRIPT_DIR}/sync-superset-env.sh" ]; then
    NAMESPACE="${NAMESPACE}" RESTART_DEPLOYMENTS=no "${SCRIPT_DIR}/sync-superset-env.sh"
else
    log_warning "sync-superset-env.sh not found - skipping automatic sync"
    log_info "Run ./sync-superset-env.sh manually after ArgoCD sync if needed"
fi

# Display summary
log_section "Secret Creation Summary"
echo "Namespace: ${NAMESPACE}"
echo "Secret: ${SECRET_NAME} (source of truth for all Superset credentials)"
echo "Admin Username: ${ADMIN_USERNAME}"
echo "Admin Email: ${ADMIN_EMAIL}"
echo ""
log_warning "IMPORTANT: Save these credentials securely!"
echo "Admin Password: ${ADMIN_PASSWORD}"
echo ""
log_info "Secret management:"
echo "  - ${SECRET_NAME}: Source of truth for credentials"
echo "  - superset-env: Auto-synced from ${SECRET_NAME} by sync-superset-env.sh"
echo ""
log_info "After ArgoCD sync, if Superset fails with connection errors:"
echo "  ./sync-superset-env.sh"
echo ""
log_info "To view secret:"
echo "  kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} -o yaml"

# Create a backup file (encrypted)
BACKUP_DIR="${SCRIPT_DIR}/../../backups"
mkdir -p "${BACKUP_DIR}"
BACKUP_FILE="${BACKUP_DIR}/superset-secrets-$(date +%Y%m%d-%H%M%S).txt"

cat > "${BACKUP_FILE}" <<EOF
# Superset Secrets Backup
# Created: $(date)
# Namespace: ${NAMESPACE}
# Secret Name: ${SECRET_NAME}

ADMIN_USERNAME=${ADMIN_USERNAME}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
ADMIN_EMAIL=${ADMIN_EMAIL}
DATABASE_PASSWORD=${DATABASE_PASSWORD}
SECRET_KEY=${SECRET_KEY}

# DO NOT COMMIT THIS FILE TO VERSION CONTROL
# Store it securely (e.g., encrypted vault, password manager)
EOF

chmod 600 "${BACKUP_FILE}"
log_success "Credentials backed up to: ${BACKUP_FILE}"
log_warning "Please store this file securely and delete it after backing up elsewhere!"

