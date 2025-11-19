#!/bin/bash
# Common functions for installation scripts
# Centralizes cleanup logic, resource management, logging, and utilities
# Source this file in your scripts: source "${SCRIPT_DIR}/../tools/common.sh"

# =============================================================================
# COLOR DEFINITIONS
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_step() {
    echo -e "${PURPLE}[STEP]${NC} $1" >&2
}

log_section() {
    echo -e "${CYAN}==========================================${NC}" >&2
    echo -e "${CYAN}$1${NC}" >&2
    echo -e "${CYAN}==========================================${NC}" >&2
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

# Check if kubectl is installed and cluster is accessible
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl command not found. Aborting."
        exit 1
    fi
    
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "Cannot connect to cluster. Ensure KUBECONFIG is set. Aborting."
        exit 1
    fi
    
    log_success "kubectl configured and cluster reachable"
}

# Check if Helm is installed, install if missing
ensure_helm() {
    if ! command -v helm &> /dev/null; then
        log_warning "Helm not found. Installing via snap..."
        if command -v snap &> /dev/null; then
            sudo snap install helm --classic 2>/dev/null || {
                log_warning "snap not available. Installing Helm via script..."
                curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
            }
            log_success "Helm installed"
        else
            log_warning "snap not available. Installing Helm via script..."
            curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
            log_success "Helm installed"
        fi
    else
        log_success "Helm already installed"
    fi
}

# Check if jq is installed, install if missing
ensure_jq() {
    if ! command -v jq &> /dev/null; then
        log_warning "jq command not found. Attempting to install..."
        if command -v apt-get &> /dev/null; then
            apt-get update -y >/dev/null 2>&1 && apt-get install -y jq >/dev/null 2>&1 || \
            sudo apt-get update -y >/dev/null 2>&1 && sudo apt-get install -y jq >/dev/null 2>&1 || \
            log_error "Failed to install jq. Some operations may fail."
        elif command -v yum &> /dev/null; then
            yum install -y jq >/dev/null 2>&1 || sudo yum install -y jq >/dev/null 2>&1 || \
            log_error "Failed to install jq. Some operations may fail."
        fi
    fi
}

# Check if default storage class exists, install if missing
ensure_storage_class() {
    local script_dir="${1:-}"
    
    if ! kubectl get storageclass 2>/dev/null | grep -q "(default)"; then
        log_warning "No default storage class found. Installing local-path provisioner..."
        if [ -n "$script_dir" ] && [ -f "${script_dir}/../infrastructure/install-storage-provisioner.sh" ]; then
            "${script_dir}/../infrastructure/install-storage-provisioner.sh"
        elif [ -f "scripts/infrastructure/install-storage-provisioner.sh" ]; then
            ./scripts/infrastructure/install-storage-provisioner.sh
        else
            log_error "Storage provisioner script not found"
            return 1
        fi
    else
        log_success "Default storage class available"
    fi
}

# =============================================================================
# HELM REPOSITORY MANAGEMENT
# =============================================================================

# Add Helm repository if not already added
add_helm_repo() {
    local repo_name=$1
    local repo_url=$2
    
    if helm repo list 2>/dev/null | grep -q "^${repo_name}"; then
        log_info "Helm repository '${repo_name}' already exists"
    else
        log_info "Adding Helm repository: ${repo_name}"
        helm repo add "${repo_name}" "${repo_url}" >/dev/null 2>&1 || true
    fi
    
    log_info "Updating Helm repositories..."
    helm repo update >/dev/null 2>&1 || true
}

# =============================================================================
# NAMESPACE MANAGEMENT
# =============================================================================

# Create namespace if it doesn't exist
ensure_namespace() {
    local namespace=$1
    
    if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
        log_success "Namespace '${namespace}' already exists"
        return 0
    else
        log_info "Creating namespace '${namespace}'..."
        kubectl create namespace "${namespace}" 2>/dev/null || {
            log_error "Failed to create namespace '${namespace}'"
            return 1
        }
        log_success "Namespace '${namespace}' created"
        return 0
    fi
}

# =============================================================================
# CLEANUP MODE FUNCTIONS
# =============================================================================

# Check if cleanup mode is active
# If cleanup is enabled, scripts should delete and recreate resources
# If cleanup is disabled, scripts should update existing resources or skip
is_cleanup_mode() {
    local cleanup_mode=${ENABLE_CLEANUP:-false}
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
        log_info "Cleanup mode active - deleting $resource_type/$resource_name in namespace $namespace"
        kubectl delete "$resource_type" "$resource_name" -n "$namespace" --wait=true --grace-period=0 2>/dev/null || true
        return 0
    else
        log_info "Cleanup mode inactive - skipping deletion of $resource_type/$resource_name"
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

# =============================================================================
# HELM INSTALLATION HELPERS
# =============================================================================

# Install or upgrade Helm release based on cleanup mode
helm_install_or_upgrade() {
    local release_name=$1
    local chart=$2
    local namespace=$3
    shift 3
    local helm_args=("$@")
    
    local action=$(helm_release_action "$release_name" "$namespace")
    
    case "$action" in
        "reinstall")
            log_info "Cleanup mode: Uninstalling existing release '$release_name'..."
            helm uninstall "$release_name" -n "$namespace" --wait 2>/dev/null || true
            log_info "Installing fresh release '$release_name'..."
            helm install "$release_name" "$chart" \
                -n "$namespace" \
                "${helm_args[@]}" \
                --timeout=10m \
                --wait
            ;;
        "upgrade")
            log_info "Upgrading existing release '$release_name'..."
            helm upgrade "$release_name" "$chart" \
                -n "$namespace" \
                "${helm_args[@]}" \
                --timeout=10m \
                --wait
            ;;
        "install")
            log_info "Installing new release '$release_name'..."
            helm install "$release_name" "$chart" \
                -n "$namespace" \
                "${helm_args[@]}" \
                --timeout=10m \
                --wait
            ;;
    esac
}

# =============================================================================
# WAIT FUNCTIONS
# =============================================================================

# Wait for resource to be ready
wait_for_resource() {
    local resource_type=$1
    local resource_name=$2
    local namespace=$3
    local timeout=${4:-300}
    local condition=${5:-condition=ready}
    
    log_info "Waiting for $resource_type/$resource_name in namespace $namespace to be ready..."
    if kubectl wait --for="$condition" "$resource_type/$resource_name" -n "$namespace" --timeout="${timeout}s" 2>/dev/null; then
        log_success "$resource_type/$resource_name is ready"
        return 0
    else
        log_warning "$resource_type/$resource_name not ready within ${timeout}s, continuing..."
        return 1
    fi
}

# Wait for pods with label selector
wait_for_pods() {
    local namespace=$1
    local selector=$2
    local timeout=${3:-300}
    
    log_info "Waiting for pods with selector '$selector' in namespace $namespace..."
    if kubectl wait --for=condition=ready pod -l "$selector" -n "$namespace" --timeout="${timeout}s" 2>/dev/null; then
        log_success "Pods with selector '$selector' are ready"
        return 0
    else
        log_warning "Pods with selector '$selector' not ready within ${timeout}s, continuing..."
        return 1
    fi
}

# Wait for StatefulSet to be ready
wait_for_statefulset() {
    local statefulset_name=$1
    local namespace=$2
    local timeout=${3:-600}
    
    log_info "Waiting for StatefulSet $statefulset_name in namespace $namespace..."
    if kubectl -n "$namespace" rollout status statefulset/"$statefulset_name" --timeout="${timeout}s" 2>/dev/null; then
        log_success "StatefulSet $statefulset_name is ready"
        return 0
    else
        log_warning "StatefulSet $statefulset_name not ready within ${timeout}s, continuing..."
        return 1
    fi
}

# =============================================================================
# CLUSTER HEALTH CHECKS
# =============================================================================

# Check cluster readiness
check_cluster_health() {
    log_info "Checking cluster health..."
    
    local node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    local ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready" || echo "0")
    
    log_info "Nodes: ${ready_nodes}/${node_count} ready"
    
    if [ "$ready_nodes" -eq 0 ]; then
        log_warning "No ready nodes found!"
        kubectl get nodes || true
        log_warning "Cluster may not be able to schedule pods. Continuing anyway..."
        return 1
    fi
    
    # Check for Pending pods
    local pending_pods=$(kubectl get pods -A --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
    if [ "$pending_pods" -gt 0 ]; then
        log_warning "Found ${pending_pods} Pending pods in cluster"
        log_warning "This may indicate resource constraints or storage issues"
        kubectl get pods -A --field-selector=status.phase=Pending 2>/dev/null | head -10 || true
    fi
    
    return 0
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Get script directory (works even when script is sourced)
get_script_dir() {
    local source="${BASH_SOURCE[0]}"
    while [ -h "$source" ]; do
        local dir="$(cd -P "$(dirname "$source")" && pwd)"
        source="$(readlink "$source")"
        [[ $source != /* ]] && source="$dir/$source"
    done
    echo "$(cd -P "$(dirname "$source")" && pwd)"
}

# Generate random password
generate_password() {
    local length=${1:-32}
    openssl rand -base64 "$length" | tr -d "=+/" | cut -c1-"$length"
}

# Base64 encode (works on both Linux and macOS)
base64_encode() {
    local input="$1"
    if command -v base64 &> /dev/null; then
        echo "$input" | base64 -w 0 2>/dev/null || echo "$input" | base64
    else
        log_error "base64 command not found"
        return 1
    fi
}

# Base64 decode
base64_decode() {
    local input="$1"
    if command -v base64 &> /dev/null; then
        echo "$input" | base64 -d 2>/dev/null
    else
        log_error "base64 command not found"
        return 1
    fi
}

# =============================================================================
# CERT-MANAGER HELPERS
# =============================================================================

# Check if cert-manager is installed
check_cert_manager() {
    if kubectl get namespace cert-manager >/dev/null 2>&1; then
        log_success "cert-manager already installed"
        return 0
    else
        log_warning "cert-manager not found"
        return 1
    fi
}

# Ensure cert-manager is installed
ensure_cert_manager() {
    local script_dir="${1:-}"
    
    if ! check_cert_manager; then
        log_warning "Installing cert-manager first..."
        if [ -n "$script_dir" ] && [ -f "${script_dir}/../infrastructure/install-cert-manager.sh" ]; then
            "${script_dir}/../infrastructure/install-cert-manager.sh"
        elif [ -f "scripts/infrastructure/install-cert-manager.sh" ]; then
            ./scripts/infrastructure/install-cert-manager.sh
        else
            log_error "cert-manager installation script not found"
            return 1
        fi
    fi
}

# =============================================================================
# EXPORT FUNCTIONS FOR USE IN SCRIPTS
# =============================================================================

# Export all functions so they're available when sourced
export -f log_info log_success log_warning log_error log_step log_section
export -f check_kubectl ensure_helm ensure_jq ensure_storage_class
export -f add_helm_repo ensure_namespace
export -f is_cleanup_mode should_delete_and_recreate safe_delete_resource helm_release_action
export -f helm_install_or_upgrade
export -f wait_for_resource wait_for_pods wait_for_statefulset
export -f check_cluster_health
export -f get_script_dir generate_password base64_encode base64_decode
export -f check_cert_manager ensure_cert_manager
