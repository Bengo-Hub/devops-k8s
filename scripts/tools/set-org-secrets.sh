#!/usr/bin/env bash
# set-org-secrets.sh
# Set application secrets at GitHub organization level for direct access
# Eliminates need for per-repo secret propagation

set -euo pipefail

ORG="${ORG:-Bengo-Hub}"
SECRETS_FILE="${SECRETS_FILE:-}"

# Try multiple possible paths for secrets file
POSSIBLE_PATHS=(
  "$SECRETS_FILE"
  "/d/KubeSecrets/git-secrets/Bengo-Hub__devops-k8s/secrets.txt"
  "D:/KubeSecrets/git-secrets/Bengo-Hub__devops-k8s/secrets.txt"
  "/mnt/d/KubeSecrets/git-secrets/Bengo-Hub__devops-k8s/secrets.txt"
  "/tmp/exported-secrets.txt"
)

for path in "${POSSIBLE_PATHS[@]}"; do
  if [ -n "$path" ] && [ -f "$path" ]; then
    SECRETS_FILE="$path"
    echo "[INFO] Found secrets file: $SECRETS_FILE"
    break
  fi
done

if [ -z "$SECRETS_FILE" ] || [ ! -f "$SECRETS_FILE" ]; then
  echo "[ERROR] Secrets file not found"
  echo "[INFO] Provide via: SECRETS_FILE=/path/to/secrets.txt $0"
  exit 1
fi

# Check gh auth
if ! gh auth status &>/dev/null; then
  echo "[ERROR] gh not authenticated. Run: gh auth login"
  exit 1
fi

echo "[INFO] Setting organization-level secrets for: $ORG"
echo "[INFO] Source: $SECRETS_FILE"

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

# Application secrets (safe to share across repos via org-level)
# Exclude environment-specific secrets (KUBE_CONFIG, SSH keys, Contabo credentials)
APP_SECRETS=(
  "POSTGRES_PASSWORD"
  "REDIS_PASSWORD"
  "RABBITMQ_PASSWORD"
  "REGISTRY_USERNAME"
  "REGISTRY_PASSWORD"
  "REGISTRY_EMAIL"
  "GIT_TOKEN"
  "GIT_USER"
  "GIT_EMAIL"
  "GIT_APP_ID"
  "GIT_APP_SECRET"
  "GOOGLE_CLIENT_ID"
  "GOOGLE_CLIENT_SECRET"
  "DEFAULT_TENANT_SLUG"
  "GLOBAL_ADMIN_EMAIL"
  "SSH_HOST"
  "SSH_USER"
)

SUCCESS=0
FAILED=0
SKIPPED=0

echo ""
echo "=== Setting Organization Secrets ==="
echo ""

for secret_name in "${APP_SECRETS[@]}"; do
  value="${SECRETS_MAP[$secret_name]:-}"
  
  if [ -z "$value" ]; then
    echo "[WARN] $secret_name not found in secrets file - skipping"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  
  # Mask sensitive values in output
  if [[ "$secret_name" == *"PASSWORD"* ]] || [[ "$secret_name" == *"SECRET"* ]] || [[ "$secret_name" == *"TOKEN"* ]]; then
    masked="${value:0:1}****${value: -1}"
    echo "[INFO] Setting $secret_name (length: ${#value}, masked: $masked)"
  else
    echo "[INFO] Setting $secret_name (value: $value)"
  fi
  
  # Set org-level secret with "all" visibility
  # Note: Change to --visibility selected if you want granular repo control
  if echo -n "$value" | gh secret set "$secret_name" --org "$ORG" --visibility all 2>&1; then
    SUCCESS=$((SUCCESS + 1))
  else
    echo "[ERROR] Failed to set $secret_name"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "=== Summary ==="
echo "✓ Success: $SUCCESS"
echo "✗ Failed: $FAILED"
echo "⊝ Skipped: $SKIPPED"
echo ""

if [ $SUCCESS -gt 0 ]; then
  echo "[INFO] Organization secrets set successfully"
  echo "[INFO] View at: https://github.com/organizations/$ORG/settings/secrets/actions"
  echo ""
  echo "[NEXT STEPS]"
  echo "1. If you used --visibility all, skip step 2"
  echo "2. If you used --visibility selected, configure repository access:"
  echo "   - Go to: https://github.com/organizations/$ORG/settings/secrets/actions"
  echo "   - For each secret, click 'Update'"
  echo "   - Choose 'Selected repositories' and grant access"
  echo "3. Test with one repository:"
  echo "   gh secret delete POSTGRES_PASSWORD --repo $ORG/test-repo"
  echo "   gh workflow run deploy.yml --repo $ORG/test-repo"
  echo "4. Verify workflow uses org-level secrets successfully"
  echo "5. Roll out to all repos (see docs/SECRET_ORG_LEVEL_STRATEGY.md)"
fi

if [ $FAILED -gt 0 ]; then
  echo "[ERROR] Some secrets failed to set. Check errors above."
  exit 1
fi

exit 0
