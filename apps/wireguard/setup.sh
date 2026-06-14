#!/usr/bin/env bash
# =============================================================================
# CodeVertex WireGuard VPN overlay — idempotent setup
# =============================================================================
# Run this ONCE per cluster (safe to re-run any time). It:
#   1. creates namespace `vpn`
#   2. generates the WG SERVER keypair into Secret vpn/wg-server-keys IF absent
#      (the PRIVATE key never leaves this Secret)
#   3. generates a WG_PEER_SYNC_TOKEN into the same Secret IF absent
#   4. writes the server PUBLIC key + sync token into the backend Secret
#      (isp-billing-backend/isp-billing-backend-secrets) so the backend can hand
#      the pubkey to routers and authenticate the reconcile loop
#   5. applies the WG server manifests (or leaves that to ArgoCD)
#
# Requirements: kubectl (configured for the target cluster) + wg (wireguard-tools).
# If `wg` is unavailable locally, the script falls back to generating the keypair
# inside a throwaway pod on the cluster.
#
# Re-running is a no-op for existing keys (it will NOT rotate the server key),
# but it WILL re-sync the backend Secret with the current server pubkey/token.
# =============================================================================
set -euo pipefail

VPN_NS="${VPN_NS:-vpn}"
BACKEND_NS="${BACKEND_NS:-isp-billing}"
BACKEND_SECRET="${BACKEND_SECRET:-isp-billing-backend-secrets}"
WG_KEYS_SECRET="${WG_KEYS_SECRET:-wg-server-keys}"
MANIFEST_DIR="${MANIFEST_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/manifests}"
APPLY_MANIFESTS="${APPLY_MANIFESTS:-false}"  # set true to kubectl apply (else ArgoCD owns it)

info()  { echo "[setup] $*"; }
warn()  { echo "[setup][WARN] $*" >&2; }
fatal() { echo "[setup][FATAL] $*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || fatal "kubectl not found in PATH"

# ── 1. Namespace ──
info "Ensuring namespace '${VPN_NS}'"
kubectl get ns "${VPN_NS}" >/dev/null 2>&1 || kubectl create ns "${VPN_NS}"

# ── helper: generate a wg keypair (local wg if present, else in-cluster pod) ──
gen_keypair() {
  if command -v wg >/dev/null 2>&1; then
    WG_PRIV="$(wg genkey)"
    WG_PUB="$(printf '%s' "${WG_PRIV}" | wg pubkey)"
  else
    warn "'wg' not found locally — generating keypair in a throwaway cluster pod"
    WG_PRIV="$(kubectl run wg-keygen-$$ -n "${VPN_NS}" --rm -i --restart=Never \
      --image=ghcr.io/linuxserver/wireguard:1.0.20210914-r4-ls45 --quiet \
      --command -- sh -c 'wg genkey' 2>/dev/null | tr -d '\r\n ')"
    [ -n "${WG_PRIV}" ] || fatal "in-cluster keygen failed"
    WG_PUB="$(kubectl run wg-pubkey-$$ -n "${VPN_NS}" --rm -i --restart=Never \
      --image=ghcr.io/linuxserver/wireguard:1.0.20210914-r4-ls45 --quiet \
      --command -- sh -c "echo '${WG_PRIV}' | wg pubkey" 2>/dev/null | tr -d '\r\n ')"
  fi
  [ -n "${WG_PRIV}" ] && [ -n "${WG_PUB}" ] || fatal "keypair generation produced empty values"
}

# ── 2. Server keypair Secret (create only if absent — never rotate silently) ──
if kubectl -n "${VPN_NS}" get secret "${WG_KEYS_SECRET}" >/dev/null 2>&1; then
  info "Secret ${VPN_NS}/${WG_KEYS_SECRET} already exists — keeping existing server key"
  WG_PUB="$(kubectl -n "${VPN_NS}" get secret "${WG_KEYS_SECRET}" -o jsonpath='{.data.publickey}' | base64 -d)"
  WG_SYNC_TOKEN="$(kubectl -n "${VPN_NS}" get secret "${WG_KEYS_SECRET}" -o jsonpath='{.data.WG_PEER_SYNC_TOKEN}' | base64 -d 2>/dev/null || echo '')"
  if [ -z "${WG_SYNC_TOKEN}" ]; then
    info "No WG_PEER_SYNC_TOKEN in existing Secret — generating + patching one"
    WG_SYNC_TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    kubectl -n "${VPN_NS}" patch secret "${WG_KEYS_SECRET}" --type merge \
      -p "{\"data\":{\"WG_PEER_SYNC_TOKEN\":\"$(printf '%s' "${WG_SYNC_TOKEN}" | base64 -w0)\"}}"
  fi
else
  info "Generating WG server keypair + peer-sync token"
  gen_keypair
  WG_SYNC_TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  kubectl -n "${VPN_NS}" create secret generic "${WG_KEYS_SECRET}" \
    --from-literal=privatekey="${WG_PRIV}" \
    --from-literal=publickey="${WG_PUB}" \
    --from-literal=WG_PEER_SYNC_TOKEN="${WG_SYNC_TOKEN}"
  unset WG_PRIV
  info "Created Secret ${VPN_NS}/${WG_KEYS_SECRET} (server pubkey: ${WG_PUB})"
fi

# ── 3. Sync server PUBLIC key + sync token into the backend Secret ──
if kubectl -n "${BACKEND_NS}" get secret "${BACKEND_SECRET}" >/dev/null 2>&1; then
  info "Patching backend Secret ${BACKEND_NS}/${BACKEND_SECRET} with WG_SERVER_PUBLIC_KEY + WG_PEER_SYNC_TOKEN"
  kubectl -n "${BACKEND_NS}" patch secret "${BACKEND_SECRET}" --type merge -p "{\"data\":{
    \"WG_SERVER_PUBLIC_KEY\":\"$(printf '%s' "${WG_PUB}" | base64 -w0)\",
    \"WG_PEER_SYNC_TOKEN\":\"$(printf '%s' "${WG_SYNC_TOKEN}" | base64 -w0)\"
  }}"
  warn "Restart the backend so it re-reads the Secret: kubectl -n ${BACKEND_NS} rollout restart deploy/isp-billing-backend"
else
  warn "Backend Secret ${BACKEND_NS}/${BACKEND_SECRET} not found — set these manually:"
  warn "  WG_SERVER_PUBLIC_KEY=${WG_PUB}"
  warn "  WG_PEER_SYNC_TOKEN=<the value in ${VPN_NS}/${WG_KEYS_SECRET}>"
fi

# ── 4. Apply WG manifests (optional; ArgoCD usually owns these) ──
if [ "${APPLY_MANIFESTS}" = "true" ]; then
  info "Applying WG manifests from ${MANIFEST_DIR}"
  kubectl apply -f "${MANIFEST_DIR}"
else
  info "Skipping manifest apply (ArgoCD app 'wireguard' owns apps/wireguard/manifests)."
  info "To apply manually: APPLY_MANIFESTS=true $0"
fi

info "Done. Server pubkey: ${WG_PUB}"
info "Verify: kubectl -n ${VPN_NS} get pods,svc; kubectl -n ${VPN_NS} exec deploy/wireguard -- wg show"
