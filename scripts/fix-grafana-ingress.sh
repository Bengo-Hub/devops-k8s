#!/bin/bash
set -euo pipefail

# Fix Grafana ingress - allow HTTP while cert provisions

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}Fixing Grafana Ingress...${NC}"

# Patch Grafana ingress to allow HTTP (remove SSL redirect temporarily)
echo -e "${YELLOW}Removing SSL redirect from Grafana ingress...${NC}"
kubectl patch ingress prometheus-grafana -n monitoring --type=json -p='[
  {
    "op": "remove",
    "path": "/spec/tls"
  }
]' 2>/dev/null || true

# Also remove cert-manager annotation temporarily
kubectl annotate ingress prometheus-grafana -n monitoring cert-manager.io/cluster-issuer- 2>/dev/null || true

echo -e "${GREEN}✓ Grafana ingress patched to allow HTTP${NC}"
echo ""
echo -e "${BLUE}Test access:${NC}"
echo "  curl -H 'Host: grafana.masterspace.co.ke' http://77.237.232.66/"
echo "  OR visit: http://grafana.masterspace.co.ke (in browser)"
echo ""
echo -e "${YELLOW}Once working, you can re-enable TLS:${NC}"
echo "  kubectl patch ingress prometheus-grafana -n monitoring --type=json -p='[{\"op\":\"add\",\"path\":\"/metadata/annotations/cert-manager.io~1cluster-issuer\",\"value\":\"letsencrypt-prod\"}]'"
echo ""

