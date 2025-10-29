#!/bin/bash
set -euo pipefail

# Vertical Pod Autoscaler Installation Script
# Installs VPA components for automatic pod resource optimization

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default configuration
VPA_VERSION=${VPA_VERSION:-1.2.0}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(dirname "$SCRIPT_DIR")/vpa-manifests"

echo -e "${GREEN}Installing Vertical Pod Autoscaler (VPA) v${VPA_VERSION}...${NC}"
echo -e "${BLUE}Note: Use VPA_VERSION env var to override (e.g., VPA_VERSION=1.1.0)${NC}"

# Pre-flight checks
if ! command -v kubectl &> /dev/null; then
  echo -e "${RED}kubectl command not found. Aborting.${NC}"
  exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo -e "${RED}Cannot connect to cluster. Ensure KUBECONFIG is set. Aborting.${NC}"
  exit 1
fi

echo -e "${GREEN}✓ kubectl configured and cluster reachable${NC}"

# Check if VPA is already installed
if kubectl get deployment -n kube-system vpa-recommender >/dev/null 2>&1; then
  echo -e "${YELLOW}VPA already installed. Checking version...${NC}"
  CURRENT_VERSION=$(kubectl get deployment -n kube-system vpa-recommender -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -oP '(?<=:v)\d+\.\d+\.\d+' || echo "unknown")
  echo -e "${BLUE}Current VPA version: ${CURRENT_VERSION}${NC}"
  
  read -p "Do you want to upgrade/reinstall VPA? (y/N): " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}VPA installation skipped.${NC}"
    exit 0
  fi
fi

# Create manifests directory if it doesn't exist
mkdir -p "${MANIFESTS_DIR}"

# Download VPA manifests
VPA_MANIFEST="${MANIFESTS_DIR}/vpa-v${VPA_VERSION}.yaml"

if [ ! -f "$VPA_MANIFEST" ]; then
  echo -e "${YELLOW}Downloading VPA v${VPA_VERSION} manifests...${NC}"
  
  # VPA manifests are in the autoscaler repo, not as releases
  # Download individual components and combine
  TEMP_DIR=$(mktemp -d)
  
  echo -e "${BLUE}Downloading VPA components from GitHub...${NC}"
  
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
      echo -e "${GREEN}  ✓ Downloaded ${component}${NC}"
    else
      echo -e "${YELLOW}  ⚠ Could not download ${component}, trying without version suffix...${NC}"
      # Some versions use slightly different file names
      component_alt=$(echo "$component" | sed 's/-gen//g')
      curl -fsSL "${VPA_BASE_URL}/${component_alt}" -o "${TEMP_DIR}/${component}" 2>/dev/null || true
    fi
  done
  
  # Combine all components into single manifest
  cat "${TEMP_DIR}"/*.yaml > "$VPA_MANIFEST" 2>/dev/null || {
    echo -e "${RED}Failed to combine VPA manifests${NC}"
    echo -e "${YELLOW}Trying direct installation from repo...${NC}"
    
    # Fallback: Clone repo and use install script
    git clone --depth 1 --branch vertical-pod-autoscaler-${VPA_VERSION} \
      https://github.com/kubernetes/autoscaler.git "${TEMP_DIR}/autoscaler" 2>/dev/null || {
      echo -e "${RED}Failed to clone autoscaler repo${NC}"
      echo -e "${YELLOW}Available versions: https://github.com/kubernetes/autoscaler/tags${NC}"
      echo -e "${BLUE}Try: VPA_VERSION=1.2.0 ./scripts/install-vpa.sh${NC}"
      rm -rf "${TEMP_DIR}"
      exit 1
    }
    
    # Use the official install script
    cd "${TEMP_DIR}/autoscaler/vertical-pod-autoscaler"
    ./hack/vpa-up.sh
    cd - >/dev/null
    rm -rf "${TEMP_DIR}"
    
    echo -e "${GREEN}✓ VPA installed via official script${NC}"
    exit 0
  }
  
  rm -rf "${TEMP_DIR}"
  echo -e "${GREEN}✓ VPA manifests prepared${NC}"
else
  echo -e "${GREEN}✓ VPA manifests already exist: ${VPA_MANIFEST}${NC}"
fi

# Apply VPA manifests
echo -e "${YELLOW}Installing VPA components...${NC}"

if kubectl apply -f "$VPA_MANIFEST"; then
  echo -e "${GREEN}✓ VPA components installed successfully${NC}"
else
  echo -e "${RED}Failed to install VPA components${NC}"
  exit 1
fi

# Wait for VPA components to be ready
echo -e "${YELLOW}Waiting for VPA components to be ready (may take 1-2 minutes)...${NC}"

# Wait for VPA Recommender
kubectl wait --for=condition=available deployment/vpa-recommender -n kube-system --timeout=120s || echo -e "${YELLOW}VPA Recommender still starting...${NC}"

# Wait for VPA Updater
kubectl wait --for=condition=available deployment/vpa-updater -n kube-system --timeout=120s || echo -e "${YELLOW}VPA Updater still starting...${NC}"

# Wait for VPA Admission Controller
kubectl wait --for=condition=available deployment/vpa-admission-controller -n kube-system --timeout=120s || echo -e "${YELLOW}VPA Admission Controller still starting...${NC}"

# Verify installation
echo ""
echo -e "${GREEN}=== VPA Installation Complete ===${NC}"
echo ""

echo -e "${BLUE}VPA Components Status:${NC}"
kubectl get pods -n kube-system -l app.kubernetes.io/name=vpa || kubectl get pods -n kube-system | grep vpa || true

echo ""
echo -e "${BLUE}VPA Deployments:${NC}"
kubectl get deployments -n kube-system | grep vpa || true

echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Create VPA resources for your applications"
echo "2. Start with 'updateMode: Off' to observe recommendations"
echo "3. Review recommendations: kubectl describe vpa <vpa-name>"
echo "4. Enable auto-updates when confident: 'updateMode: Recreate' or 'Auto'"
echo ""
echo -e "${BLUE}Example VPA Resource:${NC}"
echo "See ${MANIFESTS_DIR}/example-vpa.yaml for configuration examples"
echo ""
echo -e "${BLUE}Documentation:${NC}"
echo "- Local: ${MANIFESTS_DIR}/README.md"
echo "- Official: https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler"
echo "- BengoERP Guide: $(dirname "$SCRIPT_DIR")/docs/scaling.md"
echo ""

# Check if metrics-server is installed (required for VPA)
if ! kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
  echo -e "${YELLOW}⚠️  Warning: metrics-server not found${NC}"
  echo -e "${YELLOW}VPA requires metrics-server to function properly${NC}"
  echo -e "${BLUE}Install metrics-server:${NC}"
  echo "kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
  echo ""
fi

echo -e "${GREEN}✅ VPA installation complete!${NC}"

