#!/usr/bin/env bash
# check-and-sync-secrets.sh
# Helper script for build.sh files to check required secrets and auto-sync from devops-k8s
# Usage: source this file in build.sh, then call: check_and_sync_secrets "SECRET1" "SECRET2" ...

check_and_sync_secrets() {
  local REQUIRED_SECRETS=("$@")
  local MISSING_SECRETS=()
  local REPO_FULL_NAME=""
  
  # Detect current repo name
  if command -v gh &>/dev/null; then
    REPO_FULL_NAME=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
  fi
  
  if [ -z "$REPO_FULL_NAME" ]; then
    echo "[WARN] Could not detect repository name. Skipping secret sync check."
    return 0
  fi
  
  echo "[INFO] Checking required secrets for $REPO_FULL_NAME"
  
  # Check which secrets are missing
  for SECRET_NAME in "${REQUIRED_SECRETS[@]}"; do
    if ! gh secret list --repo "$REPO_FULL_NAME" --json name -q '.[].name' 2>/dev/null | grep -q "^${SECRET_NAME}$"; then
      echo "[WARN] Secret $SECRET_NAME is missing"
      MISSING_SECRETS+=("$SECRET_NAME")
    fi
  done
  
  if [ ${#MISSING_SECRETS[@]} -eq 0 ]; then
    echo "[INFO] All required secrets are present"
    return 0
  fi
  
  echo "[INFO] Missing secrets: ${MISSING_SECRETS[*]}"
  echo "[INFO] Attempting to sync secrets from devops-k8s..."
  
  # Call centralized propagate script
  local DEVOPS_REPO="Bengo-Hub/devops-k8s"
  local PROPAGATE_SCRIPT_URL="https://raw.githubusercontent.com/$DEVOPS_REPO/main/scripts/tools/propagate-to-repo.sh"
  local TEMP_SCRIPT="/tmp/propagate-to-repo-$$.sh"
  
  # Download propagate script
  if command -v curl &>/dev/null; then
    curl -fsSL "$PROPAGATE_SCRIPT_URL" -o "$TEMP_SCRIPT" 2>/dev/null || {
      echo "[ERROR] Failed to download propagate script from $DEVOPS_REPO"
      return 1
    }
  elif command -v wget &>/dev/null; then
    wget -q "$PROPAGATE_SCRIPT_URL" -O "$TEMP_SCRIPT" 2>/dev/null || {
      echo "[ERROR] Failed to download propagate script from $DEVOPS_REPO"
      return 1
    }
  else
    echo "[ERROR] Neither curl nor wget found. Cannot download propagate script."
    return 1
  fi
  
  chmod +x "$TEMP_SCRIPT"
  
  # Run propagate script
  if bash "$TEMP_SCRIPT" "$REPO_FULL_NAME" "${MISSING_SECRETS[@]}"; then
    echo "[INFO] Successfully synced secrets from $DEVOPS_REPO"
    rm -f "$TEMP_SCRIPT"
    return 0
  else
    echo "[ERROR] Failed to sync secrets from $DEVOPS_REPO"
    rm -f "$TEMP_SCRIPT"
    return 1
  fi
}
