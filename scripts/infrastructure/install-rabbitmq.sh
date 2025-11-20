#!/usr/bin/env bash
# RabbitMQ installation script for shared infrastructure
# Installs RabbitMQ in infra namespace as shared infrastructure
# Part of devops-k8s infrastructure provisioning

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tools/common.sh"

# Configuration
NAMESPACE=${RABBITMQ_NAMESPACE:-infra}
RABBITMQ_PASSWORD=${RABBITMQ_PASSWORD:-rabbitmq}
RABBITMQ_USERNAME=${RABBITMQ_USERNAME:-user}

log_section "Installing RabbitMQ (Shared Infrastructure)"
log_info "Namespace: ${NAMESPACE}"
log_info "Username: ${RABBITMQ_USERNAME}"
log_info "Purpose: Shared message broker for all services"

# Pre-flight checks
check_kubectl
ensure_helm

# Create namespace if it doesn't exist
ensure_namespace "${NAMESPACE}"

# Ensure Helm repos
add_helm_repo "bitnami" "https://charts.bitnami.com/bitnami"

# Install or upgrade RabbitMQ
log_info "Installing/upgrading RabbitMQ..."
log_info "This may take 3-5 minutes..."

# Build Helm arguments - prioritize environment variables
RABBITMQ_HELM_ARGS=()

# Priority 1: Use RABBITMQ_PASSWORD from environment (GitHub secrets)
if [[ -n "${RABBITMQ_PASSWORD:-}" ]]; then
  echo -e "${GREEN}Using RABBITMQ_PASSWORD from environment/GitHub secrets (priority)${NC}"
  RABBITMQ_HELM_ARGS+=(--set auth.username="$RABBITMQ_USERNAME")
  RABBITMQ_HELM_ARGS+=(--set auth.password="$RABBITMQ_PASSWORD")
  RABBITMQ_HELM_ARGS+=(--set auth.erlangCookie=$(openssl rand -hex 32))
fi

# Resource configuration for production
RABBITMQ_HELM_ARGS+=(--set resources.requests.memory="512Mi")
RABBITMQ_HELM_ARGS+=(--set resources.requests.cpu="250m")
RABBITMQ_HELM_ARGS+=(--set resources.limits.memory="1Gi")
RABBITMQ_HELM_ARGS+=(--set resources.limits.cpu="500m")

# Persistence
RABBITMQ_HELM_ARGS+=(--set persistence.enabled=true)
RABBITMQ_HELM_ARGS+=(--set persistence.size="10Gi")

# Metrics
RABBITMQ_HELM_ARGS+=(--set metrics.enabled=true)

# Common functions already sourced above

set +e
if helm -n "${NAMESPACE}" status rabbitmq >/dev/null 2>&1; then
  # Check if RabbitMQ is healthy
  IS_RABBITMQ_HEALTHY=$(kubectl -n "${NAMESPACE}" get statefulset rabbitmq -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "1" && echo "true" || echo "false")
  
  # If RABBITMQ_PASSWORD is explicitly set, check if it matches current secret
  if [[ -n "${RABBITMQ_PASSWORD:-}" ]]; then
    # Get current password from secret
    CURRENT_RABBITMQ_PASS=$(kubectl -n "${NAMESPACE}" get secret rabbitmq -o jsonpath='{.data.rabbitmq-password}' 2>/dev/null | base64 -d || true)
    
    if [[ "$CURRENT_RABBITMQ_PASS" == "$RABBITMQ_PASSWORD" ]]; then
      log_success "RabbitMQ password unchanged - skipping upgrade"
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
        log_warning "RabbitMQ not healthy. Performing Helm upgrade..."
        helm upgrade rabbitmq bitnami/rabbitmq \
          -n "${NAMESPACE}" \
          --reset-values \
          "${RABBITMQ_HELM_ARGS[@]}" \
          --timeout=10m \
          --wait 2>&1 | tee /tmp/helm-rabbitmq-install.log
        HELM_RABBITMQ_EXIT=${PIPESTATUS[0]}
      fi
    fi
  elif [[ "$IS_RABBITMQ_HEALTHY" == "true" ]]; then
    log_success "RabbitMQ already installed and healthy - skipping"
    HELM_RABBITMQ_EXIT=0
  else
    echo -e "${YELLOW}RabbitMQ exists but not ready; performing safe upgrade${NC}"
    helm upgrade rabbitmq bitnami/rabbitmq \
      -n "${NAMESPACE}" \
      --reuse-values \
      --timeout=10m \
      --wait 2>&1 | tee /tmp/helm-rabbitmq-install.log
    HELM_RABBITMQ_EXIT=${PIPESTATUS[0]}
  fi
else
  echo -e "${YELLOW}RabbitMQ not found; installing fresh${NC}"
  
  # Only clean up orphaned resources if cleanup mode is active
  if is_cleanup_mode; then
    echo -e "${BLUE}Cleanup mode active - checking for orphaned RabbitMQ resources...${NC}"
    # Clean up any orphaned resources
    kubectl delete statefulset,pod,service -n "${NAMESPACE}" -l app.kubernetes.io/name=rabbitmq --wait=true --grace-period=0 --force 2>/dev/null || true
    sleep 5
  else
    echo -e "${BLUE}Cleanup mode inactive - checking for existing resources to update...${NC}"
    # If StatefulSet exists but Helm release doesn't, try upgrade
    if kubectl get statefulset rabbitmq -n "${NAMESPACE}" >/dev/null 2>&1; then
      echo -e "${YELLOW}RabbitMQ StatefulSet exists but Helm release missing - attempting upgrade...${NC}"
      helm upgrade rabbitmq bitnami/rabbitmq \
        -n "${NAMESPACE}" \
        "${RABBITMQ_HELM_ARGS[@]}" \
        --timeout=10m \
        --wait 2>&1 | tee /tmp/helm-rabbitmq-install.log
      HELM_RABBITMQ_EXIT=${PIPESTATUS[0]}
      set -e
      if [ $HELM_RABBITMQ_EXIT -eq 0 ]; then
        echo -e "${GREEN}✓ RabbitMQ upgraded${NC}"
        exit 0
      else
        echo -e "${RED}RabbitMQ upgrade failed${NC}"
        exit 1
      fi
    fi
  fi
  
  helm install rabbitmq bitnami/rabbitmq \
    -n "${NAMESPACE}" \
    "${RABBITMQ_HELM_ARGS[@]}" \
    --timeout=10m \
    --wait 2>&1 | tee /tmp/helm-rabbitmq-install.log
  HELM_RABBITMQ_EXIT=${PIPESTATUS[0]}
fi
set -e

if [ $HELM_RABBITMQ_EXIT -eq 0 ]; then
  echo -e "${GREEN}✓ RabbitMQ ready${NC}"
else
  echo -e "${RED}RabbitMQ installation failed with exit code $HELM_RABBITMQ_EXIT${NC}"
  tail -50 /tmp/helm-rabbitmq-install.log || true
  kubectl get pods -n "${NAMESPACE}" || true
  exit 1
fi

# Retrieve credentials
echo ""
echo -e "${GREEN}=== RabbitMQ Installation Complete ===${NC}"
echo ""
echo -e "${GREEN}To retrieve RabbitMQ credentials:${NC}"
echo -e "  Username: ${RABBITMQ_USERNAME}"
echo -e "  Password: kubectl -n ${NAMESPACE} get secret rabbitmq -o jsonpath='{.data.rabbitmq-password}' | base64 -d"
echo ""
echo -e "${GREEN}To connect to RabbitMQ from within the cluster:${NC}"
echo -e "  Host: rabbitmq.${NAMESPACE}.svc.cluster.local"
echo -e "  Port: 5672 (AMQP), 15672 (Management UI)"
echo ""
echo -e "${GREEN}To access RabbitMQ Management UI:${NC}"
echo -e "  kubectl port-forward -n ${NAMESPACE} svc/rabbitmq 15672:15672"
echo -e "  Then open: http://localhost:15672"
echo ""

exit 0

