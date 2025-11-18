#!/bin/bash
# Common functions for installation scripts
# Centralizes cleanup logic and resource management

# Check if cleanup mode is active
# If cleanup is enabled, scripts should delete and recreate resources
# If cleanup is disabled, scripts should update existing resources or skip
is_cleanup_mode() {
    local cleanup_mode=${ENABLE_CLEANUP:-true}
    [ "$cleanup_mode" = "true" ]
}

# Check if resource exists and should be deleted/recreated based on cleanup mode
# Returns 0 if should delete/recreate, 1 if should update/skip
should_delete_and_recreate() {
    local resource_type=$1
    local resource_name=$2
    local namespace=${3:-default}
    
    if is_cleanup_mode; then
        # Cleanup mode: delete and recreate
        return 0
    else
        # Non-cleanup mode: check if resource exists
        if kubectl get "$resource_type" "$resource_name" -n "$namespace" >/dev/null 2>&1; then
            # Resource exists - update instead of delete
            return 1
        else
            # Resource doesn't exist - safe to create
            return 0
        fi
    fi
}

# Safely delete resource only if cleanup mode is active
# Otherwise, skip deletion
safe_delete_resource() {
    local resource_type=$1
    local resource_name=$2
    local namespace=${3:-default}
    
    if is_cleanup_mode; then
        echo "Cleanup mode active - deleting $resource_type/$resource_name in namespace $namespace"
        kubectl delete "$resource_type" "$resource_name" -n "$namespace" --wait=true --grace-period=0 2>/dev/null || true
        return 0
    else
        echo "Cleanup mode inactive - skipping deletion of $resource_type/$resource_name"
        return 1
    fi
}

# Check if Helm release exists and handle based on cleanup mode
# Returns: "upgrade" if should upgrade, "install" if should install fresh, "skip" if should skip
helm_release_action() {
    local release_name=$1
    local namespace=${2:-default}
    
    if ! helm -n "$namespace" status "$release_name" >/dev/null 2>&1; then
        # Release doesn't exist - always install
        echo "install"
        return
    fi
    
    if is_cleanup_mode; then
        # Cleanup mode: uninstall and reinstall
        echo "reinstall"
    else
        # Non-cleanup mode: upgrade existing
        echo "upgrade"
    fi
}

