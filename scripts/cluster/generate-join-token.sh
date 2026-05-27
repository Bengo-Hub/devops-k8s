#!/bin/bash
set -euo pipefail

# Generate a 24-hour kubeadm join token and print the worker join command.
# Run this ON THE MASTER NODE (mss-prod-master).

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  GENERATE WORKER JOIN TOKEN${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root or with sudo${NC}"
    exit 1
fi

if ! kubectl get nodes >/dev/null 2>&1; then
    echo -e "${RED}Cannot reach the Kubernetes API. Is the cluster running?${NC}"
    exit 1
fi

echo -e "${BLUE}Generating 24-hour join token...${NC}"
JOIN_COMMAND=$(kubeadm token create --print-join-command --ttl 24h)

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  JOIN COMMAND (valid for 24 hours)${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}${JOIN_COMMAND}${NC}"
echo ""
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Copy the command above, then on each new worker VPS run:${NC}"
echo -e "${BLUE}  1. export MASTER_IP=<public-ip-of-master>${NC}"
echo -e "${BLUE}  2. export JOIN_TOKEN=<token>${NC}"
echo -e "${BLUE}  3. export CA_CERT_HASH=<sha256:...>${NC}"
echo -e "${BLUE}  4. export WORKER_NUMBER=1  # increment for each new worker${NC}"
echo -e "${BLUE}  5. bash scripts/cluster/setup-worker-node.sh${NC}"
echo ""
echo -e "${BLUE}Or paste the full kubeadm join command directly after running setup-worker-node.sh${NC}"
echo -e "${BLUE}with JOIN_COMMAND env var set.${NC}"
echo ""

# Also print parsed values for convenience
TOKEN=$(echo "$JOIN_COMMAND" | grep -oP '(?<=--token )\S+')
CA_HASH=$(echo "$JOIN_COMMAND" | grep -oP '(?<=--discovery-token-ca-cert-hash )\S+')
API_ENDPOINT=$(echo "$JOIN_COMMAND" | grep -oP '\d+\.\d+\.\d+\.\d+:\d+')

echo -e "${BLUE}Parsed values for setup-worker-node.sh env vars:${NC}"
echo -e "  MASTER_IP=${API_ENDPOINT%%:*}"
echo -e "  JOIN_TOKEN=${TOKEN}"
echo -e "  CA_CERT_HASH=${CA_HASH}"
echo ""
