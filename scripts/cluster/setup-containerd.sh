#!/bin/bash
set -euo pipefail

# Container Runtime Setup Script (containerd)
# Installs and configures containerd for Kubernetes

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  CONTAINERD SETUP${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root or with sudo${NC}"
    exit 1
fi

# Check if containerd is already installed
if command -v containerd &> /dev/null && systemctl is-active --quiet containerd; then
    echo -e "${YELLOW}containerd is already installed and running${NC}"
    read -p "Reinstall anyway? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        exit 0
    fi
fi

echo -e "${BLUE}Step 1: Adding Docker repository (for containerd)...${NC}"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

echo -e "${GREEN}✓ Docker repository added${NC}"
echo ""

echo -e "${BLUE}Step 2: Installing containerd...${NC}"
apt-get update
apt-get install -y containerd.io
echo -e "${GREEN}✓ containerd installed${NC}"
echo ""

echo -e "${BLUE}Step 3: Configuring containerd...${NC}"
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml

# Enable SystemdCgroup (required for Kubernetes)
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Configure sandbox image (pause container)
sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.9"|' /etc/containerd/config.toml

echo -e "${GREEN}✓ containerd configured${NC}"
echo ""

echo -e "${BLUE}Step 4: Starting containerd...${NC}"
systemctl daemon-reload
systemctl restart containerd
systemctl enable containerd

# Wait for containerd to be ready
sleep 5
if systemctl is-active --quiet containerd; then
    echo -e "${GREEN}✓ containerd is running${NC}"
else
    echo -e "${RED}❌ containerd failed to start${NC}"
    systemctl status containerd
    exit 1
fi
echo ""

echo -e "${BLUE}Step 5: Installing crictl (container runtime CLI)...${NC}"
CRICTL_VERSION="v1.28.0"
wget -q "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
tar zxvf "crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" -C /usr/local/bin
rm -f "crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"

# Configure crictl
mkdir -p /etc/crictl
cat <<EOF | tee /etc/crictl/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

echo -e "${GREEN}✓ crictl installed and configured${NC}"
echo ""

echo -e "${BLUE}Step 6: Verifying containerd installation...${NC}"
containerd --version
crictl --version
crictl info

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  CONTAINERD SETUP COMPLETE${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Next step: Run ./scripts/cluster/setup-kubernetes.sh${NC}"
echo ""

