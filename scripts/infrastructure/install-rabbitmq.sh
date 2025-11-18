#!/usr/bin/env bash
# RabbitMQ installation script for shared infrastructure
# Installs RabbitMQ in infra namespace as shared infrastructure
# Part of devops-k8s infrastructure provisioning

set -euo pipefail

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# Configuration
NAMESPACE=${RABBITMQ_NAMESPACE:-infra}
RABBITMQ_PASSWORD=${RABBITMQ_PASSWORD:-rabbitmq}
RABBITMQ_USERNAME=${RABBITMQ_USERNAME:-user}

echo -e "${BLUE}================================================================${NC}"
echo -e "${GREEN}Installing RabbitMQ (Shared Infrastructure)${NC}"
echo -e "${BLUE}================================================================${NC}"
echo -e "  Namespace: ${NAMESPACE}"
echo -e "  Username: ${RABBITMQ_USERNAME}"
echo -e "  Purpose: Shared message broker for all services"

# Ensure kubectl is configured
if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}✗ kubectl not configured or cluster unreachable${NC}"
  exit 1
fi
echo -e "${GREEN}✓ kubectl configured and cluster reachable${NC}"

# Create namespace if it doesn't exist
if ! kubectl get ns "${NAMESPACE}" >/dev/null 2>&1; then
  kubectl create ns "${NAMESPACE}"
  echo -e "${GREEN}✓ Namespace '${NAMESPACE}' created${NC}"
else
  echo -e "${BLUE}ℹ Namespace '${NAMESPACE}' already exists${NC}"
fi

# Ensure Helm repos
echo -e "${YELLOW}Adding Bitnami Helm repository...${NC}"
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1 || true

# Install or upgrade RabbitMQ
echo -e "${YELLOW}Installing/upgrading RabbitMQ...${NC}"
echo -e "${BLUE}This may take 3-5 minutes...${NC}"

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

# Source common functions for cleanup logic
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/../tools/common.sh" ]; then
  source "${SCRIPT_DIR}/../tools/common.sh"
fi

set +e
if helm -n "${NAMESPACE}" status rabbitmq >/dev/null 2>&1; then
  # Check if RabbitMQ is healthy
  IS_RABBITMQ_HEALTHY=$(kubectl -n "${NAMESPACE}" get statefulset rabbitmq -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "1" && echo "true" || echo "false")
  
  # If RABBITMQ_PASSWORD is explicitly set, check if it matches current secret
  if [[ -n "${RABBITMQ_PASSWORD:-}" ]]; then
    # Get current password from secret
    CURRENT_RABBITMQ_PASS=$(kubectl -n "${NAMESPACE}" get secret rabbitmq -o jsonpath='{.data.rabbitmq-password}' 2>/dev/null | base64 -d || true)
    
    if [[ "$CURRENT_RABBITMQ_PASS" == "$RABBITMQ_PASSWORD" ]]; then
      echo -e "${GREEN}✓ RabbitMQ password unchanged - skipping upgrade${NC}"
      echo -e "${BLUE}Current secret password matches provided RABBITMQ_PASSWORD${NC}"
      HELM_RABBITMQ_EXIT=0
    else
      echo -e "${YELLOW}Password mismatch detected - updating RabbitMQ to sync password${NC}"
      echo -e "${BLUE}Current password length: ${#CURRENT_RABBITMQ_PASS} chars${NC}"
      echo -e "${BLUE}New password length: ${#RABBITMQ_PASSWORD} chars${NC}"
      helm upgrade rabbitmq bitnami/rabbitmq \
        -n "${NAMESPACE}" \
        --reset-values \
        "${RABBITMQ_HELM_ARGS[@]}" \
        --timeout=10m \
        --wait 2>&1 | tee /tmp/helm-rabbitmq-install.log
      HELM_RABBITMQ_EXIT=${PIPESTATUS[0]}
    fi
  elif [[ "$IS_RABBITMQ_HEALTHY" == "true" ]]; then
    echo -e "${GREEN}✓ RabbitMQ already installed and healthy - skipping${NC}"
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

