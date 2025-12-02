#!/usr/bin/env bash
# RabbitMQ installation script for shared infrastructure
# Installs RabbitMQ in infra namespace as shared infrastructure
# Part of devops-k8s infrastructure provisioning

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tools/common.sh" || {
  echo "ERROR: Failed to source common.sh - required for logging and utilities"
  exit 1
}
source "${SCRIPT_DIR}/../tools/helm-utils.sh" || {
  echo "ERROR: Failed to source helm-utils.sh - required for Helm operations"
  exit 1
}

# Configuration
NAMESPACE=${RABBITMQ_NAMESPACE:-infra}
RABBITMQ_USERNAME=${RABBITMQ_USERNAME:-user}
FORCE_RABBITMQ_INSTALL=${FORCE_RABBITMQ_INSTALL:-${FORCE_INSTALL:-false}}

# Shared password policy:
# - POSTGRES_PASSWORD (GitHub secret) is the canonical infra password
# - RabbitMQ reuses the same password unless explicitly overridden (and we strongly recommend keeping them identical)
if [[ -z "${RABBITMQ_PASSWORD:-}" ]]; then
  if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
    RABBITMQ_PASSWORD="$POSTGRES_PASSWORD"
    log_info "RABBITMQ_PASSWORD not set - reusing POSTGRES_PASSWORD for RabbitMQ (shared infra password)"
  else
    log_error "RABBITMQ_PASSWORD is required but not set, and POSTGRES_PASSWORD is also empty"
    log_error "Please set POSTGRES_PASSWORD (preferred) or RABBITMQ_PASSWORD in GitHub organization secrets"
    exit 1
  fi
fi

log_section "Installing RabbitMQ (Shared Infrastructure)"
log_info "Namespace: ${NAMESPACE}"
log_info "Username: ${RABBITMQ_USERNAME}"
log_info "Purpose: Shared message broker for all services"

# Pre-flight checks
check_kubectl
ensure_helm

# Create namespace if it doesn't exist
ensure_namespace "${NAMESPACE}"

# Ensure PriorityClass exists (required by RabbitMQ)
MANIFESTS_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/manifests"
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
fix_stuck_helm_operation "rabbitmq" "${NAMESPACE}" || true

# Ensure Helm repos
add_helm_repo "bitnami" "https://charts.bitnami.com/bitnami"

# Install or upgrade RabbitMQ
log_info "Installing/upgrading RabbitMQ..."
log_info "This may take 3-5 minutes..."

# Build Helm arguments - prioritize environment variables
RABBITMQ_HELM_ARGS=()

# Priority 1: Use RABBITMQ_PASSWORD from environment (GitHub secrets) - REQUIRED
# RABBITMQ_PASSWORD is already validated above
log_info "Using RABBITMQ_PASSWORD from environment/GitHub secrets"
log_info "  - RabbitMQ username: ${RABBITMQ_USERNAME}"
log_info "  - RabbitMQ password: ${#RABBITMQ_PASSWORD} chars"
RABBITMQ_HELM_ARGS+=(--set auth.username="$RABBITMQ_USERNAME")
RABBITMQ_HELM_ARGS+=(--set auth.password="$RABBITMQ_PASSWORD")
RABBITMQ_HELM_ARGS+=(--set auth.erlangCookie=$(openssl rand -hex 32))

# Resource configuration for production
RABBITMQ_HELM_ARGS+=(--set resources.requests.memory="512Mi")
RABBITMQ_HELM_ARGS+=(--set resources.requests.cpu="250m")
RABBITMQ_HELM_ARGS+=(--set resources.limits.memory="1Gi")
RABBITMQ_HELM_ARGS+=(--set resources.limits.cpu="500m")

# Persistence
RABBITMQ_HELM_ARGS+=(--set persistence.enabled=true)
RABBITMQ_HELM_ARGS+=(--set persistence.size="10Gi")

# PriorityClass
RABBITMQ_HELM_ARGS+=(--set priorityClassName=db-critical)

# Metrics
RABBITMQ_HELM_ARGS+=(--set metrics.enabled=true)

# Use official RabbitMQ image instead of deprecated Bitnami Docker Hub images
# We pin to the 4.2.x series (Ubuntu-based image from the official RabbitMQ library image)
#   Docs / Dockerfile: https://github.com/docker-library/rabbitmq/tree/master/4.2/ubuntu
RABBITMQ_IMAGE_REGISTRY="docker.io"
RABBITMQ_IMAGE_REPO="rabbitmq"
RABBITMQ_IMAGE_TAG="4.2.1"
RABBITMQ_IMAGE_FULL="${RABBITMQ_IMAGE_REGISTRY}/${RABBITMQ_IMAGE_REPO}:${RABBITMQ_IMAGE_TAG}"

# Verify RabbitMQ image exists if Docker is available
if command -v docker &> /dev/null; then
  log_info "Verifying RabbitMQ image exists: ${RABBITMQ_IMAGE_FULL}"
  if docker manifest inspect "${RABBITMQ_IMAGE_FULL}" >/dev/null 2>&1; then
    log_success "RabbitMQ image verified: ${RABBITMQ_IMAGE_FULL}"
  else
    log_warning "RabbitMQ image not found: ${RABBITMQ_IMAGE_FULL}"
    log_warning "Falling back to latest tag"
    RABBITMQ_IMAGE_TAG="latest"
    RABBITMQ_IMAGE_FULL="${RABBITMQ_IMAGE_REGISTRY}/${RABBITMQ_IMAGE_REPO}:${RABBITMQ_IMAGE_TAG}"
    log_info "Using: ${RABBITMQ_IMAGE_FULL}"
  fi
fi

RABBITMQ_HELM_ARGS+=(--set image.registry="${RABBITMQ_IMAGE_REGISTRY}")
RABBITMQ_HELM_ARGS+=(--set image.repository="${RABBITMQ_IMAGE_REPO}")
RABBITMQ_HELM_ARGS+=(--set image.tag="${RABBITMQ_IMAGE_TAG}")

# Check if RabbitMQ is managed by ArgoCD (custom manifests)
if kubectl get statefulset rabbitmq -n "${NAMESPACE}" -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/instance}' 2>/dev/null | grep -q "rabbitmq"; then
    log_info "RabbitMQ is managed by ArgoCD - skipping Helm installation"
    log_info "Verifying RabbitMQ StatefulSet health..."
    
    RABBITMQ_READY=$(kubectl get statefulset rabbitmq -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    RABBITMQ_REPLICAS=$(kubectl get statefulset rabbitmq -n "${NAMESPACE}" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
    
    if [[ "$RABBITMQ_READY" -ge 1 ]]; then
        log_success "RabbitMQ is healthy and managed by ArgoCD (${RABBITMQ_READY}/${RABBITMQ_REPLICAS} replicas)"
        exit 0
    else
        log_warning "RabbitMQ StatefulSet exists but not ready (${RABBITMQ_READY}/${RABBITMQ_REPLICAS} replicas)"
        log_info "ArgoCD will handle the deployment - no action needed"
        exit 0
    fi
fi

# Check for orphaned RabbitMQ resources before proceeding
log_info "Checking for orphaned RabbitMQ resources..."
fix_orphaned_resources "rabbitmq" "${NAMESPACE}"

set +e
if helm -n "${NAMESPACE}" status rabbitmq >/dev/null 2>&1; then
  # Check if RabbitMQ is healthy
  IS_RABBITMQ_HEALTHY=$(kubectl -n "${NAMESPACE}" get statefulset rabbitmq -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "1" && echo "true" || echo "false")
  
  # If RABBITMQ_PASSWORD is explicitly set, check if it matches current secret
  if [[ -n "${RABBITMQ_PASSWORD:-}" ]]; then
    # Get current password from secret
    CURRENT_RABBITMQ_PASS=$(kubectl -n "${NAMESPACE}" get secret rabbitmq -o jsonpath='{.data.rabbitmq-password}' 2>/dev/null | base64 -d || true)
    
    # Only skip Helm upgrade when BOTH:
    #   - the password matches, and
    #   - RabbitMQ is already healthy
    # This prevents us from skipping upgrades when pods are failing
    if [[ "$CURRENT_RABBITMQ_PASS" == "$RABBITMQ_PASSWORD" && "${FORCE_RABBITMQ_INSTALL}" != "true" && "$IS_RABBITMQ_HEALTHY" == "true" ]]; then
      log_success "RabbitMQ password unchanged and StatefulSet healthy - skipping upgrade"
      log_info "Current secret password matches provided RABBITMQ_PASSWORD"
      HELM_RABBITMQ_EXIT=0
    else
      log_warning "Password mismatch detected - updating RabbitMQ to sync password"
      log_info "Current password length: ${#CURRENT_RABBITMQ_PASS} chars"
      log_info "New password length: ${#RABBITMQ_PASSWORD} chars"
      
      # Check if RabbitMQ is currently healthy - if yes, update secret directly without Helm upgrade
      if [[ "$IS_RABBITMQ_HEALTHY" == "true" ]]; then
        log_info "RabbitMQ is healthy. Updating password via secret..."
        
        # Update the secret directly (RabbitMQ will use it on next restart)
        kubectl create secret generic rabbitmq \
          --from-literal=rabbitmq-password="$RABBITMQ_PASSWORD" \
          --from-literal=rabbitmq-erlang-cookie=$(openssl rand -hex 32) \
          -n "${NAMESPACE}" \
          --dry-run=client -o yaml | kubectl apply -f -
        
        log_success "Password updated in secret. RabbitMQ will use it on next restart."
        log_info "Note: Password change will take effect on next pod restart"
        HELM_RABBITMQ_EXIT=0
      else
        log_warning "RabbitMQ not healthy. Checking for stuck Helm operation..."
        
        # Check for stuck Helm operation before upgrading
        fix_stuck_helm_operation "rabbitmq" "${NAMESPACE}" || true
        
        log_warning "Performing Helm upgrade..."
        helm upgrade rabbitmq bitnami/rabbitmq \
          -n "${NAMESPACE}" \
          --reset-values \
          "${RABBITMQ_HELM_ARGS[@]}" \
          --timeout=10m \
          --wait=false 2>&1 | tee /tmp/helm-rabbitmq-install.log
        HELM_RABBITMQ_EXIT=${PIPESTATUS[0]}
      fi
    fi
  else
    # RABBITMQ_PASSWORD not set - check health status
    if [[ "$IS_RABBITMQ_HEALTHY" == "true" ]]; then
      log_success "RabbitMQ already installed and healthy - skipping"
      HELM_RABBITMQ_EXIT=0
    else
      log_warning "RabbitMQ exists but not ready; checking for stuck operation..."
      
      # Check for stuck Helm operation
      fix_stuck_helm_operation "rabbitmq" "${NAMESPACE}" || true
      
      log_warning "Performing safe upgrade..."
      helm upgrade rabbitmq bitnami/rabbitmq \
        -n "${NAMESPACE}" \
        --reuse-values \
        --timeout=10m \
        --wait=false 2>&1 | tee /tmp/helm-rabbitmq-install.log
      HELM_RABBITMQ_EXIT=${PIPESTATUS[0]}
    fi
  fi
else
  log_info "RabbitMQ not found; installing fresh"
  
  # Only clean up orphaned resources if cleanup mode is active
  if is_cleanup_mode; then
    log_info "Cleanup mode active - checking for orphaned RabbitMQ resources..."
    # Clean up any orphaned resources
    kubectl delete statefulset,pod,service -n "${NAMESPACE}" -l app.kubernetes.io/name=rabbitmq --wait=true --grace-period=0 --force 2>/dev/null || true
    sleep 5
  else
    log_info "Cleanup mode inactive - checking for existing resources to update..."
    # If StatefulSet exists but Helm release doesn't, try upgrade
    if kubectl get statefulset rabbitmq -n "${NAMESPACE}" >/dev/null 2>&1; then
      log_warning "RabbitMQ StatefulSet exists but Helm release missing - attempting upgrade..."
      helm upgrade rabbitmq bitnami/rabbitmq \
        -n "${NAMESPACE}" \
        "${RABBITMQ_HELM_ARGS[@]}" \
        --timeout=10m \
        --wait 2>&1 | tee /tmp/helm-rabbitmq-install.log
      HELM_RABBITMQ_EXIT=${PIPESTATUS[0]}
      set -e
      if [ $HELM_RABBITMQ_EXIT -eq 0 ]; then
        log_success "RabbitMQ upgraded"
        exit 0
      else
        log_error "RabbitMQ upgrade failed"
        exit 1
      fi
    fi
  fi
  
  helm install rabbitmq bitnami/rabbitmq \
    -n "${NAMESPACE}" \
    "${RABBITMQ_HELM_ARGS[@]}" \
    --timeout=10m \
    --wait=false 2>&1 | tee /tmp/helm-rabbitmq-install.log
  HELM_RABBITMQ_EXIT=${PIPESTATUS[0]}
fi
set -e

# Initialize HELM_RABBITMQ_EXIT if not set
HELM_RABBITMQ_EXIT=${HELM_RABBITMQ_EXIT:-0}

if [ $HELM_RABBITMQ_EXIT -eq 0 ]; then
  log_success "RabbitMQ Helm operation completed"
  log_info "Waiting for RabbitMQ pods to be ready..."
  sleep 10
  
  # Check actual pod status
  RABBITMQ_READY=$(kubectl get statefulset rabbitmq -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
  RABBITMQ_REPLICAS=$(kubectl get statefulset rabbitmq -n "${NAMESPACE}" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "")
  
  # Handle empty values
  RABBITMQ_READY=${RABBITMQ_READY:-0}
  RABBITMQ_REPLICAS=${RABBITMQ_REPLICAS:-0}
  
  if [[ "$RABBITMQ_READY" =~ ^[0-9]+$ ]] && [ "$RABBITMQ_READY" -ge 1 ]; then
    log_success "RabbitMQ is ready (${RABBITMQ_READY}/${RABBITMQ_REPLICAS} replicas)"
  else
    log_warning "RabbitMQ pods not ready yet (${RABBITMQ_READY}/${RABBITMQ_REPLICAS} replicas)"
    log_info "Checking pod status..."
    kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=rabbitmq || true
    
    # Check for ImagePullBackOff
    IMAGE_PULL_ERROR=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=rabbitmq -o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}' 2>/dev/null | grep -i "ImagePull\|ErrImagePull" || echo "")
    if [[ -n "$IMAGE_PULL_ERROR" ]]; then
      log_error "Image pull error detected. Checking details..."
      kubectl describe pod -n "${NAMESPACE}" -l app.kubernetes.io/name=rabbitmq | grep -A 5 "Events:" || true
      log_warning "Possible causes:"
      echo "  - Network connectivity issues"
      echo "  - Docker registry rate limiting"
      echo "  - Image pull timeout"
      log_info "Retrying image pull..."
      kubectl delete pod -n "${NAMESPACE}" -l app.kubernetes.io/name=rabbitmq --force --grace-period=0 2>/dev/null || true
      sleep 5
    fi
    
    log_info "RabbitMQ installation initiated. Pods will start in background."
  fi
else
  log_warning "RabbitMQ Helm operation reported exit code $HELM_RABBITMQ_EXIT"
  log_warning "Checking actual RabbitMQ status..."
  
  # Wait a bit for pods to update
  sleep 10
  
  # Check if RabbitMQ StatefulSet exists and has ready replicas
  RABBITMQ_READY=$(kubectl get statefulset rabbitmq -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
  RABBITMQ_REPLICAS=$(kubectl get statefulset rabbitmq -n "${NAMESPACE}" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "")
  
  # Handle empty values
  RABBITMQ_READY=${RABBITMQ_READY:-0}
  RABBITMQ_REPLICAS=${RABBITMQ_REPLICAS:-0}
  
  log_info "RabbitMQ StatefulSet: ${RABBITMQ_READY}/${RABBITMQ_REPLICAS} replicas ready"
  
  if [[ "$RABBITMQ_READY" =~ ^[0-9]+$ ]] && [ "$RABBITMQ_READY" -ge 1 ]; then
    log_success "RabbitMQ is actually running! Continuing..."
    log_warning "Note: Helm reported a timeout, but RabbitMQ is healthy"
  else
    log_error "RabbitMQ installation/upgrade failed"
    log_warning "=== Helm output (last 50 lines) ==="
    tail -50 /tmp/helm-rabbitmq-install.log 2>/dev/null || true
    log_warning "=== Pod status ==="
    kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=rabbitmq 2>/dev/null || true
    log_warning "=== Pod events ==="
    kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' 2>/dev/null | grep -i rabbitmq | tail -10 || true
    log_warning "=== Diagnosing issues ==="
    
    # Check for ImagePullBackOff
    IMAGE_PULL_ERROR=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=rabbitmq -o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}' 2>/dev/null | grep -i "ImagePull\|ErrImagePull" || echo "")
    if [[ -n "$IMAGE_PULL_ERROR" ]]; then
      log_error "Image pull error detected"
      kubectl describe pod -n "${NAMESPACE}" -l app.kubernetes.io/name=rabbitmq | grep -A 10 "Events:" || true
    fi
    
    exit 1
  fi
fi

# Retrieve credentials
log_section "RabbitMQ Installation Complete"
log_info "To retrieve RabbitMQ credentials:"
echo "  Username: ${RABBITMQ_USERNAME}"
echo "  Password: kubectl -n ${NAMESPACE} get secret rabbitmq -o jsonpath='{.data.rabbitmq-password}' | base64 -d"
echo ""
log_info "To connect to RabbitMQ from within the cluster:"
echo "  Host: rabbitmq.${NAMESPACE}.svc.cluster.local"
echo "  Port: 5672 (AMQP), 15672 (Management UI)"
echo ""
log_info "To access RabbitMQ Management UI:"
echo "  kubectl port-forward -n ${NAMESPACE} svc/rabbitmq 15672:15672"
echo -e "  Then open: http://localhost:15672"
echo ""
exit 0