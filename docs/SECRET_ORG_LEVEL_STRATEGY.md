# Direct Organization-Level Secret Access Strategy

**Last Updated:** February 7, 2026  
**Status:** Recommended approach - eliminates propagation overhead

## Problem with Current Approach

### Current Flow (Propagation Model)
```
Local secrets file (D:/KubeSecrets/...) 
  ↓ Manual: set-propagate-secrets.sh
PROPAGATE_SECRETS secret (devops-k8s repo)
  ↓ Workflow: decode to /tmp/propagate-secrets.txt  
propagate-to-repo.sh
  ↓ gh secret set per repo
Target repo secrets (duplicated)
  ↓ Workflow access
Application deployment
```

**Issues:**
1. ❌ **Local dependency:** Requires D:/KubeSecrets access to update PROPAGATE_SECRETS
2. ❌ **Duplication:** Secrets copied to every repo (25 secrets × 18 repos = 450 secret entries)  
3. ❌ **Propagation delay:** Workflow dispatch → decode → propagate → poll (15-30s overhead)
4. ❌ **Sync complexity:** Changes require re-propagation to all repos
5. ❌ **Failure points:** Dispatch can fail, propagation can timeout, polling can miss secrets

---

## Recommended Solution: Organization-Level Secrets

### New Flow (Direct Access Model)
```
Organization-level secrets (github.com/orgs/Bengo-Hub/settings/secrets/actions)
  ↓ Direct access in workflows
Application deployment (no propagation needed)
```

**Advantages:**
1. ✅ **No local dependency:** Update secrets via GitHub UI or API
2. ✅ **Single source:** One secret, accessible to all repos with permissions
3. ✅ **Instant updates:** Changes reflect immediately in all workflows
4. ✅ **No propagation:** Eliminate dispatch, decode, polling steps
5. ✅ **Simpler maintenance:** 25 secrets total instead of 450+

---

## Implementation Guide

### Step 1: Set Secrets at Organization Level

**Method 1: GitHub UI**
```
1. Go to: https://github.com/organizations/Bengo-Hub/settings/secrets/actions
2. Click "New organization secret"
3. Name: POSTGRES_PASSWORD
4. Value: ************ (plain text)
5. Repository access: "Selected repositories" → choose all app repos
6. Save
7. Repeat for all 25 secrets
```

**Method 2: GitHub CLI (Batch)**
```bash
#!/bin/bash
# set-org-secrets.sh - Set all secrets at organization level

ORG="Bengo-Hub"
SECRETS_FILE="D:/KubeSecrets/git-secrets/Bengo-Hub__devops-k8s/secrets.txt"

# Parse secrets file
declare -A SECRETS_MAP
cur_name=""
cur_value=""

while IFS= read -r line; do
  if [[ "$line" =~ ^secret:[[:space:]]*(.+)$ ]]; then
    [[ -n "$cur_name" && -n "$cur_value" ]] && SECRETS_MAP["$cur_name"]="$cur_value"
    cur_name="${BASH_REMATCH[1]}"
    cur_value=""
  elif [[ "$line" =~ ^value:[[:space:]]*(.*)$ ]]; then
    cur_value="${BASH_REMATCH[1]}"
  elif [[ -n "$cur_value" && ! "$line" =~ ^--- && ! "$line" =~ ^secret: ]]; then
    cur_value="$cur_value"$'\n'"$line"
  fi
done < "$SECRETS_FILE"
[[ -n "$cur_name" && -n "$cur_value" ]] && SECRETS_MAP["$cur_name"]="$cur_value"

# Application secrets (safe to share across repos)
APP_SECRETS=(
  "POSTGRES_PASSWORD"
  "REDIS_PASSWORD"
  "RABBITMQ_PASSWORD"
  "REGISTRY_USERNAME"
  "REGISTRY_PASSWORD"
  "REGISTRY_EMAIL"
  "GIT_TOKEN"
  "GIT_USER"
  "GIT_EMAIL"
  "GIT_APP_ID"
  "GIT_APP_SECRET"
  "GOOGLE_CLIENT_ID"
  "GOOGLE_CLIENT_SECRET"
  "DEFAULT_TENANT_SLUG"
  "GLOBAL_ADMIN_EMAIL"
  "SSH_HOST"
  "SSH_USER"
)

# Set organization-level secrets
for secret_name in "${APP_SECRETS[@]}"; do
  value="${SECRETS_MAP[$secret_name]}"
  if [ -n "$value" ]; then
    echo "Setting $secret_name at org level..."
    echo -n "$value" | gh secret set "$secret_name" --org "$ORG" --visibility selected
    
    # Grant access to all app repos (or specific list)
    # gh secret set requires --repos flag for selected visibility
    # Or use --visibility all to grant to all repos
  else
    echo "Warning: $secret_name not found in secrets file"
  fi
done

echo "✓ Organization secrets set"
echo "Configure repository access at: https://github.com/organizations/$ORG/settings/secrets/actions"
```

**Method 3: GitHub API (Advanced)**
```bash
#!/bin/bash
# set-org-secret-api.sh - Set org secret with repo access control

ORG="Bengo-Hub"
SECRET_NAME="$1"
SECRET_VALUE="$2"
REPO_IDS=("$@")  # Array of repository IDs with access

# Get org public key for encryption
ORG_KEY=$(gh api /orgs/$ORG/actions/secrets/public-key)
KEY_ID=$(echo "$ORG_KEY" | jq -r '.key_id')
PUBLIC_KEY=$(echo "$ORG_KEY" | jq -r '.key')

# Encrypt secret value (requires sodium or python pynacl)
# Using python example:
python3 << EOF
import base64
from nacl import encoding, public

def encrypt_secret(public_key: str, secret_value: str) -> str:
    public_key_bytes = public.PublicKey(public_key.encode("utf-8"), encoding.Base64Encoder())
    sealed_box = public.SealedBox(public_key_bytes)
    encrypted = sealed_box.encrypt(secret_value.encode("utf-8"))
    return base64.b64encode(encrypted).decode("utf-8")

print(encrypt_secret("$PUBLIC_KEY", "$SECRET_VALUE"))
EOF

# Set the secret
gh api --method PUT /orgs/$ORG/actions/secrets/$SECRET_NAME \
  -f encrypted_value="$ENCRYPTED_VALUE" \
  -f key_id="$KEY_ID" \
  -f visibility="selected" \
  -F selected_repository_ids[]="$REPO_ID1" \
  -F selected_repository_ids[]="$REPO_ID2"
```

### Step 2: Update Workflows to Use Org Secrets

**Current workflow pattern (repo-level):**
```yaml
# BEFORE: Requires secret propagation
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Build
        env:
          POSTGRES_PASSWORD: ${{ secrets.POSTGRES_PASSWORD }}  # Repo-level (may not exist)
          REDIS_PASSWORD: ${{ secrets.REDIS_PASSWORD }}        # Repo-level (may not exist)
        run: |
          ./build.sh
```

**New workflow pattern (org-level with fallback):**
```yaml
# AFTER: Direct org access, no propagation needed
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Build
        env:
          # GitHub automatically checks: repo-level → org-level → environment
          POSTGRES_PASSWORD: ${{ secrets.POSTGRES_PASSWORD }}  # Org-level (always available)
          REDIS_PASSWORD: ${{ secrets.REDIS_PASSWORD }}        # Org-level (always available)
        run: |
          ./build.sh
```

**No changes needed!** GitHub Actions automatically follows secret priority:
1. Repository-level secrets (highest priority)
2. Organization-level secrets ← **NEW: Set here**
3. Environment secrets (lowest priority)

### Step 3: Handle Environment-Specific Secrets

**Secrets that vary per environment:**
- `KUBE_CONFIG` (different per cluster/environment)
- `SSH_PRIVATE_KEY` (different per environment)  
- `DOCKER_SSH_KEY` (different per environment)
- Contabo credentials (if using multiple VPS instances)

**Strategy:**
1. **Keep at repo-level** - Manually set per repository
2. **Use repository environments** - dev/staging/prod with different values
3. **Protect from propagation** - Already implemented via CRITICAL_SECRETS list

**Example: Environment-based secrets**
```yaml
# Use deployment environments for environment-specific secrets
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production  # or staging, dev
    steps:
      - name: Deploy
        env:
          # Org-level (shared across envs)
          POSTGRES_PASSWORD: ${{ secrets.POSTGRES_PASSWORD }}
          
          # Environment-level (prod-specific)
          KUBE_CONFIG: ${{ secrets.KUBE_CONFIG }}  # Different for dev/staging/prod
        run: |
          echo "$KUBE_CONFIG" | base64 -d > ~/.kube/config
```

### Step 4: Remove Propagation Infrastructure (Optional)

Once org-level secrets are working, you can:

**Keep (Recommended):**
- `set-propagate-secrets.sh` - For bulk updates from local file
- `PROPAGATE_SECRETS` secret - As backup/export mechanism
- Workflows - As fallback for repos without org access

**Remove (Optional):**
- Auto-sync from build.sh (no longer needed)
- `propagate-secrets.yml` workflow (if all repos use org secrets)
- `check-and-sync-secrets.sh` sourcing (if not using auto-sync)

**Hybrid approach (Best):**
- Use org-level for 90% of repos
- Keep propagation for special cases (external contractors, limited access repos)
- Auto-sync remains as safety net (checks org-level first, propagates if missing)

---

## Migration Path

### Phase 1: Set Organization Secrets (Week 1)

**Day 1-2: Prepare**
```bash
# 1. Audit current secrets
gh secret list --repo Bengo-Hub/devops-k8s

# 2. Extract from PROPAGATE_SECRETS or local file
echo "$PROPAGATE_SECRETS" | base64 -d > /tmp/secrets-export.txt

# 3. Run set-org-secrets.sh script
./set-org-secrets.sh
```

**Day 3: Configure Repository Access**
```
1. Go to https://github.com/organizations/Bengo-Hub/settings/secrets/actions
2. For each secret, click "Update"
3. Set "Repository access" to "Selected repositories"  
4. Choose: isp-billing-backend, truload-backend, ordering-backend, etc. (all app repos)
5. Save
```

### Phase 2: Test with One Repository (Week 1)

**Pick test repo:** `isp-billing-backend`

```bash
# 1. Remove repo-level secrets (creates dependency on org)
gh secret delete POSTGRES_PASSWORD --repo Bengo-Hub/isp-billing-backend
gh secret delete REDIS_PASSWORD --repo Bengo-Hub/isp-billing-backend
# Keep KUBE_CONFIG (environment-specific)

# 2. Trigger build workflow
gh workflow run deploy.yml --repo Bengo-Hub/isp-billing-backend

# 3. Verify secrets accessible
# Check workflow logs for successful secret usage
```

**Expected result:**
- ✅ Workflow runs successfully
- ✅ Environment variables populated from org secrets
- ✅ No "secret not found" errors
- ✅ KUBE_CONFIG still works (repo-level fallback)

### Phase 3: Rollout to All Repositories (Week 2)

**Batch removal script:**
```bash
#!/bin/bash
# remove-repo-secrets.sh - Remove application secrets from repos (fallback to org)

APP_REPOS=(
  "Bengo-Hub/isp-billing-backend"
  "Bengo-Hub/isp-billing-frontend"
  "Bengo-Hub/truload-backend"
  "Bengo-Hub/truload-frontend"
  "Bengo-Hub/ordering-backend"
  "Bengo-Hub/ordering-frontend"
  "Bengo-Hub/auth-api"
  "Bengo-Hub/notifications-api"
  # ... add all repos
)

APP_SECRETS=(
  "POSTGRES_PASSWORD"
  "REDIS_PASSWORD"
  "RABBITMQ_PASSWORD"
  "REGISTRY_USERNAME"
  "REGISTRY_PASSWORD"
  "GIT_TOKEN"
)

for repo in "${APP_REPOS[@]}"; do
  echo "Cleaning $repo..."
  for secret in "${APP_SECRETS[@]}"; do
    gh secret delete "$secret" --repo "$repo" 2>/dev/null || echo "  $secret not found (already org-level)"
  done
done

echo "✓ Repo-level secrets removed"
echo "✓ Workflows will now use org-level secrets"
```

### Phase 4: Update Documentation (Week 2)

**Update files:**
- [x] Create `SECRET_ORG_LEVEL_STRATEGY.md` (this file)
- [ ] Update `SECRET_PROPAGATION_FLOW.md` - Add org-level section
- [ ] Update `SECRET_ENCODING_STRATEGY.md` - Recommend org-level
- [ ] Update build.sh - Remove auto-sync or make optional
- [ ] Update README files - Document org-level approach

---

## Comparison Table

| Aspect | Propagation Model | Org-Level Model |
|--------|-------------------|-----------------|
| **Setup complexity** | High (multiple steps) | Low (set once) |
| **Secrets count** | 25 × 18 repos = 450 | 25 total |
| **Update speed** | 15-30s (dispatch + propagate) | Instant |
| **Local dependency** | Yes (D:/KubeSecrets) | No (GitHub UI/API) |
| **Failure points** | Many (dispatch, decode, propagate, poll) | None (direct access) |
| **Access control** | Per-repo | Per-repo (selected) or all |
| **Environment separation** | Requires manual setup | Use environments |
| **Audit trail** | Multiple places | Centralized |
| **Team collaboration** | Requires local file access | GitHub UI/API only |
| **CI/CD simplicity** | Complex (sync required) | Simple (direct access) |

**Verdict:** Org-level is superior for 90% of use cases

---

## Handling Base64-Encoded Secrets at Org Level

### Storage Format

**Store at org-level exactly as currently stored:**

```
# Plain text secrets
POSTGRES_PASSWORD: ************ (plain text)
REDIS_PASSWORD: ************ (plain text)
REGISTRY_PASSWORD: dckr_pat_**** (plain text token)

# Base64 secrets  
KUBE_CONFIG: YXBpVmVyc2lvbjogdjEKY2x1c3RlcnM6... (base64 string)
SSH_PRIVATE_KEY: LS0tLS1CRUdJTi... (base64 string)
DOCKER_SSH_KEY: LS0tLS1CRUdJTi... (base64 string)
```

**No changes needed** - Same format as repo-level propagation

### Workflow Usage

**Plain text (direct use):**
```yaml
env:
  POSTGRES_PASSWORD: ${{ secrets.POSTGRES_PASSWORD }}  # Org-level
run: |
  psql -p "$POSTGRES_PASSWORD"  # Use directly
```

**Base64 (decode first):**
```yaml
env:
  KUBE_CONFIG: ${{ secrets.KUBE_CONFIG }}  # Org-level (still base64)
run: |
  echo "$KUBE_CONFIG" | base64 -d > ~/.kube/config  # Decode
```

**Same usage pattern** - No workflow changes required

---

## Troubleshooting Org-Level Secrets

### Issue: Secret not found in workflow

**Diagnosis:**
```yaml
- name: Debug secrets
  run: |
    echo "POSTGRES_PASSWORD set: ${{ secrets.POSTGRES_PASSWORD != '' }}"
    if [ -z "${{ secrets.POSTGRES_PASSWORD }}" ]; then
      echo "ERROR: POSTGRES_PASSWORD not accessible"
      echo "Check: https://github.com/organizations/Bengo-Hub/settings/secrets/actions"
    fi
```

**Possible causes:**
1. Secret not set at org level
2. Repository not granted access
3. Typo in secret name

**Resolution:**
```bash
# 1. Verify secret exists
gh api /orgs/Bengo-Hub/actions/secrets

# 2. Check repository access
gh api /orgs/Bengo-Hub/actions/secrets/POSTGRES_PASSWORD

# 3. Grant access if missing
# Via UI: org settings → secrets → POSTGRES_PASSWORD → Update → Add repositories
```

### Issue: Repo-level secret shadows org-level

**Diagnosis:**
```bash
# Check if secret exists at repo level (takes precedence)
gh secret list --repo Bengo-Hub/isp-billing-backend | grep POSTGRES_PASSWORD
```

**If found at repo-level:**
- Repo-level secret is used (higher priority)
- Org-level secret ignored
- May have stale/different value

**Resolution:**
```bash
# Remove repo-level to fall back to org
gh secret delete POSTGRES_PASSWORD --repo Bengo-Hub/isp-billing-backend
```

### Issue: Environment-specific secret conflict

**Scenario:**
- Org-level: `KUBE_CONFIG` for prod cluster
- Repo-level: empty (expecting org fallback)
- Result: Deploys to wrong cluster

**Resolution:**
```
1. Don't set environment-specific secrets at org level
2. Keep KUBE_CONFIG at repo or environment level only
3. Document which secrets are environment-specific
```

---

## Recommended Final State

### Organization-Level Secrets (17 total)

**Application secrets (shared across all repos):**
- POSTGRES_PASSWORD
- REDIS_PASSWORD
- RABBITMQ_PASSWORD
- REGISTRY_USERNAME
- REGISTRY_PASSWORD
- REGISTRY_EMAIL
- GIT_TOKEN
- GIT_USER
- GIT_EMAIL
- GIT_APP_ID
- GIT_APP_SECRET
- GOOGLE_CLIENT_ID
- GOOGLE_CLIENT_SECRET
- DEFAULT_TENANT_SLUG
- GLOBAL_ADMIN_EMAIL
- SSH_HOST
- SSH_USER

**Repository access:** All application repos (selected)

### Repository-Level Secrets (per repo)

**Environment-specific (varies per deployment):**
- KUBE_CONFIG (cluster kubeconfig)

**Optional per-repo:**
- SSH_PRIVATE_KEY (if different per repo)
- DOCKER_SSH_KEY (if different per repo)
- Any repo-specific API keys

### devops-k8s Secrets (3 total)

**Propagation infrastructure (keep for backup):**
- PROPAGATE_SECRETS (base64 export of all secrets)
- GH_PAT (GitHub Personal Access Token for propagation)

**Infrastructure:**
- KUBE_CONFIG (main cluster)
- CONTABO_API_PASSWORD
- CONTABO_CLIENT_SECRET
- SSH_PRIVATE_KEY

### Total Secret Entries

**Before:** 25 secrets × 18 repos = 450 entries  
**After:** 17 org + (1-3 per repo × 18) = ~35-50 entries  
**Reduction:** 90% fewer secret entries to manage

---

## Migration Checklist

### Pre-Migration
- [ ] Audit all secrets in PROPAGATE_SECRETS or local file
- [ ] Identify application vs environment-specific secrets
- [ ] Document current secret values (encrypted backup)
- [ ] Choose pilot repository for testing

### Migration
- [ ] Set 17 application secrets at organization level
- [ ] Configure repository access (selected repos)
- [ ] Test with pilot repository (remove repo secrets, trigger build)
- [ ] Verify workflows access org secrets successfully
- [ ] Roll out to remaining repositories (batch delete repo secrets)
- [ ] Keep environment-specific secrets at repo/environment level

### Post-Migration
- [ ] Update documentation (propagation → org-level)
- [ ] Remove auto-sync from build.sh (or make optional)
- [ ] Archive propagation workflows (keep for special cases)
- [ ] Monitor workflows for secret access issues
- [ ] Document org-level secret update process

### Verification
- [ ] All workflows run without "secret not found" errors
- [ ] Deployments succeed with org-level secrets
- [ ] Environment-specific secrets still work (KUBE_CONFIG)
- [ ] Team can update secrets via GitHub UI
- [ ] No local file dependencies in CI/CD

---

## Summary

**Key insight:** GitHub Actions can access organization-level secrets directly without any propagation mechanism, eliminating the need for PROPAGATE_SECRETS intermediate storage and complex dispatch workflows.

**Implementation:**
1. Set secrets once at org level
2. Grant access to selected repos  
3. Remove repo-level duplicates
4. Workflows automatically use org-level (no code changes)

**Benefits:**
- ✅ 90% reduction in secret entries
- ✅ Instant updates across all repos
- ✅ No local file dependencies
- ✅ Simpler CI/CD pipelines
- ✅ Better team collaboration

**When to use propagation:**
- External contractor repos (limited org access)
- One-time secret transfers
- Backup/restore scenarios
- Special compliance requirements
