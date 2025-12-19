#!/bin/bash

# Cafe Website Deployment Setup Script
# This script creates necessary Kubernetes resources for the cafe-website deployment

set -e

NAMESPACE="cafe"
SECRET_NAME="cafe-website-secrets"

echo "🚀 Cafe Website Kubernetes Setup"
echo "=================================="

# Create namespace if it doesn't exist
echo "📦 Ensuring namespace '$NAMESPACE' exists..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Optional: Create secrets if you have the values
echo ""
echo "🔐 Setting up optional secrets..."
echo ""
echo "To create the cafe-website-secrets, run:"
echo ""
echo "kubectl create secret generic $SECRET_NAME \\"
echo "  --from-literal=mapboxToken='YOUR_MAPBOX_TOKEN' \\"
echo "  --from-literal=sentryDsn='YOUR_SENTRY_DSN' \\"
echo "  -n $NAMESPACE"
echo ""
echo "OR if you want to skip secrets, the app will work without them."
echo ""

# Create docker registry credentials if they don't exist
echo "📋 Setting up Docker registry credentials..."
if kubectl get secret registry-credentials -n "$NAMESPACE" 2>/dev/null; then
  echo "   ✓ registry-credentials already exists"
else
  echo "   ⚠️  registry-credentials does not exist"
  echo "   You can create it with:"
  echo ""
  echo "   kubectl create secret docker-registry registry-credentials \\"
  echo "     --docker-server=docker.io \\"
  echo "     --docker-username=YOUR_USERNAME \\"
  echo "     --docker-password=YOUR_PASSWORD \\"
  echo "     --docker-email=YOUR_EMAIL \\"
  echo "     -n $NAMESPACE"
fi

echo ""
echo "✅ Setup complete!"
echo ""
echo "Next steps:"
echo "1. Create secrets (optional): kubectl create secret generic cafe-website-secrets ..."
echo "2. Create registry credentials: kubectl create secret docker-registry registry-credentials ..."
echo "3. Deploy with ArgoCD or Helm"
