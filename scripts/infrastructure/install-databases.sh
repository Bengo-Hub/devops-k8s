#!/usr/bin/env bash
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
# Which components to manage in this run:
# - "all"      (default): PostgreSQL + Redis
# - "postgres": PostgreSQL only
# - "redis"   : Redis only
ONLY_COMPONENT=${ONLY_COMPONENT:-all}

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
  cat <<'PRIORITY_EOF' | kubectl apply -f -
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: db-critical
  labels:
    app.kubernetes.io/name: db-critical
spec:
  globalDefault: false
  description: "High priority for critical data services (PostgreSQL/Redis/RabbitMQ)"
  value: 1000000000
PRIORITY_EOF
  log_success "PriorityClass db-critical created"
else
  log_success "PriorityClass db-critical already exists"
fi

# Function to fix stuck Helm operations
fix_stuck_helm_operation() {
  local release_name=$1
  local namespace=${2:-${NAMESPACE}}
  
  local helm_status=$(helm -n "${namespace}" status "${release_name}" 2>/dev/null | grep "STATUS:" | awk '{print $2}' || echo "")
  if [[ "$helm_status" == "pending-upgrade" || "$helm_status" == "pending-install" || "$helm_status" == "pending-rollback" ]]; then
    log_warning "Detected stuck Helm operation for ${release_name} (status: $helm_status). Cleaning up..."
    
    # Delete pending Helm secrets
    kubectl -n "${namespace}" get secrets -l "owner=helm,status=pending-upgrade,name=${release_name}" -o name 2>/dev/null | xargs kubectl -n "${namespace}" delete 2>/dev/null || true
    kubectl -n "${namespace}" get secrets -l "owner=helm,status=pending-install,name=${release_name}" -o name 2>/dev/null | xargs kubectl -n "${namespace}" delete 2>/dev/null || true
    kubectl -n "${namespace}" get secrets -l "owner=helm,status=pending-rollback,name=${release_name}" -o name 2>/dev/null | xargs kubectl -n "${namespace}" delete 2>/dev/null || true
    
    log_success "Helm lock removed for ${release_name}"
    sleep 5
    return 0
  fi
  return 1
}

# Function to fix orphaned resources with invalid Helm ownership metadata (generic)
fix_orphaned_resources() {
  local release_name=$1
  local namespace=${2:-${NAMESPACE}}
  local resource_types=($@)
  shift 2  # Remove first two arguments (release_name, namespace)
  
  # Default resource types if none specified
  if [ $# -eq 0 ]; then
    # Include secrets and serviceaccounts explicitly to handle ownership issues
    # Also include ServiceMonitor and NetworkPolicy to fix ownership for database metrics and network resources
    # Include StatefulSets to handle cases where the main workload (postgresql) already exists without Helm ownership
    resource_types=("poddisruptionbudgets" "configmaps" "services" "secrets" "serviceaccounts" "networkpolicies" "servicemonitors" "statefulsets")
  fi
  
  for resource_type in "${resource_types[@]}"; do
    # Handle plural/singular forms
    plural_type="${resource_type}s"
    resource_list=$(kubectl api-resources | awk '$1 ~ /^'"${resource_type}"'$/ {print $2}' || echo "${plural_type}")
    
    # Get resources for this release by label
    resources=$(kubectl get "${resource_list}" -n "${namespace}" -l "app.kubernetes.io/instance=${release_name}" -o name 2>/dev/null || true)
    
    # Fallback: for secrets, also check by exact name if no labelled resources are found
    if [ -z "$resources" ] && { [ "${resource_type}" = "secrets" ] || [ "${resource_type}" = "secret" ]; }; then
      if kubectl get secret "${release_name}" -n "${namespace}" >/dev/null 2>&1; then
        resources="secret/${release_name}"
        log_info "Found secret '${release_name}' by name (no Helm labels present) - checking ownership..."
      fi
    fi

    # Fallback: for ServiceMonitors, also check by exact name if no labelled resources are found
    # This specifically fixes cases like ServiceMonitor "postgresql" blocking Helm upgrades
    if [ -z "$resources" ] && { [ "${resource_type}" = "servicemonitors" ] || [ "${resource_type}" = "servicemonitor" ]; }; then
      if kubectl get servicemonitor "${release_name}" -n "${namespace}" >/dev/null 2>&1; then
        resources="servicemonitor/${release_name}"
        log_info "Found ServiceMonitor '${release_name}' by name (no Helm labels present) - checking ownership..."
      fi
    fi

    # Fallback: for NetworkPolicies, also check by exact name if no labelled resources are found
    # This fixes cases like NetworkPolicy "postgresql" blocking Helm installs/upgrades
    if [ -z "$resources" ] && { [ "${resource_type}" = "networkpolicies" ] || [ "${resource_type}" = "networkpolicy" ]; }; then
      if kubectl get networkpolicy "${release_name}" -n "${namespace}" >/dev/null 2>&1; then
        resources="networkpolicy/${release_name}"
        log_info "Found NetworkPolicy '${release_name}' by name (no Helm labels present) - checking ownership..."
      fi
    fi

    # Fallback: for StatefulSets, also check by exact name if no labelled resources are found
    # This fixes cases like StatefulSet "postgresql" existing without Helm ownership, blocking installs/upgrades
    if [ -z "$resources" ] && { [ "${resource_type}" = "statefulsets" ] || [ "${resource_type}" = "statefulset" ]; }; then
      if kubectl get statefulset "${release_name}" -n "${namespace}" >/dev/null 2>&1; then
        resources="statefulset/${release_name}"
        log_info "Found StatefulSet '${release_name}' by name (no Helm labels present) - checking ownership..."
      fi
    fi

    # Fallback: for Redis StatefulSets specifically (redis-master, redis-replicas)
    if [ -z "$resources" ] && { [ "${resource_type}" = "statefulsets" ] || [ "${resource_type}" = "statefulset" ]; } && [ "${release_name}" = "redis" ]; then
      if kubectl get statefulset redis-master -n "${namespace}" >/dev/null 2>&1; then
        resources="${resources} statefulset/redis-master"
        log_info "Found StatefulSet 'redis-master' - checking ownership..."
      fi
      if kubectl get statefulset redis-replicas -n "${namespace}" >/dev/null 2>&1; then
        resources="${resources} statefulset/redis-replicas"
        log_info "Found StatefulSet 'redis-replicas' - checking ownership..."
      fi
    fi
    
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

if [[ "$ONLY_COMPONENT" == "all" || "$ONLY_COMPONENT" == "postgres" ]]; then
# Build and push custom PostgreSQL image with pgvector extension
log_section "Building Custom PostgreSQL Image with pgvector"
DOCKERFILE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/docker/postgresql-pgvector"
CUSTOM_IMAGE_REGISTRY=${REGISTRY_SERVER:-docker.io}
CUSTOM_IMAGE_USERNAME=${REGISTRY_USERNAME:-${DOCKER_USERNAME:-codevertex}}
CUSTOM_IMAGE_NAME="${CUSTOM_IMAGE_USERNAME}/postgresql-pgvector"
CUSTOM_IMAGE_TAG="latest"
CUSTOM_IMAGE_FULL="${CUSTOM_IMAGE_REGISTRY}/${CUSTOM_IMAGE_NAME}:${CUSTOM_IMAGE_TAG}"

# Check if Docker is available
if command -v docker &> /dev/null; then
  log_info "Docker is available - checking custom PostgreSQL image..."
  
  # Check if Dockerfile exists
  if [ -f "${DOCKERFILE_DIR}/Dockerfile" ]; then
    log_info "Dockerfile found at: ${DOCKERFILE_DIR}/Dockerfile"
    
    # Calculate Dockerfile checksum
    DOCKERFILE_CHECKSUM=$(sha256sum "${DOCKERFILE_DIR}/Dockerfile" 2>/dev/null | cut -d' ' -f1 || md5sum "${DOCKERFILE_DIR}/Dockerfile" 2>/dev/null | cut -d' ' -f1 || echo "")
    CHECKSUM_FILE="/tmp/postgresql-pgvector-dockerfile-checksum"
    
    # Check if image exists remotely (if we have registry credentials)
    IMAGE_EXISTS_REMOTE=false
    IMAGE_NEEDS_BUILD=true
    
    if [[ -n "${REGISTRY_USERNAME:-}" && -n "${REGISTRY_PASSWORD:-}" ]]; then
      log_info "Checking if custom PostgreSQL image exists remotely..."
      if docker pull "${CUSTOM_IMAGE_FULL}" >/dev/null 2>&1; then
        IMAGE_EXISTS_REMOTE=true
        log_success "Custom PostgreSQL image found remotely: ${CUSTOM_IMAGE_FULL}"
        
        # Check if Dockerfile has changed
        if [ -f "${CHECKSUM_FILE}" ]; then
          OLD_CHECKSUM=$(cat "${CHECKSUM_FILE}" 2>/dev/null || echo "")
          if [ "${OLD_CHECKSUM}" == "${DOCKERFILE_CHECKSUM}" ] && [ -n "${DOCKERFILE_CHECKSUM}" ]; then
            log_info "Dockerfile unchanged - using existing image"
            IMAGE_NEEDS_BUILD=false
          else
            log_info "Dockerfile changed - will rebuild image"
            IMAGE_NEEDS_BUILD=true
          fi
        else
          log_info "No previous checksum found - will check/build image"
        fi
      else
        log_info "Custom PostgreSQL image not found remotely - will build"
        IMAGE_NEEDS_BUILD=true
      fi
    else
      log_info "Registry credentials not available - will attempt local build only"
      # Check if image exists locally
      if docker images "${CUSTOM_IMAGE_FULL}" --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -q "${CUSTOM_IMAGE_NAME}:${CUSTOM_IMAGE_TAG}"; then
        log_info "Custom PostgreSQL image found locally: ${CUSTOM_IMAGE_FULL}"
        IMAGE_NEEDS_BUILD=false
      else
        log_info "Custom PostgreSQL image not found locally - will build"
        IMAGE_NEEDS_BUILD=true
      fi
    fi
    
    # Build image if needed
    if [ "${IMAGE_NEEDS_BUILD}" == "true" ]; then
      log_info "Building custom PostgreSQL image with pgvector extension..."
      log_info "Image: ${CUSTOM_IMAGE_FULL}"
      
      if [[ -n "${REGISTRY_USERNAME:-}" && -n "${REGISTRY_PASSWORD:-}" ]]; then
        log_info "Logging in to Docker registry..."
        echo "${REGISTRY_PASSWORD}" | docker login "${CUSTOM_IMAGE_REGISTRY}" -u "${REGISTRY_USERNAME}" --password-stdin >/dev/null 2>&1 || {
          log_warning "Failed to login to Docker registry - continuing with local build only"
        }
      fi
      
      if docker build -t "${CUSTOM_IMAGE_FULL}" "${DOCKERFILE_DIR}" >/tmp/postgresql-pgvector-build.log 2>&1; then
        log_success "Custom PostgreSQL image built successfully"
        
        # Save checksum
        echo "${DOCKERFILE_CHECKSUM}" > "${CHECKSUM_FILE}" 2>/dev/null || true
        
        # Push to registry if credentials are available
        if [[ -n "${REGISTRY_USERNAME:-}" && -n "${REGISTRY_PASSWORD:-}" ]] && [[ "${IMAGE_EXISTS_REMOTE}" != "true" ]]; then
          log_info "Pushing custom PostgreSQL image to registry..."
          if docker push "${CUSTOM_IMAGE_FULL}" >/tmp/postgresql-pgvector-push.log 2>&1; then
            log_success "Custom PostgreSQL image pushed to registry: ${CUSTOM_IMAGE_FULL}"
          else
            log_warning "Failed to push custom PostgreSQL image to registry"
            log_warning "Image built locally but not pushed. Check /tmp/postgresql-pgvector-push.log for details"
          fi
        else
          log_info "Skipping push (already exists remotely or no credentials)"
        fi
      else
        log_error "Failed to build custom PostgreSQL image"
        log_error "Check /tmp/postgresql-pgvector-build.log for build errors"
        exit 1
      fi
    else
      log_success "Using existing custom PostgreSQL image: ${CUSTOM_IMAGE_FULL}"
    fi
  else
    log_error "Dockerfile not found at: ${DOCKERFILE_DIR}/Dockerfile"
    exit 1
  fi
else
  log_info "Docker not available - assuming custom image exists in registry or will be pulled by K8s"
  # We still define the image details so Helm can use them
  CUSTOM_IMAGE_FULL="${CUSTOM_IMAGE_REGISTRY}/${CUSTOM_IMAGE_NAME}:${CUSTOM_IMAGE_TAG}"
fi

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

  FORCE_DB_INSTALL=${FORCE_DB_INSTALL:-${FORCE_INSTALL:-false}}

  # Simplify password logic: POSTGRES_PASSWORD (GitHub secret) is the single source of truth
  if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
    # Use the same password for:
    #   - postgres superuser
    #   - admin_user (admin DB user)
    #   - all secret fields (postgres-password, password, admin-user-password)
    ADMIN_PASS="$POSTGRES_PASSWORD"
PG_HELM_ARGS+=(--set global.postgresql.auth.postgresPassword="$POSTGRES_PASSWORD")
    PG_HELM_ARGS+=(--set global.postgresql.auth.password="$ADMIN_PASS")
    log_info "PostgreSQL passwords configured from POSTGRES_PASSWORD (GitHub secret)"
    log_info "  - Superuser (postgres): ${#POSTGRES_PASSWORD} chars"
    log_info "  - Admin user (admin_user): ${#ADMIN_PASS} chars"
  else
    log_error "POSTGRES_PASSWORD required but not set"
    exit 1
  fi

  # Enforce custom image usage
  log_info "Using custom PostgreSQL image with pgvector: ${CUSTOM_IMAGE_FULL}"
  PG_HELM_ARGS+=(--set image.registry="${CUSTOM_IMAGE_REGISTRY}")
  PG_HELM_ARGS+=(--set image.repository="${CUSTOM_IMAGE_NAME}")
  PG_HELM_ARGS+=(--set image.tag="${CUSTOM_IMAGE_TAG}")
  # Enable custom image usage (bypass Bitnami security check for non-standard images)
  PG_HELM_ARGS+=(--set global.security.allowInsecureImages=true)

set +e
if helm -n "${NAMESPACE}" status postgresql >/dev/null 2>&1; then
  # Check if PostgreSQL is healthy
  IS_HEALTHY=$(kubectl -n "${NAMESPACE}" get statefulset postgresql -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "1" && echo "true" || echo "false")
  
  # If POSTGRES_PASSWORD is explicitly set, check if it matches current secret
  if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
    # Get current password from secret
    CURRENT_PG_PASS=$(kubectl -n "${NAMESPACE}" get secret postgresql -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d || true)
    
      # Only skip Helm upgrade when BOTH:
      #   - the password matches, and
      #   - PostgreSQL is already healthy
      # This prevents us from skipping upgrades when pods are failing
      if [[ "$CURRENT_PG_PASS" == "$POSTGRES_PASSWORD" && "${FORCE_DB_INSTALL}" != "true" && "$IS_HEALTHY" == "true" ]]; then
        log_success "PostgreSQL password unchanged and StatefulSet healthy - skipping upgrade"
      log_info "Current secret password matches provided POSTGRES_PASSWORD"
      HELM_PG_EXIT=0
    else
      log_warning "Password mismatch detected"
      log_info "Current password length: ${#CURRENT_PG_PASS} chars"
      log_info "New password length: ${#POSTGRES_PASSWORD} chars"
        log_warning "WARNING: Updating passwords requires pod restart and may take time"
      log_info "Checking if PostgreSQL is currently healthy..."
      
        # Check if PostgreSQL is currently running - if yes, sync DATABASE passwords + secret without Helm upgrade
      if kubectl get statefulset postgresql -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "1"; then
          log_info "PostgreSQL is healthy. Syncing superuser/admin passwords with POSTGRES_PASSWORD..."
          
          # Try to update actual database passwords first using the CURRENT_PG_PASS
          PG_POD=$(kubectl -n "${NAMESPACE}" get pod -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
          if [[ -n "$PG_POD" && -n "$CURRENT_PG_PASS" ]]; then
            # Update postgres superuser password
            kubectl -n "${NAMESPACE}" exec "$PG_POD" -- \
              env PGPASSWORD="$CURRENT_PG_PASS" \
              psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "ALTER USER postgres WITH PASSWORD '${POSTGRES_PASSWORD}';" \
              >/dev/null 2>&1 || log_warning "Failed to update postgres superuser password in database (will rely on secret/Helm sync)"

            # Update admin_user password (used for per‑service DB management)
            ADMIN_PASS="$POSTGRES_PASSWORD"
            kubectl -n "${NAMESPACE}" exec "$PG_POD" -- \
              env PGPASSWORD="$CURRENT_PG_PASS" \
              psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "ALTER USER admin_user WITH PASSWORD '${ADMIN_PASS}';" \
              >/dev/null 2>&1 || log_warning "Failed to update admin_user password in database"
          else
            log_warning "Could not determine PostgreSQL pod name or current password; skipping in‑database password sync"
          fi
          
          # Update the secret directly - keep ALL secret fields in sync with POSTGRES_PASSWORD
          ADMIN_PASS="$POSTGRES_PASSWORD"
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
    
    # Delete PVCs to ensure fresh data
    log_warning "Deleting PostgreSQL PVCs (cleanup mode)..."
    kubectl delete pvc -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql --wait=true --grace-period=0 --force 2>/dev/null || true
    kubectl delete pvc -n "${NAMESPACE}" -l app.kubernetes.io/instance=postgresql --wait=true --grace-period=0 --force 2>/dev/null || true
    
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
fi

# Function to fix orphaned Redis resources
fix_orphaned_redis_resources() {
  log_info "Checking for orphaned Redis resources..."
  

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

log_info "Using Redis password from environment (shared infra password)"
log_info "  - Redis password: ${#REDIS_PASSWORD} chars"
REDIS_HELM_ARGS+=(--set global.redis.password="$REDIS_PASSWORD")

# Always fix orphaned Redis resources before any Helm operation (install or upgrade)
fix_orphaned_redis_resources

# Use stable major version tags (Redis 7 is current stable)
REDIS_HELM_ARGS+=(--set image.tag=7)
REDIS_HELM_ARGS+=(--set metrics.image.tag=1.58)  # redis-exporter stable version

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
  
  # Only clean up orphaned resources if cleanup mode is active
  if is_cleanup_mode; then
    log_info "Cleanup mode active - checking for orphaned Redis resources..."
    
    # Check for StatefulSets first (these recreate resources)
    STATEFULSETS=$(kubectl get statefulset -n "${NAMESPACE}" -l app.kubernetes.io/name=redis -o name 2>/dev/null || true)
    # Also check for redis-master specifically
    if kubectl get statefulset redis-master -n "${NAMESPACE}" >/dev/null 2>&1; then
      STATEFULSETS="${STATEFULSETS} statefulset/redis-master"
    fi
    
    if [ -n "$STATEFULSETS" ]; then
      log_warning "Found Redis StatefulSet - deleting (cleanup mode)..."
      # Force delete to ensure PVCs are released
      kubectl delete statefulset -n "${NAMESPACE}" -l app.kubernetes.io/name=redis --wait=true --grace-period=0 --force 2>/dev/null || true
      kubectl delete statefulset redis-master -n "${NAMESPACE}" --wait=true --grace-period=0 --force 2>/dev/null || true
      kubectl delete statefulset redis-replicas -n "${NAMESPACE}" --wait=true --grace-period=0 --force 2>/dev/null || true
    fi
    
    # Delete PVCs to ensure fresh data
    log_warning "Deleting Redis PVCs (cleanup mode)..."
    kubectl delete pvc -n "${NAMESPACE}" -l app.kubernetes.io/name=redis --wait=true --grace-period=0 --force 2>/dev/null || true
    kubectl delete pvc -n "${NAMESPACE}" -l app.kubernetes.io/instance=redis --wait=true --grace-period=0 --force 2>/dev/null || true
    
    # Check for failed/pending Helm release
    if helm -n "${NAMESPACE}" list -q | grep -q "^redis$" 2>/dev/null; then
      log_warning "Found existing Helm release - checking for stuck operation..."
      
      # Fix stuck Helm operation before uninstalling
      fix_stuck_helm_operation "redis" "${NAMESPACE}"
      
      log_warning "Uninstalling Helm release (cleanup mode)..."
      helm uninstall redis -n "${NAMESPACE}" --wait 2>/dev/null || true
      sleep 5
    fi
    
    # Clean up orphaned resources
    ORPHANED_RESOURCES=$(kubectl get networkpolicy,configmap,service -n "${NAMESPACE}" -l app.kubernetes.io/name=redis 2>/dev/null | grep -v NAME || true)
    if [ -n "$ORPHANED_RESOURCES" ]; then
      log_warning "Cleaning up orphaned resources (cleanup mode)..."
      kubectl delete pod,statefulset,service,networkpolicy,configmap -n "${NAMESPACE}" -l app.kubernetes.io/name=redis --wait=true --grace-period=0 --force 2>/dev/null || true
      sleep 10
    fi
  else
    log_info "Cleanup mode inactive - checking for existing resources to update..."
  fi
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

exit 0
