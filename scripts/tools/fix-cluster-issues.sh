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
  # Convert to integer (handle whitespace)
  HAS_APP_PODS=$(echo "$HAS_APP_PODS" | tr -d '[:space:]')
  HAS_APP_PODS=${HAS_APP_PODS:-0}
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
  echo "    --docker-username=\${REGISTRY_USERNAME} \\"
  echo "    --docker-password=\${REGISTRY_PASSWORD} \\"
  echo "    -n <namespace>"
  echo ""
  log_info "Note: Set REGISTRY_USERNAME and REGISTRY_PASSWORD environment variables before running the command above"
fi

# 4. Check for VPA TLS secret
log_info "Checking VPA TLS secret..."
if kubectl get deployment vpa-admission-controller -n kube-system >/dev/null 2>&1; then
  # Check if secret exists and has correct keys
  SECRET_EXISTS=$(kubectl get secret vpa-tls-certs -n kube-system >/dev/null 2>&1 && echo "true" || echo "false")
  CA_CERT_EXISTS=$(kubectl get secret vpa-tls-certs -n kube-system -o jsonpath='{.data.caCert\.pem}' 2>/dev/null | wc -c || echo "0")
  
  if [ "$SECRET_EXISTS" = "false" ] || [ "$CA_CERT_EXISTS" -lt 10 ]; then
    log_warning "VPA admission controller is installed but TLS secret is missing or invalid."
    
    if command -v openssl >/dev/null 2>&1; then
      log_info "Generating VPA TLS certificates..."
      TMP_DIR=$(mktemp -d)
      trap "rm -rf ${TMP_DIR}" EXIT
      
      # Generate CA
      openssl genrsa -out "${TMP_DIR}/ca.key" 2048 >/dev/null 2>&1
      openssl req -x509 -new -nodes -key "${TMP_DIR}/ca.key" \
        -subj "/CN=vpa-ca" -days 365 -out "${TMP_DIR}/ca.crt" >/dev/null 2>&1
      
      # Generate server cert
      openssl genrsa -out "${TMP_DIR}/server.key" 2048 >/dev/null 2>&1
      openssl req -new -key "${TMP_DIR}/server.key" \
        -subj "/CN=vpa-admission-controller.kube-system.svc" \
        -out "${TMP_DIR}/server.csr" >/dev/null 2>&1
      openssl x509 -req -in "${TMP_DIR}/server.csr" \
        -CA "${TMP_DIR}/ca.crt" -CAkey "${TMP_DIR}/ca.key" \
        -CAcreateserial -out "${TMP_DIR}/server.crt" -days 365 >/dev/null 2>&1
      
      # Create/update secret
      kubectl create secret generic vpa-tls-certs \
        --from-file=caCert.pem="${TMP_DIR}/ca.crt" \
        --from-file=serverCert.pem="${TMP_DIR}/server.crt" \
        --from-file=serverKey.pem="${TMP_DIR}/server.key" \
        -n kube-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 && \
        log_success "VPA TLS secret created" || log_warning "Failed to create VPA TLS secret"
      
      # Ensure volume mounts exist
      VOLUME_MOUNT=$(kubectl get deployment vpa-admission-controller -n kube-system \
        -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[?(@.name=="tls-certs")].name}' 2>/dev/null || echo "")
      if [ -z "$VOLUME_MOUNT" ]; then
        log_info "Adding TLS volume mount to VPA admission controller..."
        kubectl patch deployment vpa-admission-controller -n kube-system \
          --type='json' \
          -p='[{"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"tls-certs","mountPath":"/etc/tls-certs","readOnly":true}}]' >/dev/null 2>&1 || true
      fi
      
      VOLUME=$(kubectl get deployment vpa-admission-controller -n kube-system \
        -o jsonpath='{.spec.template.spec.volumes[?(@.name=="tls-certs")].name}' 2>/dev/null || echo "")
      if [ -z "$VOLUME" ]; then
        kubectl patch deployment vpa-admission-controller -n kube-system \
          --type='json' \
          -p='[{"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"tls-certs","secret":{"secretName":"vpa-tls-certs"}}}]' >/dev/null 2>&1 || true
      fi
      
      rm -rf "${TMP_DIR}"
      trap - EXIT
      
      log_info "Restarting VPA admission controller pod..."
      kubectl delete pod -n kube-system -l app=vpa-admission-controller --wait=false 2>/dev/null || true
      sleep 5
    else
      log_warning "OpenSSL not found - cannot generate VPA TLS certificates automatically."
      log_info "Run the install-vpa.sh script or create the secret manually."
    fi
  else
    log_info "VPA TLS secret exists and appears valid"
  fi
fi

# 4a. Check for duplicate ingress-nginx pods (port conflicts)
log_info "Checking for duplicate ingress-nginx pods..."
INGRESS_PODS=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller --no-headers 2>/dev/null | wc -l || echo "0")
INGRESS_RUNNING=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
INGRESS_CRASHING=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null | wc -l || echo "0")

if [ "$INGRESS_PODS" -gt 1 ] || [ "$INGRESS_CRASHING" -gt 0 ]; then
  log_warning "Found ${INGRESS_PODS} ingress-nginx pods (${INGRESS_RUNNING} running, ${INGRESS_CRASHING} crashing)"
  log_info "Cleaning up duplicate/crashing ingress-nginx pods..."
  
  # Delete all non-running pods
  NON_RUNNING_PODS=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller --field-selector=status.phase!=Running,status.phase!=Succeeded -o name 2>/dev/null || true)
  if [ -n "$NON_RUNNING_PODS" ]; then
    echo "$NON_RUNNING_PODS" | xargs -r kubectl delete -n ingress-nginx --wait=false 2>/dev/null || true
  fi
  
  # Delete orphaned replicasets
  ORPHANED_RS=$(kubectl get replicasets -n ingress-nginx -l app.kubernetes.io/component=controller --no-headers 2>/dev/null | \
    awk '{if ($2 != $3 || $2 != $4) print $1}' || true)
  if [ -n "$ORPHANED_RS" ]; then
    echo "$ORPHANED_RS" | xargs -r -I {} kubectl delete replicaset {} -n ingress-nginx --wait=false 2>/dev/null || true
  fi
  
  # Ensure deployment is scaled to 1 replica
  kubectl scale deployment ingress-nginx-controller -n ingress-nginx --replicas=1 2>/dev/null || true
fi

# 4b. Check for storage provisioner
log_info "Checking storage provisioner..."
if ! kubectl get pods -n local-path-storage -l app=local-path-provisioner --field-selector=status.phase=Running --no-headers 2>/dev/null | grep -q Running; then
  log_warning "local-path-provisioner pod is not running. PVCs may fail to bind."
  log_info "Installing storage provisioner..."
  if [ -f "${SCRIPT_DIR}/../infrastructure/install-storage-provisioner.sh" ]; then
    "${SCRIPT_DIR}/../infrastructure/install-storage-provisioner.sh" || log_warning "Failed to install storage provisioner"
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

