#!/bin/bash
set -euo pipefail

# Debug Grafana 404 issue

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}=== Debugging Grafana 404 ===${NC}"
echo ""

echo -e "${BLUE}1. Checking Grafana ingress details:${NC}"
kubectl describe ingress prometheus-grafana -n monitoring
echo ""

echo -e "${BLUE}2. Testing Grafana service directly (inside cluster):${NC}"
kubectl exec -n monitoring deploy/prometheus-grafana -- wget -O- http://localhost:3000/ 2>/dev/null | head -5
echo ""

echo -e "${BLUE}3. Testing via service from ingress controller:${NC}"
kubectl exec -n ingress-nginx deploy/ingress-nginx-controller -- wget -O- http://prometheus-grafana.monitoring.svc.cluster.local/ 2>/dev/null | head -5
echo ""

echo -e "${BLUE}4. Testing HTTPS with curl (bypass DNS):${NC}"
curl -k -H "Host: grafana.masterspace.co.ke" https://77.237.232.66/ 2>&1 | head -20
echo ""

echo -e "${BLUE}5. Checking ingress controller logs for 404:${NC}"
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=50 | grep -E "(404|grafana|error)" || echo "No errors found"
echo ""

echo -e "${BLUE}6. Checking Grafana backend configuration:${NC}"
kubectl get endpoints -n monitoring prometheus-grafana
echo ""

echo -e "${YELLOW}=== Potential Issues ===${NC}"
echo "1. If service test works but ingress doesn't: Check ingress path/backend config"
echo "2. If you get SSL errors: Certificate might be for wrong domain"
echo "3. If backend is empty: Grafana pod selector might be wrong"
echo ""

