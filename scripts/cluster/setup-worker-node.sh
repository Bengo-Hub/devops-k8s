#!/bin/bash
set -euo pipefail

# Worker Node Setup Orchestrator
# Prepares a fresh Ubuntu 24.04 LTS VPS and joins it to the mss-prod cluster.
#
# Required env vars (get these from generate-join-token.sh on the master):
#   MASTER_IP      - public IP of mss-prod-master (e.g. 77.237.232.66)
#   JOIN_TOKEN     - kubeadm bootstrap token
#   CA_CERT_HASH   - sha256:<hash> of the cluster CA
#
# Optional env vars:
#   WORKER_NUMBER  - node index suffix, default: 1 (produces hostname mss-prod-worker-1)
#   CLUSTER_NAME   - default: mss-prod
#   KUBERNETES_VERSION - default: 1.30 (must match master)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CLUSTER_NAME=${CLUSTER_NAME:-mss-prod}
WORKER_NUMBER=${WORKER_NUMBER:-1}
KUBERNETES_VERSION=${KUBERNETES_VERSION:-1.30}
MASTER_IP=${MASTER_IP:-}
JOIN_TOKEN=${JOIN_TOKEN:-}
CA_CERT_HASH=${CA_CERT_HASH:-}

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  WORKER NODE SETUP${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Cluster:          ${CLUSTER_NAME}${NC}"
echo -e "${BLUE}Worker Number:    ${WORKER_NUMBER}${NC}"
echo -e "${BLUE}Kubernetes:       v${KUBERNETES_VERSION}${NC}"
echo -e "${BLUE}Master IP:        ${MASTER_IP:-<not set>}${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root or with sudo${NC}"
    exit 1
fi

if [ -z "$MASTER_IP" ] || [ -z "$JOIN_TOKEN" ] || [ -z "$CA_CERT_HASH" ]; then
    echo -e "${RED}ERROR: MASTER_IP, JOIN_TOKEN, and CA_CERT_HASH must all be set.${NC}"
    echo -e "${YELLOW}Run 'bash scripts/cluster/generate-join-token.sh' on the master first.${NC}"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ──────────────────────────────────────────────
# Step 1: VPS base setup (swap, kernel modules, sysctl, hostname)
# ──────────────────────────────────────────────
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  STEP 1: VPS Base Setup${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

export CLUSTER_NAME
export NODE_ROLE="worker-${WORKER_NUMBER}"
bash "${SCRIPT_DIR}/setup-vps.sh"

echo ""
echo -e "${GREEN}✓ Step 1 Complete${NC}"
echo ""

# ──────────────────────────────────────────────
# Step 2: Container runtime
# ──────────────────────────────────────────────
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  STEP 2: Container Runtime (containerd)${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

bash "${SCRIPT_DIR}/setup-containerd.sh"

echo ""
echo -e "${GREEN}✓ Step 2 Complete${NC}"
echo ""

# ──────────────────────────────────────────────
# Step 3: Install kubelet + kubeadm (no cluster init, no kubectl)
# ──────────────────────────────────────────────
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  STEP 3: Install kubelet + kubeadm${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

if [ -f /etc/apt/sources.list.d/kubernetes.list ]; then
    echo -e "${GREEN}✓ Kubernetes repository already configured${NC}"
else
    mkdir -p /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/Release.key" \
        | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/ /" \
        | tee /etc/apt/sources.list.d/kubernetes.list
    echo -e "${GREEN}✓ Kubernetes repository added${NC}"
fi

apt-get update -q

COMPONENTS_TO_INSTALL=""
command -v kubelet  &>/dev/null || COMPONENTS_TO_INSTALL="$COMPONENTS_TO_INSTALL kubelet"
command -v kubeadm  &>/dev/null || COMPONENTS_TO_INSTALL="$COMPONENTS_TO_INSTALL kubeadm"

if [ -n "$COMPONENTS_TO_INSTALL" ]; then
    apt-get install -y $COMPONENTS_TO_INSTALL
    apt-mark hold kubelet kubeadm 2>/dev/null || true
    echo -e "${GREEN}✓ kubelet + kubeadm installed${NC}"
else
    echo -e "${GREEN}✓ kubelet + kubeadm already installed${NC}"
    apt-mark hold kubelet kubeadm 2>/dev/null || true
fi

systemctl enable --now kubelet
echo -e "${GREEN}✓ kubelet enabled${NC}"

echo ""
echo -e "${GREEN}✓ Step 3 Complete${NC}"
echo ""

# ──────────────────────────────────────────────
# Step 4: Join the cluster
# ──────────────────────────────────────────────
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  STEP 4: Join Cluster${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

if [ -f /etc/kubernetes/kubelet.conf ]; then
    echo -e "${GREEN}✓ Node is already joined to a cluster (kubelet.conf exists)${NC}"
    echo -e "${BLUE}  If you need to re-join, run: kubeadm reset && rm -f /etc/kubernetes/kubelet.conf${NC}"
else
    echo -e "${BLUE}Joining cluster at ${MASTER_IP}:6443 ...${NC}"
    kubeadm join "${MASTER_IP}:6443" \
        --token "${JOIN_TOKEN}" \
        --discovery-token-ca-cert-hash "${CA_CERT_HASH}"
    echo -e "${GREEN}✓ Node joined the cluster${NC}"
fi

echo ""

# ──────────────────────────────────────────────
# Done
# ──────────────────────────────────────────────
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  WORKER NODE SETUP COMPLETE${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Verify on the master node:${NC}"
echo -e "${BLUE}  kubectl get nodes${NC}"
echo ""
echo -e "${YELLOW}Note: The new node may take 1-2 minutes to reach Ready status${NC}"
echo -e "${YELLOW}while Calico CNI configures its networking.${NC}"
echo ""
