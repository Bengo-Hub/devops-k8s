#!/usr/bin/env bash
# set-propagate-secrets.sh
# Compiles secrets from exported file and sets PROPAGATE_SECRETS in devops-k8s repo
# Run this when secrets change or PROPAGATE_SECRETS needs to be initialized
# Requires: exported secrets file (e.g., from K8s or previous export)

set -euo pipefail

ORG="${ORG:-Bengo-Hub}"
REPO="${REPO:-Bengo-Hub/devops-k8s}"
SECRETS_FILE="${SECRETS_FILE:-/tmp/exported-secrets.txt}"

# Check if secrets file exists
if [ ! -f "$SECRETS_FILE" ]; then
  echo "[ERROR] Secrets file not found: $SECRETS_FILE"
  echo "[INFO] Please provide exported secrets file path via SECRETS_FILE env var"
  echo "[INFO] Example: SECRETS_FILE=/path/to/secrets.txt $0"
  exit 1
fi

echo "[INFO] Compiling secrets from: $SECRETS_FILE"

# Check gh auth
if ! gh auth status &>/dev/null; then
  echo "[ERROR] gh not authenticated. Run: gh auth login"
  exit 1
fi

# Base64 encode the secrets file
ENCODED=$(base64 -w0 < "$SECRETS_FILE" 2>/dev/null || base64 < "$SECRETS_FILE" | tr -d '\n')

if [ -z "$ENCODED" ]; then
  echo "[ERROR] Failed to encode secrets file"
  exit 1
fi

# Set PROPAGATE_SECRETS in the target repo (idempotent)
echo "[INFO] Setting PROPAGATE_SECRETS in repo: $REPO"
if echo "$ENCODED" | gh secret set PROPAGATE_SECRETS --repo "$REPO" --body - >/dev/null 2>&1; then
  echo "[INFO] Successfully set PROPAGATE_SECRETS in $REPO"
else
  echo "[ERROR] Failed to set PROPAGATE_SECRETS in $REPO"
  exit 1
fi

echo "[INFO] Done. PROPAGATE_SECRETS is ready for use by propagate-to-repo.sh"
