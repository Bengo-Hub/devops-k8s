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
  
  # Check deployment replica count (should be 1 for hostNetwork)
  CURRENT_REPLICAS=$(kubectl get deployment ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
  if [ "$CURRENT_REPLICAS" != "1" ]; then
    log_warning "Deployment has ${CURRENT_REPLICAS} replicas, but hostNetwork requires 1 replica"
    log_info "Scaling deployment to 1 replica..."
    kubectl scale deployment ingress-nginx-controller -n ingress-nginx --replicas=1
    sleep 5
  fi
  
  # Check for duplicate/crashing pods and clean them up
  ALL_PODS=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller --no-headers 2>/dev/null | wc -l || echo "0")
  RUNNING_PODS=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
  CRASHING_PODS=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null | wc -l || echo "0")
  
  if [ "$ALL_PODS" -gt 1 ] || [ "$CRASHING_PODS" -gt 0 ]; then
    log_warning "Found ${ALL_PODS} total pods (${RUNNING_PODS} running, ${CRASHING_PODS} crashing)"
    log_info "Cleaning up duplicate/crashing pods..."
    
    # Delete all non-running pods
    kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller --field-selector=status.phase!=Running,status.phase!=Succeeded -o name 2>/dev/null | \
      xargs -r kubectl delete -n ingress-nginx --wait=false 2>/dev/null || true
    
    # If we have multiple running pods, keep only the newest one
    if [ "$RUNNING_PODS" -gt 1 ]; then
      log_info "Multiple running pods detected, keeping only the newest one..."
      OLDEST_POD=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller --field-selector=status.phase=Running --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
      if [ -n "$OLDEST_POD" ]; then
        log_info "Deleting older pod: $OLDEST_POD"
        kubectl delete pod "$OLDEST_POD" -n ingress-nginx --wait=false || true
      fi
    fi
    
    sleep 5
  fi
  
  # Re-check after cleanup
  READY_PODS=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
  
  if [ "$READY_PODS" -eq 1 ]; then
    log_success "Ingress controller is running and healthy (1 pod)"
    kubectl get pod -n ingress-nginx -l app.kubernetes.io/component=controller -o wide
    echo ""
    log_info "Checking ingress backends..."
    kubectl get ingress -A || true
    echo ""
    log_info "To force reconfiguration, set FORCE_RECONFIGURE=true"
    exit 0
  elif [ "$READY_PODS" -gt 1 ]; then
    log_warning "Multiple pods still running - will force cleanup"
  else
    log_warning "No healthy pods found - will patch anyway"
  fi
fi

# Ensure deployment is scaled to 1 replica (required for hostNetwork)
CURRENT_REPLICAS=$(kubectl get deployment ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
if [ "$CURRENT_REPLICAS" != "1" ]; then
  log_info "Scaling deployment to 1 replica (required for hostNetwork)..."
  kubectl scale deployment ingress-nginx-controller -n ingress-nginx --replicas=1
  sleep 5
fi

# Patch ingress controller to use hostNetwork
log_info "Patching ingress controller to use hostNetwork..."
kubectl patch deployment ingress-nginx-controller \
  -n ingress-nginx \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/hostNetwork", "value": true}]' || \
kubectl patch deployment ingress-nginx-controller \
  -n ingress-nginx \
  --type='merge' \
  -p='{"spec":{"template":{"spec":{"hostNetwork":true}}}}'

# Also set dnsPolicy to ClusterFirstWithHostNet for proper DNS resolution
kubectl patch deployment ingress-nginx-controller \
  -n ingress-nginx \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/dnsPolicy", "value": "ClusterFirstWithHostNet"}]' || \
kubectl patch deployment ingress-nginx-controller \
  -n ingress-nginx \
  --type='merge' \
  -p='{"spec":{"template":{"spec":{"dnsPolicy":"ClusterFirstWithHostNet"}}}}'

# Clean up any duplicate pods before waiting for rollout
log_info "Cleaning up any duplicate pods..."
kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller --field-selector=status.phase!=Running,status.phase!=Succeeded -o name 2>/dev/null | \
  xargs -r kubectl delete -n ingress-nginx --wait=false 2>/dev/null || true

log_info "Waiting for ingress controller to restart..."
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=120s || true

# Final cleanup check - ensure only one pod exists
sleep 5
FINAL_POD_COUNT=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller --no-headers 2>/dev/null | wc -l || echo "0")
if [ "$FINAL_POD_COUNT" -gt 1 ]; then
  log_warning "Multiple pods still exist after rollout, cleaning up duplicates..."
  # Keep only the newest running pod
  RUNNING_PODS=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller --field-selector=status.phase=Running --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
  if [ -n "$RUNNING_PODS" ]; then
    POD_ARRAY=($RUNNING_PODS)
    # Delete all but the last (newest) pod
    for i in $(seq 0 $((${#POD_ARRAY[@]} - 2))); do
      log_info "Deleting duplicate pod: ${POD_ARRAY[$i]}"
      kubectl delete pod "${POD_ARRAY[$i]}" -n ingress-nginx --wait=false || true
    done
  fi
fi

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

