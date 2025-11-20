#!/bin/bash
set -euo pipefail

# Kubernetes Cluster Setup Script (kubeadm)
# Installs Kubernetes and initializes cluster named "mss-prod"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration (updated for Ubuntu 24.04 LTS)
CLUSTER_NAME=${CLUSTER_NAME:-mss-prod}
KUBERNETES_VERSION=${KUBERNETES_VERSION:-1.30}
POD_NETWORK_CIDR=${POD_NETWORK_CIDR:-192.168.0.0/16}

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  KUBERNETES CLUSTER SETUP${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Cluster Name: ${CLUSTER_NAME}${NC}"
echo -e "${BLUE}Kubernetes Version: ${KUBERNETES_VERSION}${NC}"
echo -e "${BLUE}Pod Network CIDR: ${POD_NETWORK_CIDR}${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root or with sudo${NC}"
    exit 1
fi

# Check if containerd is running
if ! systemctl is-active --quiet containerd; then
    echo -e "${RED}containerd is not running. Please run setup-containerd.sh first${NC}"
    exit 1
fi

echo -e "${BLUE}Step 1: Adding Kubernetes repository...${NC}"
# Check if Kubernetes repository already exists
if [ -f /etc/apt/sources.list.d/kubernetes.list ]; then
    echo -e "${GREEN}✓ Kubernetes repository already configured${NC}"
else
    mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list

echo -e "${GREEN}✓ Kubernetes repository added${NC}"
fi
echo ""

echo -e "${BLUE}Step 2: Installing Kubernetes components...${NC}"
apt-get update

# Check which components need installation
COMPONENTS_TO_INSTALL=""
if ! command -v kubelet &> /dev/null; then
    COMPONENTS_TO_INSTALL="$COMPONENTS_TO_INSTALL kubelet"
fi
if ! command -v kubeadm &> /dev/null; then
    COMPONENTS_TO_INSTALL="$COMPONENTS_TO_INSTALL kubeadm"
fi
if ! command -v kubectl &> /dev/null; then
    COMPONENTS_TO_INSTALL="$COMPONENTS_TO_INSTALL kubectl"
fi

if [ -n "$COMPONENTS_TO_INSTALL" ]; then
    echo -e "${BLUE}Installing missing components:${COMPONENTS_TO_INSTALL}${NC}"
    apt-get install -y $COMPONENTS_TO_INSTALL

# Hold versions to prevent auto-upgrade
    apt-mark hold kubelet kubeadm kubectl 2>/dev/null || true

echo -e "${GREEN}✓ Kubernetes components installed${NC}"
else
    echo -e "${GREEN}✓ Kubernetes components already installed${NC}"
    # Ensure versions are held
    apt-mark hold kubelet kubeadm kubectl 2>/dev/null || true
fi
echo ""

echo -e "${BLUE}Step 3: Enabling kubelet...${NC}"
systemctl enable --now kubelet
echo -e "${GREEN}✓ kubelet enabled${NC}"
echo ""

echo -e "${BLUE}Step 4: Initializing Kubernetes cluster...${NC}"
# Check if cluster is already initialized
if [ -f /etc/kubernetes/admin.conf ]; then
    echo -e "${GREEN}✓ Kubernetes cluster already initialized${NC}"
    echo -e "${BLUE}Skipping cluster initialization.${NC}"
    echo -e "${BLUE}If you need to reinitialize, run: kubeadm reset${NC}"
    echo ""
else
# Get the primary IP address
APISERVER_ADVERTISE_ADDRESS=$(hostname -I | awk '{print $1}')

echo -e "${YELLOW}Using API server address: ${APISERVER_ADVERTISE_ADDRESS}${NC}"

kubeadm init \
  --pod-network-cidr="${POD_NETWORK_CIDR}" \
  --apiserver-advertise-address="${APISERVER_ADVERTISE_ADDRESS}" \
  --kubernetes-version="v${KUBERNETES_VERSION}.0"

echo -e "${GREEN}✓ Cluster initialized${NC}"
fi
echo ""

echo -e "${BLUE}Step 5: Configuring kubectl for root user...${NC}"
if [ ! -f /etc/kubernetes/admin.conf ]; then
    echo -e "${YELLOW}⚠️  Cluster not initialized. Skipping kubectl configuration.${NC}"
else
mkdir -p $HOME/.kube
    if [ ! -f $HOME/.kube/config ]; then
        cp /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config
        echo -e "${GREEN}✓ kubectl configured for root${NC}"
    else
        echo -e "${GREEN}✓ kubectl already configured for root${NC}"
    fi

# Also configure for other users if they exist
if id "ubuntu" &>/dev/null; then
    mkdir -p /home/ubuntu/.kube
        if [ ! -f /home/ubuntu/.kube/config ]; then
            cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
    chown -R ubuntu:ubuntu /home/ubuntu/.kube
            echo -e "${GREEN}✓ kubectl configured for ubuntu user${NC}"
        else
            echo -e "${GREEN}✓ kubectl already configured for ubuntu user${NC}"
        fi
    fi
fi
echo ""

echo -e "${BLUE}Step 6: Allowing pods on master node (single-node setup)...${NC}"
if kubectl get nodes >/dev/null 2>&1; then
    # Check if taint already removed
    TAINT_COUNT=$(kubectl describe nodes | grep -c "node-role.kubernetes.io/control-plane" || echo "0")
    if [ "$TAINT_COUNT" -eq 0 ]; then
        echo -e "${GREEN}✓ Master node taint already removed${NC}"
    else
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
echo -e "${GREEN}✓ Master node taint removed${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  Cannot connect to cluster. Skipping taint removal.${NC}"
fi
echo ""

echo -e "${BLUE}Step 7: Installing Calico CNI...${NC}"
if kubectl get namespace calico-system >/dev/null 2>&1 && kubectl get pods -n calico-system >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Calico CNI already installed${NC}"
    echo -e "${BLUE}Verifying Calico pods...${NC}"
    kubectl get pods -n calico-system || true
else
    echo -e "${BLUE}Installing Calico CNI...${NC}"
    kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml 2>/dev/null || \
        kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml

# Wait for operator to be ready
echo -e "${YELLOW}Waiting for Tigera operator to be ready...${NC}"
    kubectl wait --for=condition=available --timeout=120s deployment/tigera-operator -n tigera-operator 2>/dev/null || true

    kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/custom-resources.yaml 2>/dev/null || \
        kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/custom-resources.yaml

# Wait for Calico pods
echo -e "${YELLOW}Waiting for Calico pods to be ready...${NC}"
sleep 30
for i in {1..30}; do
        if kubectl get pods -n calico-system 2>/dev/null | grep -q Running; then
        break
    fi
    echo -e "${BLUE}  Waiting for Calico... (${i}/30)${NC}"
    sleep 5
done

echo -e "${GREEN}✓ Calico CNI installed${NC}"
fi
echo ""

echo -e "${BLUE}Step 8: Verifying cluster status...${NC}"
sleep 10
kubectl get nodes
kubectl get pods -A

echo ""
echo -e "${BLUE}Step 9: Preparing kubeconfig for remote access...${NC}"
# Update kubeconfig with public IP if provided
if [ -n "${VPS_IP:-}" ]; then
    echo -e "${YELLOW}Updating kubeconfig server address to ${VPS_IP}...${NC}"
    sed -i "s|server: https://.*:6443|server: https://${VPS_IP}:6443|" $HOME/.kube/config
    echo -e "${GREEN}✓ Kubeconfig updated with public IP${NC}"
fi

# Display kubeconfig for copying
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  KUBERNETES CLUSTER SETUP COMPLETE${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}IMPORTANT: Save your kubeconfig!${NC}"
echo ""
echo -e "${BLUE}Base64-encoded kubeconfig (copy this to GitHub secret KUBE_CONFIG):${NC}"
echo -e "${GREEN}========================================${NC}"
cat $HOME/.kube/config | base64 -w 0 2>/dev/null || cat $HOME/.kube/config | base64
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo -e "${BLUE}  1. Copy the base64 kubeconfig above${NC}"
echo -e "${BLUE}  2. Add it as GitHub secret: KUBE_CONFIG${NC}"
echo -e "${BLUE}  3. Run provisioning workflow or scripts${NC}"
echo ""

