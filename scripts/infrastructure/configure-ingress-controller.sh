#!/bin/bash
set -euo pipefail

# Configure NGINX Ingress Controller for bare-metal/VPS
# Uses hostNetwork to bind directly to node ports 80/443

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tools/common.sh"

log_section "Configuring NGINX Ingress Controller for VPS"

# Pre-flight checks
check_kubectl

# Ensure namespace exists
ensure_namespace "ingress-nginx"

# Check if ingress controller exists
if ! kubectl get deployment ingress-nginx-controller -n ingress-nginx >/dev/null 2>&1; then
  log_info "NGINX Ingress Controller not found. Installing..."
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/cloud/deploy.yaml
  
  wait_for_pods "ingress-nginx" "app.kubernetes.io/component=controller" 120
fi

# Check current hostNetwork status
CURRENT_HOSTNET=$(kubectl get deployment -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.template.spec.hostNetwork}' 2>/dev/null || echo "false")
log_info "Current hostNetwork setting: ${CURRENT_HOSTNET}"

# Verify if actually using hostNetwork by checking pod
POD_HOSTNET=$(kubectl get pod -n ingress-nginx -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].spec.hostNetwork}' 2>/dev/null || echo "false")
log_info "Pod hostNetwork setting: ${POD_HOSTNET}"

if [ "$POD_HOSTNET" = "true" ]; then
  log_success "Ingress controller already using hostNetwork"
  
  # But check if service needs updating
  SVC_TYPE=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.type}' 2>/dev/null || echo "")
  if [ "$SVC_TYPE" = "LoadBalancer" ]; then
    log_warning "Service is still LoadBalancer type. This is OK for hostNetwork mode."
    log_info "Checking if ingress is actually working..."
    
    # Test if controller is listening on host
    if kubectl get pod -n ingress-nginx -l app.kubernetes.io/component=controller -o wide 2>/dev/null | grep -q "Running"; then
      log_success "Ingress controller pod is running with hostNetwork"
      kubectl get pod -n ingress-nginx -l app.kubernetes.io/component=controller -o wide
      echo ""
      log_info "Checking ingress backends..."
      kubectl get ingress -A
      echo ""
      log_info "If you still get 404, the issue might be:"
      echo "1. Ingress rules not matching the request"
      echo "2. Backend service not ready"
      echo "3. Certificate validation issues (use HTTP first)"
      echo ""
      VPS_IP=${VPS_IP:-YOUR_VPS_IP}
      echo "Try: curl -H 'Host: <your-domain>' http://${VPS_IP}/"
      exit 0
    fi
  fi
fi

# Patch ingress controller to use hostNetwork
log_info "Patching ingress controller to use hostNetwork..."
kubectl patch deployment ingress-nginx-controller \
  -n ingress-nginx \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/hostNetwork", "value": true}]'

# Also set dnsPolicy to ClusterFirstWithHostNet for proper DNS resolution
kubectl patch deployment ingress-nginx-controller \
  -n ingress-nginx \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/dnsPolicy", "value": "ClusterFirstWithHostNet"}]'

log_info "Waiting for ingress controller to restart..."
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=120s || true

# Verification
log_section "Ingress Controller Configuration Complete"
log_info "Ingress Controller Status:"
kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller
echo ""
log_info "Service Configuration:"
kubectl get svc -n ingress-nginx ingress-nginx-controller
echo ""
VPS_IP=${VPS_IP:-YOUR_VPS_IP}
GRAFANA_DOMAIN=${GRAFANA_DOMAIN:-grafana.masterspace.co.ke}
ARGOCD_DOMAIN=${ARGOCD_DOMAIN:-argocd.masterspace.co.ke}

log_success "Ingress controller now using hostNetwork"
log_info "Your services should now be accessible at:"
echo "  - http://${VPS_IP} (and any domain pointing to this IP)"
echo "  - https://${GRAFANA_DOMAIN}"
echo "  - https://${ARGOCD_DOMAIN}"
echo "  - https://<your-app-domains>"
echo ""
log_info "Verify ingress resources:"
echo "kubectl get ingress -A"
echo ""

