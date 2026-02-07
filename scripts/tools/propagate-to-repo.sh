#!/usr/bin/env bash
# propagate-to-repo.sh
# Propagates specific secrets to a target repo
# Usage: ./propagate-to-repo.sh <target-repo> <secret1> [secret2] ...
# Example: ./propagate-to-repo.sh Bengo-Hub/truload-backend POSTGRES_PASSWORD REDIS_PASSWORD

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <target-repo> <secret1> [secret2] ..."
  exit 1
fi

TARGET_REPO="$1"
shift
SECRETS_TO_PROPAGATE=("$@")

# PROPAGATE_SECRETS_FILE must be set explicitly - no defaults to local paths
# In CI: Set by workflow after decoding PROPAGATE_SECRETS to /tmp/propagate-secrets.txt
# Locally: Set via PROPAGATE_SECRETS_FILE=/path/to/secrets.txt
if [ -z "${PROPAGATE_SECRETS_FILE:-}" ]; then
  echo "[ERROR] PROPAGATE_SECRETS_FILE environment variable is not set"
  echo "[INFO] This script requires PROPAGATE_SECRETS_FILE to point to the secrets file"
  echo "[INFO] In CI: Should be set to /tmp/propagate-secrets.txt (decoded from PROPAGATE_SECRETS)"
  echo "[INFO] Locally: Set via PROPAGATE_SECRETS_FILE=/path/to/secrets.txt"
  echo "[INFO] Skipping direct propagation - use remote dispatch instead"
  exit 1
fi

SECRETS_FILE="${PROPAGATE_SECRETS_FILE}"

echo "[INFO] Propagating secrets to: $TARGET_REPO"
echo "[INFO] Secrets requested: ${SECRETS_TO_PROPAGATE[*]}"
echo "[DEBUG] Using secrets file: $SECRETS_FILE"

if ! gh auth status &>/dev/null; then
  echo "[ERROR] gh not authenticated"
  exit 1
fi

if [ ! -f "$SECRETS_FILE" ]; then
  echo "[ERROR] Secrets file not found: $SECRETS_FILE"
  echo "[INFO] Ensure PROPAGATE_SECRETS_FILE points to a valid file"
  exit 1
fi

# Parse secrets file
declare -A SECRETS_MAP
cur_name=""
cur_value=""

while IFS= read -r line; do
  if [[ "$line" =~ ^secret:[[:space:]]*(.+)$ ]]; then
    [[ -n "$cur_name" && -n "$cur_value" ]] && SECRETS_MAP["$cur_name"]="$cur_value"
    cur_name="${BASH_REMATCH[1]}"
    cur_value=""
  elif [[ "$line" =~ ^value:[[:space:]]*(.*)$ ]]; then
    cur_value="${BASH_REMATCH[1]}"
  elif [[ -n "$cur_value" && ! "$line" =~ ^--- && ! "$line" =~ ^secret: ]]; then
    cur_value="$cur_value"$'\n'"$line"
  fi
done < "$SECRETS_FILE"
[[ -n "$cur_name" && -n "$cur_value" ]] && SECRETS_MAP["$cur_name"]="$cur_value"

# Critical secrets that should not be overwritten if they already exist and are working
# These are typically cluster/infrastructure secrets that are manually configured
CRITICAL_SECRETS=("KUBE_CONFIG" "CONTABO_API_PASSWORD" "CONTABO_CLIENT_SECRET")

# Propagate secrets
SUCCESS=0
FAILED=0
SKIPPED=0

for SECRET_NAME in "${SECRETS_TO_PROPAGATE[@]}"; do
  if [ -z "${SECRETS_MAP[$SECRET_NAME]:-}" ]; then
    echo "[WARN] $SECRET_NAME not found in secrets file. Skipping."
    FAILED=$((FAILED + 1))
    continue
  fi
  
  # Check if this is a critical secret that already exists
  if [[ " ${CRITICAL_SECRETS[*]} " =~ " ${SECRET_NAME} " ]]; then
    if gh secret list --repo "$TARGET_REPO" --json name -q '.[].name' 2>/dev/null | grep -q "^${SECRET_NAME}$"; then
      echo "[INFO] $SECRET_NAME is a critical secret and already exists in $TARGET_REPO - skipping to prevent overwrite"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
  fi
  
  VALUE="${SECRETS_MAP[$SECRET_NAME]}"
  
  # Debug: Show masked value for credential secrets
  if [[ "$SECRET_NAME" == "REGISTRY_USERNAME" ]]; then
    echo "[DEBUG] Decoded username: $VALUE"
  elif [[ "$SECRET_NAME" == "REGISTRY_PASSWORD" ]] || [[ "$SECRET_NAME" == *"PASSWORD"* ]]; then
    MASKED="${VALUE:0:1}****${VALUE: -1}"
    echo "[DEBUG] Decoded password length: ${#VALUE} chars, masked: $MASKED"
  fi
  
  # Set secret as plain text (GitHub encrypts it automatically)
  # DO NOT base64-encode here - gh secret set expects plain text
  echo "[INFO] Setting $SECRET_NAME in $TARGET_REPO"
  if echo -n "$VALUE" | gh secret set "$SECRET_NAME" --repo "$TARGET_REPO" --body - 2>&1; then
    SUCCESS=$((SUCCESS + 1))
  else
    echo "[ERROR] Failed to set $SECRET_NAME"
    FAILED=$((FAILED + 1))
  fi
done

echo "[INFO] Summary: $SUCCESS succeeded, $FAILED failed, $SKIPPED skipped (critical secrets already present)"
if [ $FAILED -gt 0 ]; then
  exit 1
elif [ $SUCCESS -eq 0 ] && [ $SKIPPED -eq 0 ]; then
  echo "[WARN] No secrets were propagated"
  exit 1
else
  exit 0
fi
