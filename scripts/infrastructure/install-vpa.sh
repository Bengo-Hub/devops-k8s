#!/bin/bash
set -euo pipefail

# Vertical Pod Autoscaler Installation Script
# Installs VPA components for automatic pod resource optimization

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# MANIFESTS_DIR is at repo root, not under scripts
MANIFESTS_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/manifests/vpa"
source "${SCRIPT_DIR}/../tools/common.sh"

# Default configuration
VPA_VERSION=${VPA_VERSION:-1.2.0}

log_section "Installing Vertical Pod Autoscaler (VPA) v${VPA_VERSION}"
log_info "Note: Use VPA_VERSION env var to override (e.g., VPA_VERSION=1.1.0)"

# Pre-flight checks
check_kubectl

# Check if VPA is already installed and healthy
if kubectl get deployment -n kube-system vpa-recommender >/dev/null 2>&1; then
  # Check if VPA components are running
  VPA_ADMISSION_RUNNING=$(kubectl get pods -n kube-system -l app=vpa-admission-controller --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
  VPA_RECOMMENDER_RUNNING=$(kubectl get pods -n kube-system -l app=vpa-recommender --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
  VPA_UPDATER_RUNNING=$(kubectl get pods -n kube-system -l app=vpa-updater --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
  
  if [ "$VPA_ADMISSION_RUNNING" -ge 1 ] && [ "$VPA_RECOMMENDER_RUNNING" -ge 1 ] && [ "$VPA_UPDATER_RUNNING" -ge 1 ]; then
    log_success "VPA already installed and healthy - skipping"
    log_info "VPA components running: Admission=${VPA_ADMISSION_RUNNING}, Recommender=${VPA_RECOMMENDER_RUNNING}, Updater=${VPA_UPDATER_RUNNING}"
    log_info "To force reinstallation, set FORCE_INSTALL=true"
    exit 0
  fi
  
  CURRENT_VERSION=$(kubectl get deployment -n kube-system vpa-recommender -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -oP '(?<=:v)\d+\.\d+\.\d+' || echo "unknown")
  log_warning "VPA CRD exists but components not healthy. Current version: ${CURRENT_VERSION}"
  
  # Check if running in CI/CD (non-interactive)
  if [[ -n "${CI:-}" || -n "${GITHUB_ACTIONS:-}" ]]; then
    if [[ "${FORCE_INSTALL:-}" != "true" ]]; then
      log_info "Running in CI/CD and FORCE_INSTALL not set; skipping VPA upgrade"
      log_warning "VPA exists but not healthy. Set FORCE_INSTALL=true to reinstall"
      exit 0
    fi
  fi
  
  # Interactive mode - ask user
  read -p "Do you want to upgrade/reinstall VPA? (y/N): " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_success "VPA installation skipped."
    exit 0
  fi
fi

# Create manifests directory if it doesn't exist
mkdir -p "${MANIFESTS_DIR}"

# Download VPA manifests
VPA_MANIFEST="${MANIFESTS_DIR}/vpa-v${VPA_VERSION}.yaml"

if [ ! -f "$VPA_MANIFEST" ]; then
  log_info "Downloading VPA v${VPA_VERSION} manifests..."
  
  # VPA manifests are in the autoscaler repo, not as releases
  # Download individual components and combine
  TEMP_DIR=$(mktemp -d)
  
  log_info "Downloading VPA components from GitHub..."
  
  # Base URL for VPA components
  VPA_BASE_URL="https://raw.githubusercontent.com/kubernetes/autoscaler/vertical-pod-autoscaler-${VPA_VERSION}/vertical-pod-autoscaler/deploy"
  
  # Download all required components
  COMPONENTS=(
    "vpa-v1-crd-gen.yaml"
    "vpa-rbac.yaml"
    "recommender-deployment.yaml"
    "updater-deployment.yaml"
    "admission-controller-deployment.yaml"
  )
  
  for component in "${COMPONENTS[@]}"; do
    if curl -fsSL "${VPA_BASE_URL}/${component}" -o "${TEMP_DIR}/${component}"; then
      log_success "Downloaded ${component}"
    else
      log_warning "Could not download ${component}, trying without version suffix..."
      # Some versions use slightly different file names
      component_alt=$(echo "$component" | sed 's/-gen//g')
      curl -fsSL "${VPA_BASE_URL}/${component_alt}" -o "${TEMP_DIR}/${component}" 2>/dev/null || true
    fi
  done
  
  # Combine all components into single manifest
  cat "${TEMP_DIR}"/*.yaml > "$VPA_MANIFEST" 2>/dev/null || {
    log_error "Failed to combine VPA manifests"
    log_warning "Trying direct installation from repo..."
    
    # Fallback: Clone repo and use install script
    git clone --depth 1 --branch vertical-pod-autoscaler-${VPA_VERSION} \
      https://github.com/kubernetes/autoscaler.git "${TEMP_DIR}/autoscaler" 2>/dev/null || {
      log_error "Failed to clone autoscaler repo"
      log_info "Available versions: https://github.com/kubernetes/autoscaler/tags"
      log_info "Try: VPA_VERSION=1.2.0 ./scripts/infrastructure/install-vpa.sh"
      rm -rf "${TEMP_DIR}"
      exit 1
    }
    
    # Use the official install script
    cd "${TEMP_DIR}/autoscaler/vertical-pod-autoscaler"
    ./hack/vpa-up.sh
    cd - >/dev/null
    rm -rf "${TEMP_DIR}"
    
    log_success "VPA installed via official script"
    exit 0
  }
  
  rm -rf "${TEMP_DIR}"
  log_success "VPA manifests prepared"
else
  log_success "VPA manifests already exist: ${VPA_MANIFEST}"
fi

# Apply VPA manifests
log_info "Installing VPA components..."

if kubectl apply -f "$VPA_MANIFEST"; then
  log_success "VPA components installed successfully"
else
  log_error "Failed to install VPA components"
  exit 1
fi

# Wait for VPA components to be ready
log_info "Waiting for VPA components to be ready (may take 1-2 minutes)..."

# Wait for VPA Recommender
kubectl wait --for=condition=available deployment/vpa-recommender -n kube-system --timeout=120s || log_warning "VPA Recommender still starting..."

# Wait for VPA Updater
kubectl wait --for=condition=available deployment/vpa-updater -n kube-system --timeout=120s || log_warning "VPA Updater still starting..."

# Wait for VPA Admission Controller
kubectl wait --for=condition=available deployment/vpa-admission-controller -n kube-system --timeout=120s || log_warning "VPA Admission Controller still starting..."

# Verify installation
log_section "VPA Installation Complete"

log_info "VPA Components Status:"
kubectl get pods -n kube-system -l app.kubernetes.io/name=vpa || kubectl get pods -n kube-system | grep vpa || true

log_info "VPA Deployments:"
kubectl get deployments -n kube-system | grep vpa || true

log_info "Next Steps:"
echo "1. Create VPA resources for your applications"
echo "2. Start with 'updateMode: Off' to observe recommendations"
echo "3. Review recommendations: kubectl describe vpa <vpa-name>"
echo "4. Enable auto-updates when confident: 'updateMode: Recreate' or 'Auto'"
echo ""
log_info "Example VPA Resource:"
echo "See ${MANIFESTS_DIR}/example-vpa.yaml for configuration examples"
echo ""
log_info "Documentation:"
echo "- Local: ${MANIFESTS_DIR}/README.md"
echo "- Official: https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler"
echo "- BengoERP Guide: $(dirname "$SCRIPT_DIR")/../docs/scaling.md"
echo ""

# Check if metrics-server is installed (required for VPA)
if ! kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
  log_warning "metrics-server not found"
  log_warning "VPA requires metrics-server to function properly"
  log_info "Install metrics-server:"
  echo "kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
  echo ""
fi

log_success "VPA installation complete!"

