# Direct Query Secret Sync Architecture

## Overview

This document describes the new, simplified secret synchronization architecture that eliminates duplication by querying secrets directly from the source repository.

## Key Improvements

### Before (PROPAGATE_SECRETS Approach)
```
devops-k8s repo secrets
        ↓
Manual sync to PROPAGATE_SECRETS secret (base64 container)
        ↓
Check-and-sync-secrets.sh decodes & downloads
        ↓
Propagate-to-repo.sh parses and syncs each secret
        ↓
Target repo secrets
```
**Issues:**
- Duplicates secrets (stored twice: in devops-k8s + PROPAGATE_SECRETS)
- Manual update step needed when secrets change
- Complex decoding/re-encoding pipeline
- Extra file to maintain

### After (Direct Query Approach)
```
devops-k8s repo secrets
        ↓
Repository_dispatch → export-secret.yml workflow
        ↓
Reads secret from source, sets in target
        ↓
Target repo secrets
```
**Benefits:**
- Single source of truth (secrets only in devops-k8s)
- No duplication or manual sync steps
- Simpler, more direct pipeline
- Individual secret export (better auditability)

## Architecture Components

### 1. check-and-sync-secrets.sh
**Location:** `devops-k8s/scripts/tools/check-and-sync-secrets.sh`

**Function:** Called from build.sh to detect missing secrets and request export.

**Flow:**
```bash
check_and_sync_secrets "REGISTRY_PASSWORD" "POSTGRES_PASSWORD"
```

**Logic:**
1. Detect target repo name (via `gh repo view` or `GITHUB_REPOSITORY` env)
2. Check which required secrets are missing using `gh secret list`
3. For each missing secret:
   - Trigger `export-secret` repository_dispatch in source repo
   - Poll target repo until secret appears (30s max, 2s intervals)

**Environment Variables:**
- `SOURCE_SECRETS_REPO` - Default: `Bengo-Hub/devops-k8s` (override for custom source)
- `GH_PAT` or `GITHUB_TOKEN` - Required for dispatch and secret verification

**Example Usage:**
```bash
# In build.sh (isp-billing-backend)
source $DEVOPS_REPO/scripts/tools/check-and-sync-secrets.sh
check_and_sync_secrets "REGISTRY_PASSWORD" "POSTGRES_PASSWORD" "GIT_TOKEN"

# With custom source repo
SOURCE_SECRETS_REPO="Bengo-Hub/mosuon-devops-k8s" check_and_sync_secrets "SECRET1" "SECRET2"
```

### 2. export-secret.yml Workflow
**Location:** `devops-k8s/.github/workflows/export-secret.yml`

**Trigger:** `repository_dispatch` with event type `export-secret`

**Payload Format:**
```json
{
  "event_type": "export-secret",
  "client_payload": {
    "secret_name": "POSTGRES_PASSWORD",
    "target_repo": "Bengo-Hub/isp-billing-backend"
  }
}
```

**Steps:**
1. Validate payload (secret_name and target_repo present and valid)
2. Retrieve secret from source repo
3. Mask secret in logs
4. Set secret in target repo using `gh secret set`

**Key Feature:** Server-side secret transfer (secret never leaves GitHub servers)

## Workflow Diagram

```
┌─────────────────────────────────┐
│  build.sh in target repo        │
│ check_and_sync_secrets "PASS"   │
└────────────┬────────────────────┘
             │
             ↓
┌────────────────────────────────────────┐
│ check-and-sync-secrets.sh              │
│ 1. Detect target repo                  │
│ 2. Check for missing secrets           │
│ 3. Trigger export for each missing     │
└────────┬─────────────────────────────────┘
         │
         ├─→ gh secret list (verify)
         │
         ├─→ curl POST /repos/.../dispatches
         │        event_type: export-secret
         │        client_payload: {secret_name, target_repo}
         │
         ├─→ Poll: gh secret list (30s max)
         │
         └─→ Return 0 (success) or 1 (failure)
             
┌────────────────────────────────────────┐
│  devops-k8s repository                 │
│  export-secret.yml workflow triggered  │
│  1. Validate payload                   │
│  2. gh secret view SECRET_NAME         │
│  3. gh secret set to target repo       │
└────────────────────────────────────────┘
             │
             ↓
┌────────────────────────────────────────┐
│  Target repo                           │
│  Secret now available                  │
│  build.sh can continue                 │
└────────────────────────────────────────┘
```

## Multi-Repo Support

### Same Source, Multiple Targets
All repos use the same source (devops-k8s) by default:
```bash
# isp-billing-backend/build.sh
check_and_sync_secrets "POSTGRES_PASSWORD" "REGISTRY_PASSWORD"

# truload-backend/build.sh
check_and_sync_secrets "POSTGRES_PASSWORD" "REDIS_PASSWORD"

# ordering-backend/build.sh
check_and_sync_secrets "REGISTRY_PASSWORD" "GIT_TOKEN"
```

### Custom Source Repos
Individual repos can source from different sources:
```bash
# In mosuon services
SOURCE_SECRETS_REPO="Bengo-Hub/mosuon-devops-k8s" \
  check_and_sync_secrets "POSTGRES_PASSWORD"

# Fall back to source repo's own secrets (for central docs setup)
SOURCE_SECRETS_REPO="Bengo-Hub/devops-k8s/docs" \
  check_and_sync_secrets "DOCS_API_KEY"
```

### Reusable Pattern
Same `check-and-sync-secrets.sh` works across all repos because:
- Script symlinked or sourced from devops-k8s
- `SOURCE_SECRETS_REPO` env var configurable
- No hardcoded paths or repo names

## Migration from PROPAGATE_SECRETS

If you're currently using the old `PROPAGATE_SECRETS` approach:

### Step 1: Update build.sh Files
Replace:
```bash
source <path>/check-and-sync-secrets.sh  # Old version
check_and_sync_secrets "PASS" "PASSWORD"
```

With:
```bash
source <path>/check-and-sync-secrets.sh  # New version
check_and_sync_secrets "PASS" "PASSWORD"
```

The script is backward compatible but uses new export mechanism.

### Step 2: Ensure Workflow Exists
Verify `export-secret.yml` exists in your source repo:
```bash
gh workflow view export-secret -R Bengo-Hub/devops-k8s
```

If not present, copy from this repo.

### Step 3: Deprecate PROPAGATE_SECRETS (Optional)
Once tested, you can remove the `PROPAGATE_SECRETS` secret from devops-k8s (after confirming all repos working with new approach).

## Troubleshooting

### "Export dispatch failed (http 404)"
**Cause:** `export-secret.yml` workflow not present in source repo

**Fix:** Create/copy the workflow from template above

### "Timeout waiting for SECRET_NAME (not found after 30s)"
**Causes:**
1. Workflow not triggered (check Actions tab in source repo)
2. Secret doesn't exist in source repo (typo in secret name?)
3. GH_PAT token doesn't have proper scopes (needs `repo`, `workflow`)

**Debug:**
```bash
# Verify secret exists in source repo
gh secret view SECRET_NAME -R Bengo-Hub/devops-k8s

# Check workflow logs
gh run list -R Bengo-Hub/devops-k8s -w export-secret
gh run view <RUN_ID> -R Bengo-Hub/devops-k8s --log

# Verify token scopes
gh auth status
```

### "No auth token (GH_PAT or GITHUB_TOKEN) available"
**Cause:** Building outside of GitHub Actions without GH_PAT env var

**Fix:** Set token before running build:
```bash
export GH_PAT="ghp_..."
./build.sh
```

In GitHub Actions, use the built-in `GITHUB_TOKEN` (automatically set).

## Security Considerations

1. **Secret Encryption:** Secrets read from github.com servers only, never exposed in logs
2. **Audit Trail:** Export workflow logs show which repos requested which secrets
3. **Token Scopes:** GH_PAT must have `repo` (secret access) + `workflow` (dispatch trigger)
4. **Temporary Dispatch:** Dispatch requests are logged but don't persist state
5. **Server-Side Transfer:** Secret value never leaves GitHub servers (gh CLI handles this)

## YAML Examples

### Minimal Usage (Single Repo)
```yaml
# isp-billing-backend/.github/workflows/build-and-deploy.yml
name: Build

on: [push]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Sync secrets
        run: |
          source ./scripts/check-and-sync-secrets.sh
          check_and_sync_secrets "POSTGRES_PASSWORD" "REGISTRY_PASSWORD"
      - name: Build
        run: ./build.sh
```

### Multi-Service Setup
```bash
# services/shared/init-secrets.sh
source "$(git rev-parse --show-toplevel)/devops-k8s/scripts/tools/check-and-sync-secrets.sh"

export_service_secrets() {
  local SERVICE=$1
  case "$SERVICE" in
    isp-billing)
      check_and_sync_secrets "POSTGRES_PASSWORD" "REGISTRY_PASSWORD"
      ;;
    truload)
      check_and_sync_secrets "REDIS_PASSWORD" "POSTGRES_PASSWORD"
      ;;
    notifications)
      check_and_sync_secrets "NATS_PASSWORD" "GIT_TOKEN"
      ;;
  esac
}
```

## Performance

- **Dispatch latency:** ~1-2 seconds (GitHub Actions queue time)
- **Workflow startup:** ~10-15 seconds
- **Total time per secret:** ~20-30 seconds per missing secret
- **Polling overhead:** Minimal (every 2 seconds, max 15 attempts = 30s)

## Future Enhancements

1. **Batch Export:** Export multiple secrets in single workflow run
2. **Cache Validation:** Check secret hash instead of polling
3. **Webhook Feedback:** Faster notification when secret synced
4. **Org-Level Fallback:** Check org secrets if repo secret not found
5. **Dependency Graph:** Sync related secrets together (e.g., DB creds + password)
