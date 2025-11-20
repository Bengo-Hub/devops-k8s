#!/bin/bash
set -euo pipefail

# Verify all ingress configurations are correct
# Checks for:
# - Missing cert-manager annotations
# - Missing ingressClassName
# - Missing TLS configuration
# - Ingress controller health

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

log_section "Verifying Ingress Configurations"

# Pre-flight checks
check_kubectl

# Check ingress controller health
log_info "Checking ingress controller status..."
INGRESS_PODS=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller --no-headers 2>/dev/null | wc -l || echo "0")
RUNNING_PODS=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")

if [ "$INGRESS_PODS" -eq 0 ]; then
  log_error "No ingress controller pods found!"
  exit 1
elif [ "$RUNNING_PODS" -eq 0 ]; then
  log_error "No running ingress controller pods found!"
  kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller
  exit 1
elif [ "$INGRESS_PODS" -gt 1 ]; then
  log_warning "Multiple ingress controller pods found (${INGRESS_PODS} total, ${RUNNING_PODS} running)"
  log_warning "With hostNetwork, only 1 pod should be running"
  kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller
else
  log_success "Ingress controller is healthy (1 pod running)"
fi

# Check all ingresses
log_info "Checking all ingress resources..."
ALL_INGRESSES=$(kubectl get ingress -A --no-headers 2>/dev/null | grep -v "cm-acme-http-solver" || echo "")
if [ -z "$ALL_INGRESSES" ]; then
  log_warning "No ingress resources found"
  exit 0
fi

ISSUES=0

# Check each ingress
while IFS= read -r line; do
  if [ -z "$line" ]; then
    continue
  fi
  
  NAMESPACE=$(echo "$line" | awk '{print $1}')
  NAME=$(echo "$line" | awk '{print $2}')
  
  # Skip ACME solver ingresses (temporary)
  if [[ "$NAME" == cm-acme-http-solver-* ]]; then
    continue
  fi
  
  log_info "Checking ingress: ${NAMESPACE}/${NAME}"
  
  # Get ingress YAML
  INGRESS_YAML=$(kubectl get ingress "$NAME" -n "$NAMESPACE" -o yaml 2>/dev/null || echo "")
  
  if [ -z "$INGRESS_YAML" ]; then
    log_warning "  ⚠️  Could not retrieve ingress YAML"
    ((ISSUES++))
    continue
  fi
  
  # Check for ingressClassName
  if ! echo "$INGRESS_YAML" | grep -q "ingressClassName:"; then
    log_error "  ❌ Missing ingressClassName"
    ((ISSUES++))
  else
    INGRESS_CLASS=$(echo "$INGRESS_YAML" | grep "ingressClassName:" | awk '{print $2}' | tr -d '"')
    if [ "$INGRESS_CLASS" != "nginx" ]; then
      log_warning "  ⚠️  ingressClassName is '${INGRESS_CLASS}' (expected 'nginx')"
    else
      log_success "  ✓ ingressClassName: nginx"
    fi
  fi
  
  # Check for cert-manager annotation
  if ! echo "$INGRESS_YAML" | grep -q "cert-manager.io/cluster-issuer:"; then
    log_error "  ❌ Missing cert-manager.io/cluster-issuer annotation"
    ((ISSUES++))
  else
    ISSUER=$(echo "$INGRESS_YAML" | grep "cert-manager.io/cluster-issuer:" | awk '{print $2}' | tr -d '"')
    log_success "  ✓ cert-manager annotation: ${ISSUER}"
  fi
  
  # Check for TLS configuration
  if ! echo "$INGRESS_YAML" | grep -qA 2 "tls:"; then
    log_warning "  ⚠️  No TLS configuration found"
  else
    TLS_HOSTS=$(echo "$INGRESS_YAML" | grep -A 5 "tls:" | grep "hosts:" -A 3 | grep "^-" | sed 's/^[[:space:]]*-[[:space:]]*//' || echo "")
    if [ -n "$TLS_HOSTS" ]; then
      log_success "  ✓ TLS configured for: $(echo "$TLS_HOSTS" | tr '\n' ' ')"
    fi
  fi
  
  # Check for SSL redirect (should be present for production)
  if echo "$INGRESS_YAML" | grep -q "nginx.ingress.kubernetes.io/ssl-redirect:"; then
    SSL_REDIRECT=$(echo "$INGRESS_YAML" | grep "nginx.ingress.kubernetes.io/ssl-redirect:" | awk '{print $2}' | tr -d '"')
    if [ "$SSL_REDIRECT" = "true" ]; then
      log_success "  ✓ SSL redirect enabled"
    else
      log_warning "  ⚠️  SSL redirect disabled (may be intentional for ACME challenges)"
    fi
  else
    log_warning "  ⚠️  No SSL redirect annotation found"
  fi
  
done <<< "$ALL_INGRESSES"

# Summary
echo ""
if [ "$ISSUES" -eq 0 ]; then
  log_success "✅ All ingress configurations are valid"
else
  log_error "❌ Found ${ISSUES} issue(s) with ingress configurations"
  exit 1
fi

