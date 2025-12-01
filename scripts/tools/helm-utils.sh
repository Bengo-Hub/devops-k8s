#!/bin/bash
# Helm Utilities - Reusable functions for Helm operations
# Handles stuck operations, orphaned resources, and health checks
# Source this file: source "${SCRIPT_DIR}/../tools/helm-utils.sh"

# =============================================================================
# STUCK HELM OPERATION FIXES
# =============================================================================

# Fix stuck Helm operations (pending-upgrade/install/rollback)
# Cleans up pending Helm secrets that can block operations
# 
# Usage: fix_stuck_helm_operation <release_name> [namespace]
# Returns: 0 if stuck operation was fixed, 1 if no stuck operation found
fix_stuck_helm_operation() {
  local release_name=$1
  local namespace=${2:-${NAMESPACE:-default}}
  
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

# =============================================================================
# ORPHANED RESOURCE MANAGEMENT
# =============================================================================

# Fix orphaned resources with invalid Helm ownership metadata (generic)
#
# This function handles resources that exist but lack proper Helm annotations,
# which can cause "invalid ownership metadata" errors during Helm operations.
#
# Usage: fix_orphaned_resources <release_name> <namespace> [resource_types...]
# Example: fix_orphaned_resources "postgresql" "infra" "secrets" "services"
#
# If no resource types specified, checks common types:
# - poddisruptionbudgets, configmaps, services, secrets, serviceaccounts
# - networkpolicies, servicemonitors, statefulsets
fix_orphaned_resources() {
  local release_name=$1
  local namespace=${2:-${NAMESPACE:-default}}
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

# =============================================================================
# HELM RELEASE HEALTH CHECKS
# =============================================================================

# Check if Helm release and its main resource are healthy
#
# Usage: check_helm_release_health <release_name> <namespace> [resource_type] [resource_name]
# Returns: 0 if healthy, 1 if unhealthy or not found
# Outputs: "healthy", "unhealthy", or "not_found" to stdout
check_helm_release_health() {
  local release_name=$1
  local namespace=${2:-${NAMESPACE:-default}}
  local resource_type=${3:-statefulset}
  local resource_name=${4:-$release_name}
  
  # Check if Helm release exists
  if ! helm -n "${namespace}" status "${release_name}" >/dev/null 2>&1; then
    echo "not_found"
    return 1
  fi
  
  # Check if main resource is ready
  case "$resource_type" in
    statefulset)
      local ready=$(kubectl -n "${namespace}" get statefulset "${resource_name}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
      if [[ "$ready" =~ ^[0-9]+$ ]] && [ "$ready" -ge 1 ]; then
        echo "healthy"
        return 0
      else
        echo "unhealthy"
        return 1
      fi
      ;;
    deployment)
      local ready=$(kubectl -n "${namespace}" get deployment "${resource_name}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
      if [[ "$ready" =~ ^[0-9]+$ ]] && [ "$ready" -ge 1 ]; then
        echo "healthy"
        return 0
      else
        echo "unhealthy"
        return 1
      fi
      ;;
    *)
      log_warning "Unsupported resource type: $resource_type"
      echo "unknown"
      return 1
      ;;
  esac
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f fix_stuck_helm_operation
export -f fix_orphaned_resources
export -f check_helm_release_health
