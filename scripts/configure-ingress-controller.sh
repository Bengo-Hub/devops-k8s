#!/bin/bash
set -euo pipefail

# Configure NGINX Ingress Controller for bare-metal/VPS
# Uses hostNetwork to bind directly to node ports 80/443

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}Configuring NGINX Ingress Controller for VPS...${NC}"

# Pre-flight checks
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo -e "${RED}Cannot connect to cluster. Aborting.${NC}"
  exit 1
fi

# Check if ingress controller exists
if ! kubectl get namespace ingress-nginx >/dev/null 2>&1; then
  echo -e "${YELLOW}NGINX Ingress Controller not found. Installing...${NC}"
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/cloud/deploy.yaml
  
  echo -e "${YELLOW}Waiting for ingress controller to be ready...${NC}"
  kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=120s || true
fi

# Check if already using hostNetwork
if kubectl get deployment -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.template.spec.hostNetwork}' 2>/dev/null | grep -q "true"; then
  echo -e "${GREEN}✓ Ingress controller already configured with hostNetwork${NC}"
  kubectl get svc -n ingress-nginx ingress-nginx-controller
  exit 0
fi

# Patch ingress controller to use hostNetwork
echo -e "${YELLOW}Patching ingress controller to use hostNetwork...${NC}"
kubectl patch deployment ingress-nginx-controller \
  -n ingress-nginx \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/hostNetwork", "value": true}]'

# Also set dnsPolicy to ClusterFirstWithHostNet for proper DNS resolution
kubectl patch deployment ingress-nginx-controller \
  -n ingress-nginx \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/dnsPolicy", "value": "ClusterFirstWithHostNet"}]'

echo -e "${YELLOW}Waiting for ingress controller to restart...${NC}"
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=120s || true

# Verification
echo ""
echo -e "${GREEN}=== Ingress Controller Configuration Complete ===${NC}"
echo ""
echo -e "${BLUE}Ingress Controller Status:${NC}"
kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller
echo ""
echo -e "${BLUE}Service Configuration:${NC}"
kubectl get svc -n ingress-nginx ingress-nginx-controller
echo ""
echo -e "${GREEN}✓ Ingress controller now using hostNetwork${NC}"
echo -e "${YELLOW}Your services should now be accessible at:${NC}"
echo "  - http://77.237.232.66 (and any domain pointing to this IP)"
echo "  - https://grafana.masterspace.co.ke"
echo "  - https://argocd.masterspace.co.ke"
echo "  - https://erpapi.masterspace.co.ke"
echo "  - https://erp.masterspace.co.ke"
echo ""
echo -e "${BLUE}Verify ingress resources:${NC}"
echo "kubectl get ingress -A"
echo ""

