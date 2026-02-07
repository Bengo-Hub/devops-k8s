#!/usr/bin/env bash
# check-and-sync-secrets.sh
# Helper script for build.sh files to check required secrets and auto-sync from devops-k8s
# Usage: source this file in build.sh, then call: check_and_sync_secrets "SECRET1" "SECRET2" ...

check_and_sync_secrets() {
  local REQUIRED_SECRETS=("$@")
  local MISSING_SECRETS=()
  local REPO_FULL_NAME=""
  
  # Detect current repo name. Prefer 'gh' but fall back to GITHUB_REPOSITORY env var if needed
  if command -v gh &>/dev/null; then
    # Try to get the repo using gh; if it fails, fall back to GITHUB_REPOSITORY
    if REPO_FULL_NAME=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null); then
      :
    else
      echo "[WARN] 'gh repo view' failed or is unauthenticated; falling back to GITHUB_REPOSITORY if set"
      REPO_FULL_NAME="${GITHUB_REPOSITORY:-}"
    fi
  else
    # gh not available; try GitHub Actions env var
    REPO_FULL_NAME="${GITHUB_REPOSITORY:-}"
  fi

  if [ -z "$REPO_FULL_NAME" ]; then
    echo "[WARN] Could not detect repository name. Skipping secret sync check."
    echo "[WARN] Ensure 'gh' is installed and authenticated or set GITHUB_REPOSITORY env var (owner/repo)"
    return 0
  fi

  # Ensure gh is authenticated (required for cross-repo secret writes)
  if command -v gh &>/dev/null; then
    if ! gh auth status --hostname github.com >/dev/null 2>&1; then
      echo "[WARN] gh is not authenticated. Attempting non-interactive auth using GH_PAT or GITHUB_TOKEN env vars"
      if [ -n "${GH_PAT:-}" ]; then
        echo "${GH_PAT}" | gh auth login --with-token >/dev/null 2>&1 || echo "[WARN] gh auth login with GH_PAT failed"
      elif [ -n "${GITHUB_TOKEN:-}" ]; then
        echo "${GITHUB_TOKEN}" | gh auth login --with-token >/dev/null 2>&1 || echo "[WARN] gh auth login with GITHUB_TOKEN failed"
      else
        echo "[WARN] No GH token available in env; propagate script may fail due to lack of auth"
      fi
    fi
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
  
  local DEVOPS_REPO="Bengo-Hub/devops-k8s"
  local DISPATCH_NEEDED=false
  
  # In CI environments (GitHub Actions), skip direct propagation since:
  # - PROPAGATE_SECRETS_FILE won't be set (no local files)
  # - Remote dispatch uses centralized PROPAGATE_SECRETS secret instead
  if [ -n "${GITHUB_ACTIONS:-}" ] || [ -n "${CI:-}" ]; then
    echo "[INFO] Running in CI environment - using remote dispatch (no local secrets file)"
    DISPATCH_NEEDED=true
  elif [ -n "${PROPAGATE_SECRETS_FILE:-}" ] && [ -f "${PROPAGATE_SECRETS_FILE}" ]; then
    echo "[INFO] PROPAGATE_SECRETS_FILE is set and exists - attempting direct propagation"
    
    local PROPAGATE_SCRIPT_URL="https://raw.githubusercontent.com/$DEVOPS_REPO/main/scripts/tools/propagate-to-repo.sh"
    local TEMP_SCRIPT="/tmp/propagate-to-repo-$$.sh"
    
    # Download propagate script
    if command -v curl &>/dev/null; then
      curl -fsSL "$PROPAGATE_SCRIPT_URL" -o "$TEMP_SCRIPT" 2>/dev/null || {
        echo "[WARN] Failed to download propagate script from $DEVOPS_REPO"
        DISPATCH_NEEDED=true
      }
    elif command -v wget &>/dev/null; then
      wget -q "$PROPAGATE_SCRIPT_URL" -O "$TEMP_SCRIPT" 2>/dev/null || {
        echo "[WARN] Failed to download propagate script from $DEVOPS_REPO"
        DISPATCH_NEEDED=true
      }
    else
      echo "[WARN] Neither curl nor wget found. Cannot download propagate script."
      DISPATCH_NEEDED=true
    fi
    
    if [ "$DISPATCH_NEEDED" = "false" ]; then
      chmod +x "$TEMP_SCRIPT"
      
      # Run propagate script with PROPAGATE_SECRETS_FILE set
      if bash "$TEMP_SCRIPT" "$REPO_FULL_NAME" "${MISSING_SECRETS[@]}"; then
        echo "[INFO] Successfully synced secrets from $DEVOPS_REPO via direct propagation"
        rm -f "$TEMP_SCRIPT"
        return 0
      else
        echo "[WARN] Direct propagation failed - falling back to remote dispatch"
        rm -f "$TEMP_SCRIPT"
        DISPATCH_NEEDED=true
      fi
    fi
  else
    echo "[INFO] PROPAGATE_SECRETS_FILE not set or file not found - using remote dispatch"
    DISPATCH_NEEDED=true
  fi
  
  # Remote dispatch fallback (or primary method in CI)
  if [ "$DISPATCH_NEEDED" = "true" ]; then
    # Select token for dispatch authentication
    if [ -n "${PROPAGATE_TRIGGER_TOKEN:-}" ]; then
      echo "[INFO] Using PROPAGATE_TRIGGER_TOKEN to request devops-k8s to propagate secrets"
      tokenToUse="${PROPAGATE_TRIGGER_TOKEN}"
      tokenSource="PROPAGATE_TRIGGER_TOKEN"
    elif [ -n "${GH_PAT:-}" ]; then
      echo "[INFO] Using GH_PAT env to request devops-k8s to propagate secrets"
      tokenToUse="${GH_PAT}"
      tokenSource="GH_PAT"
    elif [ -n "${GITHUB_TOKEN:-}" ]; then
      echo "[INFO] Using GITHUB_TOKEN env to request devops-k8s to propagate secrets"
      tokenToUse="${GITHUB_TOKEN}"
      tokenSource="GITHUB_TOKEN"
    else
      tokenToUse=""
      tokenSource=""
    fi

    if [ -n "${tokenToUse:-}" ]; then
      # Build JSON payload
      js_secrets="["
      for s in "${MISSING_SECRETS[@]}"; do
        js_secrets+="\"${s}\",";
      done
      js_secrets="${js_secrets%,}]"

      body="{\"event_type\":\"propagate-secrets\",\"client_payload\":{\"target_repo\":\"$REPO_FULL_NAME\",\"secrets\":$js_secrets}}"

      # Mask token for debug (show first/last 4 chars)
      tokenMask="${tokenToUse:0:4}****${tokenToUse: -4}"
      echo "[DEBUG] Using token from $tokenSource: $tokenMask"

      resp=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: token ${tokenToUse}" \
        -d "$body" \
        "https://api.github.com/repos/$DEVOPS_REPO/dispatches" ) || true

      if [ "$resp" = "204" ] || [ "$resp" = "201" ]; then
        echo "[INFO] Dispatch request accepted by $DEVOPS_REPO (http $resp) using $tokenSource"
        echo "[INFO] Waiting for secrets to be propagated by devops-k8s workflow..."
        
        # Ensure gh is authenticated for secret list commands
        if ! gh auth status &>/dev/null; then
          echo "[DEBUG] Authenticating gh CLI with $tokenSource for secret verification"
          echo "${tokenToUse}" | gh auth login --with-token 2>/dev/null || {
            echo "[WARN] Could not authenticate gh CLI, will retry secret checks anyway"
          }
        fi
        
        # Initial delay to allow workflow to start (GitHub Actions startup ~3-5 seconds)
        echo "[DEBUG] Initial wait of 5 seconds for workflow to start..."
        sleep 5
        
        # Poll for secrets to appear (max 60 seconds, check every 2 seconds)
        local MAX_WAIT=30
        local WAIT_INTERVAL=2
        local attempts=0
        local all_secrets_present=false
        
        while [ $attempts -lt $MAX_WAIT ]; do
          attempts=$((attempts + 1))
          sleep $WAIT_INTERVAL
          
          # Check if all missing secrets are now present
          local still_missing=0
          for secret_name in "${MISSING_SECRETS[@]}"; do
            if ! gh secret list --repo "$REPO_FULL_NAME" --json name -q '.[].name' 2>/dev/null | grep -q "^${secret_name}$"; then
              still_missing=$((still_missing + 1))
            fi
          done
          
          if [ $still_missing -eq 0 ]; then
            all_secrets_present=true
            echo "[INFO] ✓ All secrets successfully propagated after $((attempts * WAIT_INTERVAL)) seconds"
            return 0
          else
            # Show progress every 5 attempts (10 seconds)
            if [ $((attempts % 5)) -eq 0 ]; then
              echo "[INFO] Still waiting... ($still_missing secrets pending, ${attempts}/${MAX_WAIT} attempts)"
            fi
          fi
        done
        
        # Timeout reached
        if [ "$all_secrets_present" = "false" ]; then
          echo "[ERROR] Timeout waiting for secrets to be propagated after $((MAX_WAIT * WAIT_INTERVAL)) seconds"
          echo "[ERROR] The following secrets are still missing:"
          for secret_name in "${MISSING_SECRETS[@]}"; do
            if ! gh secret list --repo "$REPO_FULL_NAME" --json name -q '.[].name' 2>/dev/null | grep -q "^${secret_name}$"; then
              echo "  - $secret_name"
            fi
          done
          echo "[ERROR] Check devops-k8s workflow logs: https://github.com/$DEVOPS_REPO/actions/workflows/propagate-secrets.yml"
          return 1
        fi
        
        return 0
      else
        echo "[ERROR] Dispatch request failed (http $resp)"
        return 1
      fi
    else
      echo "[ERROR] No authentication token available for dispatch (PROPAGATE_TRIGGER_TOKEN, GH_PAT, or GITHUB_TOKEN required)"
      return 1
    fi
  fi
  
  echo "[ERROR] Failed to sync secrets from $DEVOPS_REPO"
  return 1
}
