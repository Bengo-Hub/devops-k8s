#!/usr/bin/env bash
# Read-only drift check. Never reads a value.
#
#  1. A Secret owned by a SealedSecret whose data was written by anything other than the
#     controller after the SealedSecret last synced. That write is lost at the next controller
#     restart (every node reboot), which is how pos-api lost TERMINAL_JWT_SECRET on 2026-11-07
#     and how the 2026-11-17 INTERNAL_SERVICE_KEY rotation nearly reverted on seven services.
#  2. A SealedSecret that is not Synced=True.
#  3. An Opaque or dockerconfigjson Secret with no SealedSecret behind it, outside the namespaces
#     and names that are unsealed by design (cert-manager, operators, ArgoCD internals, the
#     sealing keys, Helm output). Listed as a warning; it fails only with STRICT_UNSEALED=1.
#
# Exit 1 when 1 or 2 (or 3 with STRICT_UNSEALED=1) finds anything. Run nightly by
# .github/workflows/sealed-secrets-drift.yml.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/seal-lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Only metadata is kept from the Secrets; data is dropped before anything is written.
kubectl get secrets -A -o json --show-managed-fields | seal_python -c '
import json, sys
d = json.load(sys.stdin)
for s in d["items"]:
    s.pop("data", None); s.pop("stringData", None)
    (s.get("metadata") or {}).get("annotations", {}).pop("kubectl.kubernetes.io/last-applied-configuration", None)
json.dump(d, sys.stdout)
' > "${tmp}/secrets.json"
kubectl get sealedsecrets -A -o json > "${tmp}/sealed.json"

STRICT_UNSEALED="${STRICT_UNSEALED:-0}" seal_python - "${tmp}/secrets.json" "${tmp}/sealed.json" <<'PY'
import json, os, sys
secrets = json.load(open(sys.argv[1]))["items"]
sealed = {(s["metadata"]["namespace"], s["metadata"]["name"]): s for s in json.load(open(sys.argv[2]))["items"]}

UNSEALED_NAMESPACES = {"kube-system", "kube-public", "kube-node-lease", "cert-manager", "ingress-nginx",
                       "calico-system", "calico-apiserver", "tigera-operator", "vpa", "messaging"}
UNSEALED_NAMES = {("argocd", "argocd-secret"), ("argocd", "argocd-redis"), ("argocd", "argocd-initial-admin-secret")}

problems, warnings = [], []
for s in secrets:
    m = s["metadata"]; ns, name = m["namespace"], m["name"]
    typ = s.get("type", "")
    owners = [o for o in m.get("ownerReferences", []) if o.get("kind") == "SealedSecret"]
    if owners:
        ss = sealed.get((ns, owners[0]["name"]))
        cond = next((c for c in (ss or {}).get("status", {}).get("conditions", []) if c.get("type") == "Synced"), {})
        synced_at = cond.get("lastUpdateTime", "")
        if cond.get("status") != "True":
            problems.append(f"{ns}/{name}: SealedSecret not Synced ({cond.get('status', 'no status')})")
        for mf in m.get("managedFields", []):
            if mf.get("manager") == "controller":
                continue
            if "f:data" in (mf.get("fieldsV1") or {}) and mf.get("time", "") > synced_at:
                problems.append(f"{ns}/{name}: data written by {mf.get('manager')} at {mf.get('time')} after the last sync ({synced_at}); it reverts at the next controller restart")
        continue
    if typ not in ("Opaque", "kubernetes.io/dockerconfigjson"):
        continue
    if ns in UNSEALED_NAMESPACES or (ns, name) in UNSEALED_NAMES or m.get("ownerReferences"):
        continue
    if (m.get("labels") or {}).get("app.kubernetes.io/managed-by") == "Helm":
        continue
    warnings.append(f"{ns}/{name}: {typ} Secret with no SealedSecret")

for p in problems:
    print(f"DRIFT  {p}")
for w in warnings:
    print(f"UNSEALED  {w}")
print(f"summary: {len(problems)} drift, {len(warnings)} unsealed")
if problems or (warnings and os.environ.get("STRICT_UNSEALED") == "1"):
    sys.exit(1)
PY
