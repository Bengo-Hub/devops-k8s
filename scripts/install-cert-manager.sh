#!/bin/bash
set -euo pipefail

# Production-ready cert-manager Installation
# Configures Let's Encrypt for automatic TLS certificates

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default production configuration
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL:-info@codevertexitsolutions.com}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(dirname "$SCRIPT_DIR")/manifests"

echo -e "${GREEN}Installing cert-manager (Production)...${NC}"
echo -e "${BLUE}Let's Encrypt Email: ${LETSENCRYPT_EMAIL}${NC}"

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

# Install or upgrade cert-manager
if kubectl get namespace cert-manager >/dev/null 2>&1; then
  echo -e "${YELLOW}cert-manager already installed. Upgrading if needed...${NC}"
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
else
  echo -e "${YELLOW}Installing cert-manager...${NC}"
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
fi

# Wait for pods
echo -e "${YELLOW}Waiting for cert-manager pods to be ready...${NC}"
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/instance=cert-manager \
  -n cert-manager \
  --timeout=120s || echo -e "${YELLOW}Some pods still starting, continuing...${NC}"

# Create ClusterIssuers with dynamic email
echo -e "${YELLOW}Creating Let's Encrypt ClusterIssuers...${NC}"
cat > /tmp/cert-manager-clusterissuer-prod.yaml <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${LETSENCRYPT_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${LETSENCRYPT_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - http01:
        ingress:
          class: nginx
EOF

kubectl apply -f /tmp/cert-manager-clusterissuer-prod.yaml
echo -e "${GREEN}✓ ClusterIssuers configured${NC}"

# Verification
echo ""
echo -e "${GREEN}=== cert-manager Installation Complete ===${NC}"
echo ""
echo -e "${BLUE}Verification:${NC}"
kubectl get pods -n cert-manager
echo ""
kubectl get clusterissuer
echo ""
echo -e "${YELLOW}cert-manager is ready to provision TLS certificates automatically${NC}"
echo -e "${YELLOW}Ingress resources with annotation 'cert-manager.io/cluster-issuer: letsencrypt-prod' will get TLS${NC}"
echo ""
