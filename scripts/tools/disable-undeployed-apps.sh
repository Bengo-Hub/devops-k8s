#!/bin/bash
# Disable automatic sync for apps without Docker images
# This prevents ArgoCD from continuously recreating failed pods

set -euo pipefail

# Apps that DON'T have images yet (disable automatic sync)
# Deployed apps removed: isp-billing-backend, isp-billing-frontend,
# ordering-backend, ordering-frontend, notifications-api
UNDEPLOYED_APPS=(
  "inventory-api"
  "inventory-ui"
  "logistics-api"
  "logistics-ui"
  "pos-api"
  "pos-ui"
  "projects-api"
  "projects-ui"
  "ticketing-api"
  "ticketing-ui"
  "treasury-api"
  "treasury-ui"
)

echo "🔧 Disabling automatic sync for undeployed apps..."

for APP in "${UNDEPLOYED_APPS[@]}"; do
  echo "  📦 Disabling sync for $APP..."

  # Patch ArgoCD Application to disable automated sync
  kubectl patch application "$APP" -n argocd --type=merge -p '{
    "spec": {
      "syncPolicy": {
        "automated": null
      }
    }
  }' 2>/dev/null || echo "    ⚠️  App $APP not found or already patched"
done

echo ""
echo "✅ Done! Undeployed apps will no longer auto-sync."
echo "   To re-enable automatic sync for an app, run:"
echo "   kubectl patch application <app-name> -n argocd --type=merge -p '{\"spec\":{\"syncPolicy\":{\"automated\":{\"prune\":true,\"selfHeal\":true}}}}'"
