#!/bin/bash
# Fix etcd database space exceeded issue
# This script compacts and defragments etcd to reclaim space

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${RED}========================================${NC}"
echo -e "${RED}  ETCD SPACE RECOVERY SCRIPT${NC}"
echo -e "${RED}========================================${NC}"
echo ""
echo -e "${YELLOW}This script will compact and defragment etcd to reclaim space${NC}"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}kubectl not found. Please install kubectl first.${NC}"
    exit 1
fi

# Check cluster connectivity
if ! kubectl cluster-info >/dev/null 2>&1; then
    echo -e "${RED}Cannot connect to cluster. Check your kubeconfig.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Connected to cluster${NC}"
echo ""

# Get etcd pod
echo -e "${YELLOW}Finding etcd pod...${NC}"
ETCD_POD=$(kubectl get pods -n kube-system -l component=etcd -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$ETCD_POD" ]; then
    echo -e "${RED}❌ Could not find etcd pod in kube-system namespace${NC}"
    echo -e "${YELLOW}Trying alternative methods...${NC}"
    
    # Try to find etcd on the node directly
    echo -e "${YELLOW}Attempting to run etcdctl on the node...${NC}"
    echo -e "${BLUE}This requires SSH access to your cluster node${NC}"
    echo ""
    echo -e "${YELLOW}Run these commands on your Kubernetes master node:${NC}"
    echo ""
    echo -e "${BLUE}# Get current etcd revision${NC}"
    echo "ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \\"
    echo "  --cacert=/etc/kubernetes/pki/etcd/ca.crt \\"
    echo "  --cert=/etc/kubernetes/pki/etcd/server.crt \\"
    echo "  --key=/etc/kubernetes/pki/etcd/server.key \\"
    echo "  endpoint status --write-out=table"
    echo ""
    echo -e "${BLUE}# Compact etcd (replace <revision> with current revision from above)${NC}"
    echo "ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \\"
    echo "  --cacert=/etc/kubernetes/pki/etcd/ca.crt \\"
    echo "  --cert=/etc/kubernetes/pki/etcd/server.crt \\"
    echo "  --key=/etc/kubernetes/pki/etcd/server.key \\"
    echo "  compact <revision>"
    echo ""
    echo -e "${BLUE}# Defragment etcd${NC}"
    echo "ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \\"
    echo "  --cacert=/etc/kubernetes/pki/etcd/ca.crt \\"
    echo "  --cert=/etc/kubernetes/pki/etcd/server.crt \\"
    echo "  --key=/etc/kubernetes/pki/etcd/server.key \\"
    echo "  defrag --cluster"
    echo ""
    echo -e "${BLUE}# Disable automatic compaction and set alarm${NC}"
    echo "ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \\"
    echo "  --cacert=/etc/kubernetes/pki/etcd/ca.crt \\"
    echo "  --cert=/etc/kubernetes/pki/etcd/server.crt \\"
    echo "  --key=/etc/kubernetes/pki/etcd/server.key \\"
    echo "  alarm disarm"
    echo ""
    exit 1
fi

echo -e "${GREEN}✓ Found etcd pod: $ETCD_POD${NC}"
echo ""

# Check etcd status
echo -e "${YELLOW}Checking etcd status...${NC}"
kubectl exec -n kube-system "$ETCD_POD" -- sh -c \
  "ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --write-out=table" 2>&1 || true

echo ""

# Get current revision
echo -e "${YELLOW}Getting current etcd revision...${NC}"
REVISION=$(kubectl exec -n kube-system "$ETCD_POD" -- sh -c \
  "ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --write-out=json" 2>/dev/null | grep -o '"revision":[0-9]*' | cut -d: -f2 || echo "0")

if [ "$REVISION" -eq 0 ]; then
    echo -e "${RED}❌ Could not get etcd revision${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Current revision: $REVISION${NC}"
echo ""

# Compact etcd
echo -e "${YELLOW}Compacting etcd to revision $REVISION...${NC}"
kubectl exec -n kube-system "$ETCD_POD" -- sh -c \
  "ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  compact $REVISION" 2>&1

echo -e "${GREEN}✓ Compaction complete${NC}"
echo ""

# Defragment etcd
echo -e "${YELLOW}Defragmenting etcd...${NC}"
kubectl exec -n kube-system "$ETCD_POD" -- sh -c \
  "ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  defrag --cluster" 2>&1

echo -e "${GREEN}✓ Defragmentation complete${NC}"
echo ""

# Disarm alarms
echo -e "${YELLOW}Disarming etcd alarms...${NC}"
kubectl exec -n kube-system "$ETCD_POD" -- sh -c \
  "ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  alarm disarm" 2>&1 || true

echo -e "${GREEN}✓ Alarms disarmed${NC}"
echo ""

# Check status after cleanup
echo -e "${YELLOW}Checking etcd status after cleanup...${NC}"
kubectl exec -n kube-system "$ETCD_POD" -- sh -c \
  "ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --write-out=table" 2>&1 || true

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  ETCD RECOVERY COMPLETE${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo -e "${BLUE}1. Verify cluster is healthy: kubectl get nodes${NC}"
echo -e "${BLUE}2. Check for Pending resources: kubectl get pods -A${NC}"
echo -e "${BLUE}3. Retry failed operations${NC}"
echo ""
echo -e "${YELLOW}To prevent this in the future:${NC}"
echo -e "${YELLOW}1. Run this script periodically (weekly/monthly)${NC}"
echo -e "${YELLOW}2. Delete old/unused resources regularly${NC}"
echo -e "${YELLOW}3. Consider increasing etcd disk space${NC}"
echo ""

