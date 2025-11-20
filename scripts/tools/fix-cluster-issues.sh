#!/bin/bash
set -euo pipefail

# Cluster Issues Diagnostic and Fix Script
# Addresses common issues: ImagePullBackOff, missing secrets, port conflicts

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

log_section "Cluster Issues Diagnostic and Fix"

# Check kubectl
check_kubectl

# 1. Check for duplicate monitoring stacks (causing port conflicts)
log_info "Checking for duplicate monitoring installations..."
DUPLICATE_MONITORING=$(kubectl get pods -n infra -l app.kubernetes.io/name=prometheus-node-exporter --no-headers 2>/dev/null | wc -l || echo "0")
if [ "$DUPLICATE_MONITORING" -gt 1 ]; then
  log_warning "Found multiple node-exporter pods (${DUPLICATE_MONITORING}). This may cause port conflicts."
  log_info "Checking for duplicate Helm releases..."
  kubectl get pods -n infra -l app.kubernetes.io/name=prometheus-node-exporter -o wide || true
fi

# 2. Check Docker Hub rate limiting
log_info "Checking Docker Hub image pull status..."
IMAGE_PULL_ERRORS=$(kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded -o json 2>/dev/null | \
  jq -r '.items[] | select(.status.containerStatuses[]?.state.waiting?.reason == "ImagePullBackOff" or .status.containerStatuses[]?.state.waiting?.reason == "ErrImagePull") | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || echo "")

if [ -n "$IMAGE_PULL_ERRORS" ]; then
  log_warning "Found ImagePullBackOff errors. Possible causes:"
  echo "  - Docker Hub rate limiting (anonymous pulls limited to 100/6hrs)"
  echo "  - Network connectivity issues"
  echo "  - Missing image pull secrets"
  echo ""
  log_info "Affected pods:"
  echo "$IMAGE_PULL_ERRORS" | while read -r pod; do
    if [ -n "$pod" ]; then
      NS=$(echo "$pod" | cut -d'/' -f1)
      NAME=$(echo "$pod" | cut -d'/' -f2)
      IMAGE=$(kubectl get pod "$NAME" -n "$NS" -o jsonpath='{.spec.containers[0].image}' 2>/dev/null || echo "unknown")
      echo "  - $pod (image: $IMAGE)"
    fi
  done
fi

# 3. Check for missing registry-credentials secrets
log_info "Checking for missing registry-credentials secrets..."
NAMESPACES=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
MISSING_REGISTRY_SECRETS=""

for ns in $NAMESPACES; do
  # Skip system namespaces
  if [[ "$ns" == "kube-system" || "$ns" == "kube-public" || "$ns" == "kube-node-lease" || "$ns" == "default" ]]; then
    continue
  fi
  
  # Check if namespace has pods that need registry-credentials
  HAS_APP_PODS=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -v "Completed\|Succeeded" | wc -l || echo "0")
  if [ "$HAS_APP_PODS" -gt 0 ]; then
    if ! kubectl get secret registry-credentials -n "$ns" >/dev/null 2>&1; then
      MISSING_REGISTRY_SECRETS="$MISSING_REGISTRY_SECRETS $ns"
    fi
  fi
done

if [ -n "$MISSING_REGISTRY_SECRETS" ]; then
  log_warning "Found namespaces missing registry-credentials secret:"
  for ns in $MISSING_REGISTRY_SECRETS; do
    echo "  - $ns"
  done
  echo ""
  log_info "To create registry-credentials secret, run:"
  echo "  kubectl create secret docker-registry registry-credentials \\"
  echo "    --docker-server=docker.io \\"
  echo "    --docker-username=$REGISTRY_USERNAME \\"
  echo "    --docker-password=$REGISTRY_PASSWORD \\"
  echo "    -n <namespace>"
fi

# 4. Check for VPA TLS secret
log_info "Checking VPA TLS secret..."
if kubectl get deployment vpa-admission-controller -n kube-system >/dev/null 2>&1; then
  if ! kubectl get secret vpa-tls-certs -n kube-system >/dev/null 2>&1; then
    log_warning "VPA admission controller is installed but TLS secret is missing."
    log_info "VPA admission controller will generate the secret automatically on first run."
    log_info "If it's stuck, you can delete the admission controller pod to trigger secret generation:"
    echo "  kubectl delete pod -n kube-system -l app=vpa-admission-controller"
  fi
fi

# 5. Check for CreateContainerConfigError (missing application secrets)
log_info "Checking for CreateContainerConfigError..."
CONFIG_ERRORS=$(kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded -o json 2>/dev/null | \
  jq -r '.items[] | select(.status.containerStatuses[]?.state.waiting?.reason == "CreateContainerConfigError") | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || echo "")

if [ -n "$CONFIG_ERRORS" ]; then
  log_warning "Found CreateContainerConfigError. This usually means missing secrets or configmaps."
  echo "$CONFIG_ERRORS" | while read -r pod; do
    if [ -n "$pod" ]; then
      NS=$(echo "$pod" | cut -d'/' -f1)
      NAME=$(echo "$pod" | cut -d'/' -f2)
      echo "  - $pod"
      # Try to get more details
      ERROR_MSG=$(kubectl get pod "$NAME" -n "$NS" -o jsonpath='{.status.containerStatuses[0].state.waiting.message}' 2>/dev/null || echo "")
      if [ -n "$ERROR_MSG" ]; then
        echo "    Error: $ERROR_MSG"
      fi
    fi
  done
fi

# 6. Check node-exporter port conflict
log_info "Checking node-exporter port conflict..."
NODE_EXPORTER_PENDING=$(kubectl get pods --all-namespaces -l app.kubernetes.io/name=prometheus-node-exporter --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l || echo "0")
if [ "$NODE_EXPORTER_PENDING" -gt 0 ]; then
  log_warning "Found pending node-exporter pods. This is usually due to port conflicts."
  log_info "Node-exporter uses hostNetwork and binds to port 9100."
  log_info "Only one node-exporter pod can run per node."
  log_info "Checking for duplicate monitoring installations..."
  kubectl get pods --all-namespaces -l app.kubernetes.io/name=prometheus-node-exporter -o wide || true
fi

# Summary and recommendations
echo ""
log_section "Summary and Recommendations"
echo ""
echo "1. Docker Hub Rate Limiting:"
echo "   - Anonymous pulls are limited to 100 per 6 hours"
echo "   - Solution: Create registry-credentials secret with Docker Hub credentials"
echo "   - Or: Wait for rate limit to reset"
echo ""
echo "2. Missing Secrets:"
if [ -n "$MISSING_REGISTRY_SECRETS" ]; then
  echo "   - Create registry-credentials secrets in affected namespaces"
fi
if [ -n "$CONFIG_ERRORS" ]; then
  echo "   - Check application-specific secrets/configmaps"
fi
echo ""
echo "3. Port Conflicts:"
if [ "$NODE_EXPORTER_PENDING" -gt 0 ]; then
  echo "   - Remove duplicate monitoring installations"
  echo "   - Only one prometheus-node-exporter should run per node"
fi
echo ""
echo "4. VPA TLS Secret:"
echo "   - Will be auto-generated by admission controller"
echo "   - If stuck, restart the admission controller pod"
echo ""

log_success "Diagnostic complete"

