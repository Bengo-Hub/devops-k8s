#!/usr/bin/env bash
# check-and-sync-secrets.sh
# Check if required secrets exist in current repo
# If missing, can be synced via devops-k8s/sync-secrets workflow
# Usage: source <(curl -s https://raw.githubusercontent.com/Bengo-Hub/devops-k8s/main/scripts/tools/check-and-sync-secrets.sh)
#        check_and_sync_secrets "SECRET1" "SECRET2" ...

check_and_sync_secrets() {
  local requested_secrets=("$@")
  
  if [ ${#requested_secrets[@]} -eq 0 ]; then
    echo "[INFO] No secrets requested for sync check"
    return 0
  fi
  
  # Detect current repository
  local CURRENT_REPO=""
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    CURRENT_REPO="$GITHUB_REPOSITORY"
  else
    CURRENT_REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
  fi
  
  if [ -z "$CURRENT_REPO" ]; then
    echo "[WARN] Could not detect repository - skipping secret check"
    return 0
  fi
  
  echo "[INFO] Checking secrets in $CURRENT_REPO..."
  
  # Ensure gh CLI is authenticated
  if ! gh auth status &>/dev/null 2>&1; then
    if [ -n "${GH_PAT:-}" ]; then
      echo "${GH_PAT}" | gh auth login --with-token 2>/dev/null || true
    elif [ -n "${GITHUB_TOKEN:-}" ]; then
      echo "${GITHUB_TOKEN}" | gh auth login --with-token 2>/dev/null || true
    fi
  fi
  
  local MISSING_SECRETS=()
  local PRESENT_SECRETS=0
  
  # Check each requested secret
  for secret_name in "${requested_secrets[@]}"; do
    if gh secret list --repo "$CURRENT_REPO" 2>/dev/null | grep -q "^${secret_name}[[:space:]]"; then
      echo "[✓] $secret_name exists"
      PRESENT_SECRETS=$((PRESENT_SECRETS + 1))
    else
      echo "[✗] $secret_name missing"
      MISSING_SECRETS+=("$secret_name")
    fi
  done
  
  # Summary
  if [ ${#MISSING_SECRETS[@]} -eq 0 ]; then
    echo "[SUCCESS] All ${#requested_secrets[@]} secrets are present"
    return 0
  fi
  
  echo ""
  echo "[WARN] ${#MISSING_SECRETS[@]} secret(s) missing: ${MISSING_SECRETS[*]}"
  echo ""
  echo "To sync secrets from devops-k8s:"
  echo "  1. Via GitHub UI:"
  echo "     https://github.com/Bengo-Hub/devops-k8s/actions/workflows/sync-secrets.yml"
  echo "     - Click 'Run workflow'"
  echo "     - Target: $CURRENT_REPO"
  echo "     - Secrets: ${MISSING_SECRETS[*]}"
  echo ""
  echo "  2. Via gh CLI:"
  echo "     gh workflow run sync-secrets.yml \\"
  echo "       --repo Bengo-Hub/devops-k8s \\"
  echo "       -f target_repo=$CURRENT_REPO \\"
  echo "       -f secrets='${MISSING_SECRETS[*]}'"
  echo ""
  echo "  3. Manual setup:"
  echo "     https://github.com/$CURRENT_REPO/settings/secrets/actions"
  echo ""
  
  # In CI, we want to fail fast
  if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "[ERROR] Cannot proceed without required secrets in CI"
    return 1
  fi
  
  # In local/dev, just warn
  echo "[INFO] Continuing with existing secrets (local environment)"
  return 0
}

# Export function for use in other scripts
export -f check_and_sync_secrets 2>/dev/null || true
