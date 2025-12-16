#!/bin/bash
set -euo pipefail

# Service health check and troubleshooting scripts

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}=== Cluster Services Status ===${NC}"
echo ""

# Check kubectl connectivity
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo -e "${RED}Cannot connect to cluster. Check KUBECONFIG.${NC}"
  exit 1
fi

echo -e "${BLUE}Checking Ingress Controller...${NC}"
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
echo ""

echo -e "${BLUE}Checking cert-manager...${NC}"
kubectl get pods -n cert-manager
kubectl get clusterissuer
echo ""

echo -e "${BLUE}Checking Argo CD...${NC}"
kubectl get pods -n argocd
kubectl get ingress -n argocd
echo ""

echo -e "${BLUE}Checking Monitoring...${NC}"
MONITORING_NAMESPACE=${MONITORING_NAMESPACE:-infra}
kubectl get pods -n "${MONITORING_NAMESPACE}"
kubectl get ingress -n "${MONITORING_NAMESPACE}"
echo ""

echo -e "${BLUE}Checking ERP Services...${NC}"
kubectl get pods -n erp
kubectl get ingress -n erp
echo ""

echo -e "${BLUE}Checking Certificates...${NC}"
kubectl get certificate -A
echo ""

echo -e "${BLUE}Checking all Ingresses...${NC}"
kubectl get ingress -A
echo ""

echo -e "${YELLOW}=== Troubleshooting Tips ===${NC}"
echo ""
echo "If Grafana shows 404:"
echo "1. Check ingress exists: kubectl get ingress -n ${MONITORING_NAMESPACE}"
echo "2. Check certificate: kubectl get certificate -n ${MONITORING_NAMESPACE}"
echo "3. Describe ingress: kubectl describe ingress -n ${MONITORING_NAMESPACE}"
GRAFANA_DOMAIN=${GRAFANA_DOMAIN:-grafana.masterspace.co.ke}
VPS_IP=${VPS_IP:-YOUR_VPS_IP}
echo "4. Check DNS: nslookup ${GRAFANA_DOMAIN} (should point to ${VPS_IP})"
echo "5. Check ingress controller logs: kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller"
echo ""
echo "Port-forward alternatives:"
echo "  Grafana: kubectl port-forward -n ${MONITORING_NAMESPACE} svc/prometheus-grafana 3000:80"
echo "  Argo CD: kubectl port-forward -n argocd svc/argocd-server 8080:443"
echo ""

