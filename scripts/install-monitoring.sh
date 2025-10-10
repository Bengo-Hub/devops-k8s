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

# Install or upgrade kube-prometheus-stack
if helm -n monitoring status prometheus >/dev/null 2>&1; then
  echo -e "${YELLOW}kube-prometheus-stack already installed. Upgrading...${NC}"
  #helm upgrade prometheus prometheus-community/kube-prometheus-stack \
  #  -n monitoring \
  #  -f "${TEMP_VALUES}" \
  #  --timeout=15m \
  #  --wait
else
  echo -e "${YELLOW}Installing kube-prometheus-stack (this may take 10-15 minutes)...${NC}"
  helm install prometheus prometheus-community/kube-prometheus-stack \
    -n monitoring \
    -f "${TEMP_VALUES}" \
    --timeout=15m \
    --wait \
    --debug || {
      echo -e "${RED}Installation timed out or failed. Checking status...${NC}"
      kubectl get pods -n monitoring
      helm -n monitoring status prometheus || true
      exit 1
    }
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
