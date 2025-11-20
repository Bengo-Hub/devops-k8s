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
HELM_STATUS=$(helm -n "${NAMESPACE}" status rabbitmq 2>/dev/null | grep "STATUS:" | awk '{print $2}' || echo "")
if [[ "$HELM_STATUS" == "pending-upgrade" || "$HELM_STATUS" == "pending-install" || "$HELM_STATUS" == "pending-rollback" ]]; then
  log_warning "Detected stuck Helm operation (status: $HELM_STATUS). Cleaning up..."
  
  # Delete pending Helm secrets
  kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-upgrade,name=rabbitmq" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
  kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-install,name=rabbitmq" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
  kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-rollback,name=rabbitmq" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
  
  log_success "Helm lock removed"
  sleep 5
fi

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

# PriorityClass
RABBITMQ_HELM_ARGS+=(--set priorityClassName=db-critical)

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
        log_warning "RabbitMQ not healthy. Checking for stuck Helm operation..."
        
        # Check for stuck Helm operation before upgrading
        HELM_STATUS=$(helm -n "${NAMESPACE}" status rabbitmq 2>/dev/null | grep "STATUS:" | awk '{print $2}' || echo "")
        if [[ "$HELM_STATUS" == "pending-upgrade" || "$HELM_STATUS" == "pending-install" || "$HELM_STATUS" == "pending-rollback" ]]; then
          log_warning "⚠️  Stuck Helm operation detected (status: $HELM_STATUS). Cleaning up..."
          
          # Delete pending Helm secrets
          kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-upgrade,name=rabbitmq" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
          kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-install,name=rabbitmq" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
          kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-rollback,name=rabbitmq" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
          
          log_success "✓ Helm lock removed. Proceeding with upgrade..."
          sleep 5
        fi
        
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
  elif [[ "$IS_RABBITMQ_HEALTHY" == "true" ]]; then
    log_success "RabbitMQ already installed and healthy - skipping"
    HELM_RABBITMQ_EXIT=0
  else
    echo -e "${YELLOW}RabbitMQ exists but not ready; checking for stuck operation...${NC}"
    
    # Check for stuck Helm operation
    HELM_STATUS=$(helm -n "${NAMESPACE}" status rabbitmq 2>/dev/null | grep "STATUS:" | awk '{print $2}' || echo "")
    if [[ "$HELM_STATUS" == "pending-upgrade" || "$HELM_STATUS" == "pending-install" || "$HELM_STATUS" == "pending-rollback" ]]; then
      echo -e "${YELLOW}⚠️  Stuck Helm operation detected (status: $HELM_STATUS). Cleaning up...${NC}"
      
      # Delete pending Helm secrets
      kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-upgrade,name=rabbitmq" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
      kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-install,name=rabbitmq" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
      kubectl -n "${NAMESPACE}" get secrets -l "owner=helm,status=pending-rollback,name=rabbitmq" -o name 2>/dev/null | xargs kubectl -n "${NAMESPACE}" delete 2>/dev/null || true
      
      echo -e "${GREEN}✓ Helm lock removed${NC}"
      sleep 5
    fi
    
    echo -e "${YELLOW}Performing safe upgrade...${NC}"
    helm upgrade rabbitmq bitnami/rabbitmq \
      -n "${NAMESPACE}" \
      --reuse-values \
      --timeout=10m \
      --wait=false 2>&1 | tee /tmp/helm-rabbitmq-install.log
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
    --wait=false 2>&1 | tee /tmp/helm-rabbitmq-install.log
  HELM_RABBITMQ_EXIT=${PIPESTATUS[0]}
fi
set -e

if [ $HELM_RABBITMQ_EXIT -eq 0 ]; then
  echo -e "${GREEN}✓ RabbitMQ Helm operation completed${NC}"
  echo -e "${BLUE}Waiting for RabbitMQ pods to be ready...${NC}"
  sleep 10
  
  # Check actual pod status
  RABBITMQ_READY=$(kubectl get statefulset rabbitmq -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
  RABBITMQ_REPLICAS=$(kubectl get statefulset rabbitmq -n "${NAMESPACE}" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "")
  
  # Handle empty values
  RABBITMQ_READY=${RABBITMQ_READY:-0}
  RABBITMQ_REPLICAS=${RABBITMQ_REPLICAS:-0}
  
  if [[ "$RABBITMQ_READY" =~ ^[0-9]+$ ]] && [ "$RABBITMQ_READY" -ge 1 ]; then
    echo -e "${GREEN}✓ RabbitMQ is ready (${RABBITMQ_READY}/${RABBITMQ_REPLICAS} replicas)${NC}"
  else
    echo -e "${YELLOW}⚠️  RabbitMQ pods not ready yet (${RABBITMQ_READY}/${RABBITMQ_REPLICAS} replicas)${NC}"
    echo -e "${BLUE}Checking pod status...${NC}"
    kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=rabbitmq || true
    
    # Check for ImagePullBackOff
    IMAGE_PULL_ERROR=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=rabbitmq -o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}' 2>/dev/null | grep -i "ImagePull\|ErrImagePull" || echo "")
    if [[ -n "$IMAGE_PULL_ERROR" ]]; then
      echo -e "${RED}⚠️  Image pull error detected. Checking details...${NC}"
      kubectl describe pod -n "${NAMESPACE}" -l app.kubernetes.io/name=rabbitmq | grep -A 5 "Events:" || true
      echo -e "${YELLOW}Possible causes:${NC}"
      echo "  - Network connectivity issues"
      echo "  - Docker registry rate limiting"
      echo "  - Image pull timeout"
      echo -e "${BLUE}Retrying image pull...${NC}"
      kubectl delete pod -n "${NAMESPACE}" -l app.kubernetes.io/name=rabbitmq --force --grace-period=0 2>/dev/null || true
      sleep 5
    fi
    
    echo -e "${BLUE}RabbitMQ installation initiated. Pods will start in background.${NC}"
  fi
else
  echo -e "${YELLOW}RabbitMQ Helm operation reported exit code $HELM_RABBITMQ_EXIT${NC}"
  echo -e "${YELLOW}Checking actual RabbitMQ status...${NC}"
  
  # Wait a bit for pods to update
  sleep 10
  
  # Check if RabbitMQ StatefulSet exists and has ready replicas
  RABBITMQ_READY=$(kubectl get statefulset rabbitmq -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
  RABBITMQ_REPLICAS=$(kubectl get statefulset rabbitmq -n "${NAMESPACE}" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "")
  
  # Handle empty values
  RABBITMQ_READY=${RABBITMQ_READY:-0}
  RABBITMQ_REPLICAS=${RABBITMQ_REPLICAS:-0}
  
  echo -e "${BLUE}RabbitMQ StatefulSet: ${RABBITMQ_READY}/${RABBITMQ_REPLICAS} replicas ready${NC}"
  
  if [[ "$RABBITMQ_READY" =~ ^[0-9]+$ ]] && [ "$RABBITMQ_READY" -ge 1 ]; then
    echo -e "${GREEN}✓ RabbitMQ is actually running! Continuing...${NC}"
    echo -e "${YELLOW}Note: Helm reported a timeout, but RabbitMQ is healthy${NC}"
  else
    echo -e "${RED}RabbitMQ installation/upgrade failed${NC}"
    echo -e "${YELLOW}=== Helm output (last 50 lines) ===${NC}"
    tail -50 /tmp/helm-rabbitmq-install.log 2>/dev/null || true
    echo -e "${YELLOW}=== Pod status ===${NC}"
    kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=rabbitmq 2>/dev/null || true
    echo -e "${YELLOW}=== Pod events ===${NC}"
    kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' 2>/dev/null | grep -i rabbitmq | tail -10 || true
    echo -e "${YELLOW}=== Diagnosing issues ===${NC}"
    
    # Check for ImagePullBackOff
    IMAGE_PULL_ERROR=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=rabbitmq -o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}' 2>/dev/null | grep -i "ImagePull\|ErrImagePull" || echo "")
    if [[ -n "$IMAGE_PULL_ERROR" ]]; then
      echo -e "${RED}⚠️  Image pull error detected${NC}"
      kubectl describe pod -n "${NAMESPACE}" -l app.kubernetes.io/name=rabbitmq | grep -A 10 "Events:" || true
    fi
    
    exit 1
  fi
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

