# KUBE_CONFIG Secret Diagnostic & Fix Guide

## Problem
Provision workflow fails with: `❌ Failed to connect to cluster. Check your KUBE_CONFIG.`

## Root Cause Analysis

### Secret Priority in GitHub Actions:
1. **Repository-level secrets** (highest priority) - `${{ secrets.KUBE_CONFIG }}`
2. **Organization-level secrets** (fallback)
3. **Environment secrets** (if environment specified)

### Likely Issue:
- KUBE_CONFIG was accidentally propagated to **devops-k8s repo-level** secrets
- This **OVERRIDES** the correct org-level KUBE_CONFIG
- The repo-level secret contains wrong/corrupted kubeconfig
- Provision workflow uses repo-level instead of org-level

## Diagnostic Steps

### 1. Check Repository-Level Secret
```powershell
# Check if KUBE_CONFIG exists at devops-k8s repo level
gh secret list --repo Bengo-Hub/devops-k8s | Select-String "KUBE_CONFIG"
```

**If KUBE_CONFIG appears:**
- ❌ This is the problem! Repo-level secret is overriding org-level
- It was likely propagated incorrectly from the secrets file
- **Solution:** Delete the repo-level KUBE_CONFIG

### 2. Check Organization-Level Secret
```powershell
# Check org-level secret (requires admin permission)
gh api orgs/Bengo-Hub/actions/secrets/KUBE_CONFIG | ConvertFrom-Json | Select-Object name,created_at,updated_at,visibility

# See which repos have access
gh api orgs/Bengo-Hub/actions/secrets/KUBE_CONFIG/repositories --jq '.repositories[].name'
```

**Expected:**
- ✅ KUBE_CONFIG should exist at org level
- ✅ Should be accessible to devops-k8s repository
- ✅ Contains valid kubeconfig for Contabo cluster

### 3. Compare Secret Values (if both exist)
```powershell
# You CANNOT view secret values via API, but you can check:

# A. Check when each was last updated
gh api repos/Bengo-Hub/devops-k8s/actions/secrets/KUBE_CONFIG | ConvertFrom-Json | Select-Object updated_at
gh api orgs/Bengo-Hub/actions/secrets/KUBE_CONFIG | ConvertFrom-Json | Select-Object updated_at

# B. The one updated recently (around the time provision started failing) is likely wrong
```

## Fix Steps

### Option 1: Delete Repo-Level KUBE_CONFIG (Recommended)
```powershell
# Delete the incorrect repo-level secret
gh secret delete KUBE_CONFIG --repo Bengo-Hub/devops-k8s

# Workflow will now use org-level KUBE_CONFIG
```

### Option 2: Verify & Fix Local Secrets File
If KUBE_CONFIG in your local secrets file is wrong:

```powershell
# 1. Check your local secrets file
$secretsFile = "D:\KubeSecrets\git-secrets\Bengo-Hub__devops-k8s\secrets.txt"
Get-Content $secretsFile | Select-String -Pattern "secret:\s*KUBE_CONFIG" -Context 5,50

# 2. If KUBE_CONFIG is present and shouldn't be synced to repos:
#    Remove it from the file OR add it to CRITICAL_SECRETS list

# 3. The correct KUBE_CONFIG should be:
#    - Base64-encoded kubeconfig from: cat ~/.kube/config | base64 -w 0
#    - Stored at ORG level, not repo level
#    - NOT propagated to individual application repos
```

### Option 3: Set Correct KUBE_CONFIG at Org Level
If org-level secret is missing or wrong:

```powershell
# 1. Get kubeconfig from Contabo VPS
ssh user@your-vps-ip "cat ~/.kube/config | base64 -w 0"

# 2. Set at organization level (requires org admin)
# Go to: https://github.com/organizations/Bengo-Hub/settings/secrets/actions
# Click "New organization secret"
# Name: KUBE_CONFIG
# Value: <paste base64 kubeconfig>
# Repository access: Select repositories → devops-k8s

# OR via CLI:
echo "YOUR_BASE64_KUBECONFIG" | gh secret set KUBE_CONFIG --org Bengo-Hub --repos devops-k8s
```

## Verification

After fixing, verify provision workflow:

```powershell
# 1. Trigger provision workflow manually
# https://github.com/Bengo-Hub/devops-k8s/actions/workflows/provision.yml
# Click "Run workflow"

# 2. Check "Configure kubeconfig" step logs
# Should show:
# ✅ KUBE_CONFIG secret found
# ✅ Kubeconfig written to ~/.kube/config (XXXX bytes)
# ✅ Successfully connected to Kubernetes cluster

# 3. If still failing, check cluster connectivity:
# SSH to VPS and run:
kubectl cluster-info
kubectl get nodes

# If cluster is down, restart it:
sudo systemctl start kubelet
```

## Prevention

To prevent this issue in other repos:

### Updated propagate-to-repo.sh (Already Applied)
```bash
# Critical secrets that should NOT be propagated
CRITICAL_SECRETS=("KUBE_CONFIG" "CONTABO_API_PASSWORD" "CONTABO_CLIENT_SECRET")

# Skips if critical secret already exists in target repo
if [[ " ${CRITICAL_SECRETS[*]} " =~ " ${SECRET_NAME} " ]]; then
  if secret_exists_in_repo; then
    echo "Skipping critical secret - already set"
  fi
fi
```

### Application Build Scripts (Already Applied to isp-billing-backend)
```bash
# Sync only application secrets, exclude infrastructure secrets
check_and_sync_secrets "REGISTRY_USERNAME" "REGISTRY_PASSWORD" "GIT_TOKEN" "POSTGRES_PASSWORD" "REDIS_PASSWORD"
# KUBE_CONFIG excluded - must be set manually per environment
```

## Summary

**Quick Fix:**
```powershell
# Delete repo-level KUBE_CONFIG from devops-k8s
gh secret delete KUBE_CONFIG --repo Bengo-Hub/devops-k8s

# Verify org-level secret exists
gh api orgs/Bengo-Hub/actions/secrets/KUBE_CONFIG

# Re-run provision workflow
```

**Root Cause:**
- Infrastructure secrets (KUBE_CONFIG) should be org-level, environment-specific
- Application secrets (Docker, DB, Redis) can be repo-level, synced via propagate
- Mixing these caused kubeconfig corruption

**Prevention Applied:**
- ✅ propagate-to-repo.sh now protects KUBE_CONFIG
- ✅ Application build scripts exclude KUBE_CONFIG from sync
- ✅ Critical secrets won't overwrite existing values
