#!/bin/bash
# Diagnostic script to identify why pods are Pending

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  PENDING PODS DIAGNOSTIC${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check nodes
echo -e "${YELLOW}=== Node Status ===${NC}"
kubectl get nodes -o wide
echo ""

# Check node resources
echo -e "${YELLOW}=== Node Resource Usage ===${NC}"
kubectl top nodes 2>/dev/null || echo "Metrics server not available"
echo ""

# Get all Pending pods
PENDING_PODS=$(kubectl get pods -A --field-selector=status.phase=Pending --no-headers -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name 2>/dev/null)

if [ -z "$PENDING_PODS" ]; then
  echo -e "${GREEN}✓ No Pending pods found${NC}"
  exit 0
fi

echo -e "${YELLOW}=== Pending Pods ===${NC}"
kubectl get pods -A --field-selector=status.phase=Pending
echo ""

echo -e "${YELLOW}=== Analyzing Pending Reasons ===${NC}"
while IFS= read -r line; do
  NS=$(echo "$line" | awk '{print $1}')
  POD=$(echo "$line" | awk '{print $2}')
  
  echo -e "${BLUE}Checking: $NS/$POD${NC}"
  
  # Get pod conditions and events
  CONDITIONS=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.conditions[?(@.status=="False")].message}' 2>/dev/null)
  
  if echo "$CONDITIONS" | grep -iq "insufficient.*memory"; then
    echo -e "  ${RED}❌ Insufficient memory on nodes${NC}"
  elif echo "$CONDITIONS" | grep -iq "insufficient.*cpu"; then
    echo -e "  ${RED}❌ Insufficient CPU on nodes${NC}"
  elif echo "$CONDITIONS" | grep -iq "no nodes"; then
    echo -e "  ${RED}❌ No nodes available for scheduling${NC}"
  elif kubectl get events -n "$NS" --field-selector involvedObject.name="$POD" 2>/dev/null | grep -iq "FailedScheduling.*node(s) had volume node affinity conflict"; then
    echo -e "  ${RED}❌ Volume node affinity conflict${NC}"
  elif kubectl get events -n "$NS" --field-selector involvedObject.name="$POD" 2>/dev/null | grep -iq "FailedScheduling.*persistentvolumeclaim.*not found"; then
    echo -e "  ${RED}❌ PVC not found${NC}"
  elif kubectl get events -n "$NS" --field-selector involvedObject.name="$POD" 2>/dev/null | grep -iq "FailedScheduling.*waiting for unbound.*PersistentVolumeClaim"; then
    echo -e "  ${RED}❌ Waiting for PVC to be bound${NC}"
    
    # Get PVC info
    PVCS=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.spec.volumes[*].persistentVolumeClaim.claimName}' 2>/dev/null)
    if [ -n "$PVCS" ]; then
      echo -e "    ${YELLOW}PVCs: $PVCS${NC}"
      for pvc in $PVCS; do
        PVC_STATUS=$(kubectl get pvc "$pvc" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Not Found")
        echo -e "      ${BLUE}$pvc: $PVC_STATUS${NC}"
      done
    fi
  else
    # Show last event
    LAST_EVENT=$(kubectl get events -n "$NS" --field-selector involvedObject.name="$POD" --sort-by='.lastTimestamp' 2>/dev/null | grep -v "LAST SEEN" | tail -1)
    if [ -n "$LAST_EVENT" ]; then
      echo -e "    ${YELLOW}Last event: $LAST_EVENT${NC}"
    else
      echo -e "    ${YELLOW}No specific reason found - check pod describe${NC}"
    fi
  fi
  echo ""
done <<< "$PENDING_PODS"

# Check storage classes
echo -e "${YELLOW}=== Storage Classes ===${NC}"
kubectl get storageclass
echo ""

# Check PVCs
echo -e "${YELLOW}=== Pending PVCs ===${NC}"
kubectl get pvc -A --field-selector=status.phase=Pending 2>/dev/null || echo "No Pending PVCs"
echo ""

# Check for PVs
echo -e "${YELLOW}=== Available PVs ===${NC}"
kubectl get pv 2>/dev/null || echo "No PVs found"
echo ""

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  RECOMMENDATIONS${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Provide recommendations
if kubectl get pvc -A --field-selector=status.phase=Pending 2>/dev/null | grep -q "Pending"; then
  echo -e "${YELLOW}📦 Pending PVCs detected:${NC}"
  echo -e "  - Check if storage provisioner is installed: kubectl get pods -n kube-system -l app=local-path-provisioner"
  echo -e "  - Verify default storage class: kubectl get storageclass"
  echo -e "  - Try: ./scripts/install-storage-provisioner.sh"
  echo ""
fi

if [ "$READY_NODES" -eq 0 ] 2>/dev/null || ! kubectl get nodes 2>/dev/null | grep -q "Ready"; then
  echo -e "${RED}❌ No ready nodes:${NC}"
  echo -e "  - Check node status: kubectl describe nodes"
  echo -e "  - Check if kubelet is running on nodes"
  echo ""
fi

echo -e "${GREEN}Run 'kubectl describe pod <pod-name> -n <namespace>' for detailed information${NC}"
echo ""

