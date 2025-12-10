#!/bin/bash
# Deploy cleanup CronJob and infrastructure HPAs
# Run this once to set up automated pod cleanup and autoscaling

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}Deploying cluster automation...${NC}"

# 1. Deploy cleanup CronJob
echo "📦 Deploying automated pod cleanup CronJob..."
kubectl apply -f manifests/cleanup-cronjob.yaml
echo -e "${GREEN}✓ Cleanup CronJob deployed (runs every 30 minutes)${NC}"

# 2. Deploy infrastructure HPAs
echo "📦 Deploying infrastructure autoscaling..."
kubectl apply -f manifests/infrastructure-hpa.yaml
echo -e "${GREEN}✓ Infrastructure HPAs deployed${NC}"

# 3. Make pre-deploy health check executable
chmod +x scripts/tools/pre-deploy-health-check.sh
echo -e "${GREEN}✓ Pre-deploy health check script configured${NC}"

# 4. Verify deployments
echo ""
echo "🔍 Verifying deployments..."
echo ""
echo "CronJob status:"
kubectl get cronjob -n kube-system cleanup-failed-pods

echo ""
echo "HPA status:"
kubectl get hpa -n infra
kubectl get hpa -n auth

echo ""
echo -e "${GREEN}✅ Cluster automation deployed successfully!${NC}"
echo ""
echo "📋 Next steps:"
echo "  1. Monitor cleanup: kubectl logs -n kube-system -l app=pod-cleanup --tail=50"
echo "  2. Check HPAs: kubectl get hpa -A"
echo "  3. Test health check: ./scripts/tools/pre-deploy-health-check.sh auth-api auth"
echo ""
echo -e "${YELLOW}⚠️  To integrate pre-deploy checks with ArgoCD:${NC}"
echo "  Add PreSync hook to app.yaml files:"
echo ""
echo "  apiVersion: v1"
echo "  kind: Job"
echo "  metadata:"
echo "    annotations:"
echo "      argocd.argoproj.io/hook: PreSync"
echo "      argocd.argoproj.io/hook-delete-policy: HookSucceeded"
echo "  spec:"
echo "    template:"
echo "      spec:"
echo "        containers:"
echo "          - name: health-check"
echo "            image: bitnami/kubectl:latest"
echo "            command: ['/scripts/pre-deploy-health-check.sh', 'APP_NAME', 'NAMESPACE']"
