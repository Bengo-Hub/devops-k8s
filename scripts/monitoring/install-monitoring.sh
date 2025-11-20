#!/bin/bash
set -euo pipefail

# Production-ready Monitoring Stack Installation
# Installs Prometheus, Grafana, Alertmanager with production defaults

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# MANIFESTS_DIR is at repo root, not under scripts
MANIFESTS_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/manifests"
source "${SCRIPT_DIR}/../tools/common.sh"

# Default production configuration
GRAFANA_DOMAIN=${GRAFANA_DOMAIN:-grafana.masterspace.co.ke}
MONITORING_NAMESPACE=${MONITORING_NAMESPACE:-infra}

log_section "Installing Prometheus + Grafana monitoring stack (Production)"
log_info "Grafana Domain: ${GRAFANA_DOMAIN}"

# Pre-flight checks
check_kubectl
ensure_storage_class "${SCRIPT_DIR}"
ensure_helm
ensure_cert_manager "${SCRIPT_DIR}"

# Add Helm repository
add_helm_repo "prometheus-community" "https://prometheus-community.github.io/helm-charts"

# Create infra namespace (monitoring is deployed here as shared infrastructure)
ensure_namespace "${MONITORING_NAMESPACE}"

# Update prometheus-values.yaml with dynamic domain
TEMP_VALUES=/tmp/prometheus-values-prod.yaml

# Check if manifest file exists before copying
if [ ! -f "${MANIFESTS_DIR}/monitoring/prometheus-values.yaml" ]; then
  log_error "Manifest file not found: ${MANIFESTS_DIR}/monitoring/prometheus-values.yaml"
  log_info "MANIFESTS_DIR resolved to: ${MANIFESTS_DIR}"
  log_info "SCRIPT_DIR: ${SCRIPT_DIR}"
  log_info "Current working directory: $(pwd)"
  log_info "Checking if file exists at alternative locations..."
  ls -la "${MANIFESTS_DIR}/monitoring/" 2>/dev/null || true
  ls -la "$(dirname "$SCRIPT_DIR")/../manifests/monitoring/" 2>/dev/null || true
  exit 1
fi

cp "${MANIFESTS_DIR}/monitoring/prometheus-values.yaml" "${TEMP_VALUES}"
sed -i "s|grafana\.masterspace\.co\.ke|${GRAFANA_DOMAIN}|g" "${TEMP_VALUES}" 2>/dev/null || \
  sed -i '' "s|grafana\.masterspace\.co\.ke|${GRAFANA_DOMAIN}|g" "${TEMP_VALUES}" 2>/dev/null || true

# Install or upgrade kube-prometheus-stack (idempotent)
log_info "Installing/upgrading kube-prometheus-stack..."
log_info "This may take 10-15 minutes. Logs will be streamed below..."

# Note: Monitoring uses helm upgrade --install which is idempotent
# Only cleanup orphaned resources if cleanup mode is active
if is_cleanup_mode && ! helm -n "${MONITORING_NAMESPACE}" status prometheus >/dev/null 2>&1; then
  log_info "Cleanup mode active - checking for orphaned monitoring resources..."
  
  # Clean up any orphaned ingresses first (prevents webhook validation errors)
  echo -e "${YELLOW}Cleaning up orphaned monitoring ingresses...${NC}"
  kubectl delete ingress -n "${MONITORING_NAMESPACE}" -l "app.kubernetes.io/name=grafana" --wait=false 2>/dev/null || true
  kubectl delete ingress -n "${MONITORING_NAMESPACE}" -l "app.kubernetes.io/instance=prometheus" --wait=false 2>/dev/null || true
  kubectl delete ingress -n "${MONITORING_NAMESPACE}" -l "app.kubernetes.io/instance=monitoring" --wait=false 2>/dev/null || true
  
  # Also check for ingresses matching the Grafana domain
  ORPHANED_GRAFANA_INGRESS=$(kubectl get ingress -n "${MONITORING_NAMESPACE}" -o json 2>/dev/null | \
    jq -r ".items[] | select(.spec.rules[]?.host == \"${GRAFANA_DOMAIN}\") | .metadata.name" 2>/dev/null || true)
  
  if [ -n "$ORPHANED_GRAFANA_INGRESS" ]; then
    echo -e "${YELLOW}Found orphaned ingress(es) for ${GRAFANA_DOMAIN}: $ORPHANED_GRAFANA_INGRESS${NC}"
    for ing in $ORPHANED_GRAFANA_INGRESS; do
      kubectl delete ingress "$ing" -n "${MONITORING_NAMESPACE}" --wait=false 2>/dev/null || true
    done
  fi
  
  # Clean up any orphaned resources before install
  kubectl delete statefulset,deployment,pod,service -n "${MONITORING_NAMESPACE}" -l "app.kubernetes.io/instance=prometheus" --wait=true --grace-period=0 --force 2>/dev/null || true
  sleep 5
fi

# If Grafana PVC already exists, do NOT attempt to shrink it. Respect current size.
HELM_EXTRA_OPTS=""
GRAFANA_PVC_SIZE=$(kubectl -n "${MONITORING_NAMESPACE}" get pvc prometheus-grafana -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || true)
if [ -n "${GRAFANA_PVC_SIZE:-}" ]; then
  echo -e "${YELLOW}Detected existing Grafana PVC size: ${GRAFANA_PVC_SIZE} - preventing shrink on upgrade${NC}"
  HELM_EXTRA_OPTS="$HELM_EXTRA_OPTS --set-string grafana.persistence.size=${GRAFANA_PVC_SIZE}"
fi

# Function to fix stuck Helm operations
fix_stuck_helm() {
    local release_name=${1:-prometheus}
    local namespace=${2:-${MONITORING_NAMESPACE}}

    echo -e "${YELLOW}🔧 Attempting to fix stuck Helm operation for ${release_name}...${NC}"

    # Check for stuck operations
    local status=$(helm status ${release_name} -n ${namespace} 2>/dev/null | grep "STATUS:" | awk '{print $2}')
    
    if [[ "$status" == "pending-upgrade" || "$status" == "pending-install" || "$status" == "pending-rollback" ]]; then
        echo -e "${YELLOW}📊 Found stuck operation (status: $status), attempting cleanup...${NC}"

        # CRITICAL: Delete the Helm secret that's locking the operation
        echo -e "${YELLOW}🔓 Unlocking Helm release by removing pending secret...${NC}"
        
        # Find and delete the pending-upgrade secret
        PENDING_SECRETS=$(kubectl -n ${namespace} get secrets -l "owner=helm,status=pending-upgrade,name=${release_name}" -o name 2>/dev/null || true)
        if [ -n "$PENDING_SECRETS" ]; then
            echo -e "${YELLOW}Deleting pending operation secrets:${NC}"
            echo "$PENDING_SECRETS" | xargs kubectl -n ${namespace} delete 2>/dev/null || true
        fi
        
        # Also clean up pending-install and pending-rollback
        kubectl -n ${namespace} get secrets -l "owner=helm,status=pending-install,name=${release_name}" -o name 2>/dev/null | xargs kubectl -n ${namespace} delete 2>/dev/null || true
        kubectl -n ${namespace} get secrets -l "owner=helm,status=pending-rollback,name=${release_name}" -o name 2>/dev/null | xargs kubectl -n ${namespace} delete 2>/dev/null || true

        # Force delete problematic pods
        echo -e "${YELLOW}🗑️  Force deleting stuck pods...${NC}"
        kubectl delete pods -n ${namespace} -l "app.kubernetes.io/instance=${release_name}" --force --grace-period=0 2>/dev/null || true
        
        # Wait for cleanup
        sleep 10

        # Find the last successfully deployed revision
        echo -e "${YELLOW}📜 Checking Helm history...${NC}"
        if helm history ${release_name} -n ${namespace} >/dev/null 2>&1; then
            # Get last deployed (successful) revision
            LAST_DEPLOYED=$(helm history ${release_name} -n ${namespace} --max 100 -o json 2>/dev/null | jq -r '.[] | select(.status == "deployed") | .revision' | tail -1)
            
            if [ -n "$LAST_DEPLOYED" ] && [ "$LAST_DEPLOYED" != "null" ]; then
                echo -e "${YELLOW}📉 Rolling back to last deployed revision: $LAST_DEPLOYED...${NC}"
                helm rollback ${release_name} $LAST_DEPLOYED -n ${namespace} --force --wait --timeout=5m 2>/dev/null || {
                    echo -e "${YELLOW}⚠️  Rollback command failed, but lock is removed. Proceeding...${NC}"
                }
                sleep 15
                return 0
            fi
        fi

        echo -e "${GREEN}✅ Helm lock removed. Ready for fresh install/upgrade${NC}"
        return 0
    else
        echo -e "${GREEN}✓ No stuck operation detected (status: ${status})${NC}"
        return 0
    fi
}

# Check for and clean up conflicting ingress resources
echo -e "${YELLOW}Checking for conflicting ingress resources...${NC}"
CONFLICTING_INGRESSES=$(kubectl get ingress -n "${MONITORING_NAMESPACE}" -o json 2>/dev/null | \
  jq -r ".items[] | select(.spec.rules[]?.host == \"${GRAFANA_DOMAIN}\") | .metadata.name" 2>/dev/null || true)

if [ -n "$CONFLICTING_INGRESSES" ]; then
  echo -e "${YELLOW}Found conflicting ingress(es) for ${GRAFANA_DOMAIN}:${NC}"
  echo "$CONFLICTING_INGRESSES"
  
  # Check if this is from a previous monitoring installation
  for ingress_name in $CONFLICTING_INGRESSES; do
    INGRESS_LABELS=$(kubectl get ingress "$ingress_name" -n "${MONITORING_NAMESPACE}" -o jsonpath='{.metadata.labels}' 2>/dev/null || true)
    
    # If it's from monitoring/grafana, safe to delete
    if echo "$INGRESS_LABELS" | grep -q "grafana\|prometheus\|monitoring"; then
      echo -e "${YELLOW}Deleting conflicting monitoring ingress: $ingress_name${NC}"
      kubectl delete ingress "$ingress_name" -n "${MONITORING_NAMESPACE}" --wait=false 2>/dev/null || true
    else
      echo -e "${RED}⚠️  Warning: Ingress $ingress_name exists but doesn't appear to be from monitoring stack${NC}"
      echo -e "${RED}    You may need to manually resolve this conflict${NC}"
    fi
  done
  
  sleep 5
  echo -e "${GREEN}✓ Conflicting ingresses cleaned up${NC}"
fi

# Check for stuck operations first
if helm status prometheus -n "${MONITORING_NAMESPACE}" 2>/dev/null | grep -q "STATUS: pending-upgrade"; then
    echo -e "${YELLOW}⚠️  Detected stuck Helm operation. Running fix...${NC}"
    fix_stuck_helm prometheus "${MONITORING_NAMESPACE}"
fi

# Run Helm with output to both stdout and capture exit code
set +e
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  -n "${MONITORING_NAMESPACE}" \
  -f "${TEMP_VALUES}" \
  ${HELM_EXTRA_OPTS} \
  --timeout=15m \
  --wait 2>&1 | tee /tmp/helm-monitoring-install.log
HELM_EXIT_CODE=${PIPESTATUS[0]}
set -e

# Check if Helm succeeded
if [ $HELM_EXIT_CODE -eq 0 ]; then
  echo -e "${GREEN}✓ kube-prometheus-stack installed successfully${NC}"
else
  echo -e "${RED}Installation failed with exit code $HELM_EXIT_CODE${NC}"
  echo ""
  echo -e "${YELLOW}Recent log output:${NC}"
  tail -50 /tmp/helm-monitoring-install.log || true
  echo ""
  echo -e "${YELLOW}Pod status:${NC}"
  kubectl get pods -n "${MONITORING_NAMESPACE}" || true
  echo ""
  echo -e "${YELLOW}Helm status:${NC}"
  helm -n "${MONITORING_NAMESPACE}" status prometheus || true
  echo ""

  # Check for common failure patterns and attempt fixes
  if grep -q "another operation.*in progress" /tmp/helm-monitoring-install.log 2>/dev/null; then
    echo -e "${YELLOW}🔧 Stuck operation detected during installation. Running fix...${NC}"
    fix_stuck_helm prometheus "${MONITORING_NAMESPACE}"
    echo -e "${BLUE}🔄 Please retry the installation after cleanup completes${NC}"
  elif grep -q "host.*is already defined in ingress" /tmp/helm-monitoring-install.log 2>/dev/null; then
    echo -e "${YELLOW}🔧 Ingress conflict detected. Cleaning up conflicting ingresses...${NC}"
    
    # Extract the conflicting ingress name from the error
    CONFLICTING_INGRESS=$(grep "is already defined in ingress" /tmp/helm-monitoring-install.log | sed -n 's/.*ingress \([^ ]*\).*/\1/p' | head -1)
    
    if [ -n "$CONFLICTING_INGRESS" ]; then
      # Parse namespace/name format
      INGRESS_NS=$(echo "$CONFLICTING_INGRESS" | cut -d'/' -f1)
      INGRESS_NAME=$(echo "$CONFLICTING_INGRESS" | cut -d'/' -f2)
      
      echo -e "${YELLOW}Deleting conflicting ingress: $INGRESS_NS/$INGRESS_NAME${NC}"
      kubectl delete ingress "$INGRESS_NAME" -n "$INGRESS_NS" --wait=false 2>/dev/null || true
      
      # Also clean up any other monitoring-related ingresses
      kubectl delete ingress -n "${MONITORING_NAMESPACE}" -l "app.kubernetes.io/name=grafana" --wait=false 2>/dev/null || true
      kubectl delete ingress -n "${MONITORING_NAMESPACE}" -l "app.kubernetes.io/instance=prometheus" --wait=false 2>/dev/null || true
      
      sleep 10
      
      echo -e "${BLUE}🔄 Retrying installation after ingress cleanup...${NC}"
      helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
        -n "${MONITORING_NAMESPACE}" \
        -f "${TEMP_VALUES}" \
        ${HELM_EXTRA_OPTS} \
        --timeout=15m \
        --wait 2>&1 | tee /tmp/helm-monitoring-install-retry.log
      
      RETRY_EXIT=$?
      if [ $RETRY_EXIT -eq 0 ]; then
        echo -e "${GREEN}✓ Installation succeeded after ingress cleanup!${NC}"
        exit 0
      else
        echo -e "${RED}Installation still failed after retry. Check logs.${NC}"
        tail -50 /tmp/helm-monitoring-install-retry.log || true
      fi
    fi
  fi

  echo -e "${RED}Check /tmp/helm-monitoring-install.log for full details${NC}"
  exit 1
fi

# Apply ERP-specific alerts
echo -e "${YELLOW}Applying ERP-specific alerts...${NC}"
kubectl apply -f "${MANIFESTS_DIR}/monitoring/erp-alerts.yaml"
echo -e "${GREEN}✓ ERP alerts configured${NC}"

# Get Grafana admin password
echo ""
echo -e "${GREEN}=== Monitoring Stack Installation Complete ===${NC}"
echo ""
echo -e "${BLUE}Grafana Access Information:${NC}"
echo "  URL: https://${GRAFANA_DOMAIN}"
echo "  Username: admin"
GRAFANA_PASSWORD=$(kubectl get secret -n "${MONITORING_NAMESPACE}" prometheus-grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d || echo "")
if [ -n "$GRAFANA_PASSWORD" ]; then
  echo "  Password: $GRAFANA_PASSWORD"
else
  echo "  Password: (check secret manually)"
fi
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
VPS_IP=${VPS_IP:-YOUR_VPS_IP}
echo "1. Ensure DNS: ${GRAFANA_DOMAIN} → Your VPS IP (${VPS_IP})"
echo "2. Wait for cert-manager to provision TLS (~2 mins)"
echo "3. Visit https://${GRAFANA_DOMAIN} and login"
echo "4. Import dashboards (315, 6417, 1860) - see docs/monitoring.md"
echo "5. Configure Alertmanager email: kubectl apply -f manifests/monitoring/alertmanager-config.yaml"
echo ""
echo -e "${BLUE}Alternative Access (port-forward):${NC}"
echo "kubectl port-forward -n ${MONITORING_NAMESPACE} svc/prometheus-grafana 3000:80"
echo "Then visit: http://localhost:3000"
echo ""
echo -e "${BLUE}Prometheus:${NC}"
echo "kubectl port-forward -n ${MONITORING_NAMESPACE} svc/prometheus-kube-prometheus-prometheus 9090:9090"
echo "Then visit: http://localhost:9090"
echo ""
