#!/bin/bash
set -euo pipefail

# Production-ready cert-manager Installation
# Configures Let's Encrypt for automatic TLS certificates

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# MANIFESTS_DIR is at repo root, not under scripts
MANIFESTS_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/manifests"
source "${SCRIPT_DIR}/../tools/common.sh"

log_section "Installing cert-manager (Production)"

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

# Create ClusterIssuers from the tracked manifest (single source of truth).
# Previously this regenerated a plain HTTP-01-only ClusterIssuer inline on every
# run, which would silently strip the Cloudflare DNS-01 solver (required once
# any codevertexafrica.com host is proxied through Cloudflare) if this script
# ever re-ran after that solver was added. See manifests/cert-manager-clusterissuer.yaml
# and docs/cloudflare-cutover.md.
echo -e "${YELLOW}Applying Let's Encrypt ClusterIssuers...${NC}"
kubectl apply -f "${MANIFESTS_DIR}/cert-manager-clusterissuer.yaml"
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
