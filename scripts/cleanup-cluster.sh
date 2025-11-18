#!/bin/bash
set -uo pipefail  # Removed -e so script continues on errors

# Comprehensive Cluster Cleanup Script
# Removes all namespaces, services, and resources for fresh reprovisioning
# WARNING: This will delete ALL applications and data!
# NOTE: Script continues even if some operations fail, reporting warnings instead

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SKIP_SYSTEM_NAMESPACES=true  # Don't delete kube-system, kube-public, etc.
# Cleanup enabled by default (can be disabled by setting ENABLE_CLEANUP=false)
ENABLE_CLEANUP=${ENABLE_CLEANUP:-true}
FORCE_CLEANUP=${FORCE_CLEANUP:-true}

# Safety check: Cleanup can be disabled by setting ENABLE_CLEANUP=false
if [ "$ENABLE_CLEANUP" != "true" ]; then
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}  CLUSTER CLEANUP DISABLED${NC}"
    echo -e "${RED}========================================${NC}"
    echo ""
    echo -e "${YELLOW}Cleanup is disabled (ENABLE_CLEANUP=false).${NC}"
    echo -e "${YELLOW}To enable cleanup, set ENABLE_CLEANUP=true:${NC}"
    echo ""
    echo -e "${BLUE}  export ENABLE_CLEANUP=true${NC}"
    echo -e "${BLUE}  ./scripts/cleanup-cluster.sh${NC}"
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

if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}⚠ jq command not found. Attempting to install...${NC}"
    if command -v apt-get &> /dev/null; then
        apt-get update -y >/dev/null 2>&1 && apt-get install -y jq >/dev/null 2>&1 || \
        sudo apt-get update -y >/dev/null 2>&1 && sudo apt-get install -y jq >/dev/null 2>&1 || \
        echo -e "${RED}Failed to install jq. Some cleanup operations may fail.${NC}"
    elif command -v yum &> /dev/null; then
        yum install -y jq >/dev/null 2>&1 || sudo yum install -y jq >/dev/null 2>&1 || \
        echo -e "${RED}Failed to install jq. Some cleanup operations may fail.${NC}"
    fi
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo -e "${RED}Cannot connect to cluster. Ensure KUBECONFIG is set. Aborting.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Connected to cluster${NC}"
echo -e "${GREEN}✓ jq is available: $(jq --version 2>&1)${NC}"
echo ""

# System namespaces to preserve
SYSTEM_NAMESPACES=(
    "default"
    "kube-system"
    "kube-public"
    "kube-node-lease"
    "kubernetes-dashboard"
    "calico-system"
    "calico-apiserver"
    "cert-manager"
    "ingress-nginx"
    "tigera-operator"
    "prometheus-operator"
    "grafana"
)

# Application namespaces to explicitly clean (in addition to auto-detection)
APP_NAMESPACES=(
    "argocd"
    "infra"
    "erp"
    "truload"
    "monitoring"
    "cafe"
    "treasury"
    "notifications"
    "auth-service"
    "food-delivery"
)

# Get all namespaces
ALL_NAMESPACES=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}')

force_delete_namespace() {
    local ns=$1
    
    # Validate namespace parameter is not empty
    if [ -z "$ns" ]; then
        echo -e "${YELLOW}    Warning: Empty namespace parameter, skipping...${NC}"
        return 1
    fi
    
    echo -e "${BLUE}    Deleting namespace: ${ns}${NC}"
    kubectl delete namespace "$ns" --wait=false --grace-period=0 --force 2>&1 | head -n 5 || true

    for attempt in {1..10}; do
        # Check if namespace still exists
        if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
            echo -e "${GREEN}    ✓ Namespace ${ns} deleted${NC}"
            return 0
        fi

        PHASE=$(kubectl get namespace "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        echo -e "${BLUE}      Namespace ${ns} status: ${PHASE:-Active} (attempt ${attempt}/10)${NC}"
        if [ "$PHASE" = "Terminating" ]; then
            echo -e "${YELLOW}      Namespace ${ns} stuck terminating - removing finalizers (attempt ${attempt})${NC}"
            
            # Method 1: Remove finalizers using kubectl patch
            echo -e "${BLUE}        Attempting to patch namespace finalizers...${NC}"
            kubectl patch namespace "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
            kubectl patch namespace "$ns" -p '{"spec":{"finalizers":[]}}' --type=merge 2>/dev/null || true
            
            # Method 2: Use the finalize endpoint (same as manual working command)
            TMP_FILE="/tmp/namespace-${ns}.json"
            echo -e "${BLUE}        Attempting finalize endpoint method...${NC}"
            
            # Get namespace JSON and remove finalizers
            if kubectl get namespace "$ns" -o json 2>/dev/null > "${TMP_FILE}.raw"; then
                if command -v jq &> /dev/null; then
                    jq '.spec.finalizers = []' "${TMP_FILE}.raw" > "${TMP_FILE}" 2>&1
                    JQ_EXIT=$?
                    if [ $JQ_EXIT -eq 0 ] && [ -s "${TMP_FILE}" ]; then
                        echo -e "${BLUE}        Applying finalize to namespace ${ns}...${NC}"
                        FINALIZE_OUTPUT=$(kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f "${TMP_FILE}" 2>&1)
                        FINALIZE_EXIT=$?
                        if [ $FINALIZE_EXIT -ne 0 ]; then
                            echo -e "${YELLOW}        Finalize failed: ${FINALIZE_OUTPUT}${NC}" | head -n 3
                        else
                            echo -e "${GREEN}        ✓ Finalize applied${NC}"
                        fi
                    else
                        echo -e "${YELLOW}        jq processing failed or produced empty output${NC}"
                    fi
                else
                    echo -e "${YELLOW}        jq not available, skipping finalize method${NC}"
                fi
            else
                echo -e "${YELLOW}        Could not get namespace ${ns} JSON${NC}"
            fi
            rm -f "${TMP_FILE}" "${TMP_FILE}.raw" 2>/dev/null || true
            
            # Method 3: Force delete all resources in the namespace
            echo -e "${BLUE}        Force deleting resources in namespace...${NC}"
            kubectl delete all --all -n "$ns" --grace-period=0 --force 2>/dev/null || true
        fi
        
        # Wait longer between attempts for deletions to propagate
        echo -e "${BLUE}      Waiting 1 seconds before next check...${NC}"
        sleep 1
    done

    echo -e "${YELLOW}      ⚠ Namespace ${ns} still present after forced cleanup - will continue with other namespaces${NC}"
    return 0  # Don't fail the script, just warn
}

echo -e "${BLUE}Step 1: Uninstalling all Helm releases...${NC}"
for ns in $ALL_NAMESPACES; do
    # Skip empty namespace names
    [ -z "$ns" ] && continue
    
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

# Remove ArgoCD CRDs early to avoid finalizer hangs
echo -e "${BLUE}Step 2.5: Removing ArgoCD CRDs...${NC}"
kubectl delete crd applications.argoproj.io --wait=true --grace-period=0 2>/dev/null || true
kubectl delete crd applicationprojects.argoproj.io --wait=true --grace-period=0 2>/dev/null || true
echo -e "${GREEN}✓ ArgoCD CRDs removed (if present)${NC}"
echo ""

echo -e "${BLUE}Step 3: Deleting all application namespaces...${NC}"

# First, explicitly delete known application namespaces
echo -e "${YELLOW}  Deleting known application namespaces...${NC}"
for ns in "${APP_NAMESPACES[@]}"; do
    # Skip empty namespace names
    [ -z "$ns" ] && continue
    
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        # Remove finalizers from all resources in namespace
        echo -e "${BLUE}      Removing finalizers from resources in $ns...${NC}"
        kubectl get all,pvc,configmap,secret,networkpolicy -n "$ns" -o json 2>/dev/null | \
            jq -r '.items[] | select(.metadata.finalizers != null) | "\(.kind)/\(.metadata.name)"' 2>/dev/null | \
            while read -r resource; do
                if [ -n "$resource" ]; then
                    KIND=$(echo "$resource" | cut -d'/' -f1)
                    NAME=$(echo "$resource" | cut -d'/' -f2)
                    kubectl patch "$KIND" "$NAME" -n "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
                fi
            done || true
        
        # Remove finalizers from namespace itself
        kubectl patch namespace "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
        
        # Force delete namespace
        force_delete_namespace "$ns"
    fi
done

# Refresh namespace list after deleting known namespaces
ALL_NAMESPACES=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}')

# Then delete any remaining non-system namespaces
echo -e "${YELLOW}  Deleting remaining non-system namespaces...${NC}"
for ns in $ALL_NAMESPACES; do
    # Skip empty namespace names
    [ -z "$ns" ] && continue
    
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
    
    # Skip if already processed
    skip=false
    for app_ns in "${APP_NAMESPACES[@]}"; do
        if [ "$ns" = "$app_ns" ]; then
            skip=true
            break
        fi
    done
    if [ "$skip" = "true" ]; then
        continue
    fi
    
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        # Remove finalizers from all resources
        kubectl get all,pvc,configmap,secret,networkpolicy -n "$ns" -o json 2>/dev/null | \
            jq -r '.items[] | select(.metadata.finalizers != null) | "\(.kind)/\(.metadata.name)"' 2>/dev/null | \
            while read -r resource; do
                if [ -n "$resource" ]; then
                    KIND=$(echo "$resource" | cut -d'/' -f1)
                    NAME=$(echo "$resource" | cut -d'/' -f2)
                    kubectl patch "$KIND" "$NAME" -n "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
                fi
            done || true
        
        # Remove finalizers from namespace
        kubectl patch namespace "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
        
        # Force delete namespace
        force_delete_namespace "$ns"
    fi
done
echo -e "${GREEN}✓ Application namespaces deleted${NC}"
echo ""

echo -e "${BLUE}Step 4: Cleaning up remaining resources...${NC}"

# Delete PVCs that might be stuck
echo -e "${YELLOW}  Cleaning up PVCs...${NC}"
for ns in $ALL_NAMESPACES; do
    # Skip empty namespace names
    [ -z "$ns" ] && continue
    
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

echo -e "${BLUE}Step 5: Force deleting stuck resources...${NC}"

# Force delete any remaining StatefulSets, Deployments, Pods
echo -e "${YELLOW}  Force deleting remaining workloads...${NC}"
for ns in "${APP_NAMESPACES[@]}"; do
    # Skip empty namespace names
    [ -z "$ns" ] && continue
    
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        # Force delete StatefulSets
        kubectl get statefulset -n "$ns" -o name 2>/dev/null | while read -r ss; do
            kubectl delete "$ss" -n "$ns" --grace-period=0 --force 2>/dev/null || true
        done
        
        # Force delete Deployments
        kubectl get deployment -n "$ns" -o name 2>/dev/null | while read -r dep; do
            kubectl delete "$dep" -n "$ns" --grace-period=0 --force 2>/dev/null || true
        done
        
        # Force delete Pods
        kubectl get pod -n "$ns" -o name 2>/dev/null | while read -r pod; do
            kubectl delete "$pod" -n "$ns" --grace-period=0 --force 2>/dev/null || true
        done
    fi
done

echo -e "${BLUE}Step 6: Waiting for final cleanup...${NC}"
sleep 15

# Final verification
echo -e "${BLUE}Step 7: Verifying cleanup...${NC}"
REMAINING_NAMESPACES=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
APP_NAMESPACES=""

for ns in $REMAINING_NAMESPACES; do
    # Skip empty namespace names
    [ -z "$ns" ] && continue
    
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
