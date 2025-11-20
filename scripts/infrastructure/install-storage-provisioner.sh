#!/bin/bash
set -euo pipefail

# Install local-path storage provisioner for Kubernetes
# Required for PersistentVolumeClaims on bare-metal/VPS installations

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tools/common.sh"

log_section "Installing Storage Provisioner"

# Pre-flight checks
check_kubectl

# Check if local-path-provisioner is running
if kubectl get pods -n local-path-storage -l app=local-path-provisioner --field-selector=status.phase=Running --no-headers 2>/dev/null | grep -q Running; then
  log_success "local-path-provisioner is already running"
  # Check if default storage class exists
  if kubectl get storageclass 2>/dev/null | grep -q "(default)"; then
    log_success "Default storage class already configured"
    kubectl get storageclass
    exit 0
  else
    log_info "Storage provisioner running but no default storage class. Setting local-path as default..."
    kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>/dev/null || true
    kubectl get storageclass
    exit 0
  fi
fi

# Check if any storage class already exists (but provisioner not running)
if kubectl get storageclass 2>/dev/null | grep -q "(default)"; then
  log_warning "Default storage class exists but provisioner pod not running. Reinstalling..."
fi

# Install local-path-provisioner
log_info "Installing local-path storage provisioner..."
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml

# Wait for provisioner to be ready
wait_for_pods "local-path-storage" "app=local-path-provisioner" 120

# Set as default storage class
log_info "Setting local-path as default storage class..."
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Verification
log_section "Storage Provisioner Installation Complete"
log_info "Available Storage Classes:"
kubectl get storageclass
log_success "local-path storage provisioner is ready"
log_info "PersistentVolumeClaims will now be automatically provisioned on the local disk"

