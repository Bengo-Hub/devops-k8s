#!/usr/bin/env bash
# Deploy map routing infrastructure (Valhalla + TileServer) to the logistics namespace
# Usage: ./scripts/deploy-routing.sh [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$SCRIPT_DIR/../manifests/routing"

DRY_RUN=""
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN="--dry-run=client"
  echo "=== DRY RUN MODE ==="
fi

echo "=== Deploying Map Routing Infrastructure ==="
echo "Namespace: logistics"
echo ""

# Ensure namespace exists
kubectl create namespace logistics --dry-run=client -o yaml | kubectl apply -f -

# Apply all routing manifests via kustomize
echo "Applying routing manifests..."
kubectl apply -k "$MANIFESTS_DIR" $DRY_RUN

echo ""
echo "=== Deployment initiated ==="
echo ""
echo "Monitor progress:"
echo "  kubectl get pods -n logistics -l part-of=map-services -w"
echo ""
echo "Valhalla will take 5-15 minutes on first start (downloading + building Kenya tiles)."
echo ""
echo "Verify:"
echo "  kubectl logs -n logistics deploy/valhalla --tail=20 -f"
echo "  kubectl logs -n logistics deploy/tileserver --tail=20 -f"
