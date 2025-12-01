#!/bin/bash
set -euo pipefail

# Production-ready Argo CD Installation
# Auto-configures ingress with TLS for production access

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# MANIFESTS_DIR is at repo root, not under scripts
MANIFESTS_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/manifests"
source "${SCRIPT_DIR}/../tools/common.sh"

# Default production configuration
ARGOCD_DOMAIN=${ARGOCD_DOMAIN:-argocd.masterspace.co.ke}

log_section "Installing Argo CD (Production)"
log_info "Domain: ${ARGOCD_DOMAIN}"

# Pre-flight checks
check_kubectl
ensure_helm
ensure_cert_manager "${SCRIPT_DIR}"

# Create namespace
ensure_namespace "argocd"

# Install or upgrade Argo CD
FORCE_UPGRADE=${FORCE_UPGRADE:-false}

# Check if Argo CD is already installed
if kubectl -n argocd get deploy argocd-server >/dev/null 2>&1; then
  # Check if Argo CD is healthy
  READY_REPLICAS=$(kubectl get deployment argocd-server -n argocd -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  DESIRED_REPLICAS=$(kubectl get deployment argocd-server -n argocd -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
  
  if [ "$READY_REPLICAS" -ge 1 ] && [ "$READY_REPLICAS" -eq "$DESIRED_REPLICAS" ] && [ "$FORCE_UPGRADE" != "true" ]; then
    log_success "Argo CD already installed and healthy - skipping upgrade"
    log_info "To force upgrade, set FORCE_UPGRADE=true"
  else
    if [ "$FORCE_UPGRADE" = "true" ]; then
      log_info "Force upgrade requested. Upgrading Argo CD..."
    else
      log_info "Argo CD exists but not healthy. Upgrading..."
    fi
    # Use apply - handle "already exists" errors gracefully (idempotent operation)
    set +e
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml >/dev/null 2>&1
    APPLY_EXIT=$?
    set -e
    # Check if apply succeeded or if resources already exist (both are OK)
    if [ $APPLY_EXIT -eq 0 ] || kubectl -n argocd get deploy argocd-server >/dev/null 2>&1; then
      log_success "Argo CD manifests applied (some resources may already exist)"
    else
      log_error "Failed to apply Argo CD manifests"
      exit 1
    fi
  fi
else
  log_info "Installing Argo CD..."
  # Apply manifest - handle "already exists" errors gracefully (idempotent operation)
  set +e
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml >/dev/null 2>&1
  APPLY_EXIT=$?
  set -e
  # Check if apply succeeded or if resources already exist (both are OK)
  if [ $APPLY_EXIT -eq 0 ] || kubectl -n argocd get deploy argocd-server >/dev/null 2>&1; then
    log_success "Argo CD installed (some resources may already exist)"
  else
    log_error "Failed to install Argo CD"
    exit 1
  fi
fi

# Wait for pods to be ready
wait_for_pods "argocd" "app.kubernetes.io/name=argocd-server" 300

# Deploy production ingress with TLS
log_info "Configuring production ingress with TLS..."
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

exit 0