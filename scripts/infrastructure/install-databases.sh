#!/usr/bin/env bash
set -euo pipefail

# Production-ready Database Installation
# Installs PostgreSQL and Redis with production configurations

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# MANIFESTS_DIR is at repo root/manifests/databases
MANIFESTS_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/manifests/databases"
source "${SCRIPT_DIR}/../tools/common.sh"
source "${SCRIPT_DIR}/../tools/helm-utils.sh"
source "${SCRIPT_DIR}/../tools/database-utils.sh"

# Configuration
NAMESPACE=${DB_NAMESPACE:-infra}
PG_DATABASE=${PG_DATABASE:-postgres}
MONITORING_NS=${MONITORING_NAMESPACE:-infra}
# Which components to manage in this run:
# - "all"      (default): PostgreSQL + Redis
# - "postgres": PostgreSQL only
# - "redis"   : Redis only
ONLY_COMPONENT=${ONLY_COMPONENT:-all}
# Cleanup mode DISABLED by default to prevent accidental data loss
# Enable with GitHub secret ENABLE_CLEANUP=true or environment variable
ENABLE_CLEANUP=${ENABLE_CLEANUP:-false}

log_section "Installing Shared Infrastructure Databases (Production)"
log_info "Namespace: ${NAMESPACE}"
log_info "Monitoring Namespace: ${MONITORING_NS}"
log_info "PostgreSQL Database: ${PG_DATABASE} (services create their own databases)"
if [ "${ENABLE_CLEANUP}" = "true" ]; then
  log_warning "⚠️  CLEANUP MODE ENABLED - Will delete existing resources and data"
else
  log_info "Cleanup mode disabled - Will update existing resources"
fi

# Pre-flight checks
check_kubectl
check_cluster_health
ensure_storage_class "${SCRIPT_DIR}"
ensure_helm

# Add Bitnami repository
add_helm_repo "bitnami" "https://charts.bitnami.com/bitnami"

# Create namespace
ensure_namespace "${NAMESPACE}"

# PostgreSQL Installation Section
# =============================================================================

log_section "PostgreSQL Installation"

# Skip PostgreSQL if only installing Redis
if [ "${ONLY_COMPONENT}" = "redis" ]; then
  log_info "Skipping PostgreSQL (ONLY_COMPONENT=redis)"
  POSTGRES_DEPLOYED=false
else
  # Install PostgreSQL using custom manifests
  log_info "Using custom StatefulSet manifests with CodeVertex postgresql-pgvector image"
  
  # Check if cleanup mode is enabled
  if [ "${ENABLE_CLEANUP}" = "true" ]; then
    log_warning "Cleanup mode: Deleting existing PostgreSQL resources..."
    kubectl delete -f "${MANIFESTS_DIR}/postgresql-statefulset.yaml" --ignore-not-found=true --wait=true --grace-period=0 2>/dev/null || true
    kubectl delete pvc -n "${NAMESPACE}" -l app=postgresql --wait=true --grace-period=0 2>/dev/null || true
    # Delete any Helm release if it exists
    if command -v helm >/dev/null 2>&1; then
      helm uninstall postgresql -n "${NAMESPACE}" --wait 2>/dev/null || true
    fi
    sleep 5
  fi
  
  # Ensure PostgreSQL secret exists
  if ! kubectl get secret postgresql -n "${NAMESPACE}" >/dev/null 2>&1; then
    log_info "Creating PostgreSQL secret with GitHub secrets..."
    
    # Use GitHub secrets for passwords (from environment)
    POSTGRES_PASS=${POSTGRES_PASSWORD:-$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)}
    
    kubectl create secret generic postgresql \
      -n "${NAMESPACE}" \
      --from-literal=password="${POSTGRES_PASS}" \
      --from-literal=postgres-password="${POSTGRES_PASS}" \
      --from-literal=admin-user-password="${POSTGRES_PASS}"
    
    log_success "PostgreSQL secret created with GitHub POSTGRES_PASSWORD"
  else
    log_info "PostgreSQL secret already exists - reusing"
  fi
  
  # Apply PostgreSQL manifests
  log_info "Applying PostgreSQL custom manifests..."
  kubectl apply -f "${MANIFESTS_DIR}/postgresql-statefulset.yaml"
  
  # Wait for PostgreSQL to be ready
  log_info "Waiting for PostgreSQL to be ready (timeout: 5 minutes)..."
  kubectl wait --for=condition=ready pod/postgresql-0 -n "${NAMESPACE}" --timeout=300s || {
    log_warning "PostgreSQL pod not ready after 5 minutes, checking status..."
    kubectl get pod postgresql-0 -n "${NAMESPACE}" || true
    kubectl describe pod postgresql-0 -n "${NAMESPACE}" || true
  }
  
  # Verify PostgreSQL is running
  if kubectl get pod postgresql-0 -n "${NAMESPACE}" 2>/dev/null | grep -q "2/2.*Running"; then
    log_success "PostgreSQL is ready and healthy"
    log_info "Image: docker.io/codevertex/postgresql-pgvector:latest"
    log_info "pgvector extension: Enabled"
    POSTGRES_DEPLOYED=true
  else
    log_error "PostgreSQL deployment may have issues"
    kubectl describe pod postgresql-0 -n "${NAMESPACE}" || true
    POSTGRES_DEPLOYED=false
  fi
fi

# =============================================================================
# Redis Installation Section  
# =============================================================================

# Check if cleanup mode is enabled
if [ "${ENABLE_CLEANUP}" = "true" ]; then
  log_warning "Cleanup mode: Deleting existing PostgreSQL resources..."
  kubectl delete -f "${MANIFESTS_DIR}/postgresql-statefulset.yaml" --ignore-not-found=true --wait=true --grace-period=0 2>/dev/null || true
  kubectl delete pvc -n "${NAMESPACE}" -l app=postgresql --wait=true --grace-period=0 2>/dev/null || true
  sleep 5
fi

# Ensure PostgreSQL secret exists
if ! kubectl get secret postgresql -n "${NAMESPACE}" >/dev/null 2>&1; then
  log_info "Creating PostgreSQL secret with GitHub secrets..."
  
  # Use GitHub secrets for passwords
  POSTGRES_PASS=${POSTGRES_PASSWORD:-$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)}
  
  kubectl create secret generic postgresql \
    -n "${NAMESPACE}" \
    --from-literal=password="${POSTGRES_PASS}" \
    --from-literal=postgres-password="${POSTGRES_PASS}" \
    --from-literal=admin-user-password="${POSTGRES_PASS}"
  
  log_success "PostgreSQL secret created"
else
  log_info "PostgreSQL secret already exists"
fi

# Apply PostgreSQL manifests
log_info "Applying PostgreSQL custom manifests..."
kubectl apply -f "${MANIFESTS_DIR}/postgresql-statefulset.yaml"

# Wait for PostgreSQL to be ready
log_info "Waiting for PostgreSQL to be ready..."
kubectl wait --for=condition=ready pod/postgresql-0 -n "${NAMESPACE}" --timeout=300s || true

# Check if healthy
if kubectl get pod postgresql-0 -n "${NAMESPACE}" | grep -q "2/2.*Running"; then
  log_success "PostgreSQL is ready and healthy"
  POSTGRES_DEPLOYED=true
else
  log_error "PostgreSQL deployment may have issues"
  kubectl describe pod postgresql-0 -n "${NAMESPACE}" || true
fi

set -e

# PostgreSQL installation complete (using custom manifests)
# Old Helm verification code removed - using kubectl wait instead

# =============================================================================
# Redis Installation (Custom Manifests)
# =============================================================================

log_section "Redis Installation"

# Skip Redis if only installing PostgreSQL
if [ "${ONLY_COMPONENT}" = "postgres" ]; then
  log_info "Skipping Redis (ONLY_COMPONENT=postgres)"
  REDIS_DEPLOYED=false
else
  log_info "Using custom StatefulSet manifests with official redis:7-alpine image"
  
  # Use POSTGRES_PASSWORD for Redis if REDIS_PASSWORD not set
  REDIS_PASS="${REDIS_PASSWORD:-${POSTGRES_PASSWORD:-}}"
  
  if [[ -z "${REDIS_PASS}" ]]; then
    log_error "No password provided for Redis"
    log_error "Please set POSTGRES_PASSWORD (preferred) or REDIS_PASSWORD in GitHub secrets"
    exit 1
  fi
  
  # Check if cleanup mode is enabled
  if [ "${ENABLE_CLEANUP}" = "true" ]; then
    log_warning "Cleanup mode: Deleting existing Redis resources..."
    kubectl delete -f "${MANIFESTS_DIR}/redis-statefulset.yaml" --ignore-not-found=true --wait=true --grace-period=0 2>/dev/null || true
    kubectl delete pvc -n "${NAMESPACE}" -l app=redis --wait=true --grace-period=0 2>/dev/null || true
    # Delete any Helm release if it exists
    if command -v helm >/dev/null 2>&1; then
      helm uninstall redis -n "${NAMESPACE}" --wait 2>/dev/null || true
    fi
    sleep 5
  fi
  
  # Ensure Redis secret exists
  if ! kubectl get secret redis -n "${NAMESPACE}" >/dev/null 2>&1; then
    log_info "Creating Redis secret with POSTGRES_PASSWORD..."
    kubectl create secret generic redis \
      -n "${NAMESPACE}" \
      --from-literal=redis-password="${REDIS_PASS}"
    log_success "Redis secret created with GitHub POSTGRES_PASSWORD"
  else
    log_info "Redis secret already exists - reusing"
  fi
  
  # Apply Redis manifests
  log_info "Applying Redis custom manifests..."
  kubectl apply -f "${MANIFESTS_DIR}/redis-statefulset.yaml"
  
  # Wait for Redis to be ready
  log_info "Waiting for Redis to be ready (timeout: 5 minutes)..."
  kubectl wait --for=condition=ready pod/redis-master-0 -n "${NAMESPACE}" --timeout=300s || {
    log_warning "Redis pod not ready after 5 minutes, checking status..."
    kubectl get pod redis-master-0 -n "${NAMESPACE}" || true
    kubectl describe pod redis-master-0 -n "${NAMESPACE}" || true
  }
  
  # Verify Redis is running
  if kubectl get pod redis-master-0 -n "${NAMESPACE}" 2>/dev/null | grep -q "2/2.*Running"; then
    log_success "Redis is ready and healthy"
    log_info "Image: redis:7-alpine"
    log_info "Metrics: oliver006/redis_exporter:v1.62.0-alpine"
    REDIS_DEPLOYED=true
  else
    log_error "Redis deployment may have issues"
    kubectl describe pod redis-master-0 -n "${NAMESPACE}" || true
    REDIS_DEPLOYED=false
  fi
fi  # End of ONLY_COMPONENT=postgres check for Redis

# Display credentials
log_section "Database Credentials"

# Get PostgreSQL password
log_info "PostgreSQL Credentials:"
POSTGRES_PASSWORD=$(kubectl get secret postgresql -n "${NAMESPACE}" -o jsonpath="{.data.postgres-password}" 2>/dev/null | base64 -d || echo "")
ADMIN_PASSWORD=$(kubectl get secret postgresql -n "${NAMESPACE}" -o jsonpath="{.data.admin-user-password}" 2>/dev/null | base64 -d || echo "$POSTGRES_PASSWORD")

if [ -n "$POSTGRES_PASSWORD" ]; then
  echo "  Host: postgresql.${NAMESPACE}.svc.cluster.local"
  echo "  Port: 5432"
  echo "  Database: ${PG_DATABASE} (services create their own databases)"
  echo ""
  echo "  Admin User (admin_user) - for managing per-service databases:"
  echo "    Password: ${ADMIN_PASSWORD}"
  echo "    Connection: postgresql://admin_user:${ADMIN_PASSWORD}@postgresql.${NAMESPACE}.svc.cluster.local:5432/postgres"
  echo ""
  echo "  Postgres Superuser:"
  echo "    Password: $POSTGRES_PASSWORD"
  echo "    Connection: postgresql://postgres:$POSTGRES_PASSWORD@postgresql.${NAMESPACE}.svc.cluster.local:5432/postgres"
else
  log_error "Failed to retrieve PostgreSQL password"
fi

# Get Redis password
log_info "Redis Credentials:"
REDIS_PASSWORD=$(kubectl get secret redis -n "${NAMESPACE}" -o jsonpath="{.data.redis-password}" 2>/dev/null | base64 -d || echo "")
if [ -n "$REDIS_PASSWORD" ]; then
  echo "  Host: redis-master.${NAMESPACE}.svc.cluster.local"
  echo "  Port: 6379"
  echo "  Password: $REDIS_PASSWORD"
  echo ""
  echo "  Connection String (Cache - DB 0):"
  echo "  redis://:$REDIS_PASSWORD@redis-master.${NAMESPACE}.svc.cluster.local:6379/0"
  echo ""
  echo "  Connection String (Celery - DB 1):"
  echo "  redis://:$REDIS_PASSWORD@redis-master.${NAMESPACE}.svc.cluster.local:6379/1"
else
  log_error "Failed to retrieve Redis password"
fi

log_info "Next Steps:"
echo "1. Each service will automatically create its own database during deployment"
echo "2. Services use create-service-database.sh script to create databases"
echo "3. Update service secrets with connection strings pointing to infra namespace"
echo "4. Deploy services via Argo CD - databases will be created automatically"
echo ""
log_success "Done!"
exit 0