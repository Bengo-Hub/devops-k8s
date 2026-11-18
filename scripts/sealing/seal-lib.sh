# shellcheck shell=bash
# Shared functions for sealing Secrets into manifests/sealed-secrets/<namespace>/<name>.sealedsecret.yaml.
#
# Rules every caller follows:
#   - a plaintext value only ever lives in a pipe or a shell variable, never in a file or a log line
#   - files are sealed with strict scope (they decrypt only under that name in that namespace)
#   - every SealedSecret carries argocd.argoproj.io/sync-options: Prune=false, so removing a file
#     never deletes a live Secret
#   - git is committed and pushed BEFORE anything is refreshed (selfHeal puts the old file back otherwise)
#
# Source it:  source "$(dirname "$0")/seal-lib.sh"

SEAL_CONTROLLER_NS=${SEAL_CONTROLLER_NS:-kube-system}
SEAL_CONTROLLER_NAME=${SEAL_CONTROLLER_NAME:-sealed-secrets-controller}
# Pinned to the controller version; the sha256 is from the release's checksums file.
KUBESEAL_VERSION=${KUBESEAL_VERSION:-0.38.4}
KUBESEAL_SHA256_LINUX_AMD64=${KUBESEAL_SHA256_LINUX_AMD64:-ab5ae808b0efcb167a825b6cf7f3a7c0034bd99a6301d78db2012da651a8c0b9}

SEAL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEAL_REPO_ROOT=${SEAL_REPO_ROOT:-"$(cd "${SEAL_LIB_DIR}/../.." && pwd)"}
SEALED_DIR=${SEALED_DIR:-"${SEAL_REPO_ROOT}/manifests/sealed-secrets"}

seal_log() { printf '[seal] %s\n' "$*" >&2; }
seal_die() { printf '[seal] ERROR: %s\n' "$*" >&2; exit 1; }

# A python interpreter (python3 on Linux runners, python on Windows Git Bash). Always run isolated.
seal_python() {
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys' >/dev/null 2>&1; then
    python3 -I "$@"
  else
    python -I "$@"
  fi
}

# Installs kubeseal into a private bin dir when it is missing (CI runners), checking the sha256.
ensure_kubeseal() {
  if command -v kubeseal >/dev/null 2>&1; then return 0; fi
  local bin="${HOME}/.local/bin" tmp
  mkdir -p "$bin"
  tmp="$(mktemp -d)"
  curl -fsSL --retry 3 -o "${tmp}/kubeseal.tgz" \
    "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" \
    || seal_die "kubeseal download failed"
  echo "${KUBESEAL_SHA256_LINUX_AMD64}  ${tmp}/kubeseal.tgz" | sha256sum -c - >/dev/null \
    || seal_die "kubeseal checksum mismatch"
  tar -xzf "${tmp}/kubeseal.tgz" -C "$tmp" kubeseal
  install -m 0755 "${tmp}/kubeseal" "${bin}/kubeseal"
  rm -rf "$tmp"
  export PATH="${bin}:${PATH}"
  kubeseal --version >&2
}

sealed_file_path() { printf '%s/%s/%s.sealedsecret.yaml' "$SEALED_DIR" "$1" "$2"; }

# stdin: a Secret as JSON (kubectl get -o json, or kubectl create --dry-run=client -o json)
# stdout: a minimal Secret (type, name, namespace, labels, data). Annotations are dropped on
# purpose: kubectl's last-applied-configuration annotation holds every value in plaintext.
# Optional $1 overrides the namespace (used when one source is sealed into several namespaces).
secret_json_clean() {
  local ns_override="${1:-}"
  seal_python -c '
import json, sys
s = json.load(sys.stdin)
m = s.get("metadata", {})
out = {"apiVersion": "v1", "kind": "Secret", "type": s.get("type", "Opaque"),
       "metadata": {"name": m["name"], "namespace": sys.argv[1] or m.get("namespace")},
       "data": s.get("data") or {}}
labels = m.get("labels") or {}
if labels:
    out["metadata"]["labels"] = labels
json.dump(out, sys.stdout)
' "$ns_override"
}

# Adds the Prune=false annotation to a SealedSecret YAML on stdin (kubeseal output has no
# metadata.annotations for strict scope) and drops kubeseal's "creationTimestamp: null" noise.
_seal_annotate() {
  awk '
    /^  creationTimestamp: null$/ { next }
    { print }
    !done && /^metadata:$/ { print "  annotations:"; print "    argocd.argoproj.io/sync-options: Prune=false"; done=1 }
  '
}

# stdin: Secret JSON (already cleaned). $1: output file. Writes the SealedSecret atomically.
seal_secret_json() {
  local out="$1" tmp
  mkdir -p "$(dirname "$out")"
  tmp="${out}.tmp.$$"
  if ! kubeseal --controller-namespace "$SEAL_CONTROLLER_NS" --controller-name "$SEAL_CONTROLLER_NAME" \
        --scope strict --format yaml | _seal_annotate > "$tmp"; then
    rm -f "$tmp"; seal_die "kubeseal failed for ${out}"
  fi
  grep -q '^kind: SealedSecret$' "$tmp" || { rm -f "$tmp"; seal_die "kubeseal produced no SealedSecret for ${out}"; }
  mv -f "$tmp" "$out"
}

# Number of keys under spec.encryptedData of a sealed file.
sealed_key_count() {
  awk '/^  encryptedData:/{f=1;next} f&&/^    [^ ]/{n++} f&&/^  [^ ]/{f=0} END{print n+0}' "$1"
}

# sha256 of a live Secret's .data (canonical JSON). Prints the hash only, never a value.
secret_data_hash() {
  kubectl get secret "$2" -n "$1" -o json | seal_python -c '
import json, sys, hashlib
d = json.load(sys.stdin).get("data") or {}
print(hashlib.sha256(json.dumps(d, sort_keys=True, separators=(",", ":")).encode()).hexdigest())
'
}

# Owner SealedSecret name of a live Secret ("" when it has none).
sealed_owner() {
  kubectl get secret "$2" -n "$1" \
    -o jsonpath='{.metadata.ownerReferences[?(@.kind=="SealedSecret")].name}' 2>/dev/null || true
}

# Marks an existing, unowned Secret as adoptable by the controller (metadata only; data untouched).
mark_adoptable() {
  kubectl annotate secret "$2" -n "$1" sealedsecrets.bitnami.com/managed=true --overwrite >/dev/null
}

# Bounded wait (60 x 5 s) until the SealedSecret reports Synced=True for its current generation
# and the Secret is owned by it.
wait_synced() {
  local ns="$1" name="$2" tries="${3:-60}" i gen obs st own
  for ((i = 1; i <= tries; i++)); do
    gen=$(kubectl get sealedsecret "$name" -n "$ns" -o jsonpath='{.metadata.generation}' 2>/dev/null || true)
    obs=$(kubectl get sealedsecret "$name" -n "$ns" -o jsonpath='{.status.observedGeneration}' 2>/dev/null || true)
    st=$(kubectl get sealedsecret "$name" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Synced")].status}' 2>/dev/null || true)
    own=$(sealed_owner "$ns" "$name")
    if [[ -n "$gen" && "$gen" == "$obs" && "$st" == "True" && "$own" == "$name" ]]; then
      seal_log "${ns}/${name}: Synced=True, owned by its SealedSecret"
      return 0
    fi
    sleep 5
  done
  seal_log "${ns}/${name}: not synced after $((tries * 5))s (generation=${gen:-?} observed=${obs:-?} synced=${st:-?} owner=${own:-none})"
  return 1
}

# Asks ArgoCD to re-read git for the sealed-secrets folder now instead of at the next poll.
refresh_sealed_app() {
  kubectl -n argocd annotate application sealed-secrets-manifests \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null
}

# Commits the given paths in the repo and pushes with the fetch, rebase and retry loop the
# release bot uses (other bots push to main often).
git_commit_push() {
  local repo="$1" msg="$2"; shift 2
  local branch i
  branch=${SEAL_GIT_BRANCH:-main}
  git -C "$repo" config user.name >/dev/null 2>&1 || git -C "$repo" config user.name "${GIT_USER:-devops-bot}"
  git -C "$repo" config user.email >/dev/null 2>&1 || git -C "$repo" config user.email "${GIT_EMAIL:-devops-bot@users.noreply.github.com}"
  git -C "$repo" add -- "$@"
  if git -C "$repo" diff --cached --quiet; then seal_log "nothing to commit"; return 0; fi
  git -C "$repo" commit -q -m "$msg"
  for ((i = 1; i <= 6; i++)); do
    if git -C "$repo" push -q origin "HEAD:${branch}"; then return 0; fi
    seal_log "push rejected, rebasing (attempt ${i})"
    git -C "$repo" fetch -q origin "$branch" && git -C "$repo" rebase -q "origin/${branch}" || return 1
    sleep $((i * 3))
  done
  return 1
}
