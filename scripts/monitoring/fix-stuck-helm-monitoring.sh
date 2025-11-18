#!/bin/bash
# Manual Helm Release Lock Cleanup for Monitoring Stack
# Use this when install-monitoring.sh fails with "another operation in progress"

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

RELEASE_NAME=${1:-prometheus}
NAMESPACE=${2:-monitoring}

echo -e "${YELLOW}=== Helm Release Lock Cleanup ===${NC}"
echo "Release: $RELEASE_NAME"
echo "Namespace: $NAMESPACE"
echo ""

# Check current status
echo -e "${YELLOW}Current Helm status:${NC}"
helm status $RELEASE_NAME -n $NAMESPACE 2>/dev/null || echo "No release found"
echo ""

# Get current status
STATUS=$(helm status $RELEASE_NAME -n $NAMESPACE 2>/dev/null | grep "STATUS:" | awk '{print $2}' || echo "unknown")
echo -e "${YELLOW}Detected status: ${STATUS}${NC}"

if [[ "$STATUS" == "pending-upgrade" || "$STATUS" == "pending-install" || "$STATUS" == "pending-rollback" ]]; then
    echo -e "${YELLOW}🔧 Fixing stuck operation...${NC}"
    echo ""
    
    # Step 1: Delete Helm lock secrets
    echo -e "${YELLOW}Step 1: Removing Helm lock secrets${NC}"
    echo "Pending secrets to delete:"
    kubectl -n $NAMESPACE get secrets -l "owner=helm,name=$RELEASE_NAME" | grep pending || echo "  (none found)"
    
    kubectl -n $NAMESPACE get secrets -l "owner=helm,status=pending-upgrade,name=$RELEASE_NAME" -o name 2>/dev/null | xargs kubectl -n $NAMESPACE delete 2>/dev/null || echo "  No pending-upgrade secrets"
    kubectl -n $NAMESPACE get secrets -l "owner=helm,status=pending-install,name=$RELEASE_NAME" -o name 2>/dev/null | xargs kubectl -n $NAMESPACE delete 2>/dev/null || echo "  No pending-install secrets"
    kubectl -n $NAMESPACE get secrets -l "owner=helm,status=pending-rollback,name=$RELEASE_NAME" -o name 2>/dev/null | xargs kubectl -n $NAMESPACE delete 2>/dev/null || echo "  No pending-rollback secrets"
    echo -e "${GREEN}✓ Helm locks removed${NC}"
    echo ""
    
    # Step 2: Force delete stuck pods
    echo -e "${YELLOW}Step 2: Force deleting stuck pods${NC}"
    kubectl get pods -n $NAMESPACE -l "app.kubernetes.io/instance=$RELEASE_NAME" 2>/dev/null || echo "  (no pods found)"
    kubectl delete pods -n $NAMESPACE -l "app.kubernetes.io/instance=$RELEASE_NAME" --force --grace-period=0 2>/dev/null || echo "  (no pods to delete)"
    echo -e "${GREEN}✓ Stuck pods removed${NC}"
    echo ""
    
    # Step 3: Wait for cleanup
    echo -e "${YELLOW}Step 3: Waiting 10 seconds for cleanup...${NC}"
    sleep 10
    
    # Step 4: Check Helm history and rollback if possible
    echo -e "${YELLOW}Step 4: Checking Helm history${NC}"
    if helm history $RELEASE_NAME -n $NAMESPACE >/dev/null 2>&1; then
        echo "Helm history:"
        helm history $RELEASE_NAME -n $NAMESPACE --max 10 || true
        echo ""
        
        # Find last successful deployment
        LAST_DEPLOYED=$(helm history $RELEASE_NAME -n $NAMESPACE --max 100 -o json 2>/dev/null | jq -r '.[] | select(.status == "deployed") | .revision' | tail -1 || echo "")
        
        if [ -n "$LAST_DEPLOYED" ] && [ "$LAST_DEPLOYED" != "null" ]; then
            echo -e "${YELLOW}Found last deployed revision: $LAST_DEPLOYED${NC}"
            echo -e "${YELLOW}Attempting rollback...${NC}"
            helm rollback $RELEASE_NAME $LAST_DEPLOYED -n $NAMESPACE --force --wait --timeout=5m || {
                echo -e "${YELLOW}⚠️  Rollback failed, but that's OK. Lock is removed.${NC}"
            }
        else
            echo -e "${YELLOW}No successful deployment found in history${NC}"
        fi
    else
        echo -e "${YELLOW}No Helm history available${NC}"
    fi
    echo ""
    
    # Step 5: Verify cleanup
    echo -e "${YELLOW}Step 5: Verifying cleanup${NC}"
    NEW_STATUS=$(helm status $RELEASE_NAME -n $NAMESPACE 2>/dev/null | grep "STATUS:" | awk '{print $2}' || echo "unknown")
    echo "New status: $NEW_STATUS"
    
    if [[ "$NEW_STATUS" == "deployed" ]]; then
        echo -e "${GREEN}✅ Release is now in healthy 'deployed' state${NC}"
        echo -e "${GREEN}You can now run install-monitoring.sh to upgrade${NC}"
    elif [[ "$NEW_STATUS" == "failed" ]]; then
        echo -e "${YELLOW}⚠️  Release is in 'failed' state${NC}"
        echo -e "${YELLOW}You can now run install-monitoring.sh to retry${NC}"
    elif [[ "$NEW_STATUS" == "unknown" ]]; then
        echo -e "${GREEN}✅ Helm release cleared${NC}"
        echo -e "${GREEN}You can now run install-monitoring.sh for fresh install${NC}"
    else
        echo -e "${YELLOW}Status: $NEW_STATUS${NC}"
        echo -e "${YELLOW}You can now run install-monitoring.sh${NC}"
    fi
    echo ""
    
else
    echo -e "${GREEN}✓ No stuck operation detected. Status is: $STATUS${NC}"
    echo "No cleanup needed."
    exit 0
fi

# Optional: Full uninstall (commented out for safety)
echo -e "${YELLOW}=== Optional Manual Steps ===${NC}"
echo ""
echo "If the above didn't work, you can manually uninstall (WARNING: destroys data):"
echo ""
echo "  # Full uninstall (deletes all monitoring data)"
echo "  helm uninstall $RELEASE_NAME -n $NAMESPACE"
echo ""
echo "  # Delete PVCs (WARNING: permanently deletes Prometheus/Grafana data)"
echo "  kubectl delete pvc -n $NAMESPACE -l app.kubernetes.io/instance=$RELEASE_NAME"
echo ""
echo "  # Then retry install"
echo "  ./scripts/install-monitoring.sh"
echo ""

