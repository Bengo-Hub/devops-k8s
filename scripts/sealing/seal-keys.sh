#!/usr/bin/env bash
# Adds or replaces keys in an existing sealed file. Reads KEY=value lines on stdin (the value is
# everything after the first "="), keeps only the KEY names given as arguments, and merges them
# into manifests/sealed-secrets/<ns>/<secret>.sealedsecret.yaml with kubeseal --merge-into.
# Values never touch a file or the terminal.
#
#   printf 'MY_KEY=%s\n' "$value" | scripts/sealing/seal-keys.sh <ns> <secret> MY_KEY
#
# Then: commit and push, refresh sealed-secrets-manifests, restart the workloads that read the key.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/seal-lib.sh"

ns="${1:?namespace}"; name="${2:?secret name}"; shift 2
(( $# > 0 )) || seal_die "name at least one KEY"
ensure_kubeseal
file="$(sealed_file_path "$ns" "$name")"
[[ -f "$file" ]] || seal_die "${file} does not exist; seal the Secret first (seal-from-live.sh)"

seal_python -c '
import base64, json, sys
ns, name, wanted = sys.argv[1], sys.argv[2], set(sys.argv[3:])
data = {}
for line in sys.stdin.read().splitlines():
    if "=" not in line:
        continue
    k, v = line.split("=", 1)
    if k in wanted:
        data[k] = base64.b64encode(v.encode()).decode()
missing = wanted - set(data)
if missing:
    sys.exit("missing on stdin: " + " ".join(sorted(missing)))
json.dump({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": name, "namespace": ns}, "data": data}, sys.stdout)
' "$ns" "$name" "$@" \
  | kubeseal --controller-namespace "$SEAL_CONTROLLER_NS" --controller-name "$SEAL_CONTROLLER_NAME" \
      --scope strict --format yaml --merge-into "$file"

grep -q 'argocd.argoproj.io/sync-options: Prune=false' "$file" || {
  _seal_annotate < "$file" > "${file}.tmp.$$" && mv -f "${file}.tmp.$$" "$file"
}
seal_log "merged $* into ${file#"${SEAL_REPO_ROOT}/"} ($(sealed_key_count "$file") keys)"
