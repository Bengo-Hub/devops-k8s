#!/usr/bin/env bash
# set-propagate-secrets.sh
# Compiles secrets from exported file and sets PROPAGATE_SECRETS in devops-k8s repo
# Run this when secrets change or PROPAGATE_SECRETS needs to be initialized
# Requires: exported secrets file (e.g., from K8s or previous export)

set -euo pipefail

ORG="${ORG:-Bengo-Hub}"
REPO="${REPO:-Bengo-Hub/devops-k8s}"

# Try multiple possible paths for secrets file
POSSIBLE_PATHS=(
  "${SECRETS_FILE:-}"
  "/d/KubeSecrets/git-secrets/Bengo-Hub__devops-k8s/secrets.txt"
  "D:/KubeSecrets/git-secrets/Bengo-Hub__devops-k8s/secrets.txt"
  "/mnt/d/KubeSecrets/git-secrets/Bengo-Hub__devops-k8s/secrets.txt"
  "/tmp/exported-secrets.txt"
)

SECRETS_FILE=""
for path in "${POSSIBLE_PATHS[@]}"; do
  if [ -n "$path" ] && [ -f "$path" ]; then
    SECRETS_FILE="$path"
    echo "[DEBUG] Found secrets file at: $SECRETS_FILE"
    break
  fi
done

# Check if secrets file exists
if [ -z "$SECRETS_FILE" ] || [ ! -f "$SECRETS_FILE" ]; then
  echo "[ERROR] Secrets file not found in any of the following locations:"
  for path in "${POSSIBLE_PATHS[@]}"; do
    [ -n "$path" ] && echo "  - $path"
  done
  echo ""
  echo "[INFO] Please provide secrets file path via SECRETS_FILE env var"
  echo "[INFO] Example: SECRETS_FILE=/path/to/secrets.txt $0"
  exit 1
fi

echo "[INFO] Compiling secrets from: $SECRETS_FILE"

# Show file details
FILE_SIZE=$(wc -c < "$SECRETS_FILE" | tr -d ' ')
SECRET_COUNT=$(grep -c '^[A-Z_]*=' "$SECRETS_FILE" || echo 0)
echo "[DEBUG] File size: $FILE_SIZE bytes"
echo "[DEBUG] Detected secrets count: $SECRET_COUNT"
echo "[DEBUG] First 3 secret names:"
grep '^[A-Z_]*=' "$SECRETS_FILE" | head -3 | cut -d= -f1 | sed 's/^/  - /'

# Check gh auth
echo "[DEBUG] Checking gh authentication..."
if ! gh auth status 2>&1 | head -5; then
  echo "[ERROR] gh not authenticated. Run: gh auth login"
  exit 1
fi
echo "[DEBUG] gh authenticated successfully"

# Base64 encode the secrets file
echo "[DEBUG] Encoding secrets file to base64..."
ENCODED=$(base64 -w0 < "$SECRETS_FILE" 2>/dev/null || base64 < "$SECRETS_FILE" | tr -d '\n')

if [ -z "$ENCODED" ]; then
  echo "[ERROR] Failed to encode secrets file"
  exit 1
fi

ENCODED_LENGTH=${#ENCODED}
echo "[DEBUG] Base64 encoded length: $ENCODED_LENGTH characters"
echo "[DEBUG] Base64 preview (first 50 chars): ${ENCODED:0:50}..."

# Set PROPAGATE_SECRETS in the target repo (idempotent)
echo "[INFO] Setting PROPAGATE_SECRETS in repo: $REPO"
echo "[DEBUG] Running: gh secret set PROPAGATE_SECRETS --repo $REPO"

if echo "$ENCODED" | gh secret set PROPAGATE_SECRETS --repo "$REPO" --body -; then
  echo "[INFO] ✓ Successfully set PROPAGATE_SECRETS in $REPO"
else
  EXIT_CODE=$?
  echo "[ERROR] ✗ Failed to set PROPAGATE_SECRETS in $REPO (exit code: $EXIT_CODE)"
  exit 1
fi

# Verify the secret was set
echo "[DEBUG] Verifying PROPAGATE_SECRETS was set..."
sleep 2
if gh secret list --repo "$REPO" | grep -q "PROPAGATE_SECRETS"; then
  UPDATED_AT=$(gh secret list --repo "$REPO" --json name,updatedAt -q '.[] | select(.name=="PROPAGATE_SECRETS") | .updatedAt')
  echo "[INFO] ✓ Verified: PROPAGATE_SECRETS exists (updated: $UPDATED_AT)"
else
  echo "[WARN] Could not verify PROPAGATE_SECRETS in secret list"
fi

echo "[INFO] Done. PROPAGATE_SECRETS is ready for use by propagate-to-repo.sh"
