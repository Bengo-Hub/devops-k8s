#!/usr/bin/env bash
set -euo pipefail

# Script to sync superset-secrets into superset-env
# This ensures the Helm-created superset-env has correct external service hostnames
# Run this after ArgoCD syncs or when superset-env gets recreated with defaults

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tools/common.sh"

NAMESPACE=${NAMESPACE:-infra}
SOURCE_SECRET="superset-secrets"
TARGET_SECRET="superset-env"

log_section "Syncing Superset Secrets"

# Check if source secret exists
if ! kubectl get secret "${SOURCE_SECRET}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    log_error "Source secret ${SOURCE_SECRET} not found in namespace ${NAMESPACE}"
    log_info "Run ./create-superset-secrets.sh first"
    exit 1
fi

# Get values from superset-secrets
log_info "Reading credentials from ${SOURCE_SECRET}..."
DB_PASS=$(kubectl get secret "${SOURCE_SECRET}" -n "${NAMESPACE}" -o jsonpath='{.data.DATABASE_PASSWORD}' | base64 -d)
SECRET_KEY=$(kubectl get secret "${SOURCE_SECRET}" -n "${NAMESPACE}" -o jsonpath='{.data.SECRET_KEY}' | base64 -d)
REDIS_PASS=$(kubectl get secret "${SOURCE_SECRET}" -n "${NAMESPACE}" -o jsonpath='{.data.REDIS_PASSWORD}' | base64 -d)

if [ -z "${DB_PASS}" ] || [ -z "${SECRET_KEY}" ]; then
    log_error "Failed to read required credentials from ${SOURCE_SECRET}"
    exit 1
fi

# Delete superset-env if it exists
if kubectl get secret "${TARGET_SECRET}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    log_info "Deleting existing ${TARGET_SECRET}..."
    kubectl delete secret "${TARGET_SECRET}" -n "${NAMESPACE}"
fi

# Create superset-env with correct values
log_info "Creating ${TARGET_SECRET} with correct external service hostnames..."
kubectl create secret generic "${TARGET_SECRET}" \
    --namespace="${NAMESPACE}" \
    --from-literal=DB_HOST="postgresql.infra.svc.cluster.local" \
    --from-literal=DB_PORT="5432" \
    --from-literal=DB_USER="superset_user" \
    --from-literal=DB_PASS="${DB_PASS}" \
    --from-literal=DB_NAME="superset" \
    --from-literal=SECRET_KEY="${SECRET_KEY}" \
    --from-literal=SUPERSET_SECRET_KEY="${SECRET_KEY}" \
    --from-literal=REDIS_HOST="redis-master.infra.svc.cluster.local" \
    --from-literal=REDIS_PORT="6379" \
    --from-literal=REDIS_PASSWORD="${REDIS_PASS}"

if [ $? -eq 0 ]; then
    log_success "Secret ${TARGET_SECRET} synced successfully"
else
    log_error "Failed to create ${TARGET_SECRET}"
    exit 1
fi

# Check if we should restart deployments
if [[ "${RESTART_DEPLOYMENTS:-yes}" == "yes" ]]; then
    log_info "Restarting Superset deployments to pick up new secret..."
    kubectl rollout restart deployment superset superset-worker superset-celerybeat -n "${NAMESPACE}" 2>/dev/null || true
    log_success "Deployments restarted"
else
    log_info "Skipping deployment restart (set RESTART_DEPLOYMENTS=yes to enable)"
fi

log_success "Superset environment secret synced from ${SOURCE_SECRET}"
echo ""
log_info "Run this script after each ArgoCD sync if Superset pods fail with connection errors"
