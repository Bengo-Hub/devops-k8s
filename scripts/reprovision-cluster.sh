#!/bin/bash
set -euo pipefail

# Complete Cluster Reprovisioning Script
# Cleans cluster completely and reprovisions everything fresh
# WARNING: This will delete ALL applications and data!

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
ENABLE_CLEANUP=${ENABLE_CLEANUP:-true}
FORCE_CLEANUP=${FORCE_CLEANUP:-true}
SKIP_PROVISION=${SKIP_PROVISION:-false}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${RED}========================================${NC}"
echo -e "${RED}  CLUSTER REPROVISIONING SCRIPT${NC}"
echo -e "${RED}========================================${NC}"
echo ""
echo -e "${YELLOW}This script will:${NC}"
echo -e "${YELLOW}  1. Clean up ALL application namespaces and resources${NC}"
echo -e "${YELLOW}  2. Reprovision infrastructure from scratch${NC}"
echo ""

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

# Step 1: Cleanup
if [ "$ENABLE_CLEANUP" = "true" ]; then
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  STEP 1: CLEANUP${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    export ENABLE_CLEANUP=true
    export FORCE_CLEANUP=true
    "${SCRIPT_DIR}/cleanup-cluster.sh"
    
    echo ""
    echo -e "${GREEN}✓ Cleanup complete${NC}"
    echo ""
else
    echo -e "${YELLOW}Skipping cleanup (ENABLE_CLEANUP=false)${NC}"
    echo ""
fi

# Step 2: Reprovision
if [ "$SKIP_PROVISION" != "true" ]; then
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  STEP 2: REPROVISIONING${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    echo -e "${YELLOW}Installing infrastructure components...${NC}"
    echo ""
    
    # 1. Storage provisioner
    echo -e "${BLUE}[1/9] Installing storage provisioner...${NC}"
    "${SCRIPT_DIR}/install-storage-provisioner.sh"
    echo ""
    
    # 2. Databases (PostgreSQL & Redis)
    echo -e "${BLUE}[2/9] Installing databases (PostgreSQL & Redis)...${NC}"
    export NAMESPACE=${DB_NAMESPACE:-infra}
    export PG_DATABASE=postgres
    "${SCRIPT_DIR}/install-databases.sh"
    echo ""
    
    # 3. RabbitMQ
    echo -e "${BLUE}[3/9] Installing RabbitMQ...${NC}"
    export RABBITMQ_NAMESPACE=${DB_NAMESPACE:-infra}
    "${SCRIPT_DIR}/install-rabbitmq.sh"
    echo ""
    
    # 4. Ingress Controller
    echo -e "${BLUE}[4/9] Configuring ingress controller...${NC}"
    "${SCRIPT_DIR}/configure-ingress-controller.sh"
    echo ""
    
    # 5. cert-manager
    echo -e "${BLUE}[5/9] Installing cert-manager...${NC}"
    "${SCRIPT_DIR}/install-cert-manager.sh"
    echo ""
    
    # 6. Argo CD
    echo -e "${BLUE}[6/9] Installing Argo CD...${NC}"
    export ARGOCD_DOMAIN=${ARGOCD_DOMAIN:-argocd.masterspace.co.ke}
    "${SCRIPT_DIR}/install-argocd.sh"
    echo ""
    
    # 7. Bootstrap ArgoCD applications
    echo -e "${BLUE}[7/9] Bootstrapping ArgoCD applications...${NC}"
    if [ -f "${SCRIPT_DIR}/../apps/root-app.yaml" ]; then
        kubectl apply -f "${SCRIPT_DIR}/../apps/root-app.yaml" || true
    fi
    
    # Apply individual applications
    for app_file in "${SCRIPT_DIR}/../apps"/*/app.yaml; do
        if [ -f "$app_file" ]; then
            kubectl apply -f "$app_file" || true
        fi
    done
    echo ""
    
    # 8. Monitoring
    echo -e "${BLUE}[8/9] Installing monitoring stack...${NC}"
    export GRAFANA_DOMAIN=${GRAFANA_DOMAIN:-grafana.masterspace.co.ke}
    export MONITORING_NAMESPACE=${DB_NAMESPACE:-infra}
    "${SCRIPT_DIR}/install-monitoring.sh"
    echo ""
    
    # 9. VPA
    echo -e "${BLUE}[9/9] Installing Vertical Pod Autoscaler...${NC}"
    "${SCRIPT_DIR}/install-vpa.sh"
    echo ""
    
    echo -e "${GREEN}✓ Reprovisioning complete${NC}"
    echo ""
else
    echo -e "${YELLOW}Skipping provisioning (SKIP_PROVISION=true)${NC}"
    echo ""
fi

# Step 3: Verification
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  STEP 3: VERIFICATION${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

echo -e "${YELLOW}Checking infrastructure pods...${NC}"
NAMESPACE=${DB_NAMESPACE:-infra}
kubectl get pods -n "$NAMESPACE" || true
echo ""

echo -e "${YELLOW}Checking ArgoCD...${NC}"
kubectl get pods -n argocd || true
echo ""

echo -e "${YELLOW}Checking Helm releases...${NC}"
helm list -A || true
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  REPROVISIONING COMPLETE${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo -e "${BLUE}  1. Verify all pods are running: kubectl get pods -A${NC}"
echo -e "${BLUE}  2. Check ArgoCD applications: kubectl get applications -n argocd${NC}"
echo -e "${BLUE}  3. Access ArgoCD: https://${ARGOCD_DOMAIN:-argocd.masterspace.co.ke}${NC}"
echo -e "${BLUE}  4. Access Grafana: https://${GRAFANA_DOMAIN:-grafana.masterspace.co.ke}${NC}"
echo ""

