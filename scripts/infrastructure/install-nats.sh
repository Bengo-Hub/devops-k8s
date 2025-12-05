#!/usr/bin/env bash
set -euo pipefail

# Installs or Verifies NATS Deployment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tools/common.sh"
source "${SCRIPT_DIR}/../tools/helm-utils.sh"

NAMESPACE=${NATS_NAMESPACE:-messaging}

log_section "Installing NATS (JetStream)"

# Pre-flight checks
check_kubectl
check_cluster_health
ensure_helm

# Add NATS repository
add_helm_repo "nats" "https://nats-io.github.io/k8s/helm/charts/"

# Create namespace
ensure_namespace "${NAMESPACE}"

log_info "NATS is managed via ArgoCD (apps/nats/app.yaml)."
log_info "This script ensures the chart is available and namespace exists."

# Manual install/upgrade check (optional, if running outside ArgoCD)
if [ "${MANUAL_INSTALL:-false}" = "true" ]; then
    log_info "Manual install requested..."
    helm upgrade --install nats nats/nats \
        --namespace "${NAMESPACE}" \
        --set config.jetstream.enabled=true \
        --set config.jetstream.fileStore.enabled=true \
        --set config.jetstream.fileStore.pvc.enabled=true \
        --set config.jetstream.fileStore.pvc.size=10Gi \
        --set config.cluster.enabled=true \
        --set config.cluster.replicas=3 \
        --wait
    log_success "NATS installed manually."
else
    log_info "Skipping manual Helm install (ArgoCD will handle it)."
    log_info "Run with MANUAL_INSTALL=true to force usage of this script."
fi

# Verify connection URL for apps
log_info "Service URL: nats.${NAMESPACE}.svc.cluster.local:4222"
