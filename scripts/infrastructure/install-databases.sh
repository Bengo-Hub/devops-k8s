#!/bin/bash
set -euo pipefail

# Production-ready Database Installation
# Installs PostgreSQL and Redis with production configurations

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# MANIFESTS_DIR is at repo root, not under scripts
MANIFESTS_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/manifests"
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
    enabled: false  # Disabled by default - will be enabled if Prometheus Operator CRDs exist
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

# Check if Prometheus Operator CRDs exist (for ServiceMonitor)
PROMETHEUS_OPERATOR_CRDS_EXIST=false
if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    PROMETHEUS_OPERATOR_CRDS_EXIST=true
    log_info "Prometheus Operator CRDs detected - ServiceMonitor will be enabled"
else
    log_info "Prometheus Operator CRDs not found - ServiceMonitor disabled (will be enabled after monitoring stack installation)"
    log_info "To enable ServiceMonitor later, run: helm upgrade postgresql bitnami/postgresql -n ${NAMESPACE} --set metrics.serviceMonitor.enabled=true --reuse-values"
fi

# Ensure PriorityClass exists (required by PostgreSQL)
log_info "Ensuring PriorityClass db-critical exists..."
if ! kubectl get priorityclass db-critical >/dev/null 2>&1; then
  log_info "Creating PriorityClass db-critical..."
  kubectl apply -f "${MANIFESTS_DIR}/priorityclasses/db-critical.yaml" || {
    log_warning "Failed to apply PriorityClass. Creating inline..."
    kubectl create priorityclass db-critical \
      --value=1000000000 \
      --description="High priority for critical data services (PostgreSQL/Redis/RabbitMQ)" \
      --dry-run=client -o yaml | kubectl apply -f -
  }
  log_success "PriorityClass db-critical created"
else
  log_success "PriorityClass db-critical already exists"
fi

# Check for stuck Helm operations before proceeding
log_info "Checking for stuck Helm operations..."
HELM_STATUS=$(helm -n "${NAMESPACE}" status postgresql 2>/dev/null | grep "STATUS:" | awk '{print $2}' || echo "")
if [[ "$HELM_STATUS" == "pending-upgrade" || "$HELM_STATUS" == "pending-install" || "$HELM_STATUS" == "pending-rollback" ]]; then
  log_warning "Detected stuck Helm operation (status: $HELM_STATUS). Cleaning up..."
  
  # Delete pending Helm secrets
  kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-upgrade,name=postgresql" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
  kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-install,name=postgresql" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
  kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-rollback,name=postgresql" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
  
  log_success "Helm lock removed"
  sleep 5
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

# Enable ServiceMonitor only if Prometheus Operator CRDs exist
if [ "$PROMETHEUS_OPERATOR_CRDS_EXIST" = true ]; then
    PG_HELM_ARGS+=(--set metrics.serviceMonitor.enabled=true)
    log_info "ServiceMonitor enabled for PostgreSQL metrics"
else
    PG_HELM_ARGS+=(--set metrics.serviceMonitor.enabled=false)
    log_info "ServiceMonitor disabled (Prometheus Operator not installed yet)"
fi

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
        POSTGRES_DEPLOYED=true
      else
        echo -e "${YELLOW}PostgreSQL not healthy. Checking for stuck Helm operation...${NC}"
        
        # Check for stuck Helm operation before upgrading
        HELM_STATUS=$(helm -n "${NAMESPACE}" status postgresql 2>/dev/null | grep "STATUS:" | awk '{print $2}' || echo "")
        if [[ "$HELM_STATUS" == "pending-upgrade" || "$HELM_STATUS" == "pending-install" || "$HELM_STATUS" == "pending-rollback" ]]; then
          echo -e "${YELLOW}⚠️  Stuck Helm operation detected (status: $HELM_STATUS). Cleaning up...${NC}"
          
          # Delete pending Helm secrets
          kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-upgrade,name=postgresql" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
          kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-install,name=postgresql" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
          kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-rollback,name=postgresql" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
          
          echo -e "${GREEN}✓ Helm lock removed. Proceeding with upgrade...${NC}"
          sleep 5
        fi
        
        echo -e "${YELLOW}Performing Helm upgrade...${NC}"
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
    POSTGRES_DEPLOYED=true
  else
    echo -e "${YELLOW}PostgreSQL exists but not ready; checking for stuck operation...${NC}"
    
    # Check for stuck Helm operation
    HELM_STATUS=$(helm -n "${NAMESPACE}" status postgresql 2>/dev/null | grep "STATUS:" | awk '{print $2}' || echo "")
    if [[ "$HELM_STATUS" == "pending-upgrade" || "$HELM_STATUS" == "pending-install" || "$HELM_STATUS" == "pending-rollback" ]]; then
      echo -e "${YELLOW}⚠️  Stuck Helm operation detected (status: $HELM_STATUS). Cleaning up...${NC}"
      
      # Delete pending Helm secrets
      kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-upgrade,name=postgresql" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
      kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-install,name=postgresql" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
      kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-rollback,name=postgresql" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
      
      echo -e "${GREEN}✓ Helm lock removed${NC}"
      sleep 5
    fi
    
    echo -e "${YELLOW}Performing safe upgrade...${NC}"
    helm upgrade postgresql bitnami/postgresql \
      --version 16.7.27 \
      -n "${NAMESPACE}" \
      --reuse-values \
      --timeout=10m \
      --wait 2>&1 | tee /tmp/helm-postgresql-install.log
    HELM_PG_EXIT=${PIPESTATUS[0]}
    POSTGRES_DEPLOYED=true
  fi
  
  # POSTGRES_DEPLOYED is set to true above if already installed/healthy
  # If not set, it means we need to install (will be checked below)

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
      echo -e "${YELLOW}Found existing Helm release - checking for stuck operation...${NC}"
      
      # Check for stuck Helm operation before uninstalling
      HELM_STATUS=$(helm -n "${NAMESPACE}" status postgresql 2>/dev/null | grep "STATUS:" | awk '{print $2}' || echo "")
      if [[ "$HELM_STATUS" == "pending-upgrade" || "$HELM_STATUS" == "pending-install" || "$HELM_STATUS" == "pending-rollback" ]]; then
        echo -e "${YELLOW}⚠️  Stuck Helm operation detected (status: $HELM_STATUS). Cleaning up...${NC}"
        
        # Delete pending Helm secrets
        kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-upgrade,name=postgresql" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
        kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-install,name=postgresql" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
        kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-rollback,name=postgresql" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
        
        echo -e "${GREEN}✓ Helm lock removed${NC}"
        sleep 5
      fi
      
      echo -e "${YELLOW}Uninstalling Helm release (cleanup mode)...${NC}"
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
  PG_READY=$(kubectl get statefulset postgresql -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
  PG_REPLICAS=$(kubectl get statefulset postgresql -n "${NAMESPACE}" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "")
  
  # Handle empty values (StatefulSet might not exist)
  PG_READY=${PG_READY:-0}
  PG_REPLICAS=${PG_REPLICAS:-0}
  
  echo -e "${BLUE}PostgreSQL StatefulSet: ${PG_READY}/${PG_REPLICAS} replicas ready${NC}"
  
  # Check if PG_READY is a valid number before comparison
  if [[ "$PG_READY" =~ ^[0-9]+$ ]] && [ "$PG_READY" -ge 1 ]; then
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

# Check for stuck Helm operations before proceeding with Redis
log_info "Checking for stuck Redis Helm operations..."
HELM_STATUS=$(helm -n "${NAMESPACE}" status redis 2>/dev/null | grep "STATUS:" | awk '{print $2}' || echo "")
if [[ "$HELM_STATUS" == "pending-upgrade" || "$HELM_STATUS" == "pending-install" || "$HELM_STATUS" == "pending-rollback" ]]; then
  log_warning "Detected stuck Helm operation (status: $HELM_STATUS). Cleaning up..."
  
  # Delete pending Helm secrets
  kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-upgrade,name=redis" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
  kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-install,name=redis" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
  kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-rollback,name=redis" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
  
  log_success "Helm lock removed"
  sleep 5
fi

# Function to fix orphaned Redis resources
fix_orphaned_redis_resources() {
  log_info "Checking for orphaned Redis resources..."
  
  # Check for orphaned ServiceMonitors (in monitoring namespace or infra namespace)
  MONITORING_NS=${MONITORING_NAMESPACE:-infra}
  ORPHANED_REDIS_SERVICEMONITORS=$(kubectl get servicemonitor -n "${MONITORING_NS}" -o json 2>/dev/null | \
    jq -r '.items[] | select((.metadata.labels."app.kubernetes.io/name" == "redis" or .metadata.name == "redis") and (.metadata.annotations."meta.helm.sh/release-name" == null or .metadata.annotations."meta.helm.sh/release-name" != "redis")) | .metadata.name' 2>/dev/null || true)
  
  # Also check in infra namespace if different from monitoring namespace
  if [ "${MONITORING_NS}" != "${NAMESPACE}" ]; then
    ORPHANED_REDIS_SERVICEMONITORS_INFRA=$(kubectl get servicemonitor -n "${NAMESPACE}" -o json 2>/dev/null | \
      jq -r '.items[] | select((.metadata.labels."app.kubernetes.io/name" == "redis" or .metadata.name == "redis") and (.metadata.annotations."meta.helm.sh/release-name" == null or .metadata.annotations."meta.helm.sh/release-name" != "redis")) | .metadata.name' 2>/dev/null || true)
    if [ -n "$ORPHANED_REDIS_SERVICEMONITORS_INFRA" ]; then
      ORPHANED_REDIS_SERVICEMONITORS="${ORPHANED_REDIS_SERVICEMONITORS} ${ORPHANED_REDIS_SERVICEMONITORS_INFRA}"
    fi
  fi

  if [ -n "$ORPHANED_REDIS_SERVICEMONITORS" ]; then
    log_warning "Found orphaned Redis ServiceMonitors without Helm ownership: $ORPHANED_REDIS_SERVICEMONITORS"
    for sm in $ORPHANED_REDIS_SERVICEMONITORS; do
      log_info "Fixing orphaned ServiceMonitor: $sm"
      # Determine which namespace the ServiceMonitor is in
      SM_NS="${MONITORING_NS}"
      if ! kubectl get servicemonitor "$sm" -n "${MONITORING_NS}" >/dev/null 2>&1; then
        SM_NS="${NAMESPACE}"
      fi
      
      # Try to add Helm ownership annotations
      if kubectl -n "${SM_NS}" annotate servicemonitor "$sm" \
        meta.helm.sh/release-name=redis \
        meta.helm.sh/release-namespace="${NAMESPACE}" \
        --overwrite 2>/dev/null; then
        log_success "✓ Annotated ServiceMonitor $sm with Helm ownership"
      else
        # If annotation fails, delete the orphaned ServiceMonitor (Helm will recreate it)
        log_warning "Failed to annotate ServiceMonitor $sm, deleting it (Helm will recreate)..."
        kubectl -n "${SM_NS}" delete servicemonitor "$sm" --wait=false 2>/dev/null || true
        log_success "✓ Deleted orphaned ServiceMonitor $sm"
      fi
    done
    sleep 3
  fi
  
  # Check for orphaned services (including redis-metrics)
  ORPHANED_REDIS_SERVICES=$(kubectl -n "${NAMESPACE}" get service -o json 2>/dev/null | \
    jq -r '.items[] | select((.metadata.labels."app.kubernetes.io/name" == "redis" or .metadata.name | contains("redis")) and (.metadata.annotations."meta.helm.sh/release-name" == null or .metadata.annotations."meta.helm.sh/release-name" != "redis")) | .metadata.name' 2>/dev/null || true)

  if [ -n "$ORPHANED_REDIS_SERVICES" ]; then
    log_warning "Found orphaned Redis services without Helm ownership: $ORPHANED_REDIS_SERVICES"
    for svc in $ORPHANED_REDIS_SERVICES; do
      log_info "Fixing orphaned service: $svc"
      # Try to add Helm ownership annotations
      if kubectl -n "${NAMESPACE}" annotate service "$svc" \
        meta.helm.sh/release-name=redis \
        meta.helm.sh/release-namespace="${NAMESPACE}" \
        --overwrite 2>/dev/null; then
        log_success "✓ Annotated service $svc with Helm ownership"
      else
        # If annotation fails, delete the orphaned service (Helm will recreate it)
        log_warning "Failed to annotate service $svc, deleting it (Helm will recreate)..."
        kubectl -n "${NAMESPACE}" delete service "$svc" --wait=false 2>/dev/null || true
        log_success "✓ Deleted orphaned service $svc"
      fi
    done
    sleep 3
  fi

  # Check for orphaned configmaps
  ORPHANED_REDIS_CONFIGMAPS=$(kubectl -n "${NAMESPACE}" get configmap -l app.kubernetes.io/name=redis -o json 2>/dev/null | \
    jq -r '.items[] | select(.metadata.annotations."meta.helm.sh/release-name" == null or .metadata.annotations."meta.helm.sh/release-name" != "redis") | .metadata.name' 2>/dev/null || true)

  if [ -n "$ORPHANED_REDIS_CONFIGMAPS" ]; then
    log_warning "Found orphaned Redis configmaps without Helm ownership: $ORPHANED_REDIS_CONFIGMAPS"
    for cm in $ORPHANED_REDIS_CONFIGMAPS; do
      log_info "Fixing orphaned configmap: $cm"
      if kubectl -n "${NAMESPACE}" annotate configmap "$cm" \
        meta.helm.sh/release-name=redis \
        meta.helm.sh/release-namespace="${NAMESPACE}" \
        --overwrite 2>/dev/null; then
        log_success "✓ Annotated configmap $cm with Helm ownership"
      else
        log_warning "Failed to annotate configmap $cm, deleting it (Helm will recreate)..."
        kubectl -n "${NAMESPACE}" delete configmap "$cm" --wait=false 2>/dev/null || true
        log_success "✓ Deleted orphaned configmap $cm"
      fi
    done
    sleep 3
  fi
}

# Install or upgrade Redis (idempotent)
echo -e "${YELLOW}Installing/upgrading Redis...${NC}"
echo -e "${BLUE}This may take 3-5 minutes...${NC}"

# Build Helm arguments - prioritize environment variables
REDIS_HELM_ARGS=()

# Always use values file as base
REDIS_HELM_ARGS+=(-f "${MANIFESTS_DIR}/databases/redis-values.yaml")

# Check if ServiceMonitor CRD exists (Prometheus Operator)
if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
  # Get monitoring namespace (default to infra)
  MONITORING_NS=${MONITORING_NAMESPACE:-infra}
  echo -e "${GREEN}[INFO] ServiceMonitor enabled for Redis metrics (namespace: ${MONITORING_NS})${NC}"
  REDIS_HELM_ARGS+=(--set metrics.serviceMonitor.enabled=true --set metrics.serviceMonitor.namespace="${MONITORING_NS}")
else
  echo -e "${YELLOW}[INFO] ServiceMonitor CRD not found - disabling Redis metrics ServiceMonitor${NC}"
  REDIS_HELM_ARGS+=(--set metrics.serviceMonitor.enabled=false)
fi

# Priority 1: Use REDIS_PASSWORD from environment (GitHub secrets)
if [[ -n "${REDIS_PASSWORD:-}" ]]; then
  echo -e "${GREEN}Using REDIS_PASSWORD from environment/GitHub secrets (priority)${NC}"
  REDIS_HELM_ARGS+=(--set global.redis.password="$REDIS_PASSWORD")
else
  echo -e "${YELLOW}No REDIS_PASSWORD in environment; using values file or auto-generated${NC}"
fi

set +e
if helm -n "${NAMESPACE}" status redis >/dev/null 2>&1; then
  # Check if Redis is healthy
  IS_REDIS_HEALTHY=$(kubectl -n "${NAMESPACE}" get statefulset redis-master -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "1" && echo "true" || echo "false")
  
  # Always ensure password matches GitHub secrets if REDIS_PASSWORD is provided
  if [[ -n "${REDIS_PASSWORD:-}" ]]; then
    # Get current password from secret
    CURRENT_REDIS_PASS=$(kubectl -n "${NAMESPACE}" get secret redis -o jsonpath='{.data.redis-password}' 2>/dev/null | base64 -d || true)
    
    # Always update secret to match GitHub secrets password (source of truth)
    if [[ "$CURRENT_REDIS_PASS" != "$REDIS_PASSWORD" ]]; then
      echo -e "${YELLOW}Updating Redis secret to match GitHub secrets password...${NC}"
      echo -e "${BLUE}Current password length: ${#CURRENT_REDIS_PASS} chars${NC}"
      echo -e "${BLUE}GitHub secrets password length: ${#REDIS_PASSWORD} chars${NC}"
      
      # Update the secret to match GitHub secrets (source of truth)
      kubectl create secret generic redis \
        --from-literal=redis-password="$REDIS_PASSWORD" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
      
      echo -e "${GREEN}✓ Redis secret updated to match GitHub secrets password${NC}"
    else
      echo -e "${GREEN}✓ Redis password already matches GitHub secrets${NC}"
    fi
    
    # If Redis is healthy, no need to upgrade - secret is already updated
    if [[ "$IS_REDIS_HEALTHY" == "true" ]]; then
      echo -e "${GREEN}✓ Redis is healthy and password matches GitHub secrets - skipping upgrade${NC}"
      HELM_REDIS_EXIT=0
    else
      echo -e "${YELLOW}Redis not healthy. Checking for stuck Helm operation and orphaned resources...${NC}"
      
      # Check for stuck Helm operation before upgrading
      HELM_STATUS=$(helm -n "${NAMESPACE}" status redis 2>/dev/null | grep "STATUS:" | awk '{print $2}' || echo "")
      if [[ "$HELM_STATUS" == "pending-upgrade" || "$HELM_STATUS" == "pending-install" || "$HELM_STATUS" == "pending-rollback" ]]; then
        echo -e "${YELLOW}⚠️  Stuck Helm operation detected (status: $HELM_STATUS). Cleaning up...${NC}"
        
        # Delete pending Helm secrets
        kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-upgrade,name=redis" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
        kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-install,name=redis" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
        kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-rollback,name=redis" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
        
        echo -e "${GREEN}✓ Helm lock removed${NC}"
        sleep 5
      fi
      
      # Fix orphaned resources BEFORE Helm upgrade
      fix_orphaned_redis_resources
      
      echo -e "${YELLOW}Performing Helm upgrade with GitHub secrets password...${NC}"
      helm upgrade redis bitnami/redis \
        -n "${NAMESPACE}" \
        --reset-values \
        -f "${MANIFESTS_DIR}/databases/redis-values.yaml" \
        "${REDIS_HELM_ARGS[@]}" \
        --timeout=10m \
        --wait=false 2>&1 | tee /tmp/helm-redis-install.log
      HELM_REDIS_EXIT=${PIPESTATUS[0]}
    fi
  elif [[ "$IS_REDIS_HEALTHY" == "true" ]]; then
    echo -e "${GREEN}✓ Redis already installed and healthy - skipping${NC}"
    HELM_REDIS_EXIT=0
  else
    echo -e "${YELLOW}Redis exists but not ready; checking for stuck operation and orphaned resources...${NC}"
    
    # Check for stuck Helm operation
    HELM_STATUS=$(helm -n "${NAMESPACE}" status redis 2>/dev/null | grep "STATUS:" | awk '{print $2}' || echo "")
    if [[ "$HELM_STATUS" == "pending-upgrade" || "$HELM_STATUS" == "pending-install" || "$HELM_STATUS" == "pending-rollback" ]]; then
      echo -e "${YELLOW}⚠️  Stuck Helm operation detected (status: $HELM_STATUS). Cleaning up...${NC}"
      
      # Delete pending Helm secrets
      kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-upgrade,name=redis" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
      kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-install,name=redis" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
      kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-rollback,name=redis" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
      
      echo -e "${GREEN}✓ Helm lock removed${NC}"
      sleep 5
    fi
    
    # Fix orphaned resources BEFORE Helm upgrade
    fix_orphaned_redis_resources
    
    echo -e "${YELLOW}Performing safe upgrade...${NC}"
    helm upgrade redis bitnami/redis \
      -n "${NAMESPACE}" \
      --reuse-values \
      "${REDIS_HELM_ARGS[@]}" \
      --timeout=10m \
      --wait=false 2>&1 | tee /tmp/helm-redis-install.log
    HELM_REDIS_EXIT=${PIPESTATUS[0]}
  fi
else
  echo -e "${YELLOW}Redis not found; installing fresh${NC}"
  helm install redis bitnami/redis \
    -n "${NAMESPACE}" \
    "${REDIS_HELM_ARGS[@]}" \
    --timeout=10m \
    --wait=false 2>&1 | tee /tmp/helm-redis-install.log
  HELM_REDIS_EXIT=${PIPESTATUS[0]}
fi
set -e

if [ $HELM_REDIS_EXIT -eq 0 ]; then
  echo -e "${GREEN}✓ Redis Helm operation completed${NC}"
  echo -e "${BLUE}Waiting for Redis pods to be ready...${NC}"
  sleep 10
  
  # Check actual pod status
  REDIS_READY=$(kubectl get statefulset redis-master -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
  REDIS_REPLICAS=$(kubectl get statefulset redis-master -n "${NAMESPACE}" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "")
  
  # Handle empty values
  REDIS_READY=${REDIS_READY:-0}
  REDIS_REPLICAS=${REDIS_REPLICAS:-0}
  
  if [[ "$REDIS_READY" =~ ^[0-9]+$ ]] && [ "$REDIS_READY" -ge 1 ]; then
    echo -e "${GREEN}✓ Redis is ready (${REDIS_READY}/${REDIS_REPLICAS} replicas)${NC}"
  else
    echo -e "${YELLOW}⚠️  Redis pods not ready yet (${REDIS_READY}/${REDIS_REPLICAS} replicas)${NC}"
    echo -e "${BLUE}Checking pod status...${NC}"
    kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=redis || true
    
    # Check for image pull errors
    IMAGE_PULL_ERRORS=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=redis -o json 2>/dev/null | \
      jq -r '.items[] | select(.status.containerStatuses[]?.state.waiting.reason == "ImagePullBackOff" or .status.containerStatuses[]?.state.waiting.reason == "ErrImagePull") | .metadata.name' 2>/dev/null || true)
    
    if [ -n "$IMAGE_PULL_ERRORS" ]; then
      echo -e "${RED}⚠️  Image pull errors detected for pods: $IMAGE_PULL_ERRORS${NC}"
      echo -e "${YELLOW}Checking registry-credentials secret...${NC}"
      
      if ! kubectl get secret registry-credentials -n "${NAMESPACE}" >/dev/null 2>&1; then
        echo -e "${RED}ERROR: registry-credentials secret missing in namespace ${NAMESPACE}${NC}"
        echo -e "${YELLOW}This secret is required for Docker Hub authentication.${NC}"
        echo -e "${YELLOW}Please ensure REGISTRY_USERNAME, REGISTRY_PASSWORD, and REGISTRY_EMAIL are set in GitHub secrets.${NC}"
        echo -e "${YELLOW}The workflow should create this automatically, but it may have failed.${NC}"
      else
        echo -e "${GREEN}✓ registry-credentials secret exists${NC}"
        echo -e "${YELLOW}Checking if pods are using imagePullSecrets...${NC}"
        kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=redis -o json 2>/dev/null | \
          jq -r '.items[] | "\(.metadata.name): imagePullSecrets=\(.spec.imagePullSecrets // [] | map(.name) | join(", "))"' 2>/dev/null || true
      fi
      
      # Check if the image tag exists or suggest using latest
      echo -e "${YELLOW}Note: If image pull fails, the Redis image tag may not exist.${NC}"
      echo -e "${YELLOW}Consider using 'latest' tag or a different version.${NC}"
    fi
    
    # Check for crash loops
    CRASH_LOOP=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=redis -o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}' 2>/dev/null | grep -i "CrashLoop\|Error" || echo "")
    if [[ -n "$CRASH_LOOP" ]]; then
      echo -e "${RED}⚠️  Crash loop detected. Checking logs...${NC}"
      kubectl logs -n "${NAMESPACE}" -l app.kubernetes.io/name=redis --tail=50 || true
    fi
    
    echo -e "${BLUE}Redis installation initiated. Pods will start in background.${NC}"
  fi
else
  echo -e "${YELLOW}Redis Helm operation reported exit code $HELM_REDIS_EXIT${NC}"
  echo -e "${YELLOW}Checking actual Redis status...${NC}"
  
  # Wait a bit for pods to update
  sleep 10
  
  # Check if Redis StatefulSet exists and has ready replicas
  REDIS_READY=$(kubectl get statefulset redis-master -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
  REDIS_REPLICAS=$(kubectl get statefulset redis-master -n "${NAMESPACE}" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "")
  
  # Handle empty values
  REDIS_READY=${REDIS_READY:-0}
  REDIS_REPLICAS=${REDIS_REPLICAS:-0}
  
  echo -e "${BLUE}Redis StatefulSet: ${REDIS_READY}/${REDIS_REPLICAS} replicas ready${NC}"
  
  if [[ "$REDIS_READY" =~ ^[0-9]+$ ]] && [ "$REDIS_READY" -ge 1 ]; then
    echo -e "${GREEN}✓ Redis is actually running! Continuing...${NC}"
    echo -e "${YELLOW}Note: Helm reported a timeout, but Redis is healthy${NC}"
  else
    echo -e "${RED}Redis installation/upgrade failed${NC}"
    echo -e "${YELLOW}=== Helm output (last 50 lines) ===${NC}"
    tail -50 /tmp/helm-redis-install.log 2>/dev/null || true
    echo -e "${YELLOW}=== Pod status ===${NC}"
    kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=redis 2>/dev/null || true
    echo -e "${YELLOW}=== Pod events ===${NC}"
    kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' 2>/dev/null | grep -i redis | tail -10 || true
    echo -e "${YELLOW}=== Pod logs (last 20 lines) ===${NC}"
    kubectl logs -n "${NAMESPACE}" -l app.kubernetes.io/name=redis --tail=20 2>/dev/null || true
    
    exit 1
  fi
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
