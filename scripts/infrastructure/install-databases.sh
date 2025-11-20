#!/bin/bash
set -euo pipefail

# Production-ready Database Installation
# Installs PostgreSQL and Redis with production configurations

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(dirname "$SCRIPT_DIR")/manifests"
source "${SCRIPT_DIR}/../tools/common.sh"

# Configuration
NAMESPACE=${DB_NAMESPACE:-infra}
PG_DATABASE=${PG_DATABASE:-postgres}

log_section "Installing Shared Infrastructure Databases (Production)"
log_info "Namespace: ${NAMESPACE}"
log_info "PostgreSQL Database: ${PG_DATABASE} (services create their own databases)"

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

# FIPS OpenSSL configuration
fips:
  openssl: false

## Primary PostgreSQL configuration
primary:
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
    enabled: false  # Will be enabled conditionally if Prometheus Operator CRDs exist
    namespace: infra
  resources:
    requests:
      memory: "128Mi"
      cpu: "100m"
    limits:
      memory: "256Mi"
      cpu: "200m"

## Network policy
networkPolicy:
  enabled: false
  allowExternal: false
VALUES_EOF

# Update database name if different from default
if [[ "$PG_DATABASE" != "postgres" ]]; then
  sed -i "s|database: \"postgres\"|database: \"${PG_DATABASE}\"|g" "${TEMP_PG_VALUES}" 2>/dev/null || \
    sed -i '' "s|database: \"postgres\"|database: \"${PG_DATABASE}\"|g" "${TEMP_PG_VALUES}" 2>/dev/null || true
fi

# Install or upgrade PostgreSQL (idempotent)
echo -e "${YELLOW}Installing/upgrading PostgreSQL...${NC}"
echo -e "${BLUE}This may take 5-10 minutes...${NC}"

# Build Helm arguments - prioritize environment variables
# Using chart version 16.7.27 (PostgreSQL 17.6.0) - stable production version
# This version is well-tested and doesn't have the FIPS validation bugs from 15.5.26
PG_HELM_ARGS=()

# Set FIPS configuration first (for compatibility)
# Chart version 16.7.27 handles FIPS gracefully, but we set it explicitly
PG_HELM_ARGS+=(--set global.defaultFips=false)
PG_HELM_ARGS+=(--set fips.openssl=false)

# Always use values file for complete configuration (includes FIPS settings as backup)
PG_HELM_ARGS+=(-f "${TEMP_PG_VALUES}")

# Priority 1: Use POSTGRES_PASSWORD from environment (GitHub secrets)
# These --set flags will override values file
if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
  echo -e "${GREEN}Using POSTGRES_PASSWORD from environment/GitHub secrets${NC}"
  echo -e "${BLUE}  - postgres user password: ${#POSTGRES_PASSWORD} chars${NC}"
  PG_HELM_ARGS+=(--set global.postgresql.auth.postgresPassword="$POSTGRES_PASSWORD")
  PG_HELM_ARGS+=(--set global.postgresql.auth.database="$PG_DATABASE")
  
  # Use same password for admin_user (unless explicitly overridden)
  if [[ -z "${POSTGRES_ADMIN_PASSWORD:-}" ]]; then
    echo -e "${BLUE}  - admin_user password: using same as postgres user${NC}"
    PG_HELM_ARGS+=(--set global.postgresql.auth.password="$POSTGRES_PASSWORD")
  fi
fi

# Add admin_user password if explicitly provided (overrides POSTGRES_PASSWORD)
if [[ -n "${POSTGRES_ADMIN_PASSWORD:-}" ]] && [[ "${POSTGRES_ADMIN_PASSWORD}" != "${POSTGRES_PASSWORD}" ]]; then
  echo -e "${GREEN}Using separate POSTGRES_ADMIN_PASSWORD for admin_user (${#POSTGRES_ADMIN_PASSWORD} chars)${NC}"
  PG_HELM_ARGS+=(--set global.postgresql.auth.password="$POSTGRES_ADMIN_PASSWORD")
fi

# Redundant FIPS setting for extra safety
PG_HELM_ARGS+=(--set global.defaultFips=false)
PG_HELM_ARGS+=(--set fips.openssl=false)

set +e
if helm -n "${NAMESPACE}" status postgresql >/dev/null 2>&1; then
  # Check if PostgreSQL is healthy
  IS_HEALTHY=$(kubectl -n "${NAMESPACE}" get statefulset postgresql -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "1" && echo "true" || echo "false")
  
  # If POSTGRES_PASSWORD is explicitly set, check if it matches current secret
  if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
    # Get current password from secret
    CURRENT_PG_PASS=$(kubectl -n "${NAMESPACE}" get secret postgresql -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d || true)
    
    if [[ "$CURRENT_PG_PASS" == "$POSTGRES_PASSWORD" ]]; then
      echo -e "${GREEN}✓ PostgreSQL password unchanged - skipping upgrade${NC}"
      echo -e "${BLUE}Current secret password matches provided POSTGRES_PASSWORD${NC}"
      HELM_PG_EXIT=0
    else
      echo -e "${YELLOW}⚠️  Password mismatch detected${NC}"
      echo -e "${BLUE}Current password length: ${#CURRENT_PG_PASS} chars${NC}"
      echo -e "${BLUE}New password length: ${#POSTGRES_PASSWORD} chars${NC}"
      echo -e "${RED}⚠️  WARNING: Updating passwords requires pod restart and may take time${NC}"
      echo -e "${YELLOW}Checking if PostgreSQL is currently healthy...${NC}"
      
      # Check if PostgreSQL is currently running - if yes, just update the secret without Helm upgrade
      if kubectl get statefulset postgresql -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "1"; then
        echo -e "${GREEN}PostgreSQL is healthy. Updating password via secret...${NC}"
        
        # Update the secret directly
        kubectl create secret generic postgresql \
          --from-literal=postgres-password="$POSTGRES_PASSWORD" \
          --from-literal=password="$POSTGRES_PASSWORD" \
          --from-literal=admin-user-password="$POSTGRES_PASSWORD" \
          -n "${NAMESPACE}" \
          --dry-run=client -o yaml | kubectl apply -f -
        
        echo -e "${GREEN}✓ Password updated in secret. PostgreSQL will use it on next restart.${NC}"
        echo -e "${YELLOW}Note: Password change will take effect on next pod restart${NC}"
        HELM_PG_EXIT=0
      else
        echo -e "${YELLOW}PostgreSQL not healthy. Performing Helm upgrade...${NC}"
        helm upgrade postgresql bitnami/postgresql \
          --version 16.7.27 \
          -n "${NAMESPACE}" \
          --reset-values \
          "${PG_HELM_ARGS[@]}" \
          --timeout=10m \
          --wait=false 2>&1 | tee /tmp/helm-postgresql-install.log
        HELM_PG_EXIT=${PIPESTATUS[0]}
      fi
    fi
  elif [[ "$IS_HEALTHY" == "true" ]]; then
    echo -e "${GREEN}✓ PostgreSQL already installed and healthy - skipping${NC}"
    HELM_PG_EXIT=0
  else
    echo -e "${YELLOW}PostgreSQL exists but not ready; performing safe upgrade${NC}"
    helm upgrade postgresql bitnami/postgresql \
      --version 16.7.27 \
      -n "${NAMESPACE}" \
      --reuse-values \
      --timeout=10m \
      --wait 2>&1 | tee /tmp/helm-postgresql-install.log
    HELM_PG_EXIT=${PIPESTATUS[0]}
  fi
POSTGRES_DEPLOYED=false

else
  echo -e "${YELLOW}PostgreSQL not found; installing fresh${NC}"
  
  # Source common functions for cleanup logic
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "${SCRIPT_DIR}/../tools/common.sh" ]; then
    source "${SCRIPT_DIR}/../tools/common.sh"
  fi
  
  # Only clean up orphaned resources if cleanup mode is active
  if is_cleanup_mode; then
    echo -e "${BLUE}Cleanup mode active - checking for orphaned PostgreSQL resources...${NC}"
    
    # Check for StatefulSets first (these recreate resources)
    STATEFULSETS=$(kubectl get statefulset -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql -o name 2>/dev/null || true)
    if [ -n "$STATEFULSETS" ]; then
      echo -e "${YELLOW}Found PostgreSQL StatefulSet - deleting (cleanup mode)...${NC}"
      kubectl delete statefulset -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql --wait=true --grace-period=0 --force 2>/dev/null || true
    fi
    
    # Check for failed/pending Helm release
    if helm -n "${NAMESPACE}" list -q | grep -q "^postgresql$" 2>/dev/null; then
      echo -e "${YELLOW}Found existing Helm release - uninstalling (cleanup mode)...${NC}"
      helm uninstall postgresql -n "${NAMESPACE}" --wait 2>/dev/null || true
      sleep 5
    fi
    
    # Clean up orphaned resources
    ORPHANED_RESOURCES=$(kubectl get networkpolicy,configmap,service -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql 2>/dev/null | grep -v NAME || true)
    if [ -n "$ORPHANED_RESOURCES" ]; then
      echo -e "${YELLOW}Cleaning up orphaned resources (cleanup mode)...${NC}"
      kubectl delete pod,statefulset,service,networkpolicy,configmap -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql --wait=true --grace-period=0 --force 2>/dev/null || true
      sleep 10
    fi
    
    # Final NetworkPolicy check
    FINAL_NP_CHECK=$(kubectl get networkpolicy postgresql -n "${NAMESPACE}" -o name 2>/dev/null || true)
    if [ -n "$FINAL_NP_CHECK" ]; then
      kubectl patch networkpolicy postgresql -n "${NAMESPACE}" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
      kubectl delete networkpolicy postgresql -n "${NAMESPACE}" --wait=true --grace-period=0 2>/dev/null || true
      sleep 5
    fi
  else
    echo -e "${BLUE}Cleanup mode inactive - checking for existing resources to update...${NC}"
    # If resources exist but Helm release doesn't, try to upgrade anyway (Helm will handle it)
    if kubectl get statefulset postgresql -n "${NAMESPACE}" >/dev/null 2>&1; then
      echo -e "${YELLOW}PostgreSQL StatefulSet exists but Helm release missing - attempting upgrade...${NC}"
      helm upgrade postgresql bitnami/postgresql \
        --version 16.7.27 \
        -n "${NAMESPACE}" \
        "${PG_HELM_ARGS[@]}" \
        --timeout=10m \
        --wait 2>&1 | tee /tmp/helm-postgresql-install.log
      HELM_PG_EXIT=${PIPESTATUS[0]}
      set -e
      if [ $HELM_PG_EXIT -eq 0 ]; then
        echo -e "${GREEN}✓ PostgreSQL upgraded${NC}"
        POSTGRES_DEPLOYED=true
      else
        echo -e "${YELLOW}PostgreSQL upgrade failed (release missing). Falling back to fresh install...${NC}"
        POSTGRES_DEPLOYED=false
        HELM_PG_EXIT=1
      fi
    fi
  fi
  
  # Install PostgreSQL if cleanup mode or no existing resources
  if [ "${POSTGRES_DEPLOYED:-false}" != "true" ]; then
    echo -e "${BLUE}Installing PostgreSQL...${NC}"
    helm install postgresql bitnami/postgresql \
      --version 16.7.27 \
      -n "${NAMESPACE}" \
      "${PG_HELM_ARGS[@]}" \
      --timeout=10m \
      --wait 2>&1 | tee /tmp/helm-postgresql-install.log
    HELM_PG_EXIT=${PIPESTATUS[0]}
    if [ $HELM_PG_EXIT -eq 0 ]; then
      POSTGRES_DEPLOYED=true
    fi
  fi
fi
set -e

if [ $HELM_PG_EXIT -eq 0 ]; then
  echo -e "${GREEN}✓ PostgreSQL ready${NC}"
else
  echo -e "${YELLOW}PostgreSQL Helm operation reported exit code $HELM_PG_EXIT${NC}"
  echo -e "${YELLOW}Checking actual PostgreSQL status...${NC}"
  
  # Wait a bit for pods to update
  sleep 10
  
  # Check if PostgreSQL StatefulSet exists and has ready replicas
  PG_READY=$(kubectl get statefulset postgresql -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  PG_REPLICAS=$(kubectl get statefulset postgresql -n "${NAMESPACE}" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
  
  echo -e "${BLUE}PostgreSQL StatefulSet: ${PG_READY}/${PG_REPLICAS} replicas ready${NC}"
  
  if [ "$PG_READY" -ge 1 ]; then
    echo -e "${GREEN}✓ PostgreSQL is actually running! Continuing...${NC}"
    echo -e "${YELLOW}Note: Helm reported a timeout, but PostgreSQL is healthy${NC}"
  else
    echo -e "${RED}PostgreSQL installation/upgrade failed${NC}"
    echo -e "${YELLOW}=== Helm output (last 50 lines) ===${NC}"
    tail -50 /tmp/helm-postgresql-install.log 2>/dev/null || true
    echo -e "${YELLOW}=== Pod status ===${NC}"
    kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql 2>/dev/null || true
    echo -e "${YELLOW}=== Pod events ===${NC}"
    kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' 2>/dev/null | grep -i postgresql | tail -10 || true
    echo -e "${YELLOW}=== PVC status ===${NC}"
    kubectl get pvc -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql 2>/dev/null || true
    
    # Check for common issues
    echo -e "${YELLOW}=== Diagnosing issues ===${NC}"
    PENDING_PVCS=$(kubectl get pvc -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
    if [ "$PENDING_PVCS" -gt 0 ]; then
      echo -e "${RED}⚠️  Found ${PENDING_PVCS} Pending PVCs - storage may not be available${NC}"
    fi
    
    exit 1
  fi
fi

# Install or upgrade Redis (idempotent)
echo -e "${YELLOW}Installing/upgrading Redis...${NC}"
echo -e "${BLUE}This may take 3-5 minutes...${NC}"

# Build Helm arguments - prioritize environment variables
REDIS_HELM_ARGS=()

# Priority 1: Use REDIS_PASSWORD from environment (GitHub secrets)
if [[ -n "${REDIS_PASSWORD:-}" ]]; then
  echo -e "${GREEN}Using REDIS_PASSWORD from environment/GitHub secrets (priority)${NC}"
  REDIS_HELM_ARGS+=(--set global.redis.password="$REDIS_PASSWORD")
# Priority 2: Use values file (for fresh installs without env var)
else
  echo -e "${YELLOW}No REDIS_PASSWORD in environment; using values file or auto-generated${NC}"
  REDIS_HELM_ARGS+=(-f "${MANIFESTS_DIR}/databases/redis-values.yaml")
fi

set +e
if helm -n "${NAMESPACE}" status redis >/dev/null 2>&1; then
  # Check if Redis is healthy
  IS_REDIS_HEALTHY=$(kubectl -n "${NAMESPACE}" get statefulset redis-master -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "1" && echo "true" || echo "false")
  
  # If REDIS_PASSWORD is explicitly set, check if it matches current secret
  if [[ -n "${REDIS_PASSWORD:-}" ]]; then
    # Get current password from secret
    CURRENT_REDIS_PASS=$(kubectl -n "${NAMESPACE}" get secret redis -o jsonpath='{.data.redis-password}' 2>/dev/null | base64 -d || true)
    
    if [[ "$CURRENT_REDIS_PASS" == "$REDIS_PASSWORD" ]]; then
      echo -e "${GREEN}✓ Redis password unchanged - skipping upgrade${NC}"
      echo -e "${BLUE}Current secret password matches provided REDIS_PASSWORD${NC}"
      HELM_REDIS_EXIT=0
    else
      echo -e "${YELLOW}Password mismatch detected - updating Redis to sync password${NC}"
      echo -e "${BLUE}Current password length: ${#CURRENT_REDIS_PASS} chars${NC}"
      echo -e "${BLUE}New password length: ${#REDIS_PASSWORD} chars${NC}"
      helm upgrade redis bitnami/redis \
        -n "${NAMESPACE}" \
        --reset-values \
        -f "${MANIFESTS_DIR}/databases/redis-values.yaml" \
        "${REDIS_HELM_ARGS[@]}" \
        --timeout=10m \
        --wait 2>&1 | tee /tmp/helm-redis-install.log
      HELM_REDIS_EXIT=${PIPESTATUS[0]}
    fi
  elif [[ "$IS_REDIS_HEALTHY" == "true" ]]; then
    echo -e "${GREEN}✓ Redis already installed and healthy - skipping${NC}"
    HELM_REDIS_EXIT=0
  else
    echo -e "${YELLOW}Redis exists but not ready; performing safe upgrade${NC}"
    helm upgrade redis bitnami/redis \
      -n "${NAMESPACE}" \
      --reuse-values \
      --timeout=10m \
      --wait 2>&1 | tee /tmp/helm-redis-install.log
    HELM_REDIS_EXIT=${PIPESTATUS[0]}
  fi
else
  echo -e "${YELLOW}Redis not found; installing fresh${NC}"
  helm install redis bitnami/redis \
    -n "${NAMESPACE}" \
    "${REDIS_HELM_ARGS[@]}" \
    --timeout=10m \
    --wait 2>&1 | tee /tmp/helm-redis-install.log
  HELM_REDIS_EXIT=${PIPESTATUS[0]}
fi
set -e

if [ $HELM_REDIS_EXIT -eq 0 ]; then
  echo -e "${GREEN}✓ Redis ready${NC}"
else
  echo -e "${RED}Redis installation failed with exit code $HELM_REDIS_EXIT${NC}"
  tail -50 /tmp/helm-redis-install.log || true
  kubectl get pods -n "${NAMESPACE}" || true
  exit 1
fi

# Retrieve credentials
echo ""
echo -e "${GREEN}=== Database Installation Complete ===${NC}"
echo ""
echo -e "${YELLOW}Retrieving credentials...${NC}"

# Get PostgreSQL passwords
echo ""
echo -e "${BLUE}PostgreSQL Credentials:${NC}"
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
  echo -e "${RED}  Failed to retrieve PostgreSQL password${NC}"
fi

# Get Redis password
echo ""
echo -e "${BLUE}Redis Credentials:${NC}"
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
  echo -e "${RED}  Failed to retrieve Redis password${NC}"
fi

echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Each service will automatically create its own database during deployment"
echo "2. Services use create-service-database.sh script to create databases"
echo "3. Update service secrets with connection strings pointing to infra namespace"
echo "4. Deploy services via Argo CD - databases will be created automatically"
echo ""
echo -e "${GREEN}Done!${NC}"
