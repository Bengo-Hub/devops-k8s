#!/usr/bin/env bash
# Seals a live Secret exactly as it is into manifests/sealed-secrets/<ns>/<name>.sealedsecret.yaml.
# Used to adopt an existing Secret and to repair drift. Writes the file only; no cluster change.
# Prints the key count and the sha256 of the live data (never a value).
#
#   scripts/sealing/seal-from-live.sh <namespace> <secret>
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/seal-lib.sh"

ns="${1:?namespace}"; name="${2:?secret name}"
ensure_kubeseal
out="$(sealed_file_path "$ns" "$name")"

live_keys=$(kubectl get secret "$name" -n "$ns" -o go-template='{{len .data}}')
kubectl get secret "$name" -n "$ns" -o json | secret_json_clean | seal_secret_json "$out"

sealed_keys=$(sealed_key_count "$out")
[[ "$live_keys" == "$sealed_keys" ]] || seal_die "${ns}/${name}: live has ${live_keys} keys, sealed file has ${sealed_keys}"
printf '%s/%s keys=%s hash=%s file=%s\n' "$ns" "$name" "$sealed_keys" "$(secret_data_hash "$ns" "$name")" "${out#"${SEAL_REPO_ROOT}/"}"
