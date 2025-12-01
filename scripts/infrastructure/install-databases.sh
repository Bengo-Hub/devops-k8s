#!/usr/bin/env bash
set -euo pipefail

# Production-ready Database Installation
# Installs PostgreSQL and Redis with production configurations

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# MANIFESTS_DIR is at repo root, not under scripts
MANIFESTS_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/manifests"
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
# Enable cleanup mode by default (deletes existing resources for fresh install)
# WARNING: This will delete all existing database data and PVCs
ENABLE_CLEANUP=${ENABLE_CLEANUP:-true}

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

# Create temporary PostgreSQL values file with proper FIPS configuration
TEMP_PG_VALUES=/tmp/postgresql-values-prod.yaml
cat > "${TEMP_PG_VALUES}" <<'VALUES_EOF'
## Global settings
global:
  postgresql:
    auth:
      postgresPassword: "" # Leave empty, will be auto-generated
      username: "admin_user"
      password: ""         # Leave empty, will be auto-generated
      database: "postgres"
  # FIPS compliance settings (required for newer chart versions)
  defaultFips: false
  # Allow custom images (required for codevertex/postgresql-pgvector)
  security:
    allowInsecureImages: true

# FIPS OpenSSL configuration
fips:
  openssl: false

## Primary PostgreSQL configuration
primary:
  ## Custom PostgreSQL image with pgvector extension
  ## Uses custom image built via GitHub Actions workflow
  image:
    registry: docker.io
    repository: codevertex/postgresql-pgvector
    tag: POSTGRES_IMAGE_TAG_PLACEHOLDER
    pullPolicy: IfNotPresent
  
  ## Enable pgvector extension initialization scripts
  initdb:
    scripts:
      create-admin-user.sql: |
        -- Ensure admin_user has superuser privileges for managing all service databases
        -- The user is created by the chart's auth.username setting, but we ensure proper privileges
        DO $$
        BEGIN
          IF EXISTS (SELECT FROM pg_user WHERE usename = 'admin_user') THEN
            ALTER USER admin_user WITH SUPERUSER CREATEDB;
          END IF;
        END
        $$;
      enable-pgvector.sql: |
        -- Enable pgvector extension in postgres database
        -- Services can enable it in their own databases during initialization
        CREATE EXTENSION IF NOT EXISTS vector;
        
        -- Grant usage on vector extension to admin_user
        GRANT USAGE ON SCHEMA public TO admin_user;
  
  resources:
    requests:
      memory: "512Mi"
      cpu: "250m"
    limits:
      memory: "2Gi"
      cpu: "1000m"
  priorityClassName: db-critical
  
  persistence:
    enabled: true
    size: 20Gi
    storageClass: ""
  
  ## PostgreSQL tuning
  extendedConfiguration: |
    max_connections = 200
    shared_buffers = 512MB
    effective_cache_size = 1536MB
    work_mem = 2621kB
    maintenance_work_mem = 128MB
    checkpoint_completion_target = 0.9
    wal_buffers = 16MB
    default_statistics_target = 100
    random_page_cost = 1.1
    effective_io_concurrency = 200
    min_wal_size = 1GB
    max_wal_size = 4GB
  
  ## Health checks
  livenessProbe:
    enabled: true
    initialDelaySeconds: 30
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 6
  
  readinessProbe:
    enabled: true
    initialDelaySeconds: 5
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 6

## Metrics for Prometheus
metrics:
  enabled: true
  serviceMonitor:
    enabled: false  # Disabled by default - will be enabled if Prometheus Operator CRDs exist
    namespace: infra
  resources:
    requests:
      memory: "128Mi"
      cpu: "100m"
    limits:
      memory: "256Mi"
      cpu: "200m"
  # Leave image config to use chart defaults

## Network policy
networkPolicy:
  enabled: true
  allowExternal: false
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: "*"
      ports:
        - port: 5432
          protocol: TCP
VALUES_EOF

# Update database name if different from default
if [[ "$PG_DATABASE" != "postgres" ]]; then
  sed -i "s|database: \"postgres\"|database: \"${PG_DATABASE}\"|g" "${TEMP_PG_VALUES}" 2>/dev/null || \
    sed -i '' "s|database: \"postgres\"|database: \"${PG_DATABASE}\"|g" "${TEMP_PG_VALUES}" 2>/dev/null || true
fi

# Update image tag (default to latest if not set)
POSTGRES_IMAGE_TAG=${POSTGRES_IMAGE_TAG:-latest}
sed -i "s|tag: POSTGRES_IMAGE_TAG_PLACEHOLDER|tag: ${POSTGRES_IMAGE_TAG}|g" "${TEMP_PG_VALUES}" 2>/dev/null || \
  sed -i '' "s|tag: POSTGRES_IMAGE_TAG_PLACEHOLDER|tag: ${POSTGRES_IMAGE_TAG}|g" "${TEMP_PG_VALUES}" 2>/dev/null || true

# Build PostgreSQL Helm arguments
PG_HELM_ARGS=()
PG_HELM_ARGS+=(-f "${TEMP_PG_VALUES}")

# Check if Prometheus Operator CRDs exist (for ServiceMonitor)
if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
  log_info "Prometheus Operator CRDs detected - ServiceMonitor will be enabled"
  PG_HELM_ARGS+=(--set metrics.serviceMonitor.enabled=true --set metrics.serviceMonitor.namespace="${MONITORING_NS}")
else
  log_info "Prometheus Operator CRDs not found - ServiceMonitor disabled (will be enabled after monitoring stack installation)"
  log_info "To enable ServiceMonitor later, run: helm upgrade postgresql bitnami/postgresql -n ${NAMESPACE} --set metrics.serviceMonitor.enabled=true --reuse-values"
fi

# Install or upgrade PostgreSQL
set +e
if helm -n "${NAMESPACE}" status postgresql >/dev/null 2>&1; then
  # PostgreSQL Helm release exists - handle upgrade or skip
  handle_existing_database "postgresql" "postgresql" "${NAMESPACE}" "bitnami/postgresql" "16.7.27" "PG_HELM_ARGS" "POSTGRES_PASSWORD" "${FORCE_DB_INSTALL:-false}"
  HELM_PG_EXIT=$HELM_EXIT_CODE
  if [[ $HELM_PG_EXIT -eq 0 ]]; then
    POSTGRES_DEPLOYED=true
  fi
else
  # PostgreSQL not found - install fresh
  handle_fresh_database_install "postgresql" "postgresql" "${NAMESPACE}" "bitnami/postgresql" "16.7.27" "PG_HELM_ARGS" "$(is_cleanup_mode && echo true || echo false)"
  HELM_PG_EXIT=$HELM_EXIT_CODE
  if [[ $HELM_PG_EXIT -eq 0 ]]; then
    POSTGRES_DEPLOYED=true
  fi
fi
set -e

# Verify PostgreSQL installation
if [[ $HELM_PG_EXIT -eq 0 ]]; then
  log_success "PostgreSQL ready"
else
  if ! verify_database_installation "postgresql" "postgresql" "${NAMESPACE}"; then
    exit 1
  fi
fi

REDIS_HELM_ARGS=()

# Always use values file as base
REDIS_HELM_ARGS+=(-f "${MANIFESTS_DIR}/databases/redis-values.yaml")

# Check if ServiceMonitor CRD exists (Prometheus Operator)
if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
  log_info "ServiceMonitor enabled for Redis metrics (namespace: ${MONITORING_NS})"
  REDIS_HELM_ARGS+=(--set metrics.serviceMonitor.enabled=true --set metrics.serviceMonitor.namespace="${MONITORING_NS}")
else
  log_info "ServiceMonitor CRD not found - disabling Redis metrics ServiceMonitor"
  REDIS_HELM_ARGS+=(--set metrics.serviceMonitor.enabled=false)
fi

# Set Redis password via Helm args (required by Bitnami chart)
if [[ -n "${REDIS_PASSWORD:-}" ]]; then
  REDIS_HELM_ARGS+=(--set global.redis.password="${REDIS_PASSWORD}")
  log_info "Redis password configured via Helm values"
fi

# Shared password policy:
# - POSTGRES_PASSWORD (GitHub secret) is the canonical infra password
# - Redis reuses the same password unless explicitly overridden (and we strongly recommend keeping them identical)
if [[ -z "${REDIS_PASSWORD:-}" ]]; then
  if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
    REDIS_PASSWORD="$POSTGRES_PASSWORD"
    log_info "REDIS_PASSWORD not set - reusing POSTGRES_PASSWORD for Redis (shared infra password)"
  else
    log_error "REDIS_PASSWORD is required but not set, and POSTGRES_PASSWORD is also empty"
    log_error "Please set POSTGRES_PASSWORD (preferred) or REDIS_PASSWORD in GitHub organization secrets"
  exit 1
  fi
fi
# Install or upgrade Redis
set +e
if helm -n "${NAMESPACE}" status redis >/dev/null 2>&1; then
  # Redis Helm release exists - ensure password matches GitHub secrets
  if [[ -n "${REDIS_PASSWORD:-}" ]]; then
    CURRENT_REDIS_PASS=$(get_secret_password "redis" "redis-password" "${NAMESPACE}")
    
    # Always update secret to match GitHub secrets (source of truth)
    if [[ "$CURRENT_REDIS_PASS" != "$REDIS_PASSWORD" ]]; then
      log_warning "Updating Redis secret to match GitHub secrets password..."
      kubectl create secret generic redis \
        --from-literal=redis-password="$REDIS_PASSWORD" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
      log_success "Redis secret updated to match GitHub secrets password"
    fi
  fi
  
  # Handle upgrade or skip
  handle_existing_database "redis" "redis-master" "${NAMESPACE}" "bitnami/redis" "" "REDIS_HELM_ARGS" "REDIS_PASSWORD" "${FORCE_DB_INSTALL:-false}"
  HELM_REDIS_EXIT=$HELM_EXIT_CODE
else
  # Redis not found - install fresh
  handle_fresh_database_install "redis" "redis-master" "${NAMESPACE}" "bitnami/redis" "" "REDIS_HELM_ARGS" "$(is_cleanup_mode && echo true || echo false)"
  HELM_REDIS_EXIT=$HELM_EXIT_CODE
fi
set -e

# Verify Redis installation
if [[ $HELM_REDIS_EXIT -eq 0 ]]; then
  log_success "Redis Helm operation completed"
  # Check if Redis is actually ready
  REDIS_READY=$(kubectl get statefulset redis-master -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [[ "$REDIS_READY" =~ ^[0-9]+$ ]] && [ "$REDIS_READY" -ge 1 ]; then
    log_success "Redis is ready"
  else
    log_info "Redis installation initiated. Pods will start in background."
  fi
else
  if ! verify_database_installation "redis" "redis-master" "${NAMESPACE}"; then
    exit 1
  fi
fi

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