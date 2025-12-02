#!/usr/bin/env bash
# Diagnostic script for ERP API migration failures
# Tests database connectivity and configuration

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_section() { echo -e "\n${CYAN}═══════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}═══════════════════════════════════════${NC}\n"; }

# Configuration
ERP_NAMESPACE="erp"
INFRA_NAMESPACE="infra"
SECRET_NAME="erp-api-env"
DB_NAME="bengo_erp"
DB_USER="erp_user"

log_section "ERP Migration Diagnostic Tool"

# Check 1: Namespace exists
log_info "1. Checking if ${ERP_NAMESPACE} namespace exists..."
if kubectl get namespace "${ERP_NAMESPACE}" >/dev/null 2>&1; then
    log_success "Namespace ${ERP_NAMESPACE} exists"
else
    log_error "Namespace ${ERP_NAMESPACE} does not exist"
    log_info "Create it with: kubectl create namespace ${ERP_NAMESPACE}"
    exit 1
fi

# Check 2: PostgreSQL StatefulSet/Deployment
log_info "2. Checking PostgreSQL deployment in ${INFRA_NAMESPACE}..."
PG_PODS=$(kubectl get pods -n "${INFRA_NAMESPACE}" -l app=postgresql -o name 2>/dev/null | wc -l)
if [[ $PG_PODS -gt 0 ]]; then
    log_success "PostgreSQL pod(s) found: ${PG_PODS}"
    kubectl get pods -n "${INFRA_NAMESPACE}" -l app=postgresql
    
    # Check if pods are ready
    READY_PODS=$(kubectl get pods -n "${INFRA_NAMESPACE}" -l app=postgresql -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' | grep -c "True" || echo "0")
    if [[ $READY_PODS -gt 0 ]]; then
        log_success "PostgreSQL pod(s) ready: ${READY_PODS}/${PG_PODS}"
    else
        log_error "No PostgreSQL pods are ready"
        log_warning "Check pod status: kubectl describe pods -n ${INFRA_NAMESPACE} -l app=postgresql"
        exit 1
    fi
else
    log_error "No PostgreSQL pods found in ${INFRA_NAMESPACE}"
    log_info "Install PostgreSQL: cd devops-k8s && ./scripts/infrastructure/install-databases.sh"
    exit 1
fi

# Check 3: PostgreSQL Service
log_info "3. Checking PostgreSQL service..."
if kubectl get svc postgresql -n "${INFRA_NAMESPACE}" >/dev/null 2>&1; then
    log_success "PostgreSQL service exists"
    SERVICE_IP=$(kubectl get svc postgresql -n "${INFRA_NAMESPACE}" -o jsonpath='{.spec.clusterIP}')
    SERVICE_PORT=$(kubectl get svc postgresql -n "${INFRA_NAMESPACE}" -o jsonpath='{.spec.ports[0].port}')
    log_info "Service: postgresql.${INFRA_NAMESPACE}.svc.cluster.local:${SERVICE_PORT} (${SERVICE_IP})"
else
    log_error "PostgreSQL service not found"
    exit 1
fi

# Check 4: PostgreSQL Secret
log_info "4. Checking PostgreSQL credentials secret..."
if kubectl get secret postgresql -n "${INFRA_NAMESPACE}" >/dev/null 2>&1; then
    log_success "PostgreSQL secret exists"
    
    # Try to get admin password
    ADMIN_PASS=$(kubectl get secret postgresql -n "${INFRA_NAMESPACE}" -o jsonpath='{.data.admin-user-password}' 2>/dev/null | base64 -d || echo "")
    if [[ -z "$ADMIN_PASS" ]]; then
        ADMIN_PASS=$(kubectl get secret postgresql -n "${INFRA_NAMESPACE}" -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d || echo "")
        ADMIN_USER="postgres"
    else
        ADMIN_USER="admin_user"
    fi
    
    if [[ -n "$ADMIN_PASS" ]]; then
        log_success "Retrieved admin credentials (user: ${ADMIN_USER}, password length: ${#ADMIN_PASS} chars)"
    else
        log_error "Could not retrieve password from secret"
        exit 1
    fi
else
    log_error "PostgreSQL secret not found in ${INFRA_NAMESPACE}"
    exit 1
fi

# Check 5: ERP API Secret
log_info "5. Checking ERP API environment secret..."
if kubectl get secret "${SECRET_NAME}" -n "${ERP_NAMESPACE}" >/dev/null 2>&1; then
    log_success "Secret ${SECRET_NAME} exists"
    
    # Verify required keys
    DB_HOST=$(kubectl get secret "${SECRET_NAME}" -n "${ERP_NAMESPACE}" -o jsonpath='{.data.DB_HOST}' 2>/dev/null | base64 -d || echo "")
    DB_PORT=$(kubectl get secret "${SECRET_NAME}" -n "${ERP_NAMESPACE}" -o jsonpath='{.data.DB_PORT}' 2>/dev/null | base64 -d || echo "")
    DB_NAME_FROM_SECRET=$(kubectl get secret "${SECRET_NAME}" -n "${ERP_NAMESPACE}" -o jsonpath='{.data.DB_NAME}' 2>/dev/null | base64 -d || echo "")
    DB_USER_FROM_SECRET=$(kubectl get secret "${SECRET_NAME}" -n "${ERP_NAMESPACE}" -o jsonpath='{.data.DB_USER}' 2>/dev/null | base64 -d || echo "")
    DB_PASS=$(kubectl get secret "${SECRET_NAME}" -n "${ERP_NAMESPACE}" -o jsonpath='{.data.DB_PASSWORD}' 2>/dev/null | base64 -d || echo "")
    
    log_info "DB_HOST: ${DB_HOST}"
    log_info "DB_PORT: ${DB_PORT}"
    log_info "DB_NAME: ${DB_NAME_FROM_SECRET}"
    log_info "DB_USER: ${DB_USER_FROM_SECRET}"
    log_info "DB_PASSWORD length: ${#DB_PASS} chars"
    
    # Verify host is correct
    if [[ "$DB_HOST" == "postgresql.infra.svc.cluster.local" ]]; then
        log_success "DB_HOST is correct"
    else
        log_warning "DB_HOST is '${DB_HOST}', expected 'postgresql.infra.svc.cluster.local'"
    fi
else
    log_error "Secret ${SECRET_NAME} not found in ${ERP_NAMESPACE}"
    log_info "Create it by running: cd erp/erp-api && ./scripts/setup_env_secrets.sh"
    exit 1
fi

# Check 6: Test PostgreSQL connectivity from ERP namespace
log_info "6. Testing PostgreSQL connectivity from ${ERP_NAMESPACE} namespace..."

# Clean up any existing test pod
kubectl delete pod -n "${ERP_NAMESPACE}" pg-diag-test --ignore-not-found >/dev/null 2>&1

# Test with admin user first
log_info "Testing connection with admin user (${ADMIN_USER})..."
TEST_OUTPUT=$(mktemp)
set +e
kubectl run -n "${ERP_NAMESPACE}" pg-diag-test --rm -i --restart=Never --image=postgres:15-alpine --timeout=30s \
  --env="PGPASSWORD=${ADMIN_PASS}" \
  --command -- psql -h postgresql.${INFRA_NAMESPACE}.svc.cluster.local -U "${ADMIN_USER}" -d postgres -c "SELECT version();" >$TEST_OUTPUT 2>&1
TEST_RC=$?
set -e

if [[ $TEST_RC -eq 0 ]]; then
    log_success "✓ PostgreSQL is accessible with admin user"
    PG_VERSION=$(grep -oP 'PostgreSQL \d+\.\d+' $TEST_OUTPUT || echo "Unknown")
    log_info "PostgreSQL Version: ${PG_VERSION}"
    rm -f $TEST_OUTPUT
else
    log_error "✗ Cannot connect to PostgreSQL"
    log_error "Test output:"
    cat $TEST_OUTPUT
    rm -f $TEST_OUTPUT
    log_error ""
    log_error "POSSIBLE CAUSES:"
    log_error "1. PostgreSQL service is not accessible from ${ERP_NAMESPACE} namespace"
    log_error "2. Network policies blocking access"
    log_error "3. PostgreSQL is not ready yet"
    exit 1
fi

# Check 7: Verify database exists
log_info "7. Checking if database '${DB_NAME}' exists..."
kubectl delete pod -n "${ERP_NAMESPACE}" pg-diag-test --ignore-not-found >/dev/null 2>&1

DB_EXISTS=$(kubectl run -n "${ERP_NAMESPACE}" pg-diag-test --rm -i --restart=Never --image=postgres:15-alpine --timeout=30s \
  --env="PGPASSWORD=${ADMIN_PASS}" \
  --command -- psql -h postgresql.${INFRA_NAMESPACE}.svc.cluster.local -U "${ADMIN_USER}" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}';" 2>/dev/null || echo "0")

if [[ "$DB_EXISTS" == "1" ]]; then
    log_success "Database '${DB_NAME}' exists"
else
    log_error "Database '${DB_NAME}' does NOT exist"
    log_info "Create it with:"
    log_info "  cd devops-k8s"
    log_info "  SERVICE_DB_NAME=${DB_NAME} SERVICE_DB_USER=${DB_USER} ./scripts/infrastructure/create-service-database.sh"
    exit 1
fi

# Check 8: Verify user exists
log_info "8. Checking if user '${DB_USER}' exists..."
kubectl delete pod -n "${ERP_NAMESPACE}" pg-diag-test --ignore-not-found >/dev/null 2>&1

USER_EXISTS=$(kubectl run -n "${ERP_NAMESPACE}" pg-diag-test --rm -i --restart=Never --image=postgres:15-alpine --timeout=30s \
  --env="PGPASSWORD=${ADMIN_PASS}" \
  --command -- psql -h postgresql.${INFRA_NAMESPACE}.svc.cluster.local -U "${ADMIN_USER}" -d postgres -tAc "SELECT 1 FROM pg_user WHERE usename='${DB_USER}';" 2>/dev/null || echo "0")

if [[ "$USER_EXISTS" == "1" ]]; then
    log_success "User '${DB_USER}' exists"
else
    log_error "User '${DB_USER}' does NOT exist"
    log_info "Create it with:"
    log_info "  cd devops-k8s"
    log_info "  SERVICE_DB_NAME=${DB_NAME} SERVICE_DB_USER=${DB_USER} ./scripts/infrastructure/create-service-database.sh"
    exit 1
fi

# Check 9: Test connection with service user
log_info "9. Testing connection with service user '${DB_USER}'..."
kubectl delete pod -n "${ERP_NAMESPACE}" pg-diag-test --ignore-not-found >/dev/null 2>&1

TEST_OUTPUT=$(mktemp)
set +e
kubectl run -n "${ERP_NAMESPACE}" pg-diag-test --rm -i --restart=Never --image=postgres:15-alpine --timeout=30s \
  --env="PGPASSWORD=${DB_PASS}" \
  --command -- psql -h postgresql.${INFRA_NAMESPACE}.svc.cluster.local -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT 1;" >$TEST_OUTPUT 2>&1
TEST_RC=$?
set -e

if [[ $TEST_RC -eq 0 ]]; then
    log_success "✓ Can connect to database as ${DB_USER}"
    rm -f $TEST_OUTPUT
else
    log_error "✗ Cannot connect as ${DB_USER}"
    log_error "Test output:"
    cat $TEST_OUTPUT
    rm -f $TEST_OUTPUT
    log_error ""
    log_error "PASSWORD MISMATCH - The password in ${SECRET_NAME} doesn't match the database"
    log_error ""
    log_error "FIX: Re-create the secret with correct password:"
    log_info "  cd erp/erp-api"
    log_info "  ./scripts/setup_env_secrets.sh"
    exit 1
fi

# Check 10: Check migration job status
log_info "10. Checking recent migration jobs..."
MIGRATION_JOBS=$(kubectl get jobs -n "${ERP_NAMESPACE}" -l component=migration --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -5)
if [[ -n "$MIGRATION_JOBS" ]]; then
    echo "$MIGRATION_JOBS"
else
    log_info "No migration jobs found"
fi

log_section "Diagnostic Complete"
log_success "All checks passed! Database connectivity is working."
log_info ""
log_info "If migrations are still failing, check:"
log_info "1. Migration job logs: kubectl logs -n ${ERP_NAMESPACE} <migration-pod-name>"
log_info "2. Recent migration jobs: kubectl get jobs -n ${ERP_NAMESPACE} -l component=migration"
log_info "3. Helm release status: helm list -n ${ERP_NAMESPACE}"

