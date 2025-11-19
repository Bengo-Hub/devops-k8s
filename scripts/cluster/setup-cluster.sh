#!/bin/bash
set -euo pipefail

# Complete Kubernetes Cluster Setup Orchestrator
# This script orchestrates all cluster setup steps in the correct order
# Prerequisites: SSH access, GitHub secrets configured (kubeconfig will be generated)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
CLUSTER_NAME=${CLUSTER_NAME:-mss-prod}
KUBERNETES_VERSION=${KUBERNETES_VERSION:-1.30}
VPS_IP=${VPS_IP:-77.237.232.66}
SKIP_VPS_SETUP=${SKIP_VPS_SETUP:-false}
SKIP_CONTAINERD=${SKIP_CONTAINERD:-false}
SKIP_KUBERNETES=${SKIP_KUBERNETES:-false}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  KUBERNETES CLUSTER SETUP ORCHESTRATOR${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}This script will set up a complete Kubernetes cluster${NC}"
echo -e "${BLUE}Prerequisites (MANUAL SETUP REQUIRED):${NC}"
echo -e "${YELLOW}  ✓ SSH access to VPS configured${NC}"
echo -e "${YELLOW}  ✓ GitHub PAT/token configured${NC}"
echo -e "${YELLOW}  ✓ SSH keys added to GitHub secrets${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root or with sudo${NC}"
    exit 1
fi

# Detect OS
if [ ! -f /etc/os-release ]; then
    echo -e "${RED}Cannot detect OS. This script requires Ubuntu 24.04 LTS${NC}"
    exit 1
fi

. /etc/os-release
if [ "$ID" != "ubuntu" ] || [ "$VERSION_ID" != "24.04" ]; then
    echo -e "${YELLOW}⚠️  Warning: This script is designed for Ubuntu 24.04 LTS${NC}"
    echo -e "${YELLOW}   Detected: $ID $VERSION_ID${NC}"
    read -p "Continue anyway? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        exit 1
    fi
fi

echo -e "${GREEN}✓ OS verified: Ubuntu 24.04 LTS${NC}"
echo ""

# Step 1: Initial VPS Setup
if [ "$SKIP_VPS_SETUP" != "true" ]; then
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  STEP 1: Initial VPS Setup${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    if [ -f "${SCRIPT_DIR}/setup-vps.sh" ]; then
        bash "${SCRIPT_DIR}/setup-vps.sh"
    else
        echo -e "${RED}setup-vps.sh not found in ${SCRIPT_DIR}${NC}"
        exit 1
    fi
    
    echo ""
    echo -e "${GREEN}✓ Step 1 Complete: VPS Initial Setup${NC}"
    echo ""
else
    echo -e "${YELLOW}⏭️  Skipping VPS setup (SKIP_VPS_SETUP=true)${NC}"
    echo ""
fi

# Step 2: Container Runtime (containerd)
if [ "$SKIP_CONTAINERD" != "true" ]; then
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  STEP 2: Container Runtime Setup${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    if [ -f "${SCRIPT_DIR}/setup-containerd.sh" ]; then
        bash "${SCRIPT_DIR}/setup-containerd.sh"
    else
        echo -e "${RED}setup-containerd.sh not found in ${SCRIPT_DIR}${NC}"
        exit 1
    fi
    
    echo ""
    echo -e "${GREEN}✓ Step 2 Complete: Container Runtime Setup${NC}"
    echo ""
else
    echo -e "${YELLOW}⏭️  Skipping containerd setup (SKIP_CONTAINERD=true)${NC}"
    echo ""
fi

# Step 3: Kubernetes Cluster Setup
if [ "$SKIP_KUBERNETES" != "true" ]; then
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  STEP 3: Kubernetes Cluster Setup${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    # Export VPS_IP if provided
    if [ -n "$VPS_IP" ]; then
        export VPS_IP
    fi
    
    if [ -f "${SCRIPT_DIR}/setup-kubernetes.sh" ]; then
        bash "${SCRIPT_DIR}/setup-kubernetes.sh"
    else
        echo -e "${RED}setup-kubernetes.sh not found in ${SCRIPT_DIR}${NC}"
        exit 1
    fi
    
    echo ""
    echo -e "${GREEN}✓ Step 3 Complete: Kubernetes Cluster Setup${NC}"
    echo ""
else
    echo -e "${YELLOW}⏭️  Skipping Kubernetes setup (SKIP_KUBERNETES=true)${NC}"
    echo ""
fi

# Step 4: Configure etcd Auto-Compaction
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  STEP 4: etcd Auto-Compaction Setup${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

if kubectl get nodes >/dev/null 2>&1; then
    echo -e "${BLUE}Configuring etcd auto-compaction to prevent space issues...${NC}"
    
    # Backup original etcd manifest
    if [ -f /etc/kubernetes/manifests/etcd.yaml ]; then
        cp /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/manifests/etcd.yaml.backup
        echo -e "${GREEN}✓ etcd manifest backed up${NC}"
        
        # Check if auto-compaction is already configured
        if grep -q "auto-compaction-mode" /etc/kubernetes/manifests/etcd.yaml; then
            echo -e "${YELLOW}⚠️  etcd auto-compaction already configured${NC}"
        else
            # Add auto-compaction flags using sed
            sed -i '/- etcd/a\    - --auto-compaction-mode=revision\n    - --auto-compaction-retention=1000\n    - --quota-backend-bytes=8589934592' /etc/kubernetes/manifests/etcd.yaml
            
            echo -e "${GREEN}✓ etcd auto-compaction configured${NC}"
            echo -e "${BLUE}  - Auto-compaction mode: revision${NC}"
            echo -e "${BLUE}  - Retention: 1000 revisions${NC}"
            echo -e "${BLUE}  - Quota: 8GB${NC}"
            echo ""
            echo -e "${YELLOW}⚠️  etcd pod will restart automatically with new configuration${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️  etcd manifest not found at /etc/kubernetes/manifests/etcd.yaml${NC}"
        echo -e "${YELLOW}   This may be a different Kubernetes distribution${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  Kubernetes cluster not accessible, skipping etcd configuration${NC}"
fi

echo ""
echo -e "${GREEN}✓ Step 4 Complete: etcd Configuration${NC}"
echo ""

# Step 5: Final Verification and Kubeconfig Preparation
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  STEP 5: Verification & Kubeconfig${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

if kubectl get nodes >/dev/null 2>&1; then
    echo -e "${BLUE}Verifying cluster status...${NC}"
    kubectl get nodes
    echo ""
    
    # Wait for node to be Ready
    echo -e "${BLUE}Waiting for node to be Ready...${NC}"
    for i in {1..60}; do
        if kubectl get nodes --no-headers 2>/dev/null | grep -q "Ready"; then
            echo -e "${GREEN}✓ Node is Ready${NC}"
            break
        fi
        echo -e "${BLUE}  Waiting... (${i}/60)${NC}"
        sleep 5
    done
    
    echo ""
    kubectl get nodes
    echo ""
    
    # Update kubeconfig with public IP if provided
    if [ -n "$VPS_IP" ]; then
        echo -e "${BLUE}Updating kubeconfig with public IP: ${VPS_IP}...${NC}"
        if [ -f "$HOME/.kube/config" ]; then
            sed -i "s|server: https://.*:6443|server: https://${VPS_IP}:6443|" "$HOME/.kube/config"
            echo -e "${GREEN}✓ Kubeconfig updated with public IP${NC}"
        fi
    fi
    
    # Display kubeconfig for GitHub secret
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  SETUP COMPLETE!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${YELLOW}IMPORTANT: Copy your kubeconfig to GitHub secrets${NC}"
    echo ""
    echo -e "${BLUE}Base64-encoded kubeconfig (for GitHub secret KUBE_CONFIG):${NC}"
    echo -e "${GREEN}========================================${NC}"
    if [ -f "$HOME/.kube/config" ]; then
        cat "$HOME/.kube/config" | base64 -w 0 2>/dev/null || cat "$HOME/.kube/config" | base64
    else
        echo -e "${RED}Kubeconfig not found at $HOME/.kube/config${NC}"
    fi
    echo -e "${GREEN}========================================${NC}"
    echo ""
else
    echo -e "${YELLOW}⚠️  Could not verify cluster. Please check manually.${NC}"
fi

echo ""
echo -e "${BLUE}Next Steps:${NC}"
echo -e "${BLUE}  1. Copy the base64 kubeconfig above${NC}"
echo -e "${BLUE}  2. Add it as GitHub organization secret: KUBE_CONFIG${NC}"
echo -e "${BLUE}  3. Ensure GitHub PAT/token is configured: DEVOPS_K8S_ACCESS_TOKEN${NC}"
echo -e "${BLUE}  4. Ensure SSH keys are in GitHub secrets: SSH_PRIVATE_KEY${NC}"
echo -e "${BLUE}  5. Run the provisioning workflow to install infrastructure${NC}"
echo ""

