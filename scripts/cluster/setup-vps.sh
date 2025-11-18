#!/bin/bash
set -euo pipefail

# Initial VPS Setup Script
# Prepares Ubuntu 22.04 VPS for Kubernetes cluster installation
# Run this FIRST before setting up Kubernetes

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  VPS INITIAL SETUP${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root or with sudo${NC}"
    exit 1
fi

# Detect OS
if [ ! -f /etc/os-release ]; then
    echo -e "${RED}Cannot detect OS. This script requires Ubuntu 22.04${NC}"
    exit 1
fi

. /etc/os-release
if [ "$ID" != "ubuntu" ] || [ "$VERSION_ID" != "22.04" ]; then
    echo -e "${YELLOW}⚠️  Warning: This script is designed for Ubuntu 22.04${NC}"
    echo -e "${YELLOW}   Detected: $ID $VERSION_ID${NC}"
    read -p "Continue anyway? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        exit 1
    fi
fi

echo -e "${BLUE}Step 1: Updating system packages...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y \
    curl \
    wget \
    git \
    vim \
    htop \
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common \
    apt-transport-https \
    jq \
    net-tools \
    iproute2 \
    iptables \
    conntrack

echo -e "${GREEN}✓ System packages updated${NC}"
echo ""

echo -e "${BLUE}Step 2: Disabling swap (required for Kubernetes)...${NC}"
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
echo -e "${GREEN}✓ Swap disabled${NC}"
echo ""

echo -e "${BLUE}Step 3: Loading required kernel modules...${NC}"
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter
echo -e "${GREEN}✓ Kernel modules loaded${NC}"
echo ""

echo -e "${BLUE}Step 4: Configuring sysctl parameters...${NC}"
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system
echo -e "${GREEN}✓ Sysctl parameters configured${NC}"
echo ""

echo -e "${BLUE}Step 5: Setting timezone...${NC}"
timedatectl set-timezone UTC
echo -e "${GREEN}✓ Timezone set to UTC${NC}"
echo ""

echo -e "${BLUE}Step 6: Setting hostname...${NC}"
CLUSTER_NAME=${CLUSTER_NAME:-mss-prod}
hostnamectl set-hostname "${CLUSTER_NAME}-master"
echo "127.0.0.1 ${CLUSTER_NAME}-master" >> /etc/hosts
echo -e "${GREEN}✓ Hostname set to ${CLUSTER_NAME}-master${NC}"
echo ""

echo -e "${BLUE}Step 7: Configuring firewall...${NC}"
if command -v ufw &> /dev/null; then
    ufw --force disable 2>/dev/null || true
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp       # SSH
    ufw allow 80/tcp       # HTTP
    ufw allow 443/tcp      # HTTPS
    ufw allow 6443/tcp     # Kubernetes API
    ufw allow 2379:2380/tcp # etcd
    ufw allow 10250/tcp    # Kubelet
    ufw allow 10251/tcp    # kube-scheduler
    ufw allow 10252/tcp    # kube-controller
    ufw allow 10255/tcp    # Read-only Kubelet
    ufw --force enable
    echo -e "${GREEN}✓ Firewall configured${NC}"
else
    echo -e "${YELLOW}⚠️  UFW not found, skipping firewall configuration${NC}"
fi
echo ""

echo -e "${BLUE}Step 8: Creating deployment tools directory...${NC}"
mkdir -p /opt/deployment-tools
chmod 755 /opt/deployment-tools
echo -e "${GREEN}✓ Deployment tools directory created${NC}"
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  VPS SETUP COMPLETE${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo -e "${BLUE}  1. Run: ./scripts/cluster/setup-containerd.sh${NC}"
echo -e "${BLUE}  2. Run: ./scripts/cluster/setup-kubernetes.sh${NC}"
echo ""

