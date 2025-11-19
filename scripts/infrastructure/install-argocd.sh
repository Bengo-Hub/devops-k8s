#!/bin/bash
set -euo pipefail

# Production-ready Argo CD Installation
# Auto-configures ingress with TLS for production access

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default production configuration
ARGOCD_DOMAIN=${ARGOCD_DOMAIN:-argocd.masterspace.co.ke}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(dirname "$SCRIPT_DIR")/manifests"

echo -e "${GREEN}Installing Argo CD (Production)...${NC}"
echo -e "${BLUE}Domain: ${ARGOCD_DOMAIN}${NC}"

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

# Check if cert-manager is installed (required for production ingress)
if ! kubectl get namespace cert-manager >/dev/null 2>&1; then
  echo -e "${YELLOW}cert-manager not found. Installing cert-manager first...${NC}"
  "${SCRIPT_DIR}/install-cert-manager.sh"
else
  echo -e "${GREEN}✓ cert-manager already installed${NC}"
fi

# Create namespace
if kubectl get namespace argocd >/dev/null 2>&1; then
  echo -e "${GREEN}✓ Namespace 'argocd' already exists${NC}"
else
  echo -e "${YELLOW}Creating namespace 'argocd'...${NC}"
  kubectl create namespace argocd
  echo -e "${GREEN}✓ Namespace 'argocd' created${NC}"
fi

# Install or upgrade Argo CD
if kubectl -n argocd get deploy argocd-server >/dev/null 2>&1; then
  echo -e "${YELLOW}Argo CD already installed. Upgrading if needed...${NC}"
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
else
  echo -e "${YELLOW}Installing Argo CD...${NC}"
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
fi

# Wait for pods to be ready
echo -e "${YELLOW}Waiting for Argo CD pods to be ready (may take 2-3 minutes)...${NC}"
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s || echo -e "${YELLOW}Some pods still starting, continuing...${NC}"

# Deploy production ingress with TLS
echo -e "${YELLOW}Configuring production ingress with TLS...${NC}"
cat > /tmp/argocd-ingress-prod.yaml <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - ${ARGOCD_DOMAIN}
    secretName: argocd-tls
  rules:
  - host: ${ARGOCD_DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 443
EOF

kubectl apply -f /tmp/argocd-ingress-prod.yaml
echo -e "${GREEN}✓ Ingress configured for ${ARGOCD_DOMAIN}${NC}"

# Get initial admin password
echo ""
echo -e "${GREEN}=== Argo CD Installation Complete ===${NC}"
echo ""
echo -e "${BLUE}Access Information:${NC}"
echo "  URL: https://${ARGOCD_DOMAIN}"
echo "  Username: admin"
if kubectl -n argocd get secret argocd-initial-admin-secret >/dev/null 2>&1; then
  INITIAL_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "")
  if [ -n "$INITIAL_PASSWORD" ]; then
    echo "  Password: $INITIAL_PASSWORD"
  else
    echo "  Password: (already changed or unavailable)"
  fi
else
  echo "  Password: (already changed)"
fi
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
VPS_IP=${VPS_IP:-YOUR_VPS_IP}
echo "1. Ensure DNS: ${ARGOCD_DOMAIN} → Your VPS IP (${VPS_IP})"
echo "2. Wait for cert-manager to provision TLS (~2 mins)"
echo "3. Visit https://${ARGOCD_DOMAIN} and login"
echo "4. Change admin password immediately"
echo "5. Add repository access (see docs/pipelines.md - Argo CD Installation section)"
echo "6. Deploy apps: kubectl apply -f apps/erp-api/app.yaml"
echo ""
echo -e "${BLUE}Alternative Access (port-forward):${NC}"
echo "kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "Then visit: https://localhost:8080"
echo ""
