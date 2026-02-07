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
    echo "[WARN] Direct propagate script failed. Attempting remote dispatch to $DEVOPS_REPO if possible"
    rm -f "$TEMP_SCRIPT"

    # If a PROPAGATE_TRIGGER_TOKEN is configured in this repo, use it to trigger
    # a workflow in the devops-k8s repo that will run the propagate operation there
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
        echo "[INFO] Secrets should be propagated shortly by devops-k8s workflow"
        return 0
      else
        echo "[ERROR] Dispatch request failed (http $resp)"
        return 1
      fi
    fi

    echo "[ERROR] Failed to sync secrets from $DEVOPS_REPO"
    return 1
  fi
}
