# Simplified Secret Management Strategy

## Overview

This document describes the simplified, production-ready secret management approach for BengoBox microservices. Secrets are centrally managed in devops repositories and synced to service repositories via GitHub Actions workflows.

## Architecture

### Source Repositories (Secret Stores)
- **devops-k8s**: Secrets for main Contabo cluster services (isp-billing, ordering, truload, auth, ERP, etc.)
- **mosuon-devops-k8s**: Secrets for mosuon VPS cluster services (game-stats)

### Secret Sync Flow
```
┌─────────────────────────┐
│  Service Repo Build     │
│  (e.g., isp-billing)    │
└───────────┬─────────────┘
            │
            │ 1. Downloads check-and-sync-secrets.sh
            │    via curl from devops-k8s
            ▼
┌─────────────────────────┐
│  check_and_sync_secrets │
│  - Checks if secrets    │
│    exist in service repo│
│  - If missing, provides │
│    instructions to sync │
└───────────┬─────────────┘
            │
            │ 2. User triggers sync-secrets.yml
            │    (manual or via gh CLI)
            ▼
┌─────────────────────────┐
│  devops-k8s Workflow    │
│  - Has access to secret │
│    values via context   │
│  - Uses gh CLI to set   │
│    secrets in target    │
└───────────┬─────────────┘
            │
            │ 3. Secrets copied to service repo
            ▼
┌─────────────────────────┐
│  Service Repo Secrets   │
│  - Available for builds │
│  - Available for deploys│
└─────────────────────────┘
```

## Components

### 1. check-and-sync-secrets.sh
**Location**: `scripts/tools/check-and-sync-secrets.sh` in devops repos

**Purpose**: Bash function that checks whether required secrets exist in the service repository

**Usage in build.sh**:
```bash
# Download and source the script
SYNC_SCRIPT=$(mktemp)
if curl -fsSL https://raw.githubusercontent.com/Bengo-Hub/devops-k8s/main/scripts/tools/check-and-sync-secrets.sh -o "$SYNC_SCRIPT" 2>/dev/null; then
  source "$SYNC_SCRIPT"
  check_and_sync_secrets "KUBE_CONFIG" "REGISTRY_USERNAME" "REGISTRY_PASSWORD" "GIT_TOKEN" || warn "Secret sync failed"
  rm -f "$SYNC_SCRIPT"
else
  warn "Unable to download secret sync script"
fi
```

**Behavior**:
- ✅ **Exists**: Shows checkmark, continues silently
- ❌ **Missing**: Shows error with 3 sync options:
  1. GitHub UI workflow dispatch
  2. gh CLI command
  3. Manual setup URL
- **In CI**: Fails fast if secrets missing (returns exit 1)
- **Local**: Warns but continues (returns exit 0)

### 2. sync-secrets.yml Workflow
**Location**: `.github/workflows/sync-secrets.yml` in devops repos

**Purpose**: GitHub Actions workflow that copies secrets from devops repo to target service repo

**Trigger**: Manual workflow dispatch via:
- **GitHub UI**: Actions → Sync Secrets → Run workflow
- **gh CLI**: 
  ```bash
  gh workflow run sync-secrets.yml \
    --repo Bengo-Hub/devops-k8s \
    -f target_repo=Bengo-Hub/isp-billing-backend \
    -f secrets='REGISTRY_USERNAME REGISTRY_PASSWORD POSTGRES_PASSWORD'
  ```

**How it works**:
1. Workflow has access to all secret values via `${{ secrets.SECRET_NAME }}`
2. Maps requested secret names to environment variables
3. **Validates** that provisioning-only secrets are never synced to service repos
4. **Warns** (not fails) if a requested secret doesn't exist in devops-k8s yet
5. Uses `gh secret set` to copy each secret to target repo
6. Reports success/failure/warnings/skips for each secret

**Authentication**: Uses `GH_PAT` from devops-k8s secrets (falls back to `GIT_TOKEN` if GH_PAT not set). The gh CLI automatically uses the `GH_TOKEN` environment variable - no explicit login needed.

**Why this works**: GitHub Actions workflows CAN access their own secret values at runtime, even though the API/CLI cannot read secrets externally. This is the only way to programmatically copy secrets between repos.

## Secret Inventory

### Provisioning-Only Secrets (🚫 NEVER sync to service repos)

These secrets are for devops-k8s infrastructure only and should **NEVER** be synced to service repositories:

- `KUBE_CONFIG` - Kubernetes config for cluster access (7540 chars, base64)
- `SSH_PRIVATE_KEY` - SSH key for repo access (620 chars, base64)
- `DOCKER_SSH_KEY` - SSH key for Docker deployments (620 chars, base64)
- `SSH_HOST` - VPS host IP (94.16.119.213)
- `SSH_USER` - VPS username (vertexhub)

**⚠️  Important**: The sync workflow will automatically **skip** these secrets if requested, preventing accidental exposure.

### Standard Application Secrets (✅ Safe to sync)

These secrets are used across most service repositories. **Always use these exact names** for consistency:

#### Docker Registry (Required for all services)
- `REGISTRY_USERNAME` - Docker registry username
- `REGISTRY_PASSWORD` - Docker registry password
- `REGISTRY_EMAIL` - info@vertexhub.tech

#### Git Access (Required for all services)
- `GIT_TOKEN` - GitHub personal access token (note: at devops-k8s level this is named `GH_PAT`, but syncs as `GIT_TOKEN` to service repos)

#### Database Passwords (Required for backend services)
- `POSTGRES_PASSWORD` - PostgreSQL database password
- `REDIS_PASSWORD` - Redis cache password
- `RABBITMQ_PASSWORD` - RabbitMQ message queue password (if used)

### Rarely Used Secrets

These may be needed for specific services:

#### M-Pesa/Payment
- `MPESA_CONSUMER_KEY`
- `MPESA_CONSUMER_SECRET`
- `MPESA_SHORTCODE`
- `MPESA_PASSKEY`

#### Email/SMTP
- `SMTP_HOST`
- `SMTP_USER`
- `SMTP_PASSWORD`

#### Security/Auth
- `JWT_SECRET_KEY`
- `ENCRYPTION_KEY`

## Service Secret Requirements

### Backend Services (API)
**Standard secrets needed** (use these exact names):
- `REGISTRY_USERNAME` - Docker registry login
- `REGISTRY_PASSWORD` - Docker registry password
- `GIT_TOKEN` - Git operations (cloning, pushing)
- `POSTGRES_PASSWORD` - Database access
- `REDIS_PASSWORD` - Cache access
- `RABBITMQ_PASSWORD` - Message queue (if used)

**🚫 Never include**: `KUBE_CONFIG`, `SSH_PRIVATE_KEY`, `DOCKER_SSH_KEY`, `SSH_HOST`, `SSH_USER`

**Example sync command**:
```bash
gh workflow run sync-secrets.yml \
  --repo Bengo-Hub/devops-k8s \
  -f target_repo=Bengo-Hub/your-backend \
  -f secrets='REGISTRY_USERNAME REGISTRY_PASSWORD GIT_TOKEN POSTGRES_PASSWORD REDIS_PASSWORD'
```

### Frontend Services (UI)
**Standard secrets needed** (use these exact names):
- `REGISTRY_USERNAME` - Docker registry login
- `REGISTRY_PASSWORD` - Docker registry password
- `GIT_TOKEN` - Git operations

**🚫 Never include**: `KUBE_CONFIG`, `SSH_PRIVATE_KEY`, `DOCKER_SSH_KEY`, `SSH_HOST`, `SSH_USER`

**Example sync command**:
```bash
gh workflow run sync-secrets.yml \
  --repo Bengo-Hub/devops-k8s \
  -f target_repo=Bengo-Hub/your-frontend \
  -f secrets='REGISTRY_USERNAME REGISTRY_PASSWORD GIT_TOKEN'
```

## Migration from Old System

### What Was Removed ❌
1. **PROPAGATE_SECRETS** - 13,584-char base64 container of all secrets
2. **propagate-secrets.yml** - Complex workflow with repository_dispatch
3. **set-propagate-secrets.yml** - Local file upload workflow
4. **propagate-to-repo.sh** - Base64 decode and propagation script
5. **set-propagate-secrets.sh** - Local file to GitHub secret uploader
6. **set-org-secrets.sh** - Organization-level secret setter
7. **Polling mechanism** - 15-second wait loops in build.sh
8. **Repository dispatch** - Event-based triggering

### What Stayed ✅
1. **check-and-sync-secrets.sh** - Simplified to just check + instruct
2. **devops-k8s repo-level secrets** - Single source of truth (25 secrets)
3. **Build.sh downloads** - Curl script from devops repo (no local files)
4. **Critical secret protection** - KUBE_CONFIG still excluded from app repos

### What's New ✨
1. **sync-secrets.yml** - Simple manual workflow for copying secrets
2. **Helpful instructions** - Check script outputs 3 ways to sync
3. **CI fail-fast** - Errors in CI, warnings locally
4. **No dependencies** - No local files needed in CI/CD

## Common Workflows

### Initial Setup (New Service Repo)
1. Add service build.sh with secret check:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/Bengo-Hub/devops-k8s/main/scripts/tools/check-and-sync-secrets.sh | bash -s "SECRET1" "SECRET2"
   ```

2. Sync secrets via GitHub UI:
   - Navigate to: https://github.com/Bengo-Hub/devops-k8s/actions/workflows/sync-secrets.yml
   - Click "Run workflow"
   - Enter target repo: `Bengo-Hub/your-service-backend`
   - Enter secrets: `KUBE_CONFIG REGISTRY_USERNAME REGISTRY_PASSWORD GIT_TOKEN`
   - Click "Run workflow"

3. Verify secrets exist:
   ```bash
   gh secret list --repo Bengo-Hub/your-service-backend
   ```

### Update Single Secret
If a secret changes (e.g., password rotation):

1. Update in devops-k8s:
   ```bash
   gh secret set POSTGRES_PASSWORD --repo Bengo-Hub/devops-k8s --body "new_password"
   ```

2. Sync to all affected services:
   ```bash
   for repo in isp-billing-backend ordering-backend truload-backend; do
     gh workflow run sync-secrets.yml \
       --repo Bengo-Hub/devops-k8s \
       -f target_repo=Bengo-Hub/$repo \
       -f secrets='POSTGRES_PASSWORD'
   done
   ```

### Bulk Sync (All Secrets to Multiple Repos)
```bash
#!/bin/bash
REPOS=(
  "isp-billing-backend"
  "isp-billing-frontend"
  "ordering-backend"
  "ordering-frontend"
  "truload-backend"
  "truload-frontend"
  "auth-api"
  "erp-api"
  "erp-ui"
)

SECRETS="KUBE_CONFIG REGISTRY_USERNAME REGISTRY_PASSWORD GIT_TOKEN POSTGRES_PASSWORD REDIS_PASSWORD"

for repo in "${REPOS[@]}"; do
  echo "Syncing to $repo..."
  gh workflow run sync-secrets.yml \
    --repo Bengo-Hub/devops-k8s \
    -f target_repo=Bengo-Hub/$repo \
    -f secrets="$SECRETS"
  sleep 2  # Rate limit protection
done
```

## Troubleshooting

### "Secret sync failed - continuing with existing secrets"
**Cause**: Secrets missing in service repo
**Solution**: Run sync-secrets.yml workflow or set manually

### "⚠️  WARNING: SECRET_NAME not found in devops-k8s secrets"
**Cause**: Secret doesn't exist in devops-k8s yet
**Behavior**: Workflow continues with warning (doesn't fail)
**Solution**: 
1. Set the secret in devops-k8s first: `gh secret set SECRET_NAME --repo Bengo-Hub/devops-k8s`
2. Re-run the sync workflow

### "🚫 SKIPPED: SECRET_NAME is a provisioning secret"
**Cause**: Attempted to sync a provisioning-only secret (KUBE_CONFIG, SSH_PRIVATE_KEY, etc.)
**Behavior**: Workflow skips the secret (doesn't sync or fail)
**Solution**: Remove provisioning secrets from your sync request. These should NEVER be in service repos.

### "Cannot detect repository"
**Cause**: Running outside git repo or gh CLI not configured
**Solution**: Set `GITHUB_REPOSITORY=Bengo-Hub/repo-name` or run from repo directory

### "gh CLI not authenticated"
**Cause**: No GitHub credentials available
**Solution**: Run `gh auth login` or set `GH_PAT` environment variable

### "Failed to sync SECRET_NAME"
**Cause**: gh secret set command failed (not a missing secret)
**Solution**: 
1. Verify secret exists: `gh secret list --repo Bengo-Hub/devops-k8s`
2. Check GH_PAT has `repo` scope
3. Ensure workflow has secret mapped in env section
4. Check target repo permissions

## Security Considerations

### Secret Storage
- ✅ **DO**: Store all secrets in devops-k8s/mosuon-devops-k8s repos
- ✅ **DO**: Use strong, unique passwords for each secret
- ❌ **DON'T**: Commit secrets to code or config files
- ❌ **DON'T**: Share secrets via email or chat

### Secret Transfer
- ✅ **DO**: Use sync-secrets.yml workflow
- ✅ **DO**: Use gh CLI with secured tokens
- ❌ **DON'T**: Copy secrets manually across repos (error-prone)
- ❌ **DON'T**: Expose secrets in logs or error messages

### Secret Scope
- ✅ **DO**: Only sync secrets needed by each service
- ✅ **DO**: Use standard secret names (REGISTRY_USERNAME, GIT_TOKEN, etc.)
- 🚫 **DON'T**: Sync provisioning secrets (KUBE_CONFIG, SSH_PRIVATE_KEY, SSH_HOST, etc.) to service repos
- ❌ **DON'T**: Give all secrets to all repos
- ❌ **DON'T**: Use production secrets in dev environments

### Base64 Handling
- ✅ **DO**: Keep KUBE_CONFIG, SSH_PRIVATE_KEY, DOCKER_SSH_KEY as-is (already base64)
- ✅ **DO**: Sync base64 secrets without re-encoding
- ❌ **DON'T**: Double-encode base64 secrets (causes corruption)
- ❌ **DON'T**: Decode base64 secrets in workflow logs

## Benefits Over Previous System

| Aspect | Old System (PROPAGATE_SECRETS) | New System (sync-secrets.yml) |
|--------|-------------------------------|------------------------------|
| **Complexity** | High (dispatch, polling, decode) | Low (one workflow, one script) |
| **Setup** | Encode all secrets to base64 container | Set secrets normally in devops repo |
| **Update** | Re-encode entire container | Update one secret, sync individually |
| **Debugging** | Hard (base64, async dispatch) | Easy (detailed logs, clear errors) |
| **Security** | All secrets in one place (blast radius) | Secrets synced per-service (isolated) |
| **Speed** | 15s+ polling delay | Immediate (no waiting) |
| **Local file** | Requires D:/KubeSecrets in setup | No local files needed |
| **Documentation** | Secret propagation flow needed | Self-documenting (check output) |
| **Failure mode** | Silent (polling timeout) | Explicit (CI fails, shows URLs) |
| **Provisioning secrets** | Could leak to service repos | Automatically blocked from sync |
| **Missing secrets** | Hard fail (breaks builds) | Soft warn (continues with others) |

## Mosuon Cluster Differences

The mosuon cluster has identical setup but uses `mosuon-devops-k8s` as source:

1. **Script URL**: `https://raw.githubusercontent.com/Bengo-Hub/mosuon-devops-k8s/master/scripts/tools/check-and-sync-secrets.sh`
2. **Workflow**: `https://github.com/Bengo-Hub/mosuon-devops-k8s/actions/workflows/sync-secrets.yml`
3. **Provisioning secrets**: KUBE_CONFIG, SSH_PRIVATE_KEY, DOCKER_SSH_KEY, SSH_HOST, SSH_USER, VPS_SSH_HOST, VPS_SSH_USER
4. **Services**: game-stats-api, game-stats-ui
5. **Standard secrets**: Same as main cluster (REGISTRY_USERNAME, REGISTRY_PASSWORD, GIT_TOKEN, etc.)

## Future Enhancements

### Possible Improvements
- [ ] Automated secret rotation scripts
- [ ] Secret expiry tracking and alerts
- [ ] Audit log of secret sync operations
- [ ] Terraform/IaC for secret provisioning
- [ ] Webhook notifications on secret changes
- [ ] Drift detection (secrets out of sync)

### Not Recommended
- ❌ Organization-level secrets (user rejected - may not exist)
- ❌ External secret managers (too much complexity for current scale)
- ❌ Automated sync on every build (unnecessary API calls)

## Support

For issues or questions:
1. Check troubleshooting section above
2. Review GitHub Actions workflow logs
3. Verify gh CLI authentication: `gh auth status`
4. Check secret existence: `gh secret list --repo Bengo-Hub/repo-name`
5. Contact DevOps team if persistent issues

---

**Last Updated**: 2025-01-20  
**Maintained By**: DevOps Team  
**Related Docs**: 
- [SECRET-MANAGEMENT.md](./SECRET-MANAGEMENT.md)
- [SECRET_ENCODING_STRATEGY.md](./SECRET_ENCODING_STRATEGY.md)
