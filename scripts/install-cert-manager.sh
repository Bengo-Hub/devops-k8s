#!/bin/bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}Installing cert-manager...${NC}"

# Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Wait for pods
echo -e "${YELLOW}Waiting for cert-manager pods to be ready...${NC}"
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/instance=cert-manager \
  -n cert-manager \
  --timeout=120s

# Create ClusterIssuer
echo -e "${YELLOW}Creating Let's Encrypt ClusterIssuers...${NC}"
kubectl apply -f manifests/cert-manager-clusterissuer.yaml

echo -e "${GREEN}cert-manager installed successfully!${NC}"
echo ""
echo -e "${YELLOW}Verify installation:${NC}"
echo "kubectl get pods -n cert-manager"
echo "kubectl get clusterissuer"

