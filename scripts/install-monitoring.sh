#!/bin/bash
set -euo pipefail

# Production-ready Monitoring Stack Installation
# Installs Prometheus, Grafana, Alertmanager with production defaults

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default production configuration
GRAFANA_DOMAIN=${GRAFANA_DOMAIN:-grafana.masterspace.co.ke}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(dirname "$SCRIPT_DIR")/manifests"

echo -e "${GREEN}Installing Prometheus + Grafana monitoring stack (Production)...${NC}"
echo -e "${BLUE}Grafana Domain: ${GRAFANA_DOMAIN}${NC}"

# Pre-flight checks
if ! command -v kubectl &> /dev/null; then
  echo -e "${RED}kubectl command not found. Aborting.${NC}"
  exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo -e "${RED}Cannot connect to cluster. Ensure KUBECONFIG is set. Aborting.${NC}"
  exit 1
fi

echo -e "${GREEN}✓ kubectl configured and cluster reachable${NC}"

# Check for storage class (required for Prometheus/Grafana PVCs)
if ! kubectl get storageclass 2>/dev/null | grep -q "(default)"; then
  echo -e "${YELLOW}No default storage class found. Installing local-path provisioner...${NC}"
  "${SCRIPT_DIR}/install-storage-provisioner.sh"
else
  echo -e "${GREEN}✓ Default storage class available${NC}"
fi

# Check for Helm (install if missing)
if ! command -v helm &> /dev/null; then
  echo -e "${YELLOW}Helm not found. Installing via snap...${NC}"
  if command -v snap &> /dev/null; then
    sudo snap install helm --classic
  else
    echo -e "${YELLOW}snap not available. Installing Helm via script...${NC}"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
  echo -e "${GREEN}✓ Helm installed${NC}"
else
  echo -e "${GREEN}✓ Helm already installed${NC}"
fi

# Check if cert-manager is installed (required for Grafana ingress TLS)
if ! kubectl get namespace cert-manager >/dev/null 2>&1; then
  echo -e "${YELLOW}cert-manager not found. Installing cert-manager first...${NC}"
  "${SCRIPT_DIR}/install-cert-manager.sh"
else
  echo -e "${GREEN}✓ cert-manager already installed${NC}"
fi

# Add Helm repository
echo -e "${YELLOW}Adding Helm repositories...${NC}"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update

# Create monitoring namespace
if kubectl get namespace monitoring >/dev/null 2>&1; then
  echo -e "${GREEN}✓ Namespace 'monitoring' already exists${NC}"
else
  echo -e "${YELLOW}Creating namespace 'monitoring'...${NC}"
  kubectl create namespace monitoring
  echo -e "${GREEN}✓ Namespace 'monitoring' created${NC}"
fi

# Update prometheus-values.yaml with dynamic domain
TEMP_VALUES=/tmp/prometheus-values-prod.yaml
cp "${MANIFESTS_DIR}/monitoring/prometheus-values.yaml" "${TEMP_VALUES}"
sed -i "s|grafana\.masterspace\.co\.ke|${GRAFANA_DOMAIN}|g" "${TEMP_VALUES}" 2>/dev/null || \
  sed -i '' "s|grafana\.masterspace\.co\.ke|${GRAFANA_DOMAIN}|g" "${TEMP_VALUES}" 2>/dev/null || true

# Install or upgrade kube-prometheus-stack (idempotent)
echo -e "${YELLOW}Installing/upgrading kube-prometheus-stack...${NC}"
echo -e "${BLUE}This may take 10-15 minutes. Logs will be streamed below...${NC}"

# If Grafana PVC already exists, do NOT attempt to shrink it. Respect current size.
HELM_EXTRA_OPTS=""
GRAFANA_PVC_SIZE=$(kubectl -n monitoring get pvc prometheus-grafana -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || true)
if [ -n "${GRAFANA_PVC_SIZE:-}" ]; then
  echo -e "${YELLOW}Detected existing Grafana PVC size: ${GRAFANA_PVC_SIZE} - preventing shrink on upgrade${NC}"
  HELM_EXTRA_OPTS="$HELM_EXTRA_OPTS --set-string grafana.persistence.size=${GRAFANA_PVC_SIZE}"
fi

# Function to fix stuck Helm operations
fix_stuck_helm() {
    local release_name=${1:-prometheus}
    local namespace=${2:-monitoring}

    echo -e "${YELLOW}🔧 Attempting to fix stuck Helm operation for ${release_name}...${NC}"

    # Check for stuck operations
    if helm status ${release_name} -n ${namespace} 2>/dev/null | grep -q "STATUS: pending-upgrade"; then
        echo -e "${YELLOW}📊 Found stuck operation, attempting cleanup...${NC}"

        # Delete stuck pods
        kubectl delete pods -n ${namespace} -l "app.kubernetes.io/instance=${release_name}" --force --grace-period=0 2>/dev/null || true

        # Wait for cleanup
        sleep 10

        # Try to rollback to last known good state
        if helm history ${release_name} -n ${namespace} >/dev/null 2>&1; then
            LAST_REVISION=$(helm history ${release_name} -n ${namespace} -o yaml | grep -A 5 "status:" | grep -B 5 "deployed" | head -1 | awk '{print $1}' | tail -1)
            if [ -n "$LAST_REVISION" ] && [ "$LAST_REVISION" != "1" ]; then
                echo -e "${YELLOW}📉 Rolling back to revision $LAST_REVISION...${NC}"
                helm rollback ${release_name} $LAST_REVISION -n ${namespace} 2>/dev/null || true
                sleep 15
                return 0
            fi
        fi

        # If rollback fails, uninstall and prepare for fresh install
        echo -e "${YELLOW}🗑️  Rolling back failed, attempting uninstall...${NC}"
        helm uninstall ${release_name} -n ${namespace} 2>/dev/null || true
        sleep 20

        # Clean up any remaining resources
        kubectl delete pvc -n ${namespace} -l "app.kubernetes.io/instance=${release_name}" --all 2>/dev/null || true
        kubectl delete pv -l "app.kubernetes.io/instance=${release_name}" --all 2>/dev/null || true

        sleep 20
        echo -e "${GREEN}✅ Cleanup completed${NC}"
    fi
}

# Check for stuck operations first
if helm status prometheus -n monitoring 2>/dev/null | grep -q "STATUS: pending-upgrade"; then
    echo -e "${YELLOW}⚠️  Detected stuck Helm operation. Running fix...${NC}"
    fix_stuck_helm prometheus monitoring
fi

# Run Helm with output to both stdout and capture exit code
set +e
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
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
  kubectl get pods -n monitoring || true
  echo ""
  echo -e "${YELLOW}Helm status:${NC}"
  helm -n monitoring status prometheus || true
  echo ""

  # Check for common failure patterns and attempt fixes
  if grep -q "another operation.*in progress" /tmp/helm-monitoring-install.log 2>/dev/null; then
    echo -e "${YELLOW}🔧 Stuck operation detected during installation. Running fix...${NC}"
    fix_stuck_helm prometheus monitoring
    echo -e "${BLUE}🔄 Please retry the installation after cleanup completes${NC}"
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
GRAFANA_PASSWORD=$(kubectl get secret -n monitoring prometheus-grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d || echo "")
if [ -n "$GRAFANA_PASSWORD" ]; then
  echo "  Password: $GRAFANA_PASSWORD"
else
  echo "  Password: (check secret manually)"
fi
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Ensure DNS: ${GRAFANA_DOMAIN} → Your VPS IP (77.237.232.66)"
echo "2. Wait for cert-manager to provision TLS (~2 mins)"
echo "3. Visit https://${GRAFANA_DOMAIN} and login"
echo "4. Import dashboards (315, 6417, 1860) - see docs/monitoring.md"
echo "5. Configure Alertmanager email: kubectl apply -f manifests/monitoring/alertmanager-config.yaml"
echo ""
echo -e "${BLUE}Alternative Access (port-forward):${NC}"
echo "kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
echo "Then visit: http://localhost:3000"
echo ""
echo -e "${BLUE}Prometheus:${NC}"
echo "kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090"
echo "Then visit: http://localhost:9090"
echo ""
