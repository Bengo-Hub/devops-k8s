#!/bin/bash
set -euo pipefail

# Production-ready cert-manager Installation
# Configures Let's Encrypt for automatic TLS certificates

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# MANIFESTS_DIR is at repo root, not under scripts
MANIFESTS_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/manifests"
source "${SCRIPT_DIR}/../tools/common.sh"

# Default production configuration
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL:-info@codevertexitsolutions.com}

log_section "Installing cert-manager (Production)"
log_info "Let's Encrypt Email: ${LETSENCRYPT_EMAIL}"

# Pre-flight checks
check_kubectl
ensure_helm

# Create namespace if needed
ensure_namespace "cert-manager"

# Install or upgrade cert-manager
if kubectl get namespace cert-manager >/dev/null 2>&1 && kubectl get deployment cert-manager -n cert-manager >/dev/null 2>&1; then
  # Check if cert-manager is healthy
  READY_REPLICAS=$(kubectl get deployment cert-manager -n cert-manager -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  DESIRED_REPLICAS=$(kubectl get deployment cert-manager -n cert-manager -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
  
  # Ensure we have integers for comparison
  READY_REPLICAS=${READY_REPLICAS:-0}
  DESIRED_REPLICAS=${DESIRED_REPLICAS:-0}
  
  if [ "$READY_REPLICAS" -ge 1 ] && [ "$READY_REPLICAS" -eq "$DESIRED_REPLICAS" ]; then
    log_success "cert-manager already installed and healthy - skipping upgrade"
    log_info "To force upgrade, set FORCE_UPGRADE=true or delete the deployment"
  else
    log_info "cert-manager exists but not healthy. Upgrading..."
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
  fi
else
  log_info "Installing cert-manager..."
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
fi

# Wait for pods
wait_for_pods "cert-manager" "app.kubernetes.io/instance=cert-manager" 600

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
