#!/bin/bash
set -euo pipefail

# Install local-path storage provisioner for Kubernetes
# Required for PersistentVolumeClaims on bare-metal/VPS installations

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}Installing Storage Provisioner...${NC}"

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

# Check if any storage class already exists
if kubectl get storageclass 2>/dev/null | grep -q "(default)"; then
  echo -e "${GREEN}✓ Default storage class already configured${NC}"
  kubectl get storageclass
  exit 0
fi

# Install local-path-provisioner
echo -e "${YELLOW}Installing local-path storage provisioner...${NC}"
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml

# Wait for provisioner to be ready
echo -e "${YELLOW}Waiting for provisioner to be ready...${NC}"
kubectl wait --for=condition=ready pod -l app=local-path-provisioner -n local-path-storage --timeout=120s || true

# Set as default storage class
echo -e "${YELLOW}Setting local-path as default storage class...${NC}"
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Verification
echo ""
echo -e "${GREEN}=== Storage Provisioner Installation Complete ===${NC}"
echo ""
echo -e "${BLUE}Available Storage Classes:${NC}"
kubectl get storageclass
echo ""
echo -e "${GREEN}✓ local-path storage provisioner is ready${NC}"
echo -e "${YELLOW}PersistentVolumeClaims will now be automatically provisioned on the local disk${NC}"
echo ""

