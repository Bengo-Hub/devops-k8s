#!/usr/bin/env bash
# Backs up the sealed-secrets controller's sealing keys (kube-system, label
# sealedsecrets.bitnami.com/sealed-secrets-key) to two places:
#
#   1. Primary: the private R2 backup bucket (the one that holds the pg_dumpall copies), as
#      sealed-secrets-keys/sealed-secrets-keys-<UTC stamp>.yaml.gz.age, encrypted with age to
#      AGE_RECIPIENT. The matching age identity lives offline only (never in the cluster, git or a
#      GitHub secret), so this copy is useless to anyone holding the bucket credentials alone.
#      The newest R2_KEEP (default 30) copies are kept.
#   2. Secondary: the SEALED_SECRETS_MASTER_KEY GitHub secret, gzip-compressed and base64 encoded
#      so it keeps fitting under GitHub's 48 KB limit (about 7 KB of YAML per key, a new key every
#      30 days). provision.yml's restore step accepts this format and the old plain YAML.
#
# The key YAML only ever lives in pipes; the only file written is the age ciphertext.
# Needs: kubectl (cluster access), gzip, age, aws CLI, gh with GH_TOKEN allowed to set repo secrets.
# Env: AGE_RECIPIENT (required), GITHUB_REPOSITORY (for the secret), SKIP_GITHUB_SECRET=1 to skip 2.
set -euo pipefail

: "${AGE_RECIPIENT:?AGE_RECIPIENT (age public key) is required}"
R2_BUCKET=${R2_BUCKET:-codevertex-platform-backups}
R2_PREFIX=${R2_PREFIX:-sealed-secrets-keys}
R2_KEEP=${R2_KEEP:-30}
SELECTOR="sealedsecrets.bitnami.com/sealed-secrets-key"

keys() { kubectl get secret -n kube-system -l "$SELECTOR" -o yaml; }

count=$(kubectl get secret -n kube-system -l "$SELECTOR" --no-headers | wc -l | tr -d ' ')
(( count > 0 )) || { echo "::error::no sealing keys found in kube-system"; exit 1; }
echo "sealing keys in cluster: ${count}"

# R2 credentials: the same Secret the pg_dumpall CronJob uses, read into masked env vars only.
r2val() { kubectl get secret postgresql-backup-r2-secrets -n infra -o jsonpath="{.data.$1}" | base64 -d; }
AWS_ACCESS_KEY_ID="$(r2val R2_ACCESS_KEY_ID)"
AWS_SECRET_ACCESS_KEY="$(r2val R2_SECRET_ACCESS_KEY)"
R2_ENDPOINT="$(r2val R2_S3_ENDPOINT)"
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  echo "::add-mask::${AWS_ACCESS_KEY_ID}"; echo "::add-mask::${AWS_SECRET_ACCESS_KEY}"; echo "::add-mask::${R2_ENDPOINT}"
fi
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=auto
# R2 rejects the newer default request checksums of aws-cli v2.23+.
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
s3() { aws --endpoint-url "$R2_ENDPOINT" "$@"; }

umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
obj="${R2_PREFIX}/sealed-secrets-keys-${stamp}.yaml.gz.age"

keys | gzip -9 | age -r "$AGE_RECIPIENT" -o "${work}/keys.age"
head -c 21 "${work}/keys.age" | grep -q '^age-encryption.org/v1' || { echo "::error::age output is not an age file"; exit 1; }
s3 s3 cp "${work}/keys.age" "s3://${R2_BUCKET}/${obj}" --only-show-errors
size=$(s3 s3api head-object --bucket "$R2_BUCKET" --key "$obj" --query ContentLength --output text)
[[ "$size" == "$(wc -c < "${work}/keys.age" | tr -d ' ')" ]] || { echo "::error::R2 object size mismatch"; exit 1; }
echo "R2: uploaded ${obj} (${size} bytes, age-encrypted, ${count} keys)"

# Retention: keep the newest R2_KEEP copies (names sort by time).
mapfile -t objs < <(s3 s3api list-objects-v2 --bucket "$R2_BUCKET" --prefix "${R2_PREFIX}/" \
  --query 'Contents[].Key' --output text | tr '\t' '\n' | grep -v '^None$' | sort)
if (( ${#objs[@]} > R2_KEEP )); then
  for old in "${objs[@]:0:${#objs[@]}-R2_KEEP}"; do
    s3 s3 rm "s3://${R2_BUCKET}/${old}" --only-show-errors && echo "R2: pruned ${old}"
  done
fi

if [[ "${SKIP_GITHUB_SECRET:-0}" != "1" ]]; then
  : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required for the GitHub secret copy}"
  keys | gzip -9 | base64 -w0 | gh secret set SEALED_SECRETS_MASTER_KEY --repo "$GITHUB_REPOSITORY"
  echo "GitHub: SEALED_SECRETS_MASTER_KEY refreshed (gzip+base64, ${count} keys)"
fi
