#!/usr/bin/env bash
# check-and-sync-secrets.sh
# Helper script for build.sh files to check required secrets and auto-sync from source repo
# Features: Direct query from source repo (devops-k8s, mosuon-devops-k8s, or custom)
# Usage: source this file in build.sh, then call: check_and_sync_secrets "SECRET1" "SECRET2" ...

check_and_sync_secrets() {
  local REQUIRED_SECRETS=("$@")
  local MISSING_SECRETS=()
  local TARGET_REPO=""
  
  # Source repo configuration (default: devops-k8s, override with SOURCE_SECRETS_REPO env var)
  local SOURCE_REPO="${SOURCE_SECRETS_REPO:-Bengo-Hub/devops-k8s}"
  
  # Detect target repo name. Prefer 'gh' but fall back to GITHUB_REPOSITORY env var
  if command -v gh &>/dev/null; then
    if TARGET_REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null); then
      :
    else
      echo "[WARN] 'gh repo view' failed; falling back to GITHUB_REPOSITORY if set"
      TARGET_REPO="${GITHUB_REPOSITORY:-}"
    fi
  else
    TARGET_REPO="${GITHUB_REPOSITORY:-}"
  fi

  if [ -z "$TARGET_REPO" ]; then
    echo "[WARN] Could not detect repository name. Skipping secret sync check."
    echo "[WARN] Ensure 'gh' is installed and authenticated or set GITHUB_REPOSITORY env var"
    return 0
  fi

  # Ensure gh is authenticated
  if command -v gh &>/dev/null; then
    if ! gh auth status --hostname github.com >/dev/null 2>&1; then
      echo "[WARN] gh is not authenticated. Attempting auth with GH_PAT or GITHUB_TOKEN"
      if [ -n "${GH_PAT:-}" ]; then
        echo "${GH_PAT}" | gh auth login --with-token >/dev/null 2>&1 || true
      elif [ -n "${GITHUB_TOKEN:-}" ]; then
        echo "${GITHUB_TOKEN}" | gh auth login --with-token >/dev/null 2>&1 || true
      fi
    fi
  fi

  echo "[INFO] Checking required secrets for $TARGET_REPO"
  
  # Check which secrets are missing from target repo
  for SECRET_NAME in "${REQUIRED_SECRETS[@]}"; do
    if ! gh secret list --repo "$TARGET_REPO" --json name -q '.[].name' 2>/dev/null | grep -q "^${SECRET_NAME}$"; then
      echo "[WARN] Secret $SECRET_NAME is missing in $TARGET_REPO"
      MISSING_SECRETS+=("$SECRET_NAME")
    fi
  done
  
  if [ ${#MISSING_SECRETS[@]} -eq 0 ]; then
    echo "[INFO] All required secrets are present in $TARGET_REPO"
    return 0
  fi
  
  echo "[INFO] Missing ${#MISSING_SECRETS[@]} secret(s); syncing from $SOURCE_REPO..."
  
  # Select token for authentication
  local AUTH_TOKEN=""
  local TOKEN_SOURCE=""
  
  if [ -n "${GH_PAT:-}" ]; then
    AUTH_TOKEN="${GH_PAT}"
    TOKEN_SOURCE="GH_PAT"
  elif [ -n "${GITHUB_TOKEN:-}" ]; then
    AUTH_TOKEN="${GITHUB_TOKEN}"
    TOKEN_SOURCE="GITHUB_TOKEN"
  else
    echo "[ERROR] No auth token (GH_PAT or GITHUB_TOKEN) available for secret sync"
    return 1
  fi

  local TOKEN_MASK="${AUTH_TOKEN:0:4}****${AUTH_TOKEN: -4}"
  echo "[DEBUG] Using auth token from $TOKEN_SOURCE: $TOKEN_MASK"
  
  # Sync each missing secret via export workflow in source repo
  local SYNC_FAILURES=0
  for SECRET_NAME in "${MISSING_SECRETS[@]}"; do
    echo "[INFO] Requesting export of $SECRET_NAME from $SOURCE_REPO..."
    
    # Build dispatch payload
    local PAYLOAD=$(cat <<EOF
{
  "event_type": "export-secret",
  "client_payload": {
    "secret_name": "$SECRET_NAME",
    "target_repo": "$TARGET_REPO"
  }
}
EOF
)
    
    # Trigger export-secret workflow in source repo
    local RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: token ${AUTH_TOKEN}" \
      -d "$PAYLOAD" \
      "https://api.github.com/repos/$SOURCE_REPO/dispatches") || true
    
    if [ "$RESP" = "204" ] || [ "$RESP" = "201" ]; then
      echo "[DEBUG] Export dispatch accepted for $SECRET_NAME (http $RESP)"
      
      # Poll until secret appears in target repo (30 seconds max, 2 second intervals)
      local POLL_ATTEMPTS=15
      local POLL_INTERVAL=2
      local poll=0
      local found=false
      
      echo "[DEBUG] Polling for $SECRET_NAME to appear in $TARGET_REPO..."
      
      while [ $poll -lt $POLL_ATTEMPTS ]; do
        sleep $POLL_INTERVAL
        poll=$((poll + 1))
        
        if gh secret list --repo "$TARGET_REPO" --json name -q '.[].name' 2>/dev/null | grep -q "^${SECRET_NAME}$"; then
          echo "[INFO] ✓ $SECRET_NAME synced successfully after $((poll * POLL_INTERVAL))s"
          found=true
          break
        fi
        
        if [ $((poll % 3)) -eq 0 ]; then
          echo "[DEBUG] Still waiting for $SECRET_NAME... (attempt $poll/$POLL_ATTEMPTS)"
        fi
      done
      
      if [ "$found" = "false" ]; then
        echo "[ERROR] Timeout waiting for $SECRET_NAME (not found after $((POLL_ATTEMPTS * POLL_INTERVAL))s)"
        echo "[INFO] Check source repo workflow logs: https://github.com/$SOURCE_REPO/actions"
        SYNC_FAILURES=$((SYNC_FAILURES + 1))
      fi
    else
      echo "[ERROR] Export dispatch failed for $SECRET_NAME (http $RESP)"
      echo "[INFO] Ensure export-secret.yml workflow exists in $SOURCE_REPO"
      SYNC_FAILURES=$((SYNC_FAILURES + 1))
    fi
  done
  
  if [ $SYNC_FAILURES -eq 0 ]; then
    echo "[INFO] Successfully synced all ${#MISSING_SECRETS[@]} secret(s) from $SOURCE_REPO"
    return 0
  else
    echo "[ERROR] Failed to sync $SYNC_FAILURES of ${#MISSING_SECRETS[@]} secret(s)"
    return 1
  fi
}
