#!/usr/bin/env bash
# Seals one Secret, built from GitHub secrets, into several namespaces (one file each).
# stdin: the Secret as JSON, normally straight from
#   kubectl create secret ... --dry-run=client -o json
# so the values only pass through env vars and pipes. Runs in a devops-k8s workflow.
#
#   kubectl create secret generic object-storage --from-literal=... --dry-run=client -o json \
#     | scripts/sealing/seal-from-github-secret.sh auth treasury inventory
#
# Writes manifests/sealed-secrets/<ns>/<name>.sealedsecret.yaml per namespace. The caller commits
# (git_commit_push) and refreshes; nothing here touches the cluster except fetching the public cert.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/seal-lib.sh"

(( $# > 0 )) || seal_die "name at least one namespace"
ensure_kubeseal
src="$(cat)"
[[ -n "$src" ]] || seal_die "no Secret JSON on stdin"
name="$(printf '%s' "$src" | seal_python -c 'import json,sys; print(json.load(sys.stdin)["metadata"]["name"])')"

for ns in "$@"; do
  out="$(sealed_file_path "$ns" "$name")"
  printf '%s' "$src" | secret_json_clean "$ns" | seal_secret_json "$out"
  seal_log "sealed ${ns}/${name} ($(sealed_key_count "$out") keys)"
done
unset src
