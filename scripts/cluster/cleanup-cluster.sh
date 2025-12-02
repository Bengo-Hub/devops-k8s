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
echo -e "${RED}  COMPLETE CLUSTER CLEANUP SCRIPT${NC}"
echo -e "${RED}========================================${NC}"
echo ""
echo -e "${YELLOW}WARNING: This script will delete:${NC}"
echo -e "${YELLOW}  - All application namespaces${NC}"
echo -e "${YELLOW}  - All Helm releases${NC}"
echo -e "${YELLOW}  - All PVCs and data${NC}"
echo -e "${YELLOW}  - All ArgoCD applications${NC}"
echo -e "${YELLOW}  - Stop Kubernetes runtime${NC}"
echo -e "${YELLOW}  - Stop Docker/containerd runtime${NC}"
echo -e "${YELLOW}  - Clean all container images and volumes${NC}"
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

echo -e "${BLUE}Step 2: Disabling ArgoCD auto-sync and self-heal...${NC}"
if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
    ARGOCD_APPS=$(kubectl get applications -A -o json 2>/dev/null || echo '{"items":[]}')
    if [ -n "$ARGOCD_APPS" ] && [ "$ARGOCD_APPS" != '{"items":[]}' ]; then
        echo "$ARGOCD_APPS" | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null | \
        while read -r app_full; do
            if [ -n "$app_full" ]; then
                NS=$(echo "$app_full" | cut -d'/' -f1)
                APP=$(echo "$app_full" | cut -d'/' -f2)
                echo -e "${YELLOW}  Disabling auto-sync for ArgoCD Application: $APP (namespace: $NS)${NC}"
                
                # Disable automated sync and selfHeal to prevent recreation
                kubectl patch application "$APP" -n "$NS" --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}' 2>/dev/null || true
                
                # Remove finalizers to prevent hanging
                kubectl patch application "$APP" -n "$NS" --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
            fi
        done || true
    fi
fi
echo -e "${GREEN}✓ ArgoCD auto-sync disabled${NC}"
echo ""

echo -e "${BLUE}Step 2.1: Deleting all ArgoCD Applications...${NC}"
if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
    ARGOCD_APPS=$(kubectl get applications -A -o json 2>/dev/null || echo '{"items":[]}')
    if [ -n "$ARGOCD_APPS" ] && [ "$ARGOCD_APPS" != '{"items":[]}' ]; then
        echo "$ARGOCD_APPS" | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null | \
        while read -r app_full; do
            if [ -n "$app_full" ]; then
                NS=$(echo "$app_full" | cut -d'/' -f1)
                APP=$(echo "$app_full" | cut -d'/' -f2)
                echo -e "${YELLOW}  Deleting ArgoCD Application: $APP (namespace: $NS)${NC}"
                kubectl delete application "$APP" -n "$NS" --wait=false --grace-period=0 2>/dev/null || true
            fi
        done || true
        
        # Wait a bit for deletions to start
        sleep 5
        
        # Force remove any stuck applications
        kubectl get applications -A -o json 2>/dev/null | \
        jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null | \
        while read -r app_full; do
            if [ -n "$app_full" ]; then
                NS=$(echo "$app_full" | cut -d'/' -f1)
                APP=$(echo "$app_full" | cut -d'/' -f2)
                echo -e "${YELLOW}  Force removing stuck Application: $APP${NC}"
                kubectl patch application "$APP" -n "$NS" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
                kubectl delete application "$APP" -n "$NS" --force --grace-period=0 2>/dev/null || true
            fi
        done || true
    fi
fi
echo -e "${GREEN}✓ ArgoCD Applications deleted${NC}"
echo ""

# Remove ArgoCD CRDs early to avoid finalizer hangs
echo -e "${BLUE}Step 2.2: Removing ArgoCD CRDs...${NC}"
kubectl delete crd applications.argoproj.io --wait=false --grace-period=0 2>/dev/null || true
kubectl delete crd applicationprojects.argoproj.io --wait=false --grace-period=0 2>/dev/null || true
kubectl delete crd appprojects.argoproj.io --wait=false --grace-period=0 2>/dev/null || true
sleep 3
echo -e "${GREEN}✓ ArgoCD CRDs removed (if present)${NC}"
echo ""

echo -e "${BLUE}Step 2.3: Scaling down ArgoCD server to prevent recreation...${NC}"
if kubectl get deployment -n argocd argocd-server >/dev/null 2>&1; then
    echo -e "${YELLOW}  Scaling down argocd-server deployment...${NC}"
    kubectl scale deployment argocd-server -n argocd --replicas=0 2>/dev/null || true
    kubectl scale deployment argocd-repo-server -n argocd --replicas=0 2>/dev/null || true
    kubectl scale deployment argocd-application-controller -n argocd --replicas=0 2>/dev/null || true
    kubectl scale statefulset argocd-application-controller -n argocd --replicas=0 2>/dev/null || true
    sleep 5
fi
echo -e "${GREEN}✓ ArgoCD components scaled down${NC}"
echo ""

echo -e "${BLUE}Step 2.4: Scaling down monitoring operators...${NC}"
if kubectl get namespace monitoring >/dev/null 2>&1; then
    echo -e "${YELLOW}  Scaling down Prometheus Operator and Grafana...${NC}"
    kubectl scale deployment -n monitoring --all --replicas=0 2>/dev/null || true
    kubectl scale statefulset -n monitoring --all --replicas=0 2>/dev/null || true
    sleep 3
fi
echo -e "${GREEN}✓ Monitoring operators scaled down${NC}"
echo ""

echo -e "${BLUE}Step 3: Deleting all application namespaces...${NC}"

# First, explicitly delete known application namespaces
echo -e "${YELLOW}  Deleting known application namespaces...${NC}"
for ns in "${APP_NAMESPACES[@]}"; do
    # Skip empty namespace names
    [ -z "$ns" ] && continue
    
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        # Scale down all deployments and statefulsets first to stop recreation
        echo -e "${BLUE}      Scaling down workloads in $ns...${NC}"
        kubectl scale deployment -n "$ns" --all --replicas=0 2>/dev/null || true
        kubectl scale statefulset -n "$ns" --all --replicas=0 2>/dev/null || true
        kubectl scale replicaset -n "$ns" --all --replicas=0 2>/dev/null || true
        sleep 2
        
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
        
        # Delete pods forcefully to stop recreation loops
        echo -e "${BLUE}      Force deleting all pods in $ns...${NC}"
        kubectl delete pods --all -n "$ns" --force --grace-period=0 2>/dev/null || true
        
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
echo -e "${BLUE}Step 8: Stopping Kubernetes and Container Runtimes...${NC}"

# Function to stop Kubernetes runtime
stop_kubernetes_runtime() {
    echo -e "${YELLOW}  Stopping Kubernetes runtime...${NC}"
    
    # Stop kubelet
    if systemctl is-active --quiet kubelet 2>/dev/null; then
        echo -e "${BLUE}    Stopping kubelet...${NC}"
        systemctl stop kubelet 2>/dev/null || true
        systemctl disable kubelet 2>/dev/null || true
    fi
    
    # Stop kube-proxy (if running as systemd service)
    if systemctl is-active --quiet kube-proxy 2>/dev/null; then
        echo -e "${BLUE}    Stopping kube-proxy...${NC}"
        systemctl stop kube-proxy 2>/dev/null || true
    fi
    
    # Stop kube-scheduler (if running as systemd service)
    if systemctl is-active --quiet kube-scheduler 2>/dev/null; then
        echo -e "${BLUE}    Stopping kube-scheduler...${NC}"
        systemctl stop kube-scheduler 2>/dev/null || true
    fi
    
    # Stop kube-controller-manager (if running as systemd service)
    if systemctl is-active --quiet kube-controller-manager 2>/dev/null; then
        echo -e "${BLUE}    Stopping kube-controller-manager...${NC}"
        systemctl stop kube-controller-manager 2>/dev/null || true
    fi
    
    # Stop kube-apiserver (if running as systemd service)
    if systemctl is-active --quiet kube-apiserver 2>/dev/null; then
        echo -e "${BLUE}    Stopping kube-apiserver...${NC}"
        systemctl stop kube-apiserver 2>/dev/null || true
    fi
    
    # Reset kubeadm (if kubeadm was used)
    if command -v kubeadm &> /dev/null; then
        echo -e "${BLUE}    Resetting kubeadm cluster...${NC}"
        kubeadm reset --force 2>/dev/null || true
    fi
    
    echo -e "${GREEN}  ✓ Kubernetes runtime stopped${NC}"
}

# Function to stop Docker runtime
stop_docker_runtime() {
    echo -e "${YELLOW}  Stopping Docker runtime...${NC}"
    
    # Stop Docker daemon
    if systemctl is-active --quiet docker 2>/dev/null; then
        echo -e "${BLUE}    Stopping Docker daemon...${NC}"
        systemctl stop docker 2>/dev/null || true
        systemctl disable docker 2>/dev/null || true
    fi
    
    # Stop containerd
    if systemctl is-active --quiet containerd 2>/dev/null; then
        echo -e "${BLUE}    Stopping containerd...${NC}"
        systemctl stop containerd 2>/dev/null || true
        systemctl disable containerd 2>/dev/null || true
    fi
    
    # Clean Docker data
    if command -v docker &> /dev/null; then
        echo -e "${BLUE}    Cleaning Docker data...${NC}"
        docker system prune -af --volumes 2>/dev/null || true
    fi
    
    # Clean containerd data
    if command -v crictl &> /dev/null; then
        echo -e "${BLUE}    Cleaning containerd data...${NC}"
        crictl rmi --all 2>/dev/null || true
        crictl rmp --all 2>/dev/null || true
    fi
    
    # Remove Docker/containerd data directories
    echo -e "${BLUE}    Removing runtime data directories...${NC}"
    rm -rf /var/lib/docker/* 2>/dev/null || true
    rm -rf /var/lib/containerd/* 2>/dev/null || true
    rm -rf /var/lib/cni/* 2>/dev/null || true
    rm -rf /etc/cni/net.d/* 2>/dev/null || true
    
    echo -e "${GREEN}  ✓ Docker/containerd runtime stopped and cleaned${NC}"
}

# Function to clean Kubernetes data
clean_kubernetes_data() {
    echo -e "${YELLOW}  Cleaning Kubernetes data directories...${NC}"
    
    # Remove Kubernetes data
    rm -rf /etc/kubernetes/* 2>/dev/null || true
    rm -rf /var/lib/kubelet/* 2>/dev/null || true
    rm -rf /var/lib/etcd/* 2>/dev/null || true
    rm -rf ~/.kube/* 2>/dev/null || true
    
    # Clean iptables rules
    echo -e "${BLUE}    Cleaning iptables rules...${NC}"
    iptables -F 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    iptables -t mangle -F 2>/dev/null || true
    iptables -X 2>/dev/null || true
    ip6tables -F 2>/dev/null || true
    ip6tables -t nat -F 2>/dev/null || true
    ip6tables -X 2>/dev/null || true
    
    # Remove CNI configs
    rm -rf /etc/cni/net.d/* 2>/dev/null || true
    rm -rf /opt/cni/bin/* 2>/dev/null || true
    
    echo -e "${GREEN}  ✓ Kubernetes data cleaned${NC}"
}

# Check if we're running on the cluster node (not from CI/CD)
if [ -f "/etc/kubernetes/admin.conf" ] || systemctl is-active --quiet kubelet 2>/dev/null; then
    echo -e "${YELLOW}  Detected cluster node - performing full runtime cleanup${NC}"
    
    # Stop Kubernetes runtime
    stop_kubernetes_runtime
    
    # Stop Docker/containerd runtime
    stop_docker_runtime
    
    # Clean Kubernetes data
    clean_kubernetes_data
    
    echo -e "${GREEN}✓ Runtime cleanup complete${NC}"
else
    echo -e "${BLUE}  Running from remote (CI/CD) - skipping runtime cleanup${NC}"
    echo -e "${BLUE}  Runtime cleanup must be run directly on the cluster node${NC}"
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
