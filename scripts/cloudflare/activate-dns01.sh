#!/bin/bash
# Activate Cloudflare DNS-01 certificate issuance for codevertexitsolutions.com.
#
# Run ON the cluster node (or anywhere with kubectl access) AFTER:
#   1. The Cloudflare zone for codevertexitsolutions.com exists, and
#   2. An API token has been created (My Profile -> API Tokens -> template
#      "Edit zone DNS", scoped to codevertexitsolutions.com only).
#
# Usage: ./activate-dns01.sh <CLOUDFLARE_API_TOKEN>
#
# Safe to run before the registrar nameserver flip: cert-manager will retry
# DNS-01 challenges until Cloudflare becomes authoritative, and existing certs
# stay valid ~30 days past their renewal time. Idempotent — re-run freely.
set -euo pipefail

TOKEN="${1:-}"
if [ -z "$TOKEN" ]; then
  echo "Usage: $0 <CLOUDFLARE_API_TOKEN>" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "==> Creating/updating cloudflare-api-token secret in cert-manager namespace"
kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --from-literal=api-token="$TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Applying ClusterIssuers (DNS-01 for codevertexitsolutions.com, HTTP-01 fallback)"
kubectl apply -f "$REPO_ROOT/manifests/cert-manager-clusterissuer.yaml"

echo "==> Verifying issuer readiness"
kubectl get clusterissuer

echo "==> Certificate status (renewals will use DNS-01 for this zone from now on)"
kubectl get certificate -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[0].status,RENEWAL:.status.renewalTime' | head -45

cat <<'EOF'

Done. Next steps in the Cloudflare dashboard:
  1. SSL/TLS -> set encryption mode to "Full (strict)".
  2. Flip hosts to Proxied (orange cloud) gradually: accounts + sso first,
     verify login end-to-end, then the rest. Keep nats + argocd DNS-only.
  3. Speed -> enable Brotli, HTTP/3, 0-RTT, Early Hints.
  4. Caching -> Cache Rule: cache-eligible for /_next/static/* and
     *.js,*.css,*.woff2,*.svg,*.png; bypass cache for *api* hostnames.
EOF
