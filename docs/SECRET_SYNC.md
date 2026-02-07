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
3. Uses `gh secret set` to copy each secret to target repo
4. Reports success/failure for each secret

**Why this works**: GitHub Actions workflows CAN access their own secret values at runtime, even though the API/CLI cannot read secrets externally. This is the only way to programmatically copy secrets between repos.

## Secret Inventory

### All Repositories (25 total secrets)

#### Base64-Encoded (3)
- `KUBE_CONFIG` - Kubernetes config for cluster access (7540 chars)
- `SSH_PRIVATE_KEY` - SSH key for repo access (620 chars)
- `DOCKER_SSH_KEY` - SSH key for Docker deployments (620 chars)

#### Docker Registry (4)
- `REGISTRY_USERNAME` - vertexhubacr
- `REGISTRY_PASSWORD` - ************
- `REGISTRY_EMAIL` - info@vertexhub.tech
- `REGISTRY_URL` - vertexhubacr.azurecr.io

#### GitHub/Git (2)
- `GIT_TOKEN` - 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
- `GH_PAT` - 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 (same token)

#### Database Passwords (4)
- `POSTGRES_PASSWORD` - ************
- `MYSQL_ROOT_PASSWORD` - ************
- `REDIS_PASSWORD` - ************
- `RABBITMQ_PASSWORD` - ************

#### VPS/Infrastructure (3 per cluster)
**Main cluster (CONTABO_*):**
- `CONTABO_SSH_HOST` - 94.16.119.213
- `CONTABO_SSH_USER` - vertexhub
- `CONTABO_SSH_PASSWORD` - ************

**Mosuon cluster (VPS_*):**
- `VPS_SSH_HOST` - [mosuon cluster IP]
- `VPS_SSH_USER` - [mosuon user]
- `VPS_SSH_PASSWORD` - ************

#### M-Pesa/Payment (4)
- `MPESA_CONSUMER_KEY`
- `MPESA_CONSUMER_SECRET`
- `MPESA_SHORTCODE`
- `MPESA_PASSKEY`

#### Email/SMTP (3)
- `SMTP_HOST`
- `SMTP_USER`
- `SMTP_PASSWORD`

#### Security/Auth (2)
- `JWT_SECRET_KEY`
- `ENCRYPTION_KEY`

## Service Secret Requirements

### Backend Services (API)
**Typical secrets needed**:
- `KUBE_CONFIG` - For deployment
- `REGISTRY_USERNAME`, `REGISTRY_PASSWORD` - For Docker push
- `GIT_TOKEN` - For git operations
- `POSTGRES_PASSWORD` - Database access
- `REDIS_PASSWORD` - Cache access
- `RABBITMQ_PASSWORD` - Message queue (if used)

**Example**: isp-billing-backend needs all of the above

### Frontend Services (UI)
**Typical secrets needed**:
- `KUBE_CONFIG` - For deployment
- `REGISTRY_USERNAME`, `REGISTRY_PASSWORD` - For Docker push
- `GIT_TOKEN` - For git operations

**Example**: isp-billing-frontend needs only these 4

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

### "Cannot detect repository"
**Cause**: Running outside git repo or gh CLI not configured
**Solution**: Set `GITHUB_REPOSITORY=Bengo-Hub/repo-name` or run from repo directory

### "gh CLI not authenticated"
**Cause**: No GitHub credentials available
**Solution**: Run `gh auth login` or set `GH_PAT` environment variable

### "Failed to sync SECRET_NAME"
**Cause**: Secret doesn't exist in devops-k8s or permission issue
**Solution**: 
1. Verify secret exists: `gh secret list --repo Bengo-Hub/devops-k8s`
2. Check GH_PAT has `repo` scope
3. Ensure workflow has secret mapped in env section

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
- ✅ **DO**: Protect infrastructure secrets (KUBE_CONFIG from app repos)
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
| **Debugging** | Hard (base64, async dispatch) | Easy (direct workflow, clear logs) |
| **Security** | All secrets in one place (blast radius) | Secrets synced per-service (isolated) |
| **Speed** | 15s+ polling delay | Immediate (no waiting) |
| **Local file** | Requires D:/KubeSecrets in setup | No local files needed |
| **Documentation** | Secret propagation flow needed | Self-documenting (check output) |
| **Failure mode** | Silent (polling timeout) | Explicit (CI fails, shows URLs) |

## Mosuon Cluster Differences

The mosuon cluster has identical setup but uses `mosuon-devops-k8s` as source:

1. **Script URL**: `https://raw.githubusercontent.com/Bengo-Hub/mosuon-devops-k8s/master/scripts/tools/check-and-sync-secrets.sh`
2. **Workflow**: `https://github.com/Bengo-Hub/mosuon-devops-k8s/actions/workflows/sync-secrets.yml`
3. **VPS secrets**: Uses `VPS_*` instead of `CONTABO_*` prefix
4. **Services**: game-stats-api, game-stats-ui

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
