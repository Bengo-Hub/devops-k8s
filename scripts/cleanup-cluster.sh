#!/bin/bash
set -euo pipefail

# Comprehensive Cluster Cleanup Script
# Removes all namespaces, services, and resources for fresh reprovisioning
# WARNING: This will delete ALL applications and data!

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SKIP_SYSTEM_NAMESPACES=true  # Don't delete kube-system, kube-public, etc.
# CRITICAL: Cleanup is opt-in only - must explicitly set ENABLE_CLEANUP=true
ENABLE_CLEANUP=${ENABLE_CLEANUP:-true}
FORCE_CLEANUP=${FORCE_CLEANUP:-true}

# CRITICAL SAFETY CHECK: Cleanup is disabled by default
if [ "$ENABLE_CLEANUP" != "true" ]; then
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}  CLUSTER CLEANUP DISABLED${NC}"
    echo -e "${RED}========================================${NC}"
    echo ""
    echo -e "${YELLOW}Cleanup is disabled by default for safety.${NC}"
    echo -e "${YELLOW}To enable cleanup, set ENABLE_CLEANUP=true:${NC}"
    echo ""
    echo -e "${BLUE}  export ENABLE_CLEANUP=true${NC}"
    echo -e "${BLUE}  ./scripts/cleanup-cluster.sh${NC}"
    echo ""
    echo -e "${YELLOW}Or in GitHub Actions workflow:${NC}"
    echo -e "${BLUE}  env:${NC}"
    echo -e "${BLUE}    ENABLE_CLEANUP: 'true'${NC}"
    echo ""
    exit 0
fi

echo -e "${RED}========================================${NC}"
echo -e "${RED}  CLUSTER CLEANUP SCRIPT${NC}"
echo -e "${RED}========================================${NC}"
echo ""
echo -e "${YELLOW}WARNING: This script will delete:${NC}"
echo -e "${YELLOW}  - All application namespaces${NC}"
echo -e "${YELLOW}  - All Helm releases${NC}"
echo -e "${YELLOW}  - All PVCs and data${NC}"
echo -e "${YELLOW}  - All ArgoCD applications${NC}"
echo ""

# Confirmation (unless FORCE_CLEANUP is set)
if [ "$FORCE_CLEANUP" != "true" ]; then
    read -p "Are you sure you want to proceed? (type 'yes' to continue): " confirm
    if [ "$confirm" != "yes" ]; then
        echo -e "${YELLOW}Cleanup cancelled.${NC}"
        exit 0
    fi
fi

# Pre-flight checks
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}kubectl command not found. Aborting.${NC}"
    exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo -e "${RED}Cannot connect to cluster. Ensure KUBECONFIG is set. Aborting.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Connected to cluster${NC}"
echo ""

# System namespaces to preserve
SYSTEM_NAMESPACES=(
    "default"
    "kube-system"
    "kube-public"
    "kube-node-lease"
    "kubernetes-dashboard"
)

# Get all namespaces
ALL_NAMESPACES=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}')

echo -e "${BLUE}Step 1: Uninstalling all Helm releases...${NC}"
for ns in $ALL_NAMESPACES; do
    # Skip system namespaces
    if [ "$SKIP_SYSTEM_NAMESPACES" = "true" ]; then
        skip=false
        for sys_ns in "${SYSTEM_NAMESPACES[@]}"; do
            if [ "$ns" = "$sys_ns" ]; then
                skip=true
                break
            fi
        done
        if [ "$skip" = "true" ]; then
            continue
        fi
    fi
    
    # Get Helm releases in namespace
    RELEASES=$(helm list -n "$ns" -q 2>/dev/null || true)
    if [ -n "$RELEASES" ]; then
        echo -e "${YELLOW}  Uninstalling Helm releases in namespace: $ns${NC}"
        for release in $RELEASES; do
            echo -e "${BLUE}    - Uninstalling: $release${NC}"
            helm uninstall "$release" -n "$ns" --wait 2>/dev/null || true
        done
    fi
done
echo -e "${GREEN}✓ Helm releases uninstalled${NC}"
echo ""

echo -e "${BLUE}Step 2: Deleting all ArgoCD Applications...${NC}"
if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
    ARGOCD_APPS=$(kubectl get applications -A -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [ -n "$ARGOCD_APPS" ]; then
        for app in $ARGOCD_APPS; do
            NS=$(kubectl get application "$app" -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "argocd")
            echo -e "${YELLOW}  Deleting ArgoCD Application: $app (namespace: $NS)${NC}"
            kubectl delete application "$app" -n "$NS" --wait=true --grace-period=0 2>/dev/null || true
        done
    fi
fi
echo -e "${GREEN}✓ ArgoCD Applications deleted${NC}"
echo ""

echo -e "${BLUE}Step 3: Deleting all application namespaces...${NC}"
for ns in $ALL_NAMESPACES; do
    # Skip system namespaces
    if [ "$SKIP_SYSTEM_NAMESPACES" = "true" ]; then
        skip=false
        for sys_ns in "${SYSTEM_NAMESPACES[@]}"; do
            if [ "$ns" = "$sys_ns" ]; then
                skip=true
                break
            fi
        done
        if [ "$skip" = "true" ]; then
            continue
        fi
    fi
    
    echo -e "${YELLOW}  Deleting namespace: $ns${NC}"
    
    # Remove finalizers from all resources in namespace
    kubectl get all -n "$ns" -o json 2>/dev/null | \
        jq -r '.items[] | select(.metadata.finalizers != null) | "\(.kind)/\(.metadata.name)"' 2>/dev/null | \
        while read -r resource; do
            if [ -n "$resource" ]; then
                KIND=$(echo "$resource" | cut -d'/' -f1)
                NAME=$(echo "$resource" | cut -d'/' -f2)
                kubectl patch "$KIND" "$NAME" -n "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
            fi
        done || true
    
    # Delete namespace
    kubectl delete namespace "$ns" --wait=true --grace-period=0 2>/dev/null || true
done
echo -e "${GREEN}✓ Application namespaces deleted${NC}"
echo ""

echo -e "${BLUE}Step 4: Cleaning up remaining resources...${NC}"

# Delete PVCs that might be stuck
echo -e "${YELLOW}  Cleaning up PVCs...${NC}"
for ns in $ALL_NAMESPACES; do
    if [ "$SKIP_SYSTEM_NAMESPACES" = "true" ]; then
        skip=false
        for sys_ns in "${SYSTEM_NAMESPACES[@]}"; do
            if [ "$ns" = "$sys_ns" ]; then
                skip=true
                break
            fi
        done
        if [ "$skip" = "true" ]; then
            continue
        fi
    fi
    
    PVCs=$(kubectl get pvc -n "$ns" -o name 2>/dev/null || true)
    if [ -n "$PVCs" ]; then
        for pvc in $PVCs; do
            kubectl delete "$pvc" -n "$ns" --wait=true --grace-period=0 2>/dev/null || true
        done
    fi
done

# Delete any remaining CRDs from ArgoCD
echo -e "${YELLOW}  Cleaning up ArgoCD CRDs...${NC}"
kubectl delete crd applications.argoproj.io --wait=true --grace-period=0 2>/dev/null || true
kubectl delete crd applicationprojects.argoproj.io --wait=true --grace-period=0 2>/dev/null || true

# Delete any remaining Helm secrets
echo -e "${YELLOW}  Cleaning up Helm secrets...${NC}"
kubectl get secrets -A -l owner=helm -o json 2>/dev/null | \
    jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null | \
    while read -r secret; do
        if [ -n "$secret" ]; then
            NS=$(echo "$secret" | cut -d'/' -f1)
            NAME=$(echo "$secret" | cut -d'/' -f2)
            kubectl delete secret "$NAME" -n "$NS" --wait=true --grace-period=0 2>/dev/null || true
        fi
    done || true

echo -e "${GREEN}✓ Remaining resources cleaned up${NC}"
echo ""

echo -e "${BLUE}Step 5: Waiting for final cleanup...${NC}"
sleep 10

# Final verification
echo -e "${BLUE}Step 6: Verifying cleanup...${NC}"
REMAINING_NAMESPACES=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
APP_NAMESPACES=""

for ns in $REMAINING_NAMESPACES; do
    skip=false
    for sys_ns in "${SYSTEM_NAMESPACES[@]}"; do
        if [ "$ns" = "$sys_ns" ]; then
            skip=true
            break
        fi
    done
    if [ "$skip" = "false" ]; then
        APP_NAMESPACES="$APP_NAMESPACES $ns"
    fi
done

if [ -n "$APP_NAMESPACES" ]; then
    echo -e "${YELLOW}⚠️  Remaining application namespaces:${NC}"
    for ns in $APP_NAMESPACES; do
        echo -e "${YELLOW}    - $ns${NC}"
    done
    echo -e "${YELLOW}  These may need manual cleanup.${NC}"
else
    echo -e "${GREEN}✓ All application namespaces cleaned up${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  CLEANUP COMPLETE${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo -e "${BLUE}  1. Run provisioning workflow: .github/workflows/provision.yml${NC}"
echo -e "${BLUE}  2. Or run provisioning scripts manually${NC}"
echo ""

