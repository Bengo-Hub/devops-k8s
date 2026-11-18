#!/usr/bin/env bash
# Seals the keys a deploy wants in a Secret, the git way. Used by service build.sh files whose
# Secret is not built by create-service-secrets.sh (UI env Secrets, extra keys such as the
# codevertex-website Prisma URLs). Never runs kubectl patch, create or apply on a Secret.
#
# stdin: the desired Secret as JSON, normally straight from
#   kubectl create secret generic <name> -n <ns> --from-literal=K=v ... --dry-run=client -o json
# so values only pass through env vars and pipes.
#
#   ... | scripts/sealing/seal-desired.sh <namespace> <secret> <app>
#
# Behaviour (generate-or-preserve, same rule as create-service-secrets.sh):
#   - every desired key the live Secret already holds keeps its live value; a different desired
#     value is reported by name only and replaces the live one only with SEAL_OVERWRITE=1
#   - desired keys the live Secret lacks are added
#   - nothing to add and a SealedSecret already owns the Secret: exit 0 (normal deploy path)
#   - otherwise the whole Secret (live keys plus the added ones) is sealed into
#     manifests/sealed-secrets/<ns>/<secret>.sealedsecret.yaml of this checkout, an existing
#     unowned Secret is marked adoptable, the file is committed and pushed with the rebase loop,
#     sealed-secrets-manifests is refreshed and the script waits for Synced=True.
# DRY_RUN=1 prints the key names that would change and stops.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/seal-lib.sh"

ns="${1:?namespace}"; name="${2:?secret name}"; app="${3:-$2}"
desired="$(cat)"
[[ -n "$desired" ]] || seal_die "no desired Secret JSON on stdin"

# mode new|differs: key names only. mode merge: the Secret to seal.
merge() {
  printf '%s' "$desired" | SEAL_OVERWRITE="${SEAL_OVERWRITE:-0}" seal_python -c '
import json, os, subprocess, sys
mode, ns, name, app = sys.argv[1:5]
desired = json.load(sys.stdin).get("data") or {}
p = subprocess.run(["kubectl", "get", "secret", name, "-n", ns, "-o", "json"], capture_output=True, text=True)
live = json.loads(p.stdout) if p.returncode == 0 and p.stdout.strip() else {}
live_data = live.get("data") or {}
if mode == "new":
    print(" ".join(k for k in sorted(desired) if k not in live_data)); sys.exit(0)
if mode == "differs":
    print(" ".join(k for k in sorted(desired) if k in live_data and live_data[k] != desired[k])); sys.exit(0)
overwrite = os.environ.get("SEAL_OVERWRITE") == "1"
data = dict(live_data)
for k, v in desired.items():
    if k not in data or overwrite:
        data[k] = v
labels = dict((live.get("metadata") or {}).get("labels") or {})
out = {"apiVersion": "v1", "kind": "Secret", "type": live.get("type", "Opaque"),
       "metadata": {"name": name, "namespace": ns}, "data": data}
if labels:
    out["metadata"]["labels"] = labels
json.dump(out, sys.stdout)
' "$1" "$ns" "$name" "$app"
}

new_keys="$(merge new | tr -d '\r')"
diff_keys="$(merge differs | tr -d '\r')"
if [[ -n "$diff_keys" && "${SEAL_OVERWRITE:-0}" != "1" ]]; then
  seal_log "${ns}/${name} keeps its current ${diff_keys} (differ from the deploy's value; rerun with SEAL_OVERWRITE=1 to replace them)"
  diff_keys=""
fi
changed="$(echo "${new_keys} ${diff_keys}" | xargs)"
owner="$(sealed_owner "$ns" "$name")"
live_exists=false
kubectl get secret "$name" -n "$ns" >/dev/null 2>&1 && live_exists=true

if [[ -z "$changed" && -n "$owner" ]]; then
  seal_log "${ns}/${name} (SealedSecret ${owner}) already holds every key this deploy sets; nothing to write"
  exit 0
fi
seal_log "${ns}/${name}: keys to seal: ${changed:-<adopt existing Secret>}"
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  seal_log "DRY_RUN=1: nothing sealed or committed"
  exit 0
fi

ensure_kubeseal
file="$(sealed_file_path "$ns" "$name")"
merge merge | seal_secret_json "$file"
unset desired
if [[ "$live_exists" == "true" && -z "$owner" ]]; then
  mark_adoptable "$ns" "$name"
fi
git_commit_push "$SEAL_REPO_ROOT" "secrets(${app}): seal ${changed:-${name} from live}" "$file" \
  || seal_die "could not push ${file#"${SEAL_REPO_ROOT}/"}; nothing changed in the cluster"
refresh_sealed_app || true
wait_synced "$ns" "$name" || seal_die "${ns}/${name} did not sync; check: kubectl get sealedsecret ${name} -n ${ns} -o yaml"
