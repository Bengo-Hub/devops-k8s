# Centralized Secret Management System

## Overview

This system provides automated secret management across all repositories using centralized scripts in `devops-k8s` and `mosuon-devops-k8s`. Applications automatically check for missing secrets and sync them from the DevOps repository during build time, eliminating manual secret configuration.

## Architecture

```
devops-k8s (Bengo-Hub org)
└── scripts/tools/
    ├── set-propagate-secrets.sh      # Initialize PROPAGATE_SECRETS from exported file
    ├── propagate-to-repo.sh          # Propagate specific secrets to target repo
    └── check-and-sync-secrets.sh     # Auto-sync helper for build.sh scripts

Application repos (truload-backend, ordering-backend, etc.)
└── build.sh
    └── Downloads check-and-sync-secrets.sh from devops-k8s
    └── Auto-syncs missing secrets before deployment
```

## Components

### 1. set-propagate-secrets.sh
**Purpose**: Initialize or update the PROPAGATE_SECRETS repository secret from an exported secrets file.

**Usage**:
```bash
SECRETS_FILE=/path/to/secrets.txt bash set-propagate-secrets.sh
```

**What it does**:
- Reads the exported secrets file (plain text format)
- Base64-encodes the entire file
- Sets it as `PROPAGATE_SECRETS` secret in devops-k8s repository
- Requires `gh` CLI authentication

**When to run**:
- After exporting new secrets from Kubernetes cluster
- When secrets need to be updated
- During initial setup

---

### 2. propagate-to-repo.sh
**Purpose**: Propagate specific secrets to a target repository.

**Usage**:
```bash
./propagate-to-repo.sh <target-repo> <secret1> [secret2] ...
```

**Examples**:
```bash
# Propagate multiple secrets to truload-backend
./propagate-to-repo.sh Bengo-Hub/truload-backend POSTGRES_PASSWORD REDIS_PASSWORD KUBE_CONFIG

# Propagate single secret to ordering-backend
./propagate-to-repo.sh Bengo-Hub/ordering-backend REGISTRY_PASSWORD
```

**What it does**:
- Reads secrets from local secrets file (default: `D:/KubeSecrets/git-secrets/Bengo-Hub__devops-k8s/secrets.txt`)
- Parses requested secret names
- Base64-encodes each secret value
- Sets them in the target repository via `gh secret set`
- Reports success/failure summary

**Environment Variables**:
- `PROPAGATE_SECRETS_FILE`: Override default secrets file path

---

### 3. check-and-sync-secrets.sh
**Purpose**: Helper function for application build.sh scripts to auto-check and sync missing secrets.

**Usage in build.sh**:
```bash
# Download and source the sync script
SYNC_SCRIPT=$(mktemp)
curl -fsSL https://raw.githubusercontent.com/Bengo-Hub/devops-k8s/main/scripts/tools/check-and-sync-secrets.sh -o "$SYNC_SCRIPT"
source "$SYNC_SCRIPT"

# Call the function with required secrets
check_and_sync_secrets "KUBE_CONFIG" "REGISTRY_USERNAME" "REGISTRY_PASSWORD" "GITHUB_TOKEN"

# Cleanup
rm -f "$SYNC_SCRIPT"
```

**What it does**:
1. Detects the current repository name via `gh repo view`
2. Lists existing secrets in the repository
3. Identifies which required secrets are missing
4. Downloads `propagate-to-repo.sh` from devops-k8s
5. Runs propagation to sync missing secrets
6. Reports results

**Returns**:
- `0` if all secrets are present or successfully synced
- `1` if secret sync fails (non-fatal in build scripts)

---

## Secrets File Format

The exported secrets file uses this text format:

```
---
secret: SECRET_NAME
value: secret_value_here
---
secret: MULTILINE_SECRET
value: line1
line2
line3
---
secret: ANOTHER_SECRET
value: another_value
---
```

**Notes**:
- Each secret block starts with `---`
- Secret names follow `secret: NAME`
- Values follow `value: VALUE`
- Multi-line values are supported
- Secrets are parsed in order
- File is base64-encoded when stored as `PROPAGATE_SECRETS`

---

## Integration in Application build.sh

All application build.sh scripts in Bengo-Hub organization now include automatic secret syncing:

### Standard Pattern (for devops-k8s apps):
```bash
#!/usr/bin/env bash
set -euo pipefail

# ... configuration variables ...

# Prerequisite checks
for tool in git docker trivy; do
  command -v "$tool" >/dev/null || { error "$tool is required"; exit 1; }
done
if [[ ${DEPLOY} == "true" ]]; then
  for tool in kubectl helm yq jq; do
    command -v "$tool" >/dev/null || { error "$tool is required"; exit 1; }
  done
fi
success "Prerequisite checks passed"

# =============================================================================
# Auto-sync secrets from devops-k8s
# =============================================================================
if [[ ${DEPLOY} == "true" ]]; then
  info "Checking and syncing required secrets from devops-k8s..."
  SYNC_SCRIPT=$(mktemp)
  if curl -fsSL https://raw.githubusercontent.com/Bengo-Hub/devops-k8s/main/scripts/tools/check-and-sync-secrets.sh -o "$SYNC_SCRIPT" 2>/dev/null; then
    source "$SYNC_SCRIPT"
    check_and_sync_secrets "KUBE_CONFIG" "REGISTRY_USERNAME" "REGISTRY_PASSWORD" "GITHUB_TOKEN" "POSTGRES_PASSWORD" "REDIS_PASSWORD" || warn "Secret sync failed - continuing with existing secrets"
    rm -f "$SYNC_SCRIPT"
  else
    warn "Unable to download secret sync script - continuing with existing secrets"
  fi
fi

# ... Docker build, push, deploy ...
```

### Modified Apps (as of implementation):
**Bengo-Hub/devops-k8s apps**:
- `TruLoad/truload-backend/build.sh` ✅
- `TruLoad/truload-frontend/build.sh` ✅
- `ordering-service/ordering-backend/build.sh` ✅
- `ordering-service/ordering-frontend/build.sh` ✅
- `auth-service/auth-api/build.sh` ✅
- `ISPBilling/isp-billing-backend/build.sh` ✅
- `ISPBilling/isp-billing-frontend/build.sh` ✅
- `notifications-service/notifications-api/build.sh` ✅
- `erp/erp-api/build.sh` ✅

**Bengo-Hub/mosuon-devops-k8s apps**:
- `mosuon/game-stats/game-stats-api/build.sh` ✅
- `mosuon/game-stats/game-stats-ui/build.sh` ✅

---

## Mosuon Organization

The same system is replicated for Mosuon apps using `mosuon-devops-k8s`:

**Repository**: `Bengo-Hub/mosuon-devops-k8s`

**Scripts**:
- `scripts/tools/set-propagate-secrets.sh`
- `scripts/tools/propagate-to-repo.sh`
- `scripts/tools/check-and-sync-secrets.sh`

**Differences**:
- Default repo: `Bengo-Hub/mosuon-devops-k8s` (instead of `Bengo-Hub/devops-k8s`)
- Secrets file path: `D:/KubeSecrets/git-secrets/Bengo-Hub__mosuon-devops-k8s/secrets.txt`
- GitHub raw URL branch: `master` (instead of `main`)

**Integration**:
```bash
# For mosuon apps (game-stats-api, game-stats-ui)
curl -fsSL https://raw.githubusercontent.com/Bengo-Hub/mosuon-devops-k8s/master/scripts/tools/check-and-sync-secrets.sh -o "$SYNC_SCRIPT"
```

---

## Setup Guide

### Initial Setup (Bengo-Hub organization)

1. **Export secrets from Kubernetes cluster**:
   ```bash
   # Export all secrets from the cluster
   kubectl get secrets --all-namespaces -o json > /tmp/k8s-secrets.json
   # Parse and format as text file (manual or scripted)
   # Save to: D:/KubeSecrets/git-secrets/Bengo-Hub__devops-k8s/secrets.txt
   ```

2. **Authenticate GitHub CLI**:
   ```bash
   gh auth login
   # Or set PAT manually
   export GH_TOKEN=ghp_YOUR_TOKEN_HERE
   ```

3. **Initialize PROPAGATE_SECRETS in devops-k8s**:
   ```bash
   cd devops-k8s/scripts/tools
   SECRETS_FILE=D:/KubeSecrets/git-secrets/Bengo-Hub__devops-k8s/secrets.txt bash set-propagate-secrets.sh
   ```

4. **Set PROPAGATE_PAT in devops-k8s** (one-time):
   ```bash
   # This PAT is used by build scripts to authenticate gh CLI
   echo "ghp_YOUR_TOKEN_HERE" | gh secret set PROPAGATE_PAT --repo Bengo-Hub/devops-k8s
   ```

5. **Test propagation to a repo**:
   ```bash
   cd devops-k8s/scripts/tools
   ./propagate-to-repo.sh Bengo-Hub/truload-backend KUBE_CONFIG POSTGRES_PASSWORD
   ```

6. **Verify secrets in target repo**:
   ```bash
   gh secret list --repo Bengo-Hub/truload-backend
   ```

### Initial Setup (Mosuon organization)

Follow the same steps but:
- Replace `devops-k8s` with `mosuon-devops-k8s`
- Use Mosuon secrets file: `D:/KubeSecrets/git-secrets/Bengo-Hub__mosuon-devops-k8s/secrets.txt`
- Test with mosuon apps: `Bengo-Hub/game-stats-api`

---

## Maintenance

### Updating Secrets

When secrets change (e.g., password rotation, new K8s credentials):

1. **Export updated secrets** to the secrets file
2. **Re-run set-propagate-secrets.sh**:
   ```bash
   SECRETS_FILE=/path/to/new-secrets.txt bash set-propagate-secrets.sh
   ```
3. **Apps will auto-sync on next build** (no manual propagation needed)

### Adding New Secrets

To add new secrets to the system:

1. **Add to secrets file** in the standard format:
   ```
   ---
   secret: NEW_SECRET_NAME
   value: new_secret_value
   ---
   ```

2. **Update PROPAGATE_SECRETS**:
   ```bash
   SECRETS_FILE=/path/to/updated-secrets.txt bash set-propagate-secrets.sh
   ```

3. **Update build.sh** in apps that need it:
   ```bash
   check_and_sync_secrets "EXISTING_SECRET" "NEW_SECRET_NAME"
   ```

### Adding New Repositories

New repositories automatically get secrets on first build if their `build.sh` includes the auto-sync logic—no manual setup required.

---

## Security Considerations

### Access Control
- **PROPAGATE_SECRETS**: Contains base64-encoded secrets file; only accessible via GitHub repo secrets (encrypted at rest)
- **PROPAGATE_PAT**: Personal Access Token with `repo` scope; required for `gh secret set` operations
- **Secrets file**: Stored locally at `D:/KubeSecrets/git-secrets/` (should be secured with file permissions)

### Best Practices
- **Rotate PAT regularly**: Update `PROPAGATE_PAT` secret in devops-k8s
- **Audit secret access**: Review GitHub Actions logs for propagation operations
- **Minimize secret exposure**: Only propagate secrets apps actually need
- **Secure local files**: Set strict permissions on `D:/KubeSecrets/` directory

---

## Troubleshooting

### "gh not authenticated"
**Fix**: Run `gh auth login` or export `GH_TOKEN=ghp_YOUR_TOKEN_HERE`

### "Secret sync failed"
**Fix**:
1. Check network connectivity to GitHub
2. Verify devops-k8s repo exists and scripts are present
3. Manually propagate secrets: `./propagate-to-repo.sh <repo> <secrets>`

### "Secret X not found"
**Fix**:
1. Check secrets file: `D:/KubeSecrets/git-secrets/Bengo-Hub__devops-k8s/secrets.txt`
2. Add missing secret in correct format
3. Re-run `set-propagate-secrets.sh`

---

## Summary

This centralized secret management system provides:
- ✅ **Zero-touch secret provisioning** for new repositories
- ✅ **Automated secret syncing** during build time
- ✅ **Centralized secret storage** in devops-k8s repositories
- ✅ **No manual secret configuration** required
- ✅ **Consistent secret management** across all applications
- ✅ **Built-in fallback** if sync fails (continues with existing secrets)

---

**Last Updated**: January 2025  
**Maintainer**: DevOps Team
