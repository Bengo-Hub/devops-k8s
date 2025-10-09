#!/bin/bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}Installing Prometheus + Grafana monitoring stack...${NC}"

# Add Helm repository
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Create monitoring namespace
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# Install kube-prometheus-stack
echo -e "${YELLOW}Installing kube-prometheus-stack...${NC}"
helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f manifests/monitoring/prometheus-values.yaml \
  --wait

# Get Grafana admin password
echo -e "${GREEN}Monitoring stack installed successfully!${NC}"
echo ""
echo -e "${YELLOW}Grafana admin password:${NC}"
kubectl get secret -n monitoring prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 -d && echo
echo ""
echo -e "${YELLOW}Access Grafana:${NC}"
echo "kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
echo "Then visit: http://localhost:3000"
echo "Username: admin"
echo ""
echo -e "${YELLOW}Apply ERP alerts:${NC}"
echo "kubectl apply -f manifests/monitoring/erp-alerts.yaml"

