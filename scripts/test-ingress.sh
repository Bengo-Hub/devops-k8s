#!/bin/bash
set -euo pipefail

# Test ingress connectivity and troubleshoot 404 issues

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

VPS_IP=${VPS_IP:-77.237.232.66}

echo -e "${GREEN}=== Ingress Troubleshooting ===${NC}"
echo ""

echo -e "${BLUE}1. Testing direct IP access (HTTP)...${NC}"
curl -v http://${VPS_IP}/ 2>&1 | head -20 || true
echo ""

echo -e "${BLUE}2. Testing with Host header (Grafana)...${NC}"
curl -v -H "Host: grafana.masterspace.co.ke" http://${VPS_IP}/ 2>&1 | head -20 || true
echo ""

echo -e "${BLUE}3. Checking Grafana service...${NC}"
kubectl get svc -n monitoring prometheus-grafana
echo ""

echo -e "${BLUE}4. Checking Grafana pods...${NC}"
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana
echo ""

echo -e "${BLUE}5. Describing Grafana ingress...${NC}"
kubectl describe ingress prometheus-grafana -n monitoring
echo ""

echo -e "${BLUE}6. Checking ingress controller logs (last 50 lines)...${NC}"
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=50
echo ""

echo -e "${YELLOW}=== Quick Fixes ===${NC}"
echo ""
echo "Try HTTP first (bypass TLS):"
echo "  curl -H 'Host: grafana.masterspace.co.ke' http://77.237.232.66/"
echo ""
echo "Port-forward to test Grafana directly:"
echo "  kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
echo "  Then visit: http://localhost:3000"
echo ""
echo "Check if Grafana is responding:"
echo "  kubectl exec -n monitoring deploy/prometheus-grafana -- wget -O- http://localhost:3000/"
echo ""

