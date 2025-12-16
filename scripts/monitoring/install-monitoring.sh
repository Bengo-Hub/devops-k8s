#!/bin/bash
set -euo pipefail

# Production-ready Monitoring Stack Installation
# Installs Prometheus, Grafana, Alertmanager with production defaults

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# MANIFESTS_DIR is at repo root, not under scripts
MANIFESTS_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/manifests"
source "${SCRIPT_DIR}/../tools/common.sh"

# Default production configuration
GRAFANA_DOMAIN=${GRAFANA_DOMAIN:-grafana.masterspace.co.ke}
MONITORING_NAMESPACE=${MONITORING_NAMESPACE:-infra}

log_section "Installing Prometheus + Grafana monitoring stack (Production)"
log_info "Grafana Domain: ${GRAFANA_DOMAIN}"

# Pre-flight checks
check_kubectl
ensure_storage_class "${SCRIPT_DIR}"
ensure_helm

# Ensure Helm is in PATH (may be installed via snap)
if ! command -v helm >/dev/null 2>&1; then
  if [ -f /snap/bin/helm ]; then
    export PATH="$PATH:/snap/bin"
    log_info "Added /snap/bin to PATH for Helm"
  fi
fi

ensure_cert_manager "${SCRIPT_DIR}"

# Add Helm repository
add_helm_repo "prometheus-community" "https://prometheus-community.github.io/helm-charts"

# Create infra namespace (monitoring is deployed here as shared infrastructure)
ensure_namespace "${MONITORING_NAMESPACE}"

# Idempotency/force flags
FORCE_MONITORING_INSTALL=${FORCE_MONITORING_INSTALL:-${FORCE_INSTALL:-false}}

# If release already exists and stack is healthy, skip unless forced
if helm -n "${MONITORING_NAMESPACE}" status prometheus >/dev/null 2>&1 && [ "${FORCE_MONITORING_INSTALL}" != "true" ]; then
  log_info "Helm release 'prometheus' already exists - checking monitoring health..."
  GRAFANA_READY=$(kubectl get pods -n "${MONITORING_NAMESPACE}" -l app.kubernetes.io/name=grafana --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
  PROM_READY=$(kubectl get pods -n "${MONITORING_NAMESPACE}" -l app.kubernetes.io/name=prometheus --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
  if [ "${GRAFANA_READY}" -ge 1 ] && [ "${PROM_READY}" -ge 1 ]; then
    log_success "Monitoring stack already installed and healthy - skipping install/upgrade (set FORCE_MONITORING_INSTALL=true or FORCE_INSTALL=true to override)."
    exit 0
  else
    log_warning "Monitoring release exists but not fully healthy - continuing with installation/upgrade."
  fi
fi

# Update prometheus-values.yaml with dynamic domain
TEMP_VALUES=/tmp/prometheus-values-prod.yaml

# Check if manifest file exists before copying
if [ ! -f "${MANIFESTS_DIR}/monitoring/prometheus-values.yaml" ]; then
  log_error "Manifest file not found: ${MANIFESTS_DIR}/monitoring/prometheus-values.yaml"
  log_info "MANIFESTS_DIR resolved to: ${MANIFESTS_DIR}"
  log_info "SCRIPT_DIR: ${SCRIPT_DIR}"
  log_info "Current working directory: $(pwd)"
  log_info "Checking if file exists at alternative locations..."
  ls -la "${MANIFESTS_DIR}/monitoring/" 2>/dev/null || true
  ls -la "$(dirname "$SCRIPT_DIR")/../manifests/monitoring/" 2>/dev/null || true
  exit 1
fi

cp "${MANIFESTS_DIR}/monitoring/prometheus-values.yaml" "${TEMP_VALUES}"
sed -i "s|grafana\.masterspace\.co\.ke|${GRAFANA_DOMAIN}|g" "${TEMP_VALUES}" 2>/dev/null || \
  sed -i '' "s|grafana\.masterspace\.co\.ke|${GRAFANA_DOMAIN}|g" "${TEMP_VALUES}" 2>/dev/null || true

# Install or upgrade kube-prometheus-stack (idempotent)
log_info "Installing/upgrading kube-prometheus-stack..."
log_info "This may take 10-15 minutes. Logs will be streamed below..."

# Note: Monitoring uses helm upgrade --install which is idempotent
# Clean up orphaned resources that may block Helm adoption
# This runs ALWAYS (not just in cleanup mode) to prevent "cannot be imported" errors
log_info "Checking for orphaned monitoring resources that may block Helm adoption..."
log_info "Scanning for resources with Helm labels but missing release annotations..."

# Function to check if resource has proper Helm release annotation
check_and_clean_orphaned() {
  local resource_type=$1
  local resource_name=$2
  
  if kubectl get "$resource_type" "$resource_name" -n "${MONITORING_NAMESPACE}" >/dev/null 2>&1; then
    # Check for release-name annotation (required for Helm adoption)
    RELEASE_NAME=$(kubectl get "$resource_type" "$resource_name" -n "${MONITORING_NAMESPACE}" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || echo "")
    
    if [ -z "$RELEASE_NAME" ]; then
      log_warning "Found orphaned $resource_type/$resource_name (missing release annotation) - deleting to allow Helm adoption"
      kubectl delete "$resource_type" "$resource_name" -n "${MONITORING_NAMESPACE}" --ignore-not-found=true || true
      return 0
    fi
  fi
  return 1
}

ORPHANED_COUNT=0

# Clean up ALL prometheus-* ServiceAccounts (kube-state-metrics, node-exporter, grafana, etc.)
for sa_name in $(kubectl get serviceaccounts -n "${MONITORING_NAMESPACE}" -o name 2>/dev/null | grep "prometheus-" | sed 's|serviceaccount/||' || echo ""); do
  if [ -n "$sa_name" ]; then
    if check_and_clean_orphaned serviceaccount "$sa_name"; then
      ORPHANED_COUNT=$((ORPHANED_COUNT + 1))
    fi
  fi
done

# Clean up other common orphaned resources (configmaps, secrets, deployments)
for resource_type in configmap secret deployment; do
  for resource_name in $(kubectl get "$resource_type" -n "${MONITORING_NAMESPACE}" -o name 2>/dev/null | grep "prometheus-" | sed "s|$resource_type/||" || echo ""); do
    if [ -n "$resource_name" ]; then
      if check_and_clean_orphaned "$resource_type" "$resource_name"; then
        ORPHANED_COUNT=$((ORPHANED_COUNT + 1))
      fi
    fi
  done
done

if [ $ORPHANED_COUNT -gt 0 ]; then
  log_success "Cleaned up $ORPHANED_COUNT orphaned resource(s)"
else
  log_info "No orphaned resources found requiring cleanup"
fi

########################
# PVC Helm adoption fix #
########################
# Helm fails if an existing PVC is missing Helm ownership metadata; patch instead of delete to preserve data
ensure_helm_metadata() {
  local resource_type=$1
  local resource_name=$2
  local release_name=$3
  local ns=$4

  # For cluster-scoped resources, do not use -n
  local ns_arg=""
  if [ -n "$ns" ] && [[ "$resource_type" != "clusterrole" && "$resource_type" != "clusterrolebinding" ]]; then
    ns_arg="-n $ns"
  fi

  if ! kubectl get "$resource_type" "$resource_name" $ns_arg >/dev/null 2>&1; then
    return 0
  fi

  local managed_by
  local ann_release
  local ann_ns
  managed_by=$(kubectl get "$resource_type" "$resource_name" $ns_arg -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)
  ann_release=$(kubectl get "$resource_type" "$resource_name" $ns_arg -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || true)
  ann_ns=$(kubectl get "$resource_type" "$resource_name" $ns_arg -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-namespace}' 2>/dev/null || true)

  if [ "$managed_by" = "Helm" ] && [ "$ann_release" = "$release_name" ] && [ "$ann_ns" = "$ns" ]; then
    log_info "Existing $resource_type/$resource_name already has Helm metadata"
    return 0
  fi

  log_warning "Existing $resource_type/$resource_name missing Helm metadata - patching for Helm adoption (preserves data)"
  kubectl label "$resource_type" "$resource_name" $ns_arg app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true
  kubectl annotate "$resource_type" "$resource_name" $ns_arg meta.helm.sh/release-name="$release_name" meta.helm.sh/release-namespace="$ns" --overwrite >/dev/null 2>&1 || true
  return 0
}

# Patch common resources before Helm install to avoid adoption failures
# PVCs (namespaced)
ensure_helm_metadata pvc prometheus-grafana prometheus "${MONITORING_NAMESPACE}"

# Cluster-scoped resources (ClusterRole, ClusterRoleBinding)
for cluster_resource_type in clusterrole clusterrolebinding; do
  for res_name in $(kubectl get "$cluster_resource_type" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep "prometheus-grafana" || echo ""); do
    if [ -n "$res_name" ]; then
      # For cluster resources, pass empty namespace (not used for cluster-scoped)
      managed=$(kubectl get "$cluster_resource_type" "$res_name" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || echo "")
      rel=$(kubectl get "$cluster_resource_type" "$res_name" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || echo "")
      relns=$(kubectl get "$cluster_resource_type" "$res_name" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-namespace}' 2>/dev/null || echo "")
      if [ "$managed" != "Helm" ] || [ "$rel" != "prometheus" ] || [ "$relns" != "${MONITORING_NAMESPACE}" ]; then
        log_warning "Patching cluster-scoped $cluster_resource_type/$res_name with Helm metadata"
        kubectl label "$cluster_resource_type" "$res_name" app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true
        kubectl annotate "$cluster_resource_type" "$res_name" meta.helm.sh/release-name=prometheus meta.helm.sh/release-namespace="${MONITORING_NAMESPACE}" --overwrite >/dev/null 2>&1 || true
      fi
    fi
  done
done

# Full cleanup mode: more aggressive resource removal
if is_cleanup_mode && ! helm -n "${MONITORING_NAMESPACE}" status prometheus >/dev/null 2>&1; then
  log_info "Cleanup mode active - performing full monitoring resource cleanup..."
  
  # Clean up any orphaned ingresses first (prevents webhook validation errors)
  echo -e "${YELLOW}Cleaning up orphaned monitoring ingresses...${NC}"
  kubectl delete ingress -n "${MONITORING_NAMESPACE}" -l "app.kubernetes.io/name=grafana" --wait=false 2>/dev/null || true
  kubectl delete ingress -n "${MONITORING_NAMESPACE}" -l "app.kubernetes.io/instance=prometheus" --wait=false 2>/dev/null || true
  kubectl delete ingress -n "${MONITORING_NAMESPACE}" -l "app.kubernetes.io/instance=monitoring" --wait=false 2>/dev/null || true
  
  # Also check for ingresses matching the Grafana domain
  ORPHANED_GRAFANA_INGRESS=$(kubectl get ingress -n "${MONITORING_NAMESPACE}" -o json 2>/dev/null | \
    jq -r ".items[] | select(.spec.rules[]?.host == \"${GRAFANA_DOMAIN}\") | .metadata.name" 2>/dev/null || true)
  
  if [ -n "$ORPHANED_GRAFANA_INGRESS" ]; then
    echo -e "${YELLOW}Found orphaned ingress(es) for ${GRAFANA_DOMAIN}: $ORPHANED_GRAFANA_INGRESS${NC}"
    for ing in $ORPHANED_GRAFANA_INGRESS; do
      kubectl delete ingress "$ing" -n "${MONITORING_NAMESPACE}" --wait=false 2>/dev/null || true
    done
  fi
  
  # Clean up any orphaned resources before install
  kubectl delete statefulset,deployment,pod,service -n "${MONITORING_NAMESPACE}" -l "app.kubernetes.io/instance=prometheus" --wait=true --grace-period=0 --force 2>/dev/null || true
  sleep 5
fi

# If Grafana PVC already exists, do NOT attempt to shrink it. Respect current size.
HELM_EXTRA_OPTS=""
GRAFANA_PVC_SIZE=$(kubectl -n "${MONITORING_NAMESPACE}" get pvc prometheus-grafana -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || true)
if [ -n "${GRAFANA_PVC_SIZE:-}" ]; then
  log_info "Detected existing Grafana PVC size: ${GRAFANA_PVC_SIZE} - preventing shrink on upgrade"
  HELM_EXTRA_OPTS="$HELM_EXTRA_OPTS --set-string grafana.persistence.size=${GRAFANA_PVC_SIZE}"
fi

# Function to fix stuck Helm operations
fix_stuck_helm() {
    local release_name=${1:-prometheus}
    local namespace=${2:-${MONITORING_NAMESPACE}}

    echo -e "${YELLOW}🔧 Attempting to fix stuck Helm operation for ${release_name}...${NC}"

    # Check for stuck operations
    local status=$(helm status ${release_name} -n ${namespace} 2>/dev/null | grep "STATUS:" | awk '{print $2}')
    
    if [[ "$status" == "pending-upgrade" || "$status" == "pending-install" || "$status" == "pending-rollback" ]]; then
        echo -e "${YELLOW}📊 Found stuck operation (status: $status), attempting cleanup...${NC}"

        # CRITICAL: Delete the Helm secret that's locking the operation
        echo -e "${YELLOW}🔓 Unlocking Helm release by removing pending secret...${NC}"
        
        # Find and delete the pending-upgrade secret
        PENDING_SECRETS=$(kubectl -n ${namespace} get secrets -l "owner=helm,status=pending-upgrade,name=${release_name}" -o name 2>/dev/null || true)
        if [ -n "$PENDING_SECRETS" ]; then
            echo -e "${YELLOW}Deleting pending operation secrets:${NC}"
            echo "$PENDING_SECRETS" | xargs -r kubectl -n ${namespace} delete 2>/dev/null || true
        fi
        
        # Also clean up pending-install and pending-rollback
        PENDING_INSTALL=$(kubectl -n ${namespace} get secrets -l "owner=helm,status=pending-install,name=${release_name}" -o name 2>/dev/null || true)
        if [ -n "$PENDING_INSTALL" ]; then
            echo "$PENDING_INSTALL" | xargs -r kubectl -n ${namespace} delete 2>/dev/null || true
        fi
        PENDING_ROLLBACK=$(kubectl -n ${namespace} get secrets -l "owner=helm,status=pending-rollback,name=${release_name}" -o name 2>/dev/null || true)
        if [ -n "$PENDING_ROLLBACK" ]; then
            echo "$PENDING_ROLLBACK" | xargs -r kubectl -n ${namespace} delete 2>/dev/null || true
        fi

        # Force delete problematic pods
        echo -e "${YELLOW}🗑️  Force deleting stuck pods...${NC}"
        kubectl delete pods -n ${namespace} -l "app.kubernetes.io/instance=${release_name}" --force --grace-period=0 2>/dev/null || true
        
        # Wait for cleanup
        sleep 10

        # Find the last successfully deployed revision
        echo -e "${YELLOW}📜 Checking Helm history...${NC}"
        if helm history ${release_name} -n ${namespace} >/dev/null 2>&1; then
            # Get last deployed (successful) revision
            LAST_DEPLOYED=$(helm history ${release_name} -n ${namespace} --max 100 -o json 2>/dev/null | jq -r '.[] | select(.status == "deployed") | .revision' | tail -1)
            
            if [ -n "$LAST_DEPLOYED" ] && [ "$LAST_DEPLOYED" != "null" ]; then
                echo -e "${YELLOW}📉 Rolling back to last deployed revision: $LAST_DEPLOYED...${NC}"
                helm rollback ${release_name} $LAST_DEPLOYED -n ${namespace} --force --wait --timeout=5m 2>/dev/null || {
                    echo -e "${YELLOW}⚠️  Rollback command failed, but lock is removed. Proceeding...${NC}"
                }
                sleep 15
                return 0
            fi
        fi

        echo -e "${GREEN}✅ Helm lock removed. Ready for fresh install/upgrade${NC}"
        return 0
    else
        echo -e "${GREEN}✓ No stuck operation detected (status: ${status})${NC}"
        return 0
    fi
}

# Check for and clean up conflicting ingress resources
echo -e "${YELLOW}Checking for conflicting ingress resources...${NC}"
ALL_INGRESSES=$(kubectl get ingress -n "${MONITORING_NAMESPACE}" -o json 2>/dev/null | \
  jq -r ".items[] | select(.spec.rules[]?.host == \"${GRAFANA_DOMAIN}\") | .metadata.name" 2>/dev/null || true)

if [ -n "$ALL_INGRESSES" ]; then
  echo -e "${YELLOW}Found ingress(es) for ${GRAFANA_DOMAIN}:${NC}"
  echo "$ALL_INGRESSES"
  
  CONFLICTING_INGRESSES=""
  
  # Filter out cert-manager ACME solver ingresses (temporary, used for Let's Encrypt validation)
  # These have naming pattern: cm-acme-http-solver-*
  for ingress_name in $ALL_INGRESSES; do
    # Skip cert-manager ACME solver ingresses (they're temporary and should be ignored)
    if echo "$ingress_name" | grep -q "^cm-acme-http-solver-"; then
      echo -e "${BLUE}ℹ️  Ignoring cert-manager ACME solver ingress: $ingress_name (temporary, used for TLS validation)${NC}"
      continue
    fi
    
    # Check if ingress is managed by Helm release
    INGRESS_LABELS=$(kubectl get ingress "$ingress_name" -n "${MONITORING_NAMESPACE}" -o jsonpath='{.metadata.labels}' 2>/dev/null || true)
    INGRESS_OWNER=$(kubectl get ingress "$ingress_name" -n "${MONITORING_NAMESPACE}" -o jsonpath='{.metadata.ownerReferences[*].name}' 2>/dev/null || true)
    
    # Check if it's managed by the prometheus Helm release
    if echo "$INGRESS_LABELS" | grep -q "app.kubernetes.io/instance=prometheus\|app.kubernetes.io/managed-by=Helm"; then
      if helm -n "${MONITORING_NAMESPACE}" status prometheus >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Ingress $ingress_name is managed by Helm release 'prometheus' - keeping it${NC}"
        continue
      else
        echo -e "${YELLOW}⚠️  Ingress $ingress_name has Helm labels but release doesn't exist - will delete${NC}"
        CONFLICTING_INGRESSES="$CONFLICTING_INGRESSES $ingress_name"
      fi
    # Check if it's from monitoring/grafana but not managed by Helm
    elif echo "$INGRESS_LABELS" | grep -q "grafana\|prometheus\|monitoring"; then
      echo -e "${YELLOW}⚠️  Found orphaned monitoring ingress: $ingress_name (not managed by Helm)${NC}"
      CONFLICTING_INGRESSES="$CONFLICTING_INGRESSES $ingress_name"
    else
      echo -e "${YELLOW}⚠️  Warning: Ingress $ingress_name exists but doesn't appear to be from monitoring stack${NC}"
      echo -e "${YELLOW}    Skipping deletion - may be managed by another service${NC}"
    fi
  done
  
  # Only delete truly conflicting ingresses
  if [ -n "$CONFLICTING_INGRESSES" ]; then
    echo -e "${YELLOW}Deleting conflicting/orphaned ingresses...${NC}"
    for ingress_name in $CONFLICTING_INGRESSES; do
      echo -e "${YELLOW}  Deleting: $ingress_name${NC}"
      kubectl delete ingress "$ingress_name" -n "${MONITORING_NAMESPACE}" --wait=false 2>/dev/null || true
    done
    sleep 5
    echo -e "${GREEN}✓ Conflicting ingresses cleaned up${NC}"
  else
    echo -e "${GREEN}✓ No conflicting ingresses found (cert-manager solver ingresses ignored)${NC}"
  fi
fi

# Check for stuck operations first
if helm status prometheus -n "${MONITORING_NAMESPACE}" 2>/dev/null | grep -q "STATUS: pending-upgrade"; then
    echo -e "${YELLOW}⚠️  Detected stuck Helm operation. Running fix...${NC}"
    fix_stuck_helm prometheus "${MONITORING_NAMESPACE}"
fi

# Run Helm with output to both stdout and capture exit code
set +e
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  -n "${MONITORING_NAMESPACE}" \
  -f "${TEMP_VALUES}" \
  ${HELM_EXTRA_OPTS} \
  --set-string grafana.adminPassword=changeme \
  --set-string grafana.ingress.enabled=true \
  --set-string grafana.ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/ssl-redirect=true \
  --set-string grafana.ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/force-ssl-redirect=true \
  --timeout=15m \
  --wait 2>&1 | tee /tmp/helm-monitoring-install.log
HELM_EXIT_CODE=${PIPESTATUS[0]}
set -e

# Check if Helm succeeded
if [ $HELM_EXIT_CODE -eq 0 ]; then
  echo -e "${GREEN}✓ kube-prometheus-stack installed successfully${NC}"
  
  # Verify ingress was created (wait a bit for resources to settle)
  echo -e "${BLUE}Verifying Grafana ingress was created...${NC}"
  sleep 5
  if ! kubectl get ingress -n "${MONITORING_NAMESPACE}" prometheus-grafana >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️  Grafana ingress not found after Helm upgrade. Checking Helm values...${NC}"
    
    # Check if ingress is enabled in Helm values
    INGRESS_ENABLED=$(helm -n "${MONITORING_NAMESPACE}" get values prometheus -o json 2>/dev/null | jq -r '.grafana.ingress.enabled // "true"' || echo "true")
    if [ "$INGRESS_ENABLED" != "true" ]; then
      echo -e "${YELLOW}⚠️  Ingress is disabled in Helm values. Enabling it...${NC}"
      helm upgrade prometheus prometheus-community/kube-prometheus-stack \
        -n "${MONITORING_NAMESPACE}" \
        -f "${TEMP_VALUES}" \
        ${HELM_EXTRA_OPTS} \
        --set-string grafana.ingress.enabled=true \
        --set-string grafana.ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/ssl-redirect=true \
        --set-string grafana.ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/force-ssl-redirect=true \
        --timeout=5m \
        --wait=false 2>&1 | tee /tmp/helm-monitoring-fix-ingress.log
      sleep 10
    else
      echo -e "${BLUE}Ingress is enabled in values. Waiting for it to be created...${NC}"
      sleep 10
      if kubectl get ingress -n "${MONITORING_NAMESPACE}" prometheus-grafana >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Grafana ingress now exists${NC}"
      else
        echo -e "${YELLOW}⚠️  Ingress still not found. This may be normal if Grafana service is not ready yet.${NC}"
      fi
    fi
  else
    echo -e "${GREEN}✓ Grafana ingress exists${NC}"
  fi
else
  echo -e "${RED}Installation failed with exit code $HELM_EXIT_CODE${NC}"
  echo ""
  echo -e "${YELLOW}Recent log output:${NC}"
  tail -50 /tmp/helm-monitoring-install.log || true
  echo ""
  echo -e "${YELLOW}Pod status:${NC}"
  kubectl get pods -n "${MONITORING_NAMESPACE}" || true
  echo ""
  echo -e "${YELLOW}Helm status:${NC}"
  helm -n "${MONITORING_NAMESPACE}" status prometheus || true
  echo ""

  # Check for common failure patterns and attempt fixes
  if grep -q "another operation.*in progress" /tmp/helm-monitoring-install.log 2>/dev/null; then
    echo -e "${YELLOW}🔧 Stuck operation detected during installation. Running fix...${NC}"
    fix_stuck_helm prometheus "${MONITORING_NAMESPACE}"
    echo -e "${BLUE}🔄 Please retry the installation after cleanup completes${NC}"
  elif grep -q "host.*is already defined in ingress" /tmp/helm-monitoring-install.log 2>/dev/null; then
    echo -e "${YELLOW}🔧 Ingress conflict detected. Cleaning up conflicting ingresses...${NC}"
    
    # Extract the conflicting ingress name from the error
    CONFLICTING_INGRESS=$(grep "is already defined in ingress" /tmp/helm-monitoring-install.log | sed -n 's/.*ingress \([^ ]*\).*/\1/p' | head -1)
    
    if [ -n "$CONFLICTING_INGRESS" ]; then
      # Parse namespace/name format
      INGRESS_NS=$(echo "$CONFLICTING_INGRESS" | cut -d'/' -f1)
      INGRESS_NAME=$(echo "$CONFLICTING_INGRESS" | cut -d'/' -f2)
      
      echo -e "${YELLOW}Deleting conflicting ingress: $INGRESS_NS/$INGRESS_NAME${NC}"
      kubectl delete ingress "$INGRESS_NAME" -n "$INGRESS_NS" --wait=false 2>/dev/null || true
      
      # Also clean up any other monitoring-related ingresses
      kubectl delete ingress -n "${MONITORING_NAMESPACE}" -l "app.kubernetes.io/name=grafana" --wait=false 2>/dev/null || true
      kubectl delete ingress -n "${MONITORING_NAMESPACE}" -l "app.kubernetes.io/instance=prometheus" --wait=false 2>/dev/null || true
      
      sleep 10
      
      echo -e "${BLUE}🔄 Retrying installation after ingress cleanup...${NC}"
      helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
        -n "${MONITORING_NAMESPACE}" \
        -f "${TEMP_VALUES}" \
        ${HELM_EXTRA_OPTS} \
        --timeout=15m \
        --wait 2>&1 | tee /tmp/helm-monitoring-install-retry.log
      
      RETRY_EXIT=$?
      if [ $RETRY_EXIT -eq 0 ]; then
        echo -e "${GREEN}✓ Installation succeeded after ingress cleanup!${NC}"
        exit 0
      else
        echo -e "${RED}Installation still failed after retry. Check logs.${NC}"
        tail -50 /tmp/helm-monitoring-install-retry.log || true
      fi
    fi
  fi

  echo -e "${RED}Check /tmp/helm-monitoring-install.log for full details${NC}"
  exit 1
fi

# Apply ERP-specific alerts
echo -e "${YELLOW}Applying ERP-specific alerts...${NC}"
# Manifests have hardcoded 'monitoring' namespace, but we're using ${MONITORING_NAMESPACE} (usually 'infra')
# Replace namespace in manifest before applying
if [ -f "${MANIFESTS_DIR}/monitoring/erp-alerts.yaml" ]; then
  sed "s/namespace: monitoring/namespace: ${MONITORING_NAMESPACE}/g" "${MANIFESTS_DIR}/monitoring/erp-alerts.yaml" | kubectl apply -f -
  echo -e "${GREEN}✓ ERP alerts configured in ${MONITORING_NAMESPACE} namespace${NC}"
else
  log_warning "erp-alerts.yaml not found, skipping..."
fi

# Check certificate status
echo ""
echo -e "${YELLOW}Checking TLS certificate status...${NC}"
CERT_READY=$(kubectl get certificate -n "${MONITORING_NAMESPACE}" grafana-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
CERT_SECRET=$(kubectl get secret -n "${MONITORING_NAMESPACE}" grafana-tls -o jsonpath='{.data.tls\.crt}' 2>/dev/null || echo "")

if [ "$CERT_READY" = "True" ] && [ -n "$CERT_SECRET" ]; then
  echo -e "${GREEN}✓ TLS certificate is ready${NC}"
  CERT_EXPIRY=$(kubectl get certificate -n "${MONITORING_NAMESPACE}" grafana-tls -o jsonpath='{.status.notAfter}' 2>/dev/null || echo "")
  if [ -n "$CERT_EXPIRY" ]; then
    echo -e "${BLUE}  Certificate expires: ${CERT_EXPIRY}${NC}"
  fi
elif [ "$CERT_READY" = "False" ] || [ "$CERT_READY" = "Unknown" ]; then
  echo -e "${YELLOW}⚠️  TLS certificate not ready yet${NC}"
  echo -e "${BLUE}Checking cert-manager status...${NC}"
  
  # Check cert-manager ClusterIssuer
  if kubectl get clusterissuer letsencrypt-prod >/dev/null 2>&1; then
    echo -e "${GREEN}✓ cert-manager ClusterIssuer 'letsencrypt-prod' exists${NC}"
  else
    echo -e "${RED}✗ cert-manager ClusterIssuer 'letsencrypt-prod' not found${NC}"
    echo -e "${YELLOW}  Run: ./scripts/infrastructure/install-cert-manager.sh${NC}"
  fi
  
  # Check Certificate resource
  if kubectl get certificate -n "${MONITORING_NAMESPACE}" grafana-tls >/dev/null 2>&1; then
    echo -e "${BLUE}Certificate resource exists. Checking status...${NC}"
    kubectl describe certificate -n "${MONITORING_NAMESPACE}" grafana-tls | grep -A 5 "Status\|Events" || true
  else
    echo -e "${YELLOW}⚠️  Certificate resource 'grafana-tls' not found in ${MONITORING_NAMESPACE} namespace${NC}"
    echo -e "${BLUE}  This should be created automatically by cert-manager when the ingress is created${NC}"
  fi
  
  # Enhanced diagnostics
  echo ""
  echo -e "${YELLOW}=== Enhanced TLS Diagnostics ===${NC}"
  
  # Check DNS resolution
  echo -e "${BLUE}1. Checking DNS resolution...${NC}"
  VPS_IP=${VPS_IP:-$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "UNKNOWN")}
  DNS_RESOLVED=$(dig +short "${GRAFANA_DOMAIN}" 2>/dev/null | head -1 || echo "")
  if [ -n "$DNS_RESOLVED" ]; then
    echo -e "${GREEN}✓ DNS resolves to: ${DNS_RESOLVED}${NC}"
    if [ "$DNS_RESOLVED" != "$VPS_IP" ] && [ "$VPS_IP" != "UNKNOWN" ]; then
      echo -e "${RED}✗ DNS points to ${DNS_RESOLVED}, but VPS IP is ${VPS_IP}${NC}"
      echo -e "${YELLOW}  Action: Update DNS A record to point ${GRAFANA_DOMAIN} → ${VPS_IP}${NC}"
    fi
  else
    echo -e "${RED}✗ DNS does not resolve for ${GRAFANA_DOMAIN}${NC}"
    echo -e "${YELLOW}  Action: Create DNS A record: ${GRAFANA_DOMAIN} → ${VPS_IP}${NC}"
  fi
  
  # Check ingress controller
  echo -e "${BLUE}2. Checking ingress controller...${NC}"
  INGRESS_PODS=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
  if [ "$INGRESS_PODS" -ge 1 ]; then
    echo -e "${GREEN}✓ Ingress controller is running (${INGRESS_PODS} pod(s))${NC}"
    INGRESS_HOSTNET=$(kubectl get pod -n ingress-nginx -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].spec.hostNetwork}' 2>/dev/null || echo "false")
    if [ "$INGRESS_HOSTNET" = "true" ]; then
      echo -e "${GREEN}✓ Ingress controller using hostNetwork (ports 80/443 bound to node)${NC}"
    else
      echo -e "${YELLOW}⚠️  Ingress controller not using hostNetwork - may need NodePort/LoadBalancer${NC}"
    fi
  else
    echo -e "${RED}✗ Ingress controller not running${NC}"
  fi
  
  # Check ingress resource
  echo -e "${BLUE}3. Checking Grafana ingress...${NC}"
  if kubectl get ingress -n "${MONITORING_NAMESPACE}" prometheus-grafana >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Grafana ingress exists${NC}"
    INGRESS_HOST=$(kubectl get ingress -n "${MONITORING_NAMESPACE}" prometheus-grafana -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")
    if [ "$INGRESS_HOST" = "${GRAFANA_DOMAIN}" ]; then
      echo -e "${GREEN}✓ Ingress host matches: ${INGRESS_HOST}${NC}"
    else
      echo -e "${YELLOW}⚠️  Ingress host mismatch: ${INGRESS_HOST} (expected: ${GRAFANA_DOMAIN})${NC}"
    fi
  else
    echo -e "${RED}✗ Grafana ingress not found${NC}"
    echo -e "${YELLOW}⚠️  Ingress was deleted but Helm didn't recreate it. Checking Helm release...${NC}"
    
    # Check if Helm release exists and try to recreate ingress
    if helm -n "${MONITORING_NAMESPACE}" status prometheus >/dev/null 2>&1; then
      echo -e "${BLUE}Helm release exists. Ingress should be managed by Helm.${NC}"
      echo -e "${BLUE}Waiting a few seconds for ingress to be created...${NC}"
      sleep 10
      
      # Check again
      if kubectl get ingress -n "${MONITORING_NAMESPACE}" prometheus-grafana >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Grafana ingress now exists${NC}"
      else
        echo -e "${YELLOW}⚠️  Ingress still not found. This may indicate a Helm values issue.${NC}"
        echo -e "${BLUE}Checking Helm values for ingress configuration...${NC}"
        helm -n "${MONITORING_NAMESPACE}" get values prometheus | grep -A 10 "ingress:" || true
      fi
    else
      echo -e "${RED}✗ Helm release 'prometheus' not found${NC}"
    fi
  fi
  
  # Check certificate challenges
  echo -e "${BLUE}4. Checking certificate challenges...${NC}"
  CHALLENGES=$(kubectl get challenges -n "${MONITORING_NAMESPACE}" -l acme.cert-manager.io/order-name 2>/dev/null | grep -v NAME | wc -l || echo "0")
  # Trim whitespace from wc output
  CHALLENGES=$(echo "$CHALLENGES" | tr -d '[:space:]')
  CHALLENGES=${CHALLENGES:-0}
  if [[ "$CHALLENGES" =~ ^[0-9]+$ ]] && [ "$CHALLENGES" -gt 0 ]; then
    echo -e "${BLUE}Found ${CHALLENGES} challenge(s). Status:${NC}"
    kubectl get challenges -n "${MONITORING_NAMESPACE}" -l acme.cert-manager.io/order-name -o custom-columns=NAME:.metadata.name,STATUS:.status.state,REASON:.status.reason 2>/dev/null || true
  else
    echo -e "${YELLOW}No challenges found yet (may still be creating)${NC}"
  fi
  
  # Check cert-manager logs for errors
  echo -e "${BLUE}5. Checking cert-manager logs (last 20 lines)...${NC}"
  CERT_MGR_LOGS=$(kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager --tail=20 2>/dev/null | grep -i "error\|fail\|denied" || echo "")
  if [ -n "$CERT_MGR_LOGS" ]; then
    echo -e "${RED}Found errors in cert-manager logs:${NC}"
    echo "$CERT_MGR_LOGS"
  else
    echo -e "${GREEN}No errors found in recent cert-manager logs${NC}"
  fi
  
  echo ""
  echo -e "${YELLOW}=== Manual Troubleshooting Commands ===${NC}"
  echo "1. Verify DNS: dig ${GRAFANA_DOMAIN} +short"
  echo "2. Check certificate: kubectl get certificate -n ${MONITORING_NAMESPACE} grafana-tls -o yaml"
  echo "3. Check challenges: kubectl get challenges -n ${MONITORING_NAMESPACE}"
  echo "4. Check cert-manager logs: kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager --tail=50"
  echo "5. Check ingress: kubectl get ingress -n ${MONITORING_NAMESPACE} prometheus-grafana -o yaml"
  echo "6. Test HTTP access: curl -v -H 'Host: ${GRAFANA_DOMAIN}' http://${VPS_IP}/"
  echo "7. Test ACME challenge path: curl -v http://${GRAFANA_DOMAIN}/.well-known/acme-challenge/test"
  echo "8. Wait 2-5 minutes for cert-manager to provision certificate"
  echo ""
  echo -e "${YELLOW}Common Issues:${NC}"
  echo "- DNS not pointing to VPS IP: Update DNS A record"
  echo "- Port 80 blocked: Ensure firewall allows port 80 (required for HTTP-01 challenge)"
  echo "- HTTPS redirect blocking ACME challenge: Check ingress has 'ssl-redirect: false' annotation"
  echo "  Current annotations: kubectl get ingress -n ${MONITORING_NAMESPACE} prometheus-grafana -o jsonpath='{.metadata.annotations}'"
  echo "- Certificate still issuing: Wait 2-5 minutes and check again"
  echo "- Ingress controller not accessible: Check hostNetwork configuration"
  echo ""
fi

# Get Grafana admin password
echo ""
echo -e "${GREEN}=== Monitoring Stack Installation Complete ===${NC}"
echo ""
echo -e "${BLUE}Grafana Access Information:${NC}"
echo "  URL: https://${GRAFANA_DOMAIN}"
echo "  Username: admin"
GRAFANA_PASSWORD=$(kubectl get secret -n "${MONITORING_NAMESPACE}" prometheus-grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d || echo "")
if [ -n "$GRAFANA_PASSWORD" ]; then
  echo "  Password: $GRAFANA_PASSWORD"
else
  echo "  Password: (check secret manually)"
fi
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
VPS_IP=${VPS_IP:-YOUR_VPS_IP}
echo "1. Ensure DNS: ${GRAFANA_DOMAIN} → Your VPS IP (${VPS_IP})"
if [ "$CERT_READY" != "True" ]; then
  echo "2. ⚠️  Wait for cert-manager to provision TLS certificate (check status above)"
  echo "   Monitor: kubectl get certificate -n ${MONITORING_NAMESPACE} grafana-tls -w"
else
  echo "2. ✓ TLS certificate is ready"
fi
echo "3. Visit https://${GRAFANA_DOMAIN} and login"
echo "4. Import dashboards (315, 6417, 1860) - see docs/monitoring.md"
echo "5. Configure Alertmanager email: sed 's/namespace: monitoring/namespace: ${MONITORING_NAMESPACE}/g' manifests/monitoring/alertmanager-config.yaml | kubectl apply -f -"
echo ""
echo -e "${BLUE}Alternative Access (port-forward - no TLS required):${NC}"
echo "kubectl port-forward -n ${MONITORING_NAMESPACE} svc/prometheus-grafana 3000:80"
echo "Then visit: http://localhost:3000"
echo ""
echo -e "${BLUE}Prometheus:${NC}"
echo "kubectl port-forward -n ${MONITORING_NAMESPACE} svc/prometheus-kube-prometheus-prometheus 9090:9090"
echo "Then visit: http://localhost:9090"
echo ""
