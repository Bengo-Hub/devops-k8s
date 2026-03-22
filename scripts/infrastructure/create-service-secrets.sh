#!/usr/bin/env bash
set -euo pipefail

# Script to create Kubernetes secrets for Go microservices
# Creates only standardized keys: POSTGRES_URL, REDIS_URL, REDIS_PASSWORD, SECRET_KEY, DATABASE_*
# All Go backends must read these env keys (no postgresUrl or service-prefixed DB URL keys).
#
# Usage:
#   SERVICE_NAME=auth-api ./create-service-secrets.sh
#   SERVICE_NAME=ordering-backend NAMESPACE=ordering ./create-service-secrets.sh
#   SERVICE_NAME=treasury-api NAMESPACE=treasury ./create-service-secrets.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tools/common.sh"

# Configuration
SERVICE_NAME=${SERVICE_NAME:-}
NAMESPACE=${NAMESPACE:-}
DB_NAME=${DB_NAME:-}
DB_USER=${DB_USER:-}
SECRET_NAME=${SECRET_NAME:-}

# Validate service name
if [[ -z "$SERVICE_NAME" ]]; then
    log_error "SERVICE_NAME is required"
    echo ""
    echo "Usage:"
    echo "  SERVICE_NAME=auth-api ./create-service-secrets.sh"
    echo "  SERVICE_NAME=ordering-backend NAMESPACE=ordering ./create-service-secrets.sh"
    echo ""
    echo "Supported services:"
    echo "  - auth, ordering, treasury, inventory, logistics, erp"
    echo "  - subscriptions, projects, notifications, iot"
    echo "  - truload, isp-billing, ticketing, cafe, pos"
    exit 1
fi

# Infer namespace from service name if not provided
if [[ -z "$NAMESPACE" ]]; then
    case "$SERVICE_NAME" in
        auth-api)
            NAMESPACE="auth"
            ;;
        auth-ui)
            NAMESPACE="auth"
            ;;
        subscriptions-api)
            NAMESPACE="subscriptions"
            ;;
        subscriptions-ui)
            NAMESPACE="subscriptions"
            ;;
        notifications-api)
            NAMESPACE="notifications"
            ;;
        notifications-ui)
            NAMESPACE="notifications"
            ;;
        logistics-ui)
            NAMESPACE="logistics"
            ;;
        logistics-api)
            NAMESPACE="logistics"
            ;;
        iot-api)
            NAMESPACE="iot"
            ;;
        iot-ui)
            NAMESPACE="iot"
            ;;
        ordering-backend)
            NAMESPACE="ordering"
            ;;
        ordering-frontend)
            NAMESPACE="ordering"
            ;;
        treasury-api)
            NAMESPACE="treasury"
            ;;
        treasury-ui)
            NAMESPACE="treasury"
            ;;
        inventory-api)
            NAMESPACE="inventory"
            ;;
        inventory-ui)
            NAMESPACE="inventory"
            ;;
        pos-api)
            NAMESPACE="pos"
            ;;
        pos-ui)
            NAMESPACE="pos"
            ;;
        erp-api)
            NAMESPACE="erp"
            ;;
        erp-ui)
            NAMESPACE="erp"
            ;;
        projects-api)
            NAMESPACE="projects"
            ;;
        projects-ui)
            NAMESPACE="projects"
            ;;
        # Subscription service — note: namespace is "subscriptions" (plural) but
        # the Helm release/secret uses "subscription-api" (singular)
        subscription-api)
            NAMESPACE="subscriptions"
            ;;
        ticketing-api)
            NAMESPACE="ticketing"
            ;;
        ticketing-ui)
            NAMESPACE="ticketing"
            ;;
        truload-backend)
            NAMESPACE="truload"
            ;;
        truload-frontend)
            NAMESPACE="truload"
            ;;
        isp-billing-backend)
            NAMESPACE="isp-billing"
            ;;
        isp-billing-frontend)
            NAMESPACE="isp-billing"
            ;;
        cafe-website)
            NAMESPACE="cafe"
            ;;
        rider-app)
            NAMESPACE="logistics"
            ;;
        iot-service-api)
            NAMESPACE="iot"
            ;;
        *)
            # Try to extract namespace from service name
            NAMESPACE=$(echo "$SERVICE_NAME" | sed 's/-service$//' | sed 's/-backend$//' | sed 's/-app$//' | sed 's/-api$//' | sed 's/-ui$//' | sed 's/-frontend$//')
            ;;
    esac
fi

# Infer database name from service name if not provided
if [[ -z "$DB_NAME" ]]; then
    DB_NAME=$(echo "$SERVICE_NAME" | sed 's/-service$//' | sed 's/-backend$//' | sed 's/-api$//' | sed 's/-app$//' | tr '-' '_')
fi

# Infer database user from database name if not provided
if [[ -z "$DB_USER" ]]; then
    DB_USER="${DB_NAME}_user"
fi

# Infer secret name if not provided
if [[ -z "$SECRET_NAME" ]]; then
    SECRET_NAME="${SERVICE_NAME}-secrets"
fi

log_section "Creating Secrets for ${SERVICE_NAME}"

log_info "Configuration:"
echo "  Service Name: ${SERVICE_NAME}"
echo "  Namespace: ${NAMESPACE}"
echo "  Database Name: ${DB_NAME}"
echo "  Database User: ${DB_USER}"
echo "  Secret Name: ${SECRET_NAME}"
echo ""

# Function to generate secure random password
generate_password() {
    local length=${1:-32}
    openssl rand -base64 48 | tr -d "=+/" | cut -c1-${length}
}

# Check if namespace exists
if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    log_warning "Namespace ${NAMESPACE} does not exist. Creating..."
    kubectl create namespace "${NAMESPACE}"
fi

# Check if secret already exists and retrieve existing values to avoid rotation
EXISTING_SECRET_KEY=""
if kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    log_info "Secret ${SECRET_NAME} already exists. Retrieving existing values to avoid rotation..."
    EXISTING_SECRET_KEY=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath="{.data.SECRET_KEY}" 2>/dev/null | base64 -d || echo "")
    
    if [[ "${ENABLE_CLEANUP:-false}" == "true" ]]; then
        log_info "Cleanup mode active: Existing secret will be fully replaced."
        kubectl delete secret "${SECRET_NAME}" -n "${NAMESPACE}"
    fi
fi

# Generate passwords and connection strings
log_info "Generating secure passwords..."

# Database password - Priority: POSTGRES_PASSWORD env > cluster secret > generate
PG_NAMESPACE=${PG_NAMESPACE:-infra}
PG_HOST=${PG_HOST:-postgresql.infra.svc.cluster.local}
PG_PORT=${PG_PORT:-5432}

# Try to get password - Priority: POSTGRES_PASSWORD env > admin-user-password secret > postgres-password secret
# CRITICAL: Service users now use POSTGRES_PASSWORD (master password) for consistency
DATABASE_PASSWORD=""
if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
    log_info "Using POSTGRES_PASSWORD from environment (GitHub secret - master password)"
    DATABASE_PASSWORD="${POSTGRES_PASSWORD}"
elif kubectl get secret postgresql -n "${PG_NAMESPACE}" >/dev/null 2>&1; then
    # Get master password from admin-user-password (used for all service users)
    DATABASE_PASSWORD=$(kubectl get secret postgresql -n "${PG_NAMESPACE}" -o jsonpath="{.data.admin-user-password}" 2>/dev/null | base64 -d || echo "")
    
    if [[ -z "$DATABASE_PASSWORD" ]]; then
        # Fallback to postgres-password if admin-user-password not found
        DATABASE_PASSWORD=$(kubectl get secret postgresql -n "${PG_NAMESPACE}" -o jsonpath="{.data.postgres-password}" 2>/dev/null | base64 -d || echo "")
    fi
    
    if [[ -n "$DATABASE_PASSWORD" ]]; then
        log_info "Retrieved master password from PostgreSQL secret (used for all service users)"
    fi
fi

# Generate new password if not found (should not happen in production)
if [[ -z "$DATABASE_PASSWORD" ]]; then
    DATABASE_PASSWORD=$(generate_password 32)
    log_warning "Generated new password. This should not happen in production!"
    log_warning "Ensure POSTGRES_PASSWORD is set or PostgreSQL secret exists."
fi

# Application SECRET_KEY (used by some services for encryption/session)
if [[ -n "${SECRET_KEY:-}" ]]; then
    APP_SECRET_KEY="$SECRET_KEY"
elif [[ -n "${EXISTING_SECRET_KEY:-}" ]]; then
    log_info "Retrieved existing app SECRET_KEY from cluster"
    APP_SECRET_KEY="$EXISTING_SECRET_KEY"
else
    APP_SECRET_KEY=$(generate_password 64)
    log_info "Generated new app SECRET_KEY"
fi

# Redis password - Priority: POSTGRES_PASSWORD env > REDIS_PASSWORD env > redis secret
# CRITICAL: Redis now uses POSTGRES_PASSWORD (master password) for consistency
REDIS_PASSWORD=""
REDIS_HOST="redis-master.infra.svc.cluster.local"
REDIS_PORT="6379"
if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
    log_info "Using POSTGRES_PASSWORD for Redis (master password)"
    REDIS_PASSWORD="${POSTGRES_PASSWORD}"
elif [[ -n "${REDIS_PASSWORD:-}" ]]; then
    log_info "Using REDIS_PASSWORD from environment"
    REDIS_PASSWORD="${REDIS_PASSWORD}"
elif kubectl get secret redis -n infra >/dev/null 2>&1; then
    REDIS_PASSWORD=$(kubectl get secret redis -n infra \
        -o jsonpath="{.data.redis-password}" | base64 -d 2>/dev/null || echo "")
    if [[ -n "$REDIS_PASSWORD" ]]; then
        log_info "Retrieved Redis password from secret"
    fi
fi

# URL-encode a string for safe embedding in connection URIs (RFC 3986 userinfo).
# Characters like ! @ : / ? # [ ] and others must be percent-encoded.
url_encode_password() {
    python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1" 2>/dev/null \
    || printf '%s' "$1" | sed 's/!/%21/g; s/@/%40/g; s/:/%3A/g; s|/|%2F|g; s/?/%3F/g; s/#/%23/g'
}

# Construct PostgreSQL URL (password is percent-encoded for safe URL parsing by Go/pgx)
if [[ -n "$DATABASE_PASSWORD" ]]; then
    ENCODED_DB_PASSWORD=$(url_encode_password "$DATABASE_PASSWORD")
    POSTGRES_URL="postgresql://${DB_USER}:${ENCODED_DB_PASSWORD}@${PG_HOST}:${PG_PORT}/${DB_NAME}?sslmode=disable"
else
    POSTGRES_URL="postgresql://${DB_USER}:CHANGE_ME@${PG_HOST}:${PG_PORT}/${DB_NAME}?sslmode=disable"
fi

# Construct Redis URL (password is percent-encoded)
if [[ -n "$REDIS_PASSWORD" ]]; then
    ENCODED_REDIS_PASSWORD=$(url_encode_password "$REDIS_PASSWORD")
    REDIS_URL="redis://:${ENCODED_REDIS_PASSWORD}@${REDIS_HOST}:${REDIS_PORT}/0"
else
    REDIS_URL="redis://${REDIS_HOST}:${REDIS_PORT}/0"
fi

# Upsert standardized keys (POSTGRES_URL, REDIS_*, SECRET_KEY, DATABASE_*)
# IMPORTANT: Uses patch to MERGE keys into existing secret, never replacing it.
# This preserves service-specific keys (OAuth, seeding) added by provision.yml.
log_info "Upserting standardized keys into ${SECRET_NAME} in namespace ${NAMESPACE}..."

# Build array of standardized key literals
declare -a secret_literals=(
    "--from-literal=POSTGRES_URL=${POSTGRES_URL}"
    "--from-literal=SECRET_KEY=${APP_SECRET_KEY}"
    "--from-literal=DATABASE_HOST=${PG_HOST}"
    "--from-literal=DATABASE_PORT=${PG_PORT}"
    "--from-literal=DATABASE_NAME=${DB_NAME}"
    "--from-literal=DATABASE_USER=${DB_USER}"
    "--from-literal=DATABASE_PASSWORD=${DATABASE_PASSWORD}"
    "--from-literal=REDIS_URL=${REDIS_URL}"
    "--from-literal=REDIS_HOST=${REDIS_HOST}"
    "--from-literal=REDIS_PORT=${REDIS_PORT}"
    "--from-literal=REDIS_PASSWORD=${REDIS_PASSWORD}"
)

if kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    # Secret exists — patch to merge standardized keys without losing existing keys
    # Generate the new data as base64 and build a JSON patch
    PATCH_JSON='{"data":{'
    PATCH_JSON+="\"POSTGRES_URL\":\"$(echo -n "${POSTGRES_URL}" | base64 -w0)\","
    PATCH_JSON+="\"SECRET_KEY\":\"$(echo -n "${APP_SECRET_KEY}" | base64 -w0)\","
    PATCH_JSON+="\"DATABASE_HOST\":\"$(echo -n "${PG_HOST}" | base64 -w0)\","
    PATCH_JSON+="\"DATABASE_PORT\":\"$(echo -n "${PG_PORT}" | base64 -w0)\","
    PATCH_JSON+="\"DATABASE_NAME\":\"$(echo -n "${DB_NAME}" | base64 -w0)\","
    PATCH_JSON+="\"DATABASE_USER\":\"$(echo -n "${DB_USER}" | base64 -w0)\","
    PATCH_JSON+="\"DATABASE_PASSWORD\":\"$(echo -n "${DATABASE_PASSWORD}" | base64 -w0)\","
    PATCH_JSON+="\"REDIS_URL\":\"$(echo -n "${REDIS_URL}" | base64 -w0)\","
    PATCH_JSON+="\"REDIS_HOST\":\"$(echo -n "${REDIS_HOST}" | base64 -w0)\","
    PATCH_JSON+="\"REDIS_PORT\":\"$(echo -n "${REDIS_PORT}" | base64 -w0)\","
    PATCH_JSON+="\"REDIS_PASSWORD\":\"$(echo -n "${REDIS_PASSWORD}" | base64 -w0)\""
    PATCH_JSON+='}}'

    kubectl patch secret "${SECRET_NAME}" -n "${NAMESPACE}" \
        --type merge -p "${PATCH_JSON}"
    RESULT=$?
    log_info "Patched existing secret (merged standardized keys, preserved service-specific keys)"
else
    # Secret does not exist — create it fresh
    kubectl create secret generic "${SECRET_NAME}" \
        --namespace="${NAMESPACE}" \
        "${secret_literals[@]}"
    RESULT=$?
    log_info "Created new secret"
fi

if [ $RESULT -eq 0 ]; then
    log_success "Secret ${SECRET_NAME} upserted successfully in namespace ${NAMESPACE}"
else
    log_error "Failed to create secret"
    exit 1
fi

# Label the secret for easier management
kubectl label secret "${SECRET_NAME}" -n "${NAMESPACE}" \
    app="${SERVICE_NAME}" \
    managed-by=script \
    --overwrite >/dev/null 2>&1 || true

# Display summary
log_section "Secret Creation Summary"
echo "Namespace: ${NAMESPACE}"
echo "Secret Name: ${SECRET_NAME}"
echo "Database: ${DB_NAME}"
echo "Database User: ${DB_USER}"
echo ""
log_warning "IMPORTANT: Save these credentials securely!"
echo "Database Password: ${DATABASE_PASSWORD}"
echo ""
echo "PostgreSQL URL: ${POSTGRES_URL}"
echo "Redis URL: ${REDIS_URL}"
echo "SECRET_KEY: ${APP_SECRET_KEY}"
echo ""

# Create backup file
BACKUP_DIR="${SCRIPT_DIR}/../../backups"
mkdir -p "${BACKUP_DIR}"
BACKUP_FILE="${BACKUP_DIR}/${SERVICE_NAME}-secrets-$(date +%Y%m%d-%H%M%S).txt"

cat > "${BACKUP_FILE}" <<EOF
# ${SERVICE_NAME} Secrets Backup
# Created: $(date)
# Namespace: ${NAMESPACE}
# Secret Name: ${SECRET_NAME}

SERVICE_NAME=${SERVICE_NAME}
NAMESPACE=${NAMESPACE}
DATABASE_NAME=${DB_NAME}
DATABASE_USER=${DB_USER}
DATABASE_PASSWORD=${DATABASE_PASSWORD}
DATABASE_HOST=${PG_HOST}
DATABASE_PORT=${PG_PORT}

REDIS_HOST=${REDIS_HOST}
REDIS_PORT=${REDIS_PORT}
REDIS_PASSWORD=${REDIS_PASSWORD}

POSTGRES_URL=${POSTGRES_URL}
REDIS_URL=${REDIS_URL}

# DO NOT COMMIT THIS FILE TO VERSION CONTROL
# Store it securely (e.g., encrypted vault, password manager)
EOF

chmod 600 "${BACKUP_FILE}"
log_success "Credentials backed up to: ${BACKUP_FILE}"
log_warning "Please store this file securely and delete it after backing up elsewhere!"

echo ""
log_info "Next Steps:"
echo "1. Create the database:"
echo "   SERVICE_DB_NAME=${DB_NAME} SERVICE_DB_USER=${DB_USER} ./create-service-database.sh"
echo ""
echo "2. Verify the secret:"
echo "   kubectl get secret ${SECRET_NAME} -n ${NAMESPACE}"
echo ""
echo "3. Deploy your service via ArgoCD:"
echo "   kubectl apply -f ../../apps/${SERVICE_NAME}/app.yaml"
echo ""
echo "4. Monitor deployment:"
echo "   kubectl get pods -n ${NAMESPACE} -w"

