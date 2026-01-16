#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Update Kubelet Configuration
# ============================================================================
# This script updates kubelet configuration to modify settings like maxPods
# Must be run on the Kubernetes node (via SSH or kubectl exec)
#
# Usage:
#   ./update-kubelet-config.sh                    # Show current config
#   ./update-kubelet-config.sh --set-max-pods=130 # Set max pods to 130
#   ./update-kubelet-config.sh --apply            # Apply changes
# ============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

KUBELET_CONFIG="/var/lib/kubelet/config.yaml"
KUBELET_KUBEADM_ARGS="/var/lib/kubelet/kubeadm-flags.env"
NEW_MAX_PODS=""
APPLY=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --set-max-pods=*)
            NEW_MAX_PODS="${1#*=}"
            shift
            ;;
        --apply)
            APPLY=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--set-max-pods=N] [--apply]"
            exit 1
            ;;
    esac
done

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root or with sudo${NC}"
    exit 1
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  KUBELET CONFIGURATION MANAGER${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Show current configuration
echo -e "${BLUE}Current kubelet configuration:${NC}"
if [ -f "$KUBELET_CONFIG" ]; then
    echo -e "${YELLOW}Config file: $KUBELET_CONFIG${NC}"

    # Extract key settings
    CURRENT_MAX_PODS=$(grep -E "^maxPods:" "$KUBELET_CONFIG" | awk '{print $2}' || echo "not set (default: 110)")
    echo "  maxPods: $CURRENT_MAX_PODS"

    CURRENT_PODS_PER_CORE=$(grep -E "^podsPerCore:" "$KUBELET_CONFIG" | awk '{print $2}' || echo "not set")
    echo "  podsPerCore: $CURRENT_PODS_PER_CORE"
else
    echo -e "${YELLOW}Kubelet config not found at $KUBELET_CONFIG${NC}"
fi

# Show node capacity
echo ""
echo -e "${BLUE}Node pod capacity:${NC}"
kubectl describe node | grep -E "^\s*(Capacity|Allocatable):" -A 10 | grep -E "(Capacity|Allocatable|pods)" | head -6

echo ""

# If setting new max pods
if [ -n "$NEW_MAX_PODS" ]; then
    echo -e "${BLUE}Requested change: maxPods = $NEW_MAX_PODS${NC}"

    # Validate
    if ! [[ "$NEW_MAX_PODS" =~ ^[0-9]+$ ]] || [ "$NEW_MAX_PODS" -lt 10 ] || [ "$NEW_MAX_PODS" -gt 500 ]; then
        echo -e "${RED}Invalid maxPods value. Must be between 10 and 500.${NC}"
        exit 1
    fi

    if [ "$APPLY" = true ]; then
        echo -e "${YELLOW}Applying changes...${NC}"

        # Backup current config
        BACKUP_FILE="${KUBELET_CONFIG}.backup.$(date +%Y%m%d-%H%M%S)"
        cp "$KUBELET_CONFIG" "$BACKUP_FILE"
        echo "  Backed up config to: $BACKUP_FILE"

        # Update or add maxPods setting
        if grep -q "^maxPods:" "$KUBELET_CONFIG"; then
            sed -i "s/^maxPods:.*/maxPods: $NEW_MAX_PODS/" "$KUBELET_CONFIG"
        else
            # Add maxPods to the end of the file
            echo "maxPods: $NEW_MAX_PODS" >> "$KUBELET_CONFIG"
        fi

        echo -e "${GREEN}  Updated maxPods to: $NEW_MAX_PODS${NC}"

        # Restart kubelet
        echo ""
        echo -e "${YELLOW}Restarting kubelet service...${NC}"
        systemctl daemon-reload
        systemctl restart kubelet

        # Wait for kubelet to be ready
        echo -e "${YELLOW}Waiting for kubelet to be ready...${NC}"
        sleep 10

        # Verify the change
        if systemctl is-active --quiet kubelet; then
            echo -e "${GREEN}Kubelet restarted successfully${NC}"

            # Check new capacity
            echo ""
            echo -e "${BLUE}New node pod capacity:${NC}"
            kubectl describe node | grep -E "^\s*(Capacity|Allocatable):" -A 10 | grep -E "(Capacity|Allocatable|pods)" | head -6
        else
            echo -e "${RED}Kubelet failed to restart! Rolling back...${NC}"
            cp "$BACKUP_FILE" "$KUBELET_CONFIG"
            systemctl restart kubelet
            exit 1
        fi
    else
        echo ""
        echo -e "${YELLOW}Dry run mode. To apply changes, add --apply flag:${NC}"
        echo "  $0 --set-max-pods=$NEW_MAX_PODS --apply"
    fi
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  DONE${NC}"
echo -e "${GREEN}========================================${NC}"
