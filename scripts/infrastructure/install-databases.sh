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
MONITORING_NS=${MONITORING_NAMESPACE:-infra}

log_section "Installing Shared Infrastructure Databases (Production)"
log_info "Namespace: ${NAMESPACE}"
log_info "Monitoring Namespace: ${MONITORING_NS}"
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

# Function to fix orphaned resources with invalid Helm ownership metadata (generic)
fix_orphaned_resources() {
  local release_name=$1
  local namespace=${2:-${NAMESPACE}}
  local resource_types=($@)
  shift 2  # Remove first two arguments (release_name, namespace)
  
  # Default resource types if none specified
  if [ $# -eq 0 ]; then
    resource_types=("networkpolicies" "poddisruptionbudgets" "configmaps" "services" "secrets")
  fi
  
  for resource_type in "${resource_types[@]}"; do
    # Handle plural/singular forms
    plural_type="${resource_type}s"
    resource_list=$(kubectl api-resources | awk '$1 ~ /^'"${resource_type}"'$/ {print $2}' || echo "${plural_type}")
    
    # Get resources for this release
    resources=$(kubectl get "${resource_list}" -n "${namespace}" -l "app.kubernetes.io/instance=${release_name}" -o name 2>/dev/null || true)
    
    if [ -n "$resources" ]; then
      log_info "Checking ${resource_list} for ownership issues..."
      for resource in $resources; do
        resource_name=$(basename "$resource")
        
        # Check Helm ownership annotations
        release_name_annotation=$(kubectl get "${resource}" -n "${namespace}" \
          -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || echo "")
        release_namespace_annotation=$(kubectl get "${resource}" -n "${namespace}" \
          -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-namespace}' 2>/dev/null || echo "")
        
        if [ -z "$release_name_annotation" ] || [ -z "$release_namespace_annotation" ]; then
          log_warning "Found ${resource_type} '${resource_name}' with invalid Helm ownership metadata"
          
          # Try to add proper Helm annotations
          if kubectl patch "${resource}" -n "${namespace}" \
            --type='json' \
            -p="[{\"op\":\"add\",\"path\":\"/metadata/annotations/meta.helm.sh~1release-name\",\"value\":\"${release_name}\"},{\"op\":\"add\",\"path\":\"/metadata/annotations/meta.helm.sh~1release-namespace\",\"value\":\"${namespace}\"}]" 2>/dev/null; then
            log_success "Added Helm ownership annotations to ${resource_type} '${resource_name}'"
          else
            # Fallback: Remove finalizers and delete
            log_warning "Failed to patch ${resource_type} '${resource_name}' - deleting to let Helm recreate..."
            kubectl patch "${resource}" -n "${namespace}" \
              -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
            kubectl delete "${resource}" -n "${namespace}" --wait=true --grace-period=0 2>/dev/null || true
            log_success "${resource_type} '${resource_name}' deleted - Helm will recreate"
            sleep 1
          fi
        elif [ "$release_name_annotation" != "$release_name" ] || [ "$release_namespace_annotation" != "$namespace" ]; then
          log_warning "${resource_type} '${resource_name}' has incorrect Helm ownership - deleting..."
          kubectl patch "${resource}" -n "${namespace}" \
            -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
          kubectl delete "${resource}" -n "${namespace}" --wait=true --grace-period=0 2>/dev/null || true
          log_success "${resource_type} '${resource_name}' deleted - Helm will recreate with correct ownership"
          sleep 1
        fi
      done
    fi
  done
}

# Check for stuck Helm operations before proceeding
log_info "Checking for stuck Helm operations..."
fix_stuck_helm_operation "postgresql" "${NAMESPACE}" || true

# Check for orphaned resources with invalid Helm ownership metadata
log_info "Checking for orphaned resources..."
fix_orphaned_resources "postgresql" "${NAMESPACE}" || true

# Install or upgrade PostgreSQL (idempotent)
log_section "Installing/upgrading PostgreSQL"
log_info "This may take 5-10 minutes..."

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

# Priority 1: Use POSTGRES_PASSWORD from environment (GitHub secrets) - REQUIRED
# These --set flags will override values file
if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
  log_error "POSTGRES_PASSWORD is required but not set in GitHub secrets"
  log_error "Please set POSTGRES_PASSWORD in GitHub organization secrets"
  exit 1
fi

log_info "Using POSTGRES_PASSWORD from environment/GitHub secrets"
log_info "  - postgres superuser password: ${#POSTGRES_PASSWORD} chars"
PG_HELM_ARGS+=(--set global.postgresql.auth.postgresPassword="$POSTGRES_PASSWORD")
PG_HELM_ARGS+=(--set global.postgresql.auth.database="$PG_DATABASE")

# Use POSTGRES_ADMIN_PASSWORD for admin_user if set, otherwise use POSTGRES_PASSWORD
if [[ -n "${POSTGRES_ADMIN_PASSWORD:-}" ]]; then
  log_info "  - admin_user password: using POSTGRES_ADMIN_PASSWORD (${#POSTGRES_ADMIN_PASSWORD} chars)"
  PG_HELM_ARGS+=(--set global.postgresql.auth.password="$POSTGRES_ADMIN_PASSWORD")
else
  log_info "  - admin_user password: using same as postgres superuser (POSTGRES_PASSWORD)"
  PG_HELM_ARGS+=(--set global.postgresql.auth.password="$POSTGRES_PASSWORD")
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
      log_success "PostgreSQL password unchanged - skipping upgrade"
      log_info "Current secret password matches provided POSTGRES_PASSWORD"
      HELM_PG_EXIT=0
    else
      log_warning "Password mismatch detected"
      log_info "Current password length: ${#CURRENT_PG_PASS} chars"
      log_info "New password length: ${#POSTGRES_PASSWORD} chars"
      log_error "WARNING: Updating passwords requires pod restart and may take time"
      log_info "Checking if PostgreSQL is currently healthy..."
      
      # Check if PostgreSQL is currently running - if yes, just update the secret without Helm upgrade
      if kubectl get statefulset postgresql -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "1"; then
        log_info "PostgreSQL is healthy. Updating password via secret..."
        
        # Update the secret directly - use POSTGRES_ADMIN_PASSWORD if set, otherwise POSTGRES_PASSWORD
        ADMIN_PASS="${POSTGRES_ADMIN_PASSWORD:-$POSTGRES_PASSWORD}"
        kubectl create secret generic postgresql \
          --from-literal=postgres-password="$POSTGRES_PASSWORD" \
          --from-literal=password="$ADMIN_PASS" \
          --from-literal=admin-user-password="$ADMIN_PASS" \
          -n "${NAMESPACE}" \
          --dry-run=client -o yaml | kubectl apply -f -
        
        log_success "Password updated in secret. PostgreSQL will use it on next restart."
        log_warning "Note: Password change will take effect on next pod restart"
        HELM_PG_EXIT=0
        POSTGRES_DEPLOYED=true
      else
        log_warning "PostgreSQL not healthy. Checking for stuck Helm operation..."
        
        # Fix stuck Helm operation before upgrading
        fix_stuck_helm_operation "postgresql" "${NAMESPACE}"
        
        log_warning "Performing Helm upgrade..."
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
    log_success "PostgreSQL already installed and healthy - skipping"
    HELM_PG_EXIT=0
    POSTGRES_DEPLOYED=true
  else
    log_warning "PostgreSQL exists but not ready; checking for stuck operation..."
    
    # Fix stuck Helm operation
    fix_stuck_helm_operation "postgresql" "${NAMESPACE}"
    
    log_warning "Performing safe upgrade..."
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
  log_info "PostgreSQL not found; installing fresh"
  
  # Only clean up orphaned resources if cleanup mode is active
  if is_cleanup_mode; then
    log_info "Cleanup mode active - checking for orphaned PostgreSQL resources..."
    
    # Check for StatefulSets first (these recreate resources)
    STATEFULSETS=$(kubectl get statefulset -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql -o name 2>/dev/null || true)
    if [ -n "$STATEFULSETS" ]; then
      log_warning "Found PostgreSQL StatefulSet - deleting (cleanup mode)..."
      kubectl delete statefulset -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql --wait=true --grace-period=0 --force 2>/dev/null || true
    fi
    
    # Check for failed/pending Helm release
    if helm -n "${NAMESPACE}" list -q | grep -q "^postgresql$" 2>/dev/null; then
      log_warning "Found existing Helm release - checking for stuck operation..."
      
      # Fix stuck Helm operation before uninstalling
      fix_stuck_helm_operation "postgresql" "${NAMESPACE}"
      
      log_warning "Uninstalling Helm release (cleanup mode)..."
      helm uninstall postgresql -n "${NAMESPACE}" --wait 2>/dev/null || true
      sleep 5
    fi
    
    # Clean up orphaned resources
    ORPHANED_RESOURCES=$(kubectl get networkpolicy,configmap,service -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql 2>/dev/null | grep -v NAME || true)
    if [ -n "$ORPHANED_RESOURCES" ]; then
      log_warning "Cleaning up orphaned resources (cleanup mode)..."
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
    log_info "Cleanup mode inactive - checking for existing resources to update..."
    
    # Fix orphaned resources before attempting Helm operations
    fix_orphaned_resources "postgresql" "${NAMESPACE}" || true
    
    # If resources exist but Helm release doesn't, try to upgrade anyway (Helm will handle it)
    if kubectl get statefulset postgresql -n "${NAMESPACE}" >/dev/null 2>&1; then
      log_warning "PostgreSQL StatefulSet exists but Helm release missing - attempting upgrade..."
      helm upgrade postgresql bitnami/postgresql \
        --version 16.7.27 \
        -n "${NAMESPACE}" \
        "${PG_HELM_ARGS[@]}" \
        --timeout=10m \
        --wait 2>&1 | tee /tmp/helm-postgresql-install.log
      HELM_PG_EXIT=${PIPESTATUS[0]}
      set -e
      if [ $HELM_PG_EXIT -eq 0 ]; then
        log_success "PostgreSQL upgraded"
        POSTGRES_DEPLOYED=true
      else
        log_warning "PostgreSQL upgrade failed (release missing). Falling back to fresh install..."
        POSTGRES_DEPLOYED=false
        HELM_PG_EXIT=1
      fi
    fi
  fi
  
  # Install PostgreSQL if cleanup mode or no existing resources
  if [ "${POSTGRES_DEPLOYED:-false}" != "true" ]; then
    # Ensure resources are fixed before fresh install
    fix_orphaned_resources "postgresql" "${NAMESPACE}" || true
    
    log_info "Installing PostgreSQL..."
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
  log_success "PostgreSQL ready"
else
  log_warning "PostgreSQL Helm operation reported exit code $HELM_PG_EXIT"
  log_warning "Checking actual PostgreSQL status..."
  
  # Wait a bit for pods to update
  sleep 10
  
  # Check if PostgreSQL StatefulSet exists and has ready replicas
  PG_READY=$(kubectl get statefulset postgresql -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
  PG_REPLICAS=$(kubectl get statefulset postgresql -n "${NAMESPACE}" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "")
  
  # Handle empty values (StatefulSet might not exist)
  PG_READY=${PG_READY:-0}
  PG_REPLICAS=${PG_REPLICAS:-0}
  
  log_info "PostgreSQL StatefulSet: ${PG_READY}/${PG_REPLICAS} replicas ready"
  
  # Check if PG_READY is a valid number before comparison
  if [[ "$PG_READY" =~ ^[0-9]+$ ]] && [ "$PG_READY" -ge 1 ]; then
    log_success "PostgreSQL is actually running! Continuing..."
    log_warning "Note: Helm reported a timeout, but PostgreSQL is healthy"
  else
    log_error "PostgreSQL installation/upgrade failed"
    log_warning "=== Helm output (last 50 lines) ==="
    tail -50 /tmp/helm-postgresql-install.log 2>/dev/null || true
    log_warning "=== Pod status ==="
    kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql 2>/dev/null || true
    log_warning "=== Pod events ==="
    kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' 2>/dev/null | grep -i postgresql | tail -10 || true
    log_warning "=== PVC status ==="
    kubectl get pvc -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql 2>/dev/null || true
    
    # Check for common issues
    log_warning "=== Diagnosing issues ==="
    PENDING_PVCS=$(kubectl get pvc -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
    if [ "$PENDING_PVCS" -gt 0 ]; then
      log_error "Found ${PENDING_PVCS} Pending PVCs - storage may not be available"
    fi
    
    exit 1
  fi
fi

# Check for stuck Helm operations before proceeding with Redis
log_info "Checking for stuck Redis Helm operations..."
fix_stuck_helm_operation "redis" "${NAMESPACE}" || true

# Function to fix orphaned Redis resources
fix_orphaned_redis_resources() {
  log_info "Checking for orphaned Redis resources..."
  
  # Use MONITORING_NS from script scope (defined at top)
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
log_section "Installing/upgrading Redis"
log_info "This may take 3-5 minutes..."

# Build Helm arguments - prioritize environment variables
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

# Priority 1: Use REDIS_PASSWORD from environment (GitHub secrets) - REQUIRED
if [[ -z "${REDIS_PASSWORD:-}" ]]; then
  log_error "REDIS_PASSWORD is required but not set in GitHub secrets"
  log_error "Please set REDIS_PASSWORD in GitHub organization secrets"
  exit 1
fi

log_info "Using REDIS_PASSWORD from environment/GitHub secrets"
log_info "  - Redis password: ${#REDIS_PASSWORD} chars"
REDIS_HELM_ARGS+=(--set global.redis.password="$REDIS_PASSWORD")

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
      log_warning "Updating Redis secret to match GitHub secrets password..."
      log_info "Current password length: ${#CURRENT_REDIS_PASS} chars"
      log_info "GitHub secrets password length: ${#REDIS_PASSWORD} chars"
      
      # Update the secret to match GitHub secrets (source of truth)
      kubectl create secret generic redis \
        --from-literal=redis-password="$REDIS_PASSWORD" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
      
      log_success "Redis secret updated to match GitHub secrets password"
    else
      log_success "Redis password already matches GitHub secrets"
    fi
    
    # If Redis is healthy, no need to upgrade - secret is already updated
    if [[ "$IS_REDIS_HEALTHY" == "true" ]]; then
      log_success "Redis is healthy and password matches GitHub secrets - skipping upgrade"
      HELM_REDIS_EXIT=0
    else
      log_warning "Redis not healthy. Checking for stuck Helm operation and orphaned resources..."
      
      # Fix stuck Helm operation before upgrading
      fix_stuck_helm_operation "redis" "${NAMESPACE}"
      
      # Fix orphaned resources BEFORE Helm upgrade
      fix_orphaned_redis_resources
      
      log_warning "Performing Helm upgrade with GitHub secrets password..."
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
    log_success "Redis already installed and healthy - skipping"
    HELM_REDIS_EXIT=0
  else
    log_warning "Redis exists but not ready; checking for stuck operation and orphaned resources..."
    
    # Fix stuck Helm operation
    fix_stuck_helm_operation "redis" "${NAMESPACE}"
    
    # Fix orphaned resources BEFORE Helm upgrade
    fix_orphaned_redis_resources
    
    log_warning "Performing safe upgrade..."
    helm upgrade redis bitnami/redis \
      -n "${NAMESPACE}" \
      --reuse-values \
      "${REDIS_HELM_ARGS[@]}" \
      --timeout=10m \
      --wait=false 2>&1 | tee /tmp/helm-redis-install.log
    HELM_REDIS_EXIT=${PIPESTATUS[0]}
  fi
else
  log_info "Redis not found; installing fresh"
  helm install redis bitnami/redis \
    -n "${NAMESPACE}" \
    "${REDIS_HELM_ARGS[@]}" \
    --timeout=10m \
    --wait=false 2>&1 | tee /tmp/helm-redis-install.log
  HELM_REDIS_EXIT=${PIPESTATUS[0]}
fi
set -e

if [ $HELM_REDIS_EXIT -eq 0 ]; then
  log_success "Redis Helm operation completed"
  log_info "Waiting for Redis pods to be ready..."
  sleep 10
  
  # Check actual pod status
  REDIS_READY=$(kubectl get statefulset redis-master -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
  REDIS_REPLICAS=$(kubectl get statefulset redis-master -n "${NAMESPACE}" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "")
  
  # Handle empty values
  REDIS_READY=${REDIS_READY:-0}
  REDIS_REPLICAS=${REDIS_REPLICAS:-0}
  
  if [[ "$REDIS_READY" =~ ^[0-9]+$ ]] && [ "$REDIS_READY" -ge 1 ]; then
    log_success "Redis is ready (${REDIS_READY}/${REDIS_REPLICAS} replicas)"
  else
    log_warning "Redis pods not ready yet (${REDIS_READY}/${REDIS_REPLICAS} replicas)"
    log_info "Checking pod status..."
    kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=redis || true
    
    # Check for image pull errors
    IMAGE_PULL_ERRORS=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=redis -o json 2>/dev/null | \
      jq -r '.items[] | select(.status.containerStatuses[]?.state.waiting.reason == "ImagePullBackOff" or .status.containerStatuses[]?.state.waiting.reason == "ErrImagePull") | .metadata.name' 2>/dev/null || true)
    
    if [ -n "$IMAGE_PULL_ERRORS" ]; then
      log_error "Image pull errors detected for pods: $IMAGE_PULL_ERRORS"
      log_warning "Checking registry-credentials secret..."
      
      if ! kubectl get secret registry-credentials -n "${NAMESPACE}" >/dev/null 2>&1; then
        log_error "ERROR: registry-credentials secret missing in namespace ${NAMESPACE}"
        log_warning "This secret is required for Docker Hub authentication."
        log_warning "Please ensure REGISTRY_USERNAME, REGISTRY_PASSWORD, and REGISTRY_EMAIL are set in GitHub secrets."
        log_warning "The workflow should create this automatically, but it may have failed."
      else
        log_success "registry-credentials secret exists"
        log_info "Checking if pods are using imagePullSecrets..."
        kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=redis -o json 2>/dev/null | \
          jq -r '.items[] | "\(.metadata.name): imagePullSecrets=\(.spec.imagePullSecrets // [] | map(.name) | join(", "))"' 2>/dev/null || true
      fi
      
      # Check if the image tag exists or suggest using latest
      log_warning "Note: If image pull fails, the Redis image tag may not exist."
      log_warning "Consider using 'latest' tag or a different version."
    fi
    
    # Check for crash loops
    CRASH_LOOP=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=redis -o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}' 2>/dev/null | grep -i "CrashLoop\|Error" || echo "")
    if [[ -n "$CRASH_LOOP" ]]; then
      log_error "Crash loop detected. Checking logs..."
      kubectl logs -n "${NAMESPACE}" -l app.kubernetes.io/name=redis --tail=50 || true
    fi
    
    log_info "Redis installation initiated. Pods will start in background."
  fi
else
  log_warning "Redis Helm operation reported exit code $HELM_REDIS_EXIT"
  log_warning "Checking actual Redis status..."
  
  # Wait a bit for pods to update
  sleep 10
  
  # Check if Redis StatefulSet exists and has ready replicas
  REDIS_READY=$(kubectl get statefulset redis-master -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
  REDIS_REPLICAS=$(kubectl get statefulset redis-master -n "${NAMESPACE}" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "")
  
  # Handle empty values
  REDIS_READY=${REDIS_READY:-0}
  REDIS_REPLICAS=${REDIS_REPLICAS:-0}
  
  log_info "Redis StatefulSet: ${REDIS_READY}/${REDIS_REPLICAS} replicas ready"
  
  if [[ "$REDIS_READY" =~ ^[0-9]+$ ]] && [ "$REDIS_READY" -ge 1 ]; then
    log_success "Redis is actually running! Continuing..."
    log_warning "Note: Helm reported a timeout, but Redis is healthy"
  else
    log_error "Redis installation/upgrade failed"
    log_warning "=== Helm output (last 50 lines) ==="
    tail -50 /tmp/helm-redis-install.log 2>/dev/null || true
    log_warning "=== Pod status ==="
    kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=redis 2>/dev/null || true
    log_warning "=== Pod events ==="
    kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' 2>/dev/null | grep -i redis | tail -10 || true
    log_warning "=== Pod logs (last 20 lines) ==="
    kubectl logs -n "${NAMESPACE}" -l app.kubernetes.io/name=redis --tail=20 2>/dev/null || true
    
    exit 1
  fi
fi

# Retrieve credentials
log_section "Database Installation Complete"
log_info "Retrieving credentials..."

# Get PostgreSQL passwords
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
