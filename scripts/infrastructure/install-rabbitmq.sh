#!/usr/bin/env bash
# RabbitMQ installation verification script
# RabbitMQ is deployed via ArgoCD using custom manifests (manifests/databases/rabbitmq-statefulset.yaml)
# This script only verifies the deployment is healthy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tools/common.sh" || {
  echo "ERROR: Failed to source common.sh - required for logging and utilities"
  exit 1
}

# Configuration
NAMESPACE=${RABBITMQ_NAMESPACE:-infra}
RABBITMQ_USERNAME=${RABBITMQ_USERNAME:-user}

log_section "Verifying RabbitMQ Deployment"
log_info "Namespace: ${NAMESPACE}"
log_info "Deployment Method: ArgoCD + Custom Manifests"
log_info "Manifests: manifests/databases/rabbitmq-statefulset.yaml"

# Pre-flight checks
check_kubectl

# Create namespace if it doesn't exist
ensure_namespace "${NAMESPACE}"

# Ensure PriorityClass exists (required by RabbitMQ manifests)
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

# Ensure RabbitMQ secret exists (ArgoCD won't create it automatically)
if ! kubectl get secret rabbitmq -n "${NAMESPACE}" >/dev/null 2>&1; then
  log_info "Creating RabbitMQ secret..."
  
  # Use POSTGRES_PASSWORD as master password, fallback to RABBITMQ_PASSWORD
  RABBITMQ_PASS="${RABBITMQ_PASSWORD:-${POSTGRES_PASSWORD:-}}"
  
  if [[ -z "${RABBITMQ_PASS}" ]]; then
    log_error "No password provided for RabbitMQ"
    log_error "Please set POSTGRES_PASSWORD (preferred) or RABBITMQ_PASSWORD in GitHub secrets"
    exit 1
  fi
  
  kubectl create secret generic rabbitmq \
    -n "${NAMESPACE}" \
    --from-literal=username="${RABBITMQ_USERNAME}" \
    --from-literal=password="${RABBITMQ_PASS}" \
    --from-literal=erlang-cookie=$(openssl rand -hex 32)
  
  log_success "RabbitMQ secret created with master password"
else
  log_success "RabbitMQ secret already exists"
fi

# Check if RabbitMQ is deployed (via ArgoCD or custom manifests)
if kubectl get statefulset rabbitmq -n "${NAMESPACE}" >/dev/null 2>&1; then
  log_info "RabbitMQ StatefulSet found - verifying health..."
  
  READY_REPLICAS=$(kubectl get statefulset rabbitmq -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  DESIRED_REPLICAS=$(kubectl get statefulset rabbitmq -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
  
  if [[ "$READY_REPLICAS" -ge 1 ]]; then
    log_success "RabbitMQ is healthy and running (${READY_REPLICAS}/${DESIRED_REPLICAS} replicas)"
    
    # Check if managed by ArgoCD
    if kubectl get statefulset rabbitmq -n "${NAMESPACE}" -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/instance}' 2>/dev/null | grep -q "rabbitmq"; then
      log_info "Deployment Method: ArgoCD (custom manifests)"
    else
      log_info "Deployment Method: Manual (custom manifests)"
    fi
  else
    log_warning "RabbitMQ StatefulSet exists but not ready (${READY_REPLICAS}/${DESIRED_REPLICAS} replicas)"
    log_info "Checking pod status..."
    kubectl get pods -n "${NAMESPACE}" -l app=rabbitmq || true
    log_info "ArgoCD will reconcile the deployment automatically"
  fi
else
  log_warning "RabbitMQ StatefulSet not found"
  log_info "RabbitMQ should be deployed via ArgoCD using:"
  log_info "  - ArgoCD Application: apps/rabbitmq/app.yaml"
  log_info "  - Manifests: manifests/databases/rabbitmq-statefulset.yaml"
  log_info "ArgoCD will create the deployment automatically"
fi

# Display connection information
log_section "RabbitMQ Connection Information"
log_info "To retrieve RabbitMQ credentials:"
echo "  Username: ${RABBITMQ_USERNAME}"
echo "  Password: kubectl -n ${NAMESPACE} get secret rabbitmq -o jsonpath='{.data.password}' | base64 -d"
echo ""
log_info "To connect to RabbitMQ from within the cluster:"
echo "  AMQP: amqp://${RABBITMQ_USERNAME}:<password>@rabbitmq.${NAMESPACE}.svc.cluster.local:5672"
echo "  Management UI: http://rabbitmq.${NAMESPACE}.svc.cluster.local:15672"
echo "  Prometheus Metrics: http://rabbitmq.${NAMESPACE}.svc.cluster.local:15692/metrics"
echo ""
log_info "To access RabbitMQ Management UI locally:"
echo "  kubectl port-forward -n ${NAMESPACE} svc/rabbitmq 15672:15672"
echo "  Then open: http://localhost:15672"
echo ""
log_success "RabbitMQ verification complete"
exit 0