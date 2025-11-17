#!/bin/bash
set -euo pipefail

# Production-ready Database Installation
# Installs PostgreSQL and Redis with production configurations

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
NAMESPACE=${DB_NAMESPACE:-infra}
PG_DATABASE=${PG_DATABASE:-postgres}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(dirname "$SCRIPT_DIR")/manifests"

echo -e "${GREEN}Installing Shared Infrastructure Databases (Production)...${NC}"
echo -e "${BLUE}Namespace: ${NAMESPACE}${NC}"
echo -e "${BLUE}PostgreSQL Database: ${PG_DATABASE} (services create their own databases)${NC}"

# Pre-flight checks
if ! command -v kubectl &> /dev/null; then
  echo -e "${RED}kubectl command not found. Aborting.${NC}"
  exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo -e "${RED}Cannot connect to cluster. Ensure KUBECONFIG is set. Aborting.${NC}"
  exit 1
fi

echo -e "${GREEN}✓ kubectl configured and cluster reachable${NC}"

# Check for storage class (required for PVCs)
if ! kubectl get storageclass 2>/dev/null | grep -q "(default)"; then
  echo -e "${YELLOW}No default storage class found. Installing local-path provisioner...${NC}"
  "${SCRIPT_DIR}/install-storage-provisioner.sh"
else
  echo -e "${GREEN}✓ Default storage class available${NC}"
fi

# Check for Helm (install if missing)
if ! command -v helm &> /dev/null; then
  echo -e "${YELLOW}Helm not found. Installing via snap...${NC}"
  if command -v snap &> /dev/null; then
    sudo snap install helm --classic
  else
    echo -e "${YELLOW}snap not available. Installing Helm via script...${NC}"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
  echo -e "${GREEN}✓ Helm installed${NC}"
else
  echo -e "${GREEN}✓ Helm already installed${NC}"
fi

# Add Bitnami repository
echo -e "${YELLOW}Adding Bitnami Helm repository...${NC}"
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm repo update

# Create namespace
if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo -e "${GREEN}✓ Namespace '${NAMESPACE}' already exists${NC}"
else
  echo -e "${YELLOW}Creating namespace '${NAMESPACE}'...${NC}"
  kubectl create namespace "${NAMESPACE}"
  echo -e "${GREEN}✓ Namespace '${NAMESPACE}' created${NC}"
fi

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
    enabled: true
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
  echo -e "${GREEN}Using POSTGRES_PASSWORD from environment/GitHub secrets (priority)${NC}"
  PG_HELM_ARGS+=(--set global.postgresql.auth.postgresPassword="$POSTGRES_PASSWORD")
  PG_HELM_ARGS+=(--set global.postgresql.auth.database="$PG_DATABASE")
fi

# Add admin_user password if provided
if [[ -n "${POSTGRES_ADMIN_PASSWORD:-}" ]]; then
  echo -e "${GREEN}Using POSTGRES_ADMIN_PASSWORD for admin_user${NC}"
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
      echo -e "${YELLOW}Password mismatch detected - updating PostgreSQL to sync password${NC}"
      echo -e "${BLUE}Current password length: ${#CURRENT_PG_PASS} chars${NC}"
      echo -e "${BLUE}New password length: ${#POSTGRES_PASSWORD} chars${NC}"
      helm upgrade postgresql bitnami/postgresql \
        --version 16.7.27 \
        -n "${NAMESPACE}" \
        --reset-values \
        "${PG_HELM_ARGS[@]}" \
        --timeout=10m \
        --wait 2>&1 | tee /tmp/helm-postgresql-install.log
      HELM_PG_EXIT=${PIPESTATUS[0]}
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
else
  echo -e "${YELLOW}PostgreSQL not found; installing fresh${NC}"
  
  # Check for ANY existing PostgreSQL resources (including StatefulSets that might recreate resources)
  echo -e "${BLUE}Checking for any existing PostgreSQL resources...${NC}"
  
  # Check for StatefulSets first (these recreate resources)
  STATEFULSETS=$(kubectl get statefulset -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql -o name 2>/dev/null || true)
  if [ -n "$STATEFULSETS" ]; then
    echo -e "${YELLOW}Found PostgreSQL StatefulSet (this recreates resources):${NC}"
    echo "$STATEFULSETS"
    echo -e "${YELLOW}Deleting StatefulSet first to stop resource recreation...${NC}"
    kubectl delete statefulset -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql --wait=true --grace-period=0 --force 2>/dev/null || true
    echo -e "${GREEN}✓ StatefulSet deleted${NC}"
  fi
  
  # Check for failed/pending Helm release (check more thoroughly)
  if helm -n "${NAMESPACE}" list -q | grep -q "^postgresql$" 2>/dev/null; then
    HELM_RELEASE_STATUS=$(helm -n "${NAMESPACE}" status postgresql -o json 2>/dev/null | grep -o '"status":"[^"]*"' || echo "unknown")
    echo -e "${YELLOW}Found existing Helm release: ${HELM_RELEASE_STATUS}${NC}"
    echo -e "${YELLOW}Uninstalling existing Helm release...${NC}"
    helm uninstall postgresql -n "${NAMESPACE}" --wait 2>/dev/null || true
    echo -e "${GREEN}✓ Helm release uninstalled${NC}"
    sleep 5
  fi
  
  # Also check for any Helm secrets (these can cause issues)
  HELM_SECRETS=$(kubectl get secret -n "${NAMESPACE}" -l owner=helm,name=postgresql -o name 2>/dev/null || true)
  if [ -n "$HELM_SECRETS" ]; then
    echo -e "${YELLOW}Found Helm release secrets, deleting...${NC}"
    kubectl delete secret -n "${NAMESPACE}" -l owner=helm,name=postgresql --wait=true 2>/dev/null || true
    sleep 2
  fi
  
  # Check for orphaned resources from previous installations
  echo -e "${BLUE}Checking for remaining orphaned PostgreSQL resources...${NC}"
  ORPHANED_RESOURCES=$(kubectl get networkpolicy,configmap,service,secret -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql 2>/dev/null | grep -v NAME || true)
  
  if [ -n "$ORPHANED_RESOURCES" ]; then
    echo -e "${YELLOW}Found remaining orphaned PostgreSQL resources:${NC}"
    echo "$ORPHANED_RESOURCES"
    echo -e "${YELLOW}Cleaning up orphaned resources to allow fresh installation...${NC}"
    
    # Delete all orphaned resources in the correct order
    # 1. StatefulSets (if any remain)
    kubectl delete statefulset -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql --grace-period=0 --force 2>/dev/null || true
    
    # 2. Pods (force delete to avoid waiting for graceful shutdown)
    kubectl delete pod -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql --grace-period=0 --force 2>/dev/null || true
    
    # 3. Services
    kubectl delete service -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql --wait=true 2>/dev/null || true
    
    # 4. NetworkPolicy (check for finalizers first)
    NETWORKPOLICIES=$(kubectl get networkpolicy -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql -o name 2>/dev/null || true)
    if [ -n "$NETWORKPOLICIES" ]; then
      for np in $NETWORKPOLICIES; do
        # Remove finalizers if present
        kubectl patch "$np" -n "${NAMESPACE}" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
      done
      kubectl delete networkpolicy -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql --wait=true 2>/dev/null || true
    fi
    
    # 5. ConfigMaps
    kubectl delete configmap -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql --wait=true 2>/dev/null || true
    
    # Wait for resources to be fully deleted
    echo -e "${BLUE}Waiting for resources to be fully deleted...${NC}"
    sleep 10
    
    # Verify deletion
    REMAINING=$(kubectl get statefulset,pod,networkpolicy,configmap,service -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql 2>/dev/null | grep -v NAME || true)
    if [ -n "$REMAINING" ]; then
      echo -e "${RED}ERROR: Resources still exist after cleanup:${NC}"
      echo "$REMAINING"
      echo -e "${RED}Manual cleanup may be required. Aborting.${NC}"
      exit 1
    fi
    
    # Keep secrets as they contain passwords we might want to preserve
    echo -e "${BLUE}Note: Keeping existing secrets to preserve credentials${NC}"
    
    echo -e "${GREEN}✓ All orphaned resources cleaned up${NC}"
  else
    echo -e "${GREEN}✓ No orphaned resources found${NC}"
  fi
  
  # Final verification - check NetworkPolicy specifically right before install
  FINAL_NP_CHECK=$(kubectl get networkpolicy postgresql -n "${NAMESPACE}" -o name 2>/dev/null || true)
  if [ -n "$FINAL_NP_CHECK" ]; then
    echo -e "${RED}ERROR: NetworkPolicy 'postgresql' still exists right before Helm install!${NC}"
    echo -e "${YELLOW}Attempting final cleanup...${NC}"
    kubectl patch networkpolicy postgresql -n "${NAMESPACE}" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    kubectl delete networkpolicy postgresql -n "${NAMESPACE}" --wait=true --grace-period=0 2>/dev/null || true
    sleep 5
    
    # Verify it's gone
    FINAL_NP_CHECK2=$(kubectl get networkpolicy postgresql -n "${NAMESPACE}" -o name 2>/dev/null || true)
    if [ -n "$FINAL_NP_CHECK2" ]; then
      echo -e "${RED}ERROR: NetworkPolicy still exists after final cleanup. Manual intervention required.${NC}"
      echo -e "${YELLOW}Run: kubectl delete networkpolicy postgresql -n ${NAMESPACE} --force --grace-period=0${NC}"
      exit 1
    fi
  fi
  
  echo -e "${BLUE}Helm command will be: helm install postgresql bitnami/postgresql -n ${NAMESPACE} ${PG_HELM_ARGS[*]}${NC}"
  
  helm install postgresql bitnami/postgresql \
    --version 16.7.27 \
    -n "${NAMESPACE}" \
    "${PG_HELM_ARGS[@]}" \
    --timeout=10m \
    --wait 2>&1 | tee /tmp/helm-postgresql-install.log
  HELM_PG_EXIT=${PIPESTATUS[0]}
fi
set -e

if [ $HELM_PG_EXIT -eq 0 ]; then
  echo -e "${GREEN}✓ PostgreSQL ready${NC}"
else
  echo -e "${RED}PostgreSQL installation/upgrade failed with exit code $HELM_PG_EXIT${NC}"
  tail -50 /tmp/helm-postgresql-install.log || true
  kubectl get pods -n "${NAMESPACE}" || true
  exit 1
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
