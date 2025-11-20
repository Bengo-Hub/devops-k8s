#!/bin/bash
set -euo pipefail

# Initial VPS Setup Script
# Prepares Ubuntu 24.04 LTS VPS for Kubernetes cluster installation
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

echo -e "${BLUE}Step 1: Updating system packages...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y

# Check which packages need installation
PACKAGES_TO_INSTALL=""
REQUIRED_PACKAGES="curl wget git vim htop ca-certificates gnupg lsb-release software-properties-common apt-transport-https jq net-tools iproute2 iptables conntrack"

for pkg in $REQUIRED_PACKAGES; do
    if ! dpkg -l | grep -q "^ii  $pkg "; then
        PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL $pkg"
    fi
done

if [ -n "$PACKAGES_TO_INSTALL" ]; then
    echo -e "${BLUE}Installing missing packages:${PACKAGES_TO_INSTALL}${NC}"
    apt-get install -y $PACKAGES_TO_INSTALL
    echo -e "${GREEN}✓ Missing packages installed${NC}"
else
    echo -e "${GREEN}✓ All required packages already installed${NC}"
fi

# Run upgrade (idempotent - only upgrades if updates available)
apt-get upgrade -y

echo -e "${GREEN}✓ System packages updated${NC}"
echo ""

echo -e "${BLUE}Step 2: Disabling swap (required for Kubernetes)...${NC}"
# Check if swap is already disabled in fstab
if grep -q "^#.*swap" /etc/fstab || ! grep -q "swap" /etc/fstab; then
    echo -e "${GREEN}✓ Swap already disabled in /etc/fstab${NC}"
else
    sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
    echo -e "${GREEN}✓ Swap disabled in /etc/fstab${NC}"
fi

# Disable swap if currently active
if swapon --show | grep -q .; then
swapoff -a
    echo -e "${GREEN}✓ Swap disabled (was active)${NC}"
else
    echo -e "${GREEN}✓ Swap already disabled${NC}"
fi
echo ""

echo -e "${BLUE}Step 3: Loading required kernel modules...${NC}"
# Check if k8s.conf already exists and is correct
if [ -f /etc/modules-load.d/k8s.conf ]; then
    if grep -q "overlay" /etc/modules-load.d/k8s.conf && grep -q "br_netfilter" /etc/modules-load.d/k8s.conf; then
        echo -e "${GREEN}✓ Kernel modules config already exists${NC}"
    else
        cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
        echo -e "${GREEN}✓ Kernel modules config updated${NC}"
    fi
else
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
    echo -e "${GREEN}✓ Kernel modules config created${NC}"
fi

# Load modules if not already loaded
if ! lsmod | grep -q "^overlay"; then
modprobe overlay
    echo -e "${GREEN}✓ overlay module loaded${NC}"
else
    echo -e "${GREEN}✓ overlay module already loaded${NC}"
fi

if ! lsmod | grep -q "^br_netfilter"; then
modprobe br_netfilter
    echo -e "${GREEN}✓ br_netfilter module loaded${NC}"
else
    echo -e "${GREEN}✓ br_netfilter module already loaded${NC}"
fi
echo ""

echo -e "${BLUE}Step 4: Configuring sysctl parameters...${NC}"
# Check if k8s.conf already exists and is correct
NEEDS_UPDATE=false
if [ -f /etc/sysctl.d/k8s.conf ]; then
    if ! grep -q "net.bridge.bridge-nf-call-iptables.*=.*1" /etc/sysctl.d/k8s.conf || \
       ! grep -q "net.bridge.bridge-nf-call-ip6tables.*=.*1" /etc/sysctl.d/k8s.conf || \
       ! grep -q "net.ipv4.ip_forward.*=.*1" /etc/sysctl.d/k8s.conf; then
        NEEDS_UPDATE=true
    fi
else
    NEEDS_UPDATE=true
fi

if [ "$NEEDS_UPDATE" = true ]; then
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system
echo -e "${GREEN}✓ Sysctl parameters configured${NC}"
else
    echo -e "${GREEN}✓ Sysctl parameters already configured${NC}"
    sysctl --system >/dev/null 2>&1 || true
fi
echo ""

echo -e "${BLUE}Step 5: Setting timezone...${NC}"
CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "")
if [ "$CURRENT_TZ" = "UTC" ]; then
    echo -e "${GREEN}✓ Timezone already set to UTC${NC}"
else
timedatectl set-timezone UTC
echo -e "${GREEN}✓ Timezone set to UTC${NC}"
fi
echo ""

echo -e "${BLUE}Step 6: Setting hostname...${NC}"
CLUSTER_NAME=${CLUSTER_NAME:-mss-prod}
EXPECTED_HOSTNAME="${CLUSTER_NAME}-master"
CURRENT_HOSTNAME=$(hostname)

if [ "$CURRENT_HOSTNAME" = "$EXPECTED_HOSTNAME" ]; then
    echo -e "${GREEN}✓ Hostname already set to ${EXPECTED_HOSTNAME}${NC}"
else
    hostnamectl set-hostname "${EXPECTED_HOSTNAME}"
    echo -e "${GREEN}✓ Hostname set to ${EXPECTED_HOSTNAME}${NC}"
fi

# Check if hostname entry already exists in /etc/hosts
if ! grep -q "${EXPECTED_HOSTNAME}" /etc/hosts; then
    echo "127.0.0.1 ${EXPECTED_HOSTNAME}" >> /etc/hosts
    echo -e "${GREEN}✓ Hostname added to /etc/hosts${NC}"
else
    echo -e "${GREEN}✓ Hostname already in /etc/hosts${NC}"
fi
echo ""

echo -e "${BLUE}Step 7: Configuring firewall...${NC}"
if command -v ufw &> /dev/null; then
    # Check if firewall is already configured
    UFW_STATUS=$(ufw status 2>/dev/null | head -1 || echo "inactive")
    if echo "$UFW_STATUS" | grep -q "Status: active"; then
        # Check if required rules exist
        REQUIRED_RULES="22/tcp 80/tcp 443/tcp 6443/tcp 2379:2380/tcp 10250/tcp 10251/tcp 10252/tcp 10255/tcp"
        ALL_RULES_EXIST=true
        for rule in $REQUIRED_RULES; do
            if ! ufw status | grep -q "$rule"; then
                ALL_RULES_EXIST=false
                break
            fi
        done
        
        if [ "$ALL_RULES_EXIST" = true ]; then
            echo -e "${GREEN}✓ Firewall already configured with required rules${NC}"
        else
            echo -e "${BLUE}Adding missing firewall rules...${NC}"
            ufw allow 22/tcp       # SSH
            ufw allow 80/tcp       # HTTP
            ufw allow 443/tcp      # HTTPS
            ufw allow 6443/tcp     # Kubernetes API
            ufw allow 2379:2380/tcp # etcd
            ufw allow 10250/tcp    # Kubelet
            ufw allow 10251/tcp    # kube-scheduler
            ufw allow 10252/tcp    # kube-controller
            ufw allow 10255/tcp    # Read-only Kubelet
            echo -e "${GREEN}✓ Firewall rules added${NC}"
        fi
    else
        echo -e "${BLUE}Configuring firewall...${NC}"
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
    fi
else
    echo -e "${YELLOW}⚠️  UFW not found, skipping firewall configuration${NC}"
fi
echo ""

echo -e "${BLUE}Step 8: Creating deployment tools directory...${NC}"
if [ -d "/opt/deployment-tools" ]; then
    echo -e "${GREEN}✓ Deployment tools directory already exists${NC}"
else
mkdir -p /opt/deployment-tools
chmod 755 /opt/deployment-tools
echo -e "${GREEN}✓ Deployment tools directory created${NC}"
fi
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  VPS SETUP COMPLETE${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo -e "${BLUE}  Option 1: Run individual scripts${NC}"
echo -e "${BLUE}    1. Run: ./scripts/cluster/setup-containerd.sh${NC}"
echo -e "${BLUE}    2. Run: ./scripts/cluster/setup-kubernetes.sh${NC}"
echo ""
echo -e "${BLUE}  Option 2: Run orchestrated setup (recommended)${NC}"
echo -e "${BLUE}    Run: ./scripts/cluster/setup-cluster.sh${NC}"
echo ""

