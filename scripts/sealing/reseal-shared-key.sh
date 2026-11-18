#!/usr/bin/env bash
# Reseals one shared value into every Secret listed for it in scripts/sealing/shared-keys.yaml,
# in one commit. The value is read once from stdin (no echo when typed at a terminal) and only
# ever lives in a shell variable and the pipe into kubeseal.
#
#   scripts/sealing/reseal-shared-key.sh INTERNAL_SERVICE_KEY            # paste, then Enter
#   some-command | scripts/sealing/reseal-shared-key.sh INTERNAL_SERVICE_KEY
#
# Options (environment): NO_COMMIT=1 writes the files only; DRY_RUN=1 lists the targets only.
#
# Afterwards: refresh sealed-secrets-manifests, check every target is Synced and that the key's
# hash is the same in all of them (VERIFY below prints namespace/secret and a hash prefix only),
# then restart the workloads listed under "restart" for the key.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/seal-lib.sh"

key="${1:?KEY name, e.g. INTERNAL_SERVICE_KEY}"
map="${SEAL_LIB_DIR}/shared-keys.yaml"

# Prints the entries of one list ("secrets" or "restart") under one key of shared-keys.yaml.
shared_list() {
  awk -v k="$1" -v l="$2" '
    /^[A-Za-z0-9_]+:[[:space:]]*$/ { cur = $1; sub(/:$/, "", cur); list = ""; next }
    cur == k && /^  [a-z]+:[[:space:]]*$/ { list = $1; sub(/:$/, "", list); next }
    cur == k && list == l && /^    - / { sub(/^    - /, ""); sub(/[[:space:]]*#.*$/, ""); print }
  ' "$map"
}

mapfile -t targets < <(shared_list "$key" secrets)
(( ${#targets[@]} > 0 )) || seal_die "no secrets listed for ${key} in ${map}"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  printf '%s\n' "${targets[@]}"; exit 0
fi

# Every target must already be sealed; resealing half of them would leave the fleet split.
missing=()
for t in "${targets[@]}"; do
  [[ -f "$(sealed_file_path "${t%%/*}" "${t#*/}")" ]] || missing+=("$t")
done
(( ${#missing[@]} == 0 )) || seal_die "not sealed yet (run seal-from-live.sh first): ${missing[*]}"

if [[ -t 0 ]]; then
  IFS= read -r -s -p "New value for ${key}: " value; echo >&2
else
  IFS= read -r value
fi
[[ -n "$value" ]] || seal_die "empty value"

ensure_kubeseal
for t in "${targets[@]}"; do
  printf '%s=%s\n' "$key" "$value" | "${SEAL_LIB_DIR}/seal-keys.sh" "${t%%/*}" "${t#*/}" "$key"
done
unset value

if [[ "${NO_COMMIT:-0}" != "1" ]]; then
  files=()
  for t in "${targets[@]}"; do files+=("$(sealed_file_path "${t%%/*}" "${t#*/}")"); done
  git_commit_push "$SEAL_REPO_ROOT" "secrets: reseal ${key} into ${#targets[@]} Secrets" "${files[@]}"
fi

cat >&2 <<EOF
Next:
  kubectl -n argocd annotate application sealed-secrets-manifests argocd.argoproj.io/refresh=hard --overwrite
  VERIFY: for t in $(printf '%s ' "${targets[@]}"); do
    printf '%s %s\n' "\$t" "\$(kubectl get secret "\${t#*/}" -n "\${t%%/*}" -o jsonpath='{.data.${key}}' | sha256sum | cut -c1-12)"; done
  Restart: $(shared_list "$key" restart | tr '\n' ' ')
EOF
