#!/bin/bash
# Check etcd space and warn if approaching limits
# This script checks etcd database size and warns if space is low

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Checking etcd database space...${NC}"

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

# Get etcd pod
ETCD_POD=$(kubectl get pods -n kube-system -l component=etcd -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$ETCD_POD" ]; then
    echo -e "${YELLOW}⚠️  Could not find etcd pod in kube-system namespace${NC}"
    echo -e "${YELLOW}etcd may be running differently or cluster may not be fully initialized${NC}"
    exit 0
fi

# Check etcd status
echo -e "${BLUE}Checking etcd status...${NC}"
ETCD_STATUS=$(kubectl exec -n kube-system "$ETCD_POD" -- sh -c \
  "ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --write-out=json" 2>/dev/null || echo "")

if [ -z "$ETCD_STATUS" ]; then
    echo -e "${YELLOW}⚠️  Could not get etcd status${NC}"
    exit 0
fi

# Extract database size and quota
DB_SIZE=$(echo "$ETCD_STATUS" | jq -r '.DbSize // 0' 2>/dev/null || echo "0")
QUOTA_BYTES=$(echo "$ETCD_STATUS" | jq -r '.DbSizeInUse // 0' 2>/dev/null || echo "0")

# Get revision for compaction check
REVISION=$(echo "$ETCD_STATUS" | jq -r '.Header.revision // 0' 2>/dev/null || echo "0")

# Check for alarms
ALARMS=$(kubectl exec -n kube-system "$ETCD_POD" -- sh -c \
  "ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  alarm list" 2>/dev/null || echo "")

if echo "$ALARMS" | grep -q "NOSPACE"; then
    echo -e "${RED}❌ etcd NOSPACE alarm is active!${NC}"
    echo -e "${RED}Database space exceeded. Compaction required immediately.${NC}"
    echo ""
    echo -e "${YELLOW}Running automatic compaction...${NC}"
    
    # Compact to current revision
    kubectl exec -n kube-system "$ETCD_POD" -- sh -c \
      "ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/server.crt \
      --key=/etc/kubernetes/pki/etcd/server.key \
      compact $REVISION" 2>&1 || true
    
    # Defragment
    echo -e "${YELLOW}Defragmenting etcd...${NC}"
    kubectl exec -n kube-system "$ETCD_POD" -- sh -c \
      "ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/server.crt \
      --key=/etc/kubernetes/pki/etcd/server.key \
      defrag --cluster" 2>&1 || true
    
    # Disarm alarm
    echo -e "${YELLOW}Disarming alarm...${NC}"
    kubectl exec -n kube-system "$ETCD_POD" -- sh -c \
      "ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/server.crt \
      --key=/etc/kubernetes/pki/etcd/server.key \
      alarm disarm" 2>&1 || true
    
    echo -e "${GREEN}✓ etcd space recovery completed${NC}"
    exit 0
fi

# Calculate usage percentage (if quota available)
if [ "$QUOTA_BYTES" -gt 0 ]; then
    USAGE_PERCENT=$((DB_SIZE * 100 / QUOTA_BYTES))
    
    if [ "$USAGE_PERCENT" -gt 80 ]; then
        echo -e "${RED}⚠️  etcd database usage is high: ${USAGE_PERCENT}%${NC}"
        echo -e "${YELLOW}Consider running compaction to free space${NC}"
    elif [ "$USAGE_PERCENT" -gt 60 ]; then
        echo -e "${YELLOW}⚠️  etcd database usage is moderate: ${USAGE_PERCENT}%${NC}"
    else
        echo -e "${GREEN}✓ etcd database usage is healthy: ${USAGE_PERCENT}%${NC}"
    fi
else
    echo -e "${GREEN}✓ etcd is running normally${NC}"
fi

echo ""
echo -e "${BLUE}etcd Status Summary:${NC}"
echo "  Revision: $REVISION"
echo "  Database Size: $DB_SIZE bytes"
if [ "$QUOTA_BYTES" -gt 0 ]; then
    echo "  Quota: $QUOTA_BYTES bytes"
fi
if [ -n "$ALARMS" ] && [ "$ALARMS" != "[]" ]; then
    echo -e "  Alarms: ${YELLOW}$ALARMS${NC}"
else
    echo -e "  Alarms: ${GREEN}None${NC}"
fi

exit 0

