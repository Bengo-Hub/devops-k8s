#!/bin/bash
# Database Installation Utilities - Reusable functions for database installations
# Handles PostgreSQL, Redis, and other database installations with common patterns
# Source this file: source "${SCRIPT_DIR}/../tools/database-utils.sh"

# =============================================================================
# DATABASE HELM ARGUMENT BUILDERS
# =============================================================================

# Build PostgreSQL Helm arguments
# Usage: build_postgres_helm_args <namespace> <monitoring_namespace> <values_file> [additional_args...]
build_postgres_helm_args() {
  local namespace=$1
  local monitoring_ns=$2
  local values_file=$3
  shift 3
  local additional_args=("$@")
  
  local helm_args=()
  helm_args+=(-f "$values_file")
  
  # Check if Prometheus Operator CRDs exist (for ServiceMonitor)
  if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    log_info "Prometheus Operator CRDs detected - ServiceMonitor will be enabled"
    helm_args+=(--set metrics.serviceMonitor.enabled=true --set metrics.serviceMonitor.namespace="$monitoring_ns")
  else
    log_info "Prometheus Operator CRDs not found - ServiceMonitor disabled"
  fi
  
  # Add any additional arguments
  helm_args+=("${additional_args[@]}")
  
  # Return via global variable (bash limitation)
  POSTGRES_HELM_ARGS=("${helm_args[@]}")
}

# Build Redis Helm arguments
# Usage: build_redis_helm_args <namespace> <monitoring_namespace> <values_file> [additional_args...]
build_redis_helm_args() {
  local namespace=$1
  local monitoring_ns=$2
  local values_file=$3
  shift 3
  local additional_args=("$@")
  
  local helm_args=()
  helm_args+=(-f "$values_file")
  
  # Check if ServiceMonitor CRD exists (Prometheus Operator)
  if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    log_info "ServiceMonitor enabled for Redis metrics (namespace: ${monitoring_ns})"
    helm_args+=(--set metrics.serviceMonitor.enabled=true --set metrics.serviceMonitor.namespace="$monitoring_ns")
  else
    log_info "ServiceMonitor CRD not found - disabling Redis metrics ServiceMonitor"
    helm_args+=(--set metrics.serviceMonitor.enabled=false)
  fi
  
  # Add any additional arguments
  helm_args+=("${additional_args[@]}")
  
  # Return via global variable
  REDIS_HELM_ARGS=("${helm_args[@]}")
}

# =============================================================================
# DATABASE HEALTH CHECKS
# =============================================================================

# Check if database StatefulSet is healthy
# Usage: check_database_health <statefulset_name> <namespace>
# Returns: "true" if healthy, "false" otherwise
check_database_health() {
  local statefulset_name=$1
  local namespace=$2
  
  local ready=$(kubectl -n "$namespace" get statefulset "$statefulset_name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [[ "$ready" =~ ^[0-9]+$ ]] && [ "$ready" -ge 1 ]; then
    echo "true"
  else
    echo "false"
  fi
}

# =============================================================================
# PASSWORD MANAGEMENT
# =============================================================================

# Sync PostgreSQL password in database and secret
# Usage: sync_postgres_password <namespace> <new_password> <current_password>
sync_postgres_password() {
  local namespace=$1
  local new_password=$2
  local current_password=${3:-}
  
  # Get PostgreSQL pod
  local pg_pod=$(kubectl -n "$namespace" get pod -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  
  if [[ -z "$pg_pod" ]]; then
    log_warning "Could not find PostgreSQL pod - skipping in-database password sync"
    return 1
  fi
  
  # If current password is provided, use it to update database passwords
  if [[ -n "$current_password" ]]; then
    log_info "Updating PostgreSQL passwords in database..."
    
    # Update postgres superuser password
    kubectl -n "$namespace" exec "$pg_pod" -- \
      env PGPASSWORD="$current_password" \
      psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "ALTER USER postgres WITH PASSWORD '${new_password}';" \
      >/dev/null 2>&1 || log_warning "Failed to update postgres superuser password in database"
    
    # Update admin_user password
    kubectl -n "$namespace" exec "$pg_pod" -- \
      env PGPASSWORD="$current_password" \
      psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "ALTER USER admin_user WITH PASSWORD '${new_password}';" \
      >/dev/null 2>&1 || log_warning "Failed to update admin_user password in database"
  fi
  
  # Update the secret
  log_info "Updating PostgreSQL secret..."
  kubectl create secret generic postgresql \
    --from-literal=postgres-password="$new_password" \
    --from-literal=password="$new_password" \
    --from-literal=admin-user-password="$new_password" \
    -n "$namespace" \
    --dry-run=client -o yaml | kubectl apply -f -
  
  log_success "PostgreSQL password synced in secret"
}

# Get current password from secret
# Usage: get_secret_password <secret_name> <password_key> <namespace>
get_secret_password() {
  local secret_name=$1
  local password_key=$2
  local namespace=$3
  
  kubectl -n "$namespace" get secret "$secret_name" -o jsonpath="{.data.${password_key}}" 2>/dev/null | base64 -d || echo ""
}

# =============================================================================
# DATABASE INSTALLATION/UPGRADE LOGIC
# =============================================================================

# Handle existing database Helm release (upgrade or skip)
# Usage: handle_existing_database <release_name> <statefulset_name> <namespace> <chart> <version> <helm_args_array> <password_env_var> <force_install>
# Returns: exit code via global variable HELM_EXIT_CODE
handle_existing_database() {
  local release_name=$1
  local statefulset_name=$2
  local namespace=$3
  local chart=$4
  local version=$5
  local helm_args_ref=$6  # Name of array variable
  local password_env_var=$7
  local force_install=${8:-false}
  
  # Dereference array
  local -n helm_args=$helm_args_ref
  
  # Check if database is healthy
  local is_healthy=$(check_database_health "$statefulset_name" "$namespace")
  
  # Get password from environment if provided
  local new_password=""
  if [[ -n "${!password_env_var:-}" ]]; then
    new_password="${!password_env_var}"
  fi
  
  # If password is provided, check if it matches current secret
  if [[ -n "$new_password" ]]; then
    local secret_name="$release_name"
    local password_key="postgres-password"
    if [[ "$release_name" == "redis" ]]; then
      password_key="redis-password"
    fi
    
    local current_pass=$(get_secret_password "$secret_name" "$password_key" "$namespace")
    
    # Only skip Helm upgrade when BOTH:
    #   - the password matches, and
    #   - database is already healthy
    if [[ "$current_pass" == "$new_password" && "$force_install" != "true" && "$is_healthy" == "true" ]]; then
      log_success "${release_name} password unchanged and StatefulSet healthy - skipping upgrade"
      HELM_EXIT_CODE=0
      return 0
    fi
    
    # Password mismatch or unhealthy - need to update
    if [[ "$is_healthy" == "true" && "$release_name" == "postgresql" ]]; then
      log_info "${release_name} is healthy. Syncing password..."
      sync_postgres_password "$namespace" "$new_password" "$current_pass"
      HELM_EXIT_CODE=0
      return 0
    fi
  elif [[ "$is_healthy" == "true" ]]; then
    log_success "${release_name} already installed and healthy - skipping"
    HELM_EXIT_CODE=0
    return 0
  fi
  
  # Need to upgrade
  log_warning "${release_name} exists but needs update; checking for stuck operation..."
  fix_stuck_helm_operation "$release_name" "$namespace"
  
  if [[ -n "$version" ]]; then
    helm upgrade "$release_name" "$chart" \
      --version "$version" \
      -n "$namespace" \
      "${helm_args[@]}" \
      --timeout=10m \
      --wait=false 2>&1 | tee "/tmp/helm-${release_name}-install.log"
  else
    helm upgrade "$release_name" "$chart" \
      -n "$namespace" \
      "${helm_args[@]}" \
      --timeout=10m \
      --wait=false 2>&1 | tee "/tmp/helm-${release_name}-install.log"
  fi
  HELM_EXIT_CODE=${PIPESTATUS[0]}
}

# Handle fresh database installation
# Usage: handle_fresh_database_install <release_name> <statefulset_name> <namespace> <chart> <version> <helm_args_array> <cleanup_mode>
handle_fresh_database_install() {
  local release_name=$1
  local statefulset_name=$2
  local namespace=$3
  local chart=$4
  local version=$5
  local helm_args_ref=$6  # Name of array variable
  local cleanup_mode=${7:-false}
  
  # Dereference array
  local -n helm_args=$helm_args_ref
  
  log_info "${release_name} not found; installing fresh"
  
  # Cleanup mode handling
  if [[ "$cleanup_mode" == "true" ]]; then
    log_info "Cleanup mode active - checking for orphaned ${release_name} resources..."
    
    # Delete StatefulSets
    local statefulsets=$(kubectl get statefulset -n "$namespace" -l app.kubernetes.io/name="$release_name" -o name 2>/dev/null || true)
    if [[ "$release_name" == "redis" ]]; then
      # Redis has specific StatefulSet names
      if kubectl get statefulset redis-master -n "$namespace" >/dev/null 2>&1; then
        statefulsets="${statefulsets} statefulset/redis-master"
      fi
      if kubectl get statefulset redis-replicas -n "$namespace" >/dev/null 2>&1; then
        statefulsets="${statefulsets} statefulset/redis-replicas"
      fi
    fi
    
    if [[ -n "$statefulsets" ]]; then
      log_warning "Found ${release_name} StatefulSet - deleting (cleanup mode)..."
      kubectl delete statefulset -n "$namespace" -l app.kubernetes.io/name="$release_name" --wait=true --grace-period=0 --force 2>/dev/null || true
      if [[ "$release_name" == "redis" ]]; then
        kubectl delete statefulset redis-master redis-replicas -n "$namespace" --wait=true --grace-period=0 --force 2>/dev/null || true
      fi
    fi
    
    # Delete PVCs
    log_warning "Deleting ${release_name} PVCs (cleanup mode)..."
    kubectl delete pvc -n "$namespace" -l app.kubernetes.io/name="$release_name" --wait=true --grace-period=0 --force 2>/dev/null || true
    kubectl delete pvc -n "$namespace" -l app.kubernetes.io/instance="$release_name" --wait=true --grace-period=0 --force 2>/dev/null || true
    
    # Uninstall Helm release if exists
    if helm -n "$namespace" list -q | grep -q "^${release_name}$" 2>/dev/null; then
      log_warning "Found existing Helm release - checking for stuck operation..."
      fix_stuck_helm_operation "$release_name" "$namespace"
      log_warning "Uninstalling Helm release (cleanup mode)..."
      helm uninstall "$release_name" -n "$namespace" --wait 2>/dev/null || true
      sleep 5
    fi
    
    # Clean up orphaned resources
    local orphaned=$(kubectl get networkpolicy,configmap,service -n "$namespace" -l app.kubernetes.io/name="$release_name" 2>/dev/null | grep -v NAME || true)
    if [[ -n "$orphaned" ]]; then
      log_warning "Cleaning up orphaned resources (cleanup mode)..."
      kubectl delete pod,statefulset,service,networkpolicy,configmap -n "$namespace" -l app.kubernetes.io/name="$release_name" --wait=true --grace-period=0 --force 2>/dev/null || true
      sleep 10
    fi
  else
    log_info "Cleanup mode inactive - checking for existing resources to update..."
    fix_orphaned_resources "$release_name" "$namespace" || true
    
    # If StatefulSet exists but Helm release doesn't, try upgrade
    if kubectl get statefulset "$statefulset_name" -n "$namespace" >/dev/null 2>&1; then
      log_warning "${release_name} StatefulSet exists but Helm release missing - attempting upgrade..."
      if [[ -n "$version" ]]; then
        helm upgrade "$release_name" "$chart" \
          --version "$version" \
          -n "$namespace" \
          "${helm_args[@]}" \
          --timeout=10m \
          --wait 2>&1 | tee "/tmp/helm-${release_name}-install.log"
      else
        helm upgrade "$release_name" "$chart" \
          -n "$namespace" \
          "${helm_args[@]}" \
          --timeout=10m \
          --wait 2>&1 | tee "/tmp/helm-${release_name}-install.log"
      fi
      HELM_EXIT_CODE=${PIPESTATUS[0]}
      if [[ $HELM_EXIT_CODE -eq 0 ]]; then
        log_success "${release_name} upgraded"
        return 0
      else
        log_warning "${release_name} upgrade failed. Falling back to fresh install..."
      fi
    fi
  fi
  
  # Install fresh
  log_info "Installing ${release_name}..."
  fix_orphaned_resources "$release_name" "$namespace" || true
  
  if [[ -n "$version" ]]; then
    helm install "$release_name" "$chart" \
      --version "$version" \
      -n "$namespace" \
      "${helm_args[@]}" \
      --timeout=10m \
      --wait=false 2>&1 | tee "/tmp/helm-${release_name}-install.log"
  else
    helm install "$release_name" "$chart" \
      -n "$namespace" \
      "${helm_args[@]}" \
      --timeout=10m \
      --wait=false 2>&1 | tee "/tmp/helm-${release_name}-install.log"
  fi
  HELM_EXIT_CODE=${PIPESTATUS[0]}
}

# Verify database installation
# Usage: verify_database_installation <release_name> <statefulset_name> <namespace>
verify_database_installation() {
  local release_name=$1
  local statefulset_name=$2
  local namespace=$3
  
  sleep 10
  
  local ready=$(kubectl get statefulset "$statefulset_name" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
  local replicas=$(kubectl get statefulset "$statefulset_name" -n "$namespace" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "")
  
  ready=${ready:-0}
  replicas=${replicas:-0}
  
  log_info "${release_name} StatefulSet: ${ready}/${replicas} replicas ready"
  
  if [[ "$ready" =~ ^[0-9]+$ ]] && [ "$ready" -ge 1 ]; then
    log_success "${release_name} is actually running! Continuing..."
    return 0
  else
    log_error "${release_name} installation/upgrade failed"
    log_warning "=== Helm output (last 50 lines) ==="
    tail -50 "/tmp/helm-${release_name}-install.log" 2>/dev/null || true
    log_warning "=== Pod status ==="
    kubectl get pods -n "$namespace" -l app.kubernetes.io/name="$release_name" 2>/dev/null || true
    log_warning "=== Pod events ==="
    kubectl get events -n "$namespace" --sort-by='.lastTimestamp' 2>/dev/null | grep -i "$release_name" | tail -10 || true
    
    # Check for common issues
    log_warning "=== Diagnosing issues ==="
    local pending_pvcs=$(kubectl get pvc -n "$namespace" -l app.kubernetes.io/name="$release_name" --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
    if [[ "$pending_pvcs" -gt 0 ]]; then
      log_error "Found ${pending_pvcs} Pending PVCs - storage may not be available"
    fi
    
    return 1
  fi
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f build_postgres_helm_args build_redis_helm_args
export -f check_database_health
export -f sync_postgres_password get_secret_password
export -f handle_existing_database handle_fresh_database_install verify_database_installation

