# Secret Propagation Flow Analysis

**Last Updated:** February 7, 2026  
**Status:** Complete flow from source to usage documented

## Overview

This document traces how secrets flow from the local master file through PROPAGATE_SECRETS to target repositories and how they're consumed in GitHub Actions workflows.

---

## Complete Secret Flow

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. SOURCE: Local Secrets File                                  │
│    D:/KubeSecrets/git-secrets/Bengo-Hub__devops-k8s/secrets.txt │
│    Format: YAML-like plain text with some values PRE-ENCODED   │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     │ set-propagate-secrets.sh
                     │ base64 encode entire file
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. CENTRALIZED STORE: PROPAGATE_SECRETS                        │
│    Secret in: Bengo-Hub/devops-k8s                             │
│    Format: BASE64 (entire secrets file encoded as one string)  │
│    Size: 13,584 chars base64 ← 10,188 bytes original           │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     │ propagate-secrets.yml workflow
                     │ echo "${PROPAGATE_SECRETS}" | base64 -d
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│ 3. WORKFLOW TEMP FILE: /tmp/propagate-secrets.txt              │
│    Format: YAML-like plain text (decoded from PROPAGATE_SECRETS)│
│    Values: KUBE_CONFIG still base64, passwords plain text      │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     │ propagate-to-repo.sh
                     │ Parse YAML-like format
                     │ echo -n "$VALUE" | gh secret set
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│ 4. TARGET REPO SECRETS: e.g., isp-billing-backend              │
│    Format: GitHub encrypted secrets (GitHub's encryption layer) │
│    KUBE_CONFIG: base64 string (as-is from source)              │
│    REGISTRY_PASSWORD: plain text (as-is from source)           │
│    POSTGRES_PASSWORD: plain text (as-is from source)           │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     │ GitHub Actions workflow
                     │ ${{ secrets.SECRET_NAME }}
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│ 5. WORKFLOW USAGE: deploy.yml, provision.yml                   │
│    KUBE_CONFIG: Decoded in workflow (base64 -d)                │
│    Passwords: Used as-is (plain text)                          │
│    Docker: echo "$REGISTRY_PASSWORD" | docker login            │
└─────────────────────────────────────────────────────────────────┘
```

---

## Detailed Format Analysis

### 1. Source: Local Secrets File

**Location:** `D:/KubeSecrets/git-secrets/Bengo-Hub__devops-k8s/secrets.txt`  
**Format:** YAML-like structure with `secret:` and `value:` pairs  
**Size:** 10,188 bytes (25 secrets)

**Format Structure:**
```yaml
repo: Bengo-Hub/devops-k8s
branch:
---
secret: REGISTRY_USERNAME
value: codevertex
---
secret: REGISTRY_PASSWORD
value: dckr_pat_****************************
---
secret: KUBE_CONFIG
value: YXBpVmVyc2lvbjogdjEKY2x1c3RlcnM6Ci0gY2x1c3RlcjoKICAgIGNlcnRpZmljYX...
---
secret: POSTGRES_PASSWORD
value: Vertex2020!
---
```

**Key Observations:**
- **Most secrets:** Stored as **plain text** (REGISTRY_PASSWORD, POSTGRES_PASSWORD, REDIS_PASSWORD)
- **KUBE_CONFIG:** Stored **PRE-ENCODED as base64** (kubeconfig YAML already base64-encoded before storage)
- **Delimiter:** `---` separates secret entries
- **Metadata:** First two lines contain repo and branch info (not parsed as secrets)

**Why KUBE_CONFIG is stored base64:**
- Original kubeconfig is multi-line YAML
- GitHub secrets support multi-line but workflows often need single-line base64
- Pre-encoding simplifies workflow usage: just decode and use
- Follows Kubernetes standard: `cat ~/.kube/config | base64 -w 0`

---

### 2. PROPAGATE_SECRETS Secret

**Created by:** `devops-k8s/scripts/tools/set-propagate-secrets.sh`  
**Storage:** GitHub secret in Bengo-Hub/devops-k8s repository  
**Updated:** 2026-02-07T17:41:35Z

**Encoding Process:**
```bash
# From set-propagate-secrets.sh lines 60-63
ENCODED=$(base64 -w0 < "$SECRETS_FILE" 2>/dev/null || base64 < "$SECRETS_FILE" | tr -d '\n')
echo "$ENCODED" | gh secret set PROPAGATE_SECRETS --repo "$REPO" --body -
```

**Result:**
- **Input:** 10,188 bytes plain text file
- **Encoding:** Entire file base64-encoded WITHOUT line breaks (`-w0`)
- **Output:** 13,584 character single-line base64 string
- **Calculation:** 10,188 bytes × 1.33 (base64 overhead) ≈ 13,550 chars ✓

**What's inside PROPAGATE_SECRETS:**
```
Base64(entire secrets.txt file) which contains:
  - Plain text passwords (REGISTRY_PASSWORD, POSTGRES_PASSWORD, etc.)
  - Base64 kubeconfig (KUBE_CONFIG value)
  - All 25 secrets in YAML-like format
```

**Why double-encoding is OK:**
- Outer base64: Transport mechanism (GitHub Actions treats it as opaque blob)
- Inner base64 (KUBE_CONFIG): Actual secret value format (workflow decodes)
- Each layer serves different purpose, no conflict

---

### 3. Workflow Decode Process

**Workflow:** `.github/workflows/propagate-secrets.yml`  
**Step:** "Prepare secrets file" (lines 63-80)

**Decode Process:**
```yaml
- name: Prepare secrets file
  env:
    PROPAGATE_SECRETS: ${{ secrets.PROPAGATE_SECRETS }}
  run: |
    echo "${PROPAGATE_SECRETS}" | base64 -d > /tmp/propagate-secrets.txt
    chmod 600 /tmp/propagate-secrets.txt
```

**Result:**
- **Input:** PROPAGATE_SECRETS (13,584 char base64 string)
- **Decode:** `base64 -d` restores **original secrets.txt format**
- **Output:** `/tmp/propagate-secrets.txt` (10,188 bytes YAML-like plain text)
- **Content:** Identical to original D:/KubeSecrets/... file

**File Stats Logged:**
```bash
echo "Decoded file size: $(wc -c < /tmp/propagate-secrets.txt) bytes"
# Output: 10188 bytes ✓

echo "Secrets count: $(grep -c '^secret:' /tmp/propagate-secrets.txt || echo 0)"
# Output: 25 ✓
```

---

### 4. Secret Propagation to Target Repos

**Script:** `devops-k8s/scripts/tools/propagate-to-repo.sh`  
**Usage:** `./propagate-to-repo.sh <target-repo> <secret1> [secret2] ...`  
**Environment:** `PROPAGATE_SECRETS_FILE=/tmp/propagate-secrets.txt`

**Parsing Logic (lines 50-63):**
```bash
declare -A SECRETS_MAP
cur_name=""
cur_value=""

while IFS= read -r line; do
  if [[ "$line" =~ ^secret:[[:space:]]*(.+)$ ]]; then
    # Start new secret
    [[ -n "$cur_name" && -n "$cur_value" ]] && SECRETS_MAP["$cur_name"]="$cur_value"
    cur_name="${BASH_REMATCH[1]}"
    cur_value=""
  elif [[ "$line" =~ ^value:[[:space:]]*(.*)$ ]]; then
    # Start value (may be multi-line)
    cur_value="${BASH_REMATCH[1]}"
  elif [[ -n "$cur_value" && ! "$line" =~ ^--- && ! "$line" =~ ^secret: ]]; then
    # Continuation of multi-line value
    cur_value="$cur_value"$'\n'"$line"
  fi
done < "$SECRETS_FILE"
```

**Key Features:**
- Handles **multi-line values** (for KUBE_CONFIG base64, though typically single line)
- Extracts secret name from `secret: NAME`
- Extracts value from `value: VALUE` (preserves format: base64 stays base64, plain text stays plain)
- Skips metadata lines (repo, branch, `---` delimiters)

**Setting Secrets (lines 100-106):**
```bash
VALUE="${SECRETS_MAP[$SECRET_NAME]}"

# Set secret as plain text (GitHub encrypts it automatically)
# DO NOT base64-encode here - gh secret set expects plain text
echo "[INFO] Setting $SECRET_NAME in $TARGET_REPO"
if echo -n "$VALUE" | gh secret set "$SECRET_NAME" --repo "$TARGET_REPO" --body -; then
  SUCCESS=$((SUCCESS + 1))
```

**CRITICAL: `echo -n "$VALUE"`**
- `-n` flag: No trailing newline (important for exact value preservation)
- `$VALUE` for REGISTRY_PASSWORD: `dckr_pat_****************************` (36 chars plain text)
- `$VALUE` for KUBE_CONFIG: `YXBpVmVyc2lvbjogdjEKY2x1c3...` (long base64 string, ~5000+ chars)
- `gh secret set` receives value via stdin (`--body -`)
- GitHub encrypts values server-side using repository-specific encryption keys

**No Additional Encoding:**
- Passwords propagated AS-IS (plain text)
- KUBE_CONFIG propagated AS-IS (base64 string from source)
- GitHub encrypts all secrets uniformly (transparent to workflow)

---

### 5. Secret Usage in Workflows

#### Example 1: Docker Login (Application Secrets)

**File:** `ISPBilling/isp-billing-backend/.github/workflows/deploy.yml` (lines 67-80)

```yaml
- name: Tag and push :latest
  env:
    REGISTRY_USERNAME: ${{ secrets.REGISTRY_USERNAME }}
    REGISTRY_PASSWORD: ${{ secrets.REGISTRY_PASSWORD }}
    REGISTRY_SERVER: docker.io
  run: |
    echo "[DEBUG] REGISTRY_PASSWORD length: ${#REGISTRY_PASSWORD} chars"
    # Output: 36 chars ✓
    
    echo "$REGISTRY_PASSWORD" | docker login \
      -u "$REGISTRY_USERNAME" \
      --password-stdin "$REGISTRY_SERVER"
```

**How it works:**
1. `${{ secrets.REGISTRY_PASSWORD }}` → GitHub decrypts secret
2. Environment variable `REGISTRY_PASSWORD` = `dckr_pat_****************************` (plain text, 36 chars)
3. Echo to stdin of `docker login` (secure, no shell exposure)
4. Docker uses plain text password for authentication

**Format expectations:**
- GitHub stores: Encrypted blob (opaque)
- GitHub returns via `${{ secrets.* }}`: **Plain text** (decrypted)
- Workflow uses: **Plain text** directly (no decode needed)

---

#### Example 2: Kubeconfig (Infrastructure Secret)

**File:** `devops-k8s/.github/workflows/provision.yml` (lines 166-220)

```yaml
- name: Configure kubeconfig
  env:
    KUBE_CONFIG_B64: ${{ secrets.KUBE_CONFIG }}
  run: |
    # Clean the base64 string (remove whitespace, newlines)
    CLEAN_B64=$(echo "$KUBE_CONFIG_B64" | tr -d '[:space:]')
    
    # Validate base64 format
    if ! echo "$CLEAN_B64" | base64 -d >/dev/null 2>&1; then
      echo "❌ Invalid base64 format in KUBE_CONFIG secret"
      exit 1
    fi
    
    # Decode and write kubeconfig
    echo "$CLEAN_B64" | base64 -d > ~/.kube/config
    chmod 600 ~/.kube/config
```

**How it works:**
1. `${{ secrets.KUBE_CONFIG }}` → GitHub decrypts secret
2. Environment variable `KUBE_CONFIG_B64` = `YXBpVmVyc2lvbjogdjEKY2x1c3RlcnM6...` (base64 string, ~5000+ chars)
3. Workflow performs `base64 -d` to decode kubeconfig YAML
4. Result written to `~/.kube/config` (multi-line YAML)

**Format expectations:**
- Local storage: KUBE_CONFIG value is **base64-encoded kubeconfig**
- PROPAGATE_SECRETS: Contains that base64 value AS-IS (no change)
- GitHub secret: Stores base64 value AS-IS (encrypted by GitHub)
- GitHub returns: **Base64 string** (decrypted, but still base64)
- Workflow decodes: `base64 -d` → **Plain text YAML kubeconfig**

**Why this works:**
```
Original kubeconfig (YAML):
  apiVersion: v1
  clusters:
  - cluster:
      certificate-authority-data: LS0tLS...
      server: https://77.237.232.66:6443
  ...

After `cat ~/.kube/config | base64 -w 0`:
  YXBpVmVyc2lvbjogdjEKY2x1c3RlcnM6Ci0gY2x1c3RlcjoKICAgIGNlcnRpZmljYX...

Stored in secrets.txt:
  secret: KUBE_CONFIG
  value: YXBpVmVyc2lvbjogdjEKY2x1c3RlcnM6Ci0gY2x1c3RlcjoKICAgIGNlcnRpZmljYX...

Stored in PROPAGATE_SECRETS:
  Base64(entire secrets.txt including the base64 KUBE_CONFIG value)

Decoded by workflow:
  secrets.txt restored → KUBE_CONFIG = YXBpVmVyc2lvbjogdjEKY2x1c3RlcnM6...

Set in GitHub:
  gh secret set KUBE_CONFIG --body "YXBpVmVyc2lvbjogdjEKY2x1c3RlcnM6..."

Used in workflow:
  ${{ secrets.KUBE_CONFIG }} = YXBpVmVyc2lvbjogdjEKY2x1c3RlcnM6...
  echo "$KUBE_CONFIG_B64" | base64 -d > ~/.kube/config
  → Original YAML kubeconfig restored ✓
```

---

## Secret Format Summary Table

| Secret Name | Source Format | PROPAGATE_SECRETS | GitHub Secret | Workflow Receives | Workflow Uses |
|-------------|---------------|-------------------|---------------|-------------------|---------------|
| REGISTRY_USERNAME | Plain text | Base64(file) | Encrypted | Plain text | Direct |
| REGISTRY_PASSWORD | Plain text | Base64(file) | Encrypted | Plain text | Direct |
| POSTGRES_PASSWORD | Plain text | Base64(file) | Encrypted | Plain text | Direct |
| REDIS_PASSWORD | Plain text | Base64(file) | Encrypted | Plain text | Direct |
| GIT_TOKEN | Plain text | Base64(file) | Encrypted | Plain text | Direct |
| **KUBE_CONFIG** | **Base64** | **Base64(file)** | **Encrypted** | **Base64 string** | **Decode first** |
| CONTABO_API_PASSWORD | Plain text | Base64(file) | Encrypted | Plain text | Direct |

**Key Insight:**
- Most secrets: Plain text all the way (GitHub encryption is transparent)
- KUBE_CONFIG: Base64 at source, stays base64 through propagation, decoded only in workflow usage
- PROPAGATE_SECRETS: Container mechanism (base64 encodes the entire file, not individual secrets)

---

## Encoding Layers Explained

### Layer 1: Individual Secret Values (Source File)

**Most Secrets (Plain Text):**
```
REGISTRY_PASSWORD
  ↓
dckr_pat_****************************  ← Plain text stored in secrets.txt
```

**KUBE_CONFIG (Exception - Pre-encoded):**
```
Original kubeconfig (YAML)
  ↓ base64 -w 0 (done manually before adding to secrets.txt)
YXBpVmVyc2lvbjogdjEKY2x1c3RlcnM6...  ← Base64 stored in secrets.txt
```

### Layer 2: Transport Encoding (PROPAGATE_SECRETS)

```
Entire secrets.txt file (10,188 bytes)
  ↓ base64 -w0 (set-propagate-secrets.sh)
cm9wbzogQmVuZ28tSHViL2Rldm9wcy1rOGV...  ← 13,584 chars stored as PROPAGATE_SECRETS
```

**Why needed:**
- Preserves exact file format (newlines, special chars)
- Single-value secret (easier to manage than 25 separate secrets)
- Safe for GitHub Actions environment variable (no multiline issues)

### Layer 3: GitHub Encryption (Automatic)

```
Any secret value
  ↓ GitHub server-side encryption (automatic, transparent)
Encrypted blob (repository-specific encryption keys)
  ↓ ${{ secrets.SECRET_NAME }} in workflow (automatic decryption)
Original value returned to workflow
```

**Characteristics:**
- Happens automatically for ALL GitHub secrets
- Uses NaCl sealed boxes (Curve25519, XSalsa20-Poly1305)
- Audited access (GitHub knows when secrets are read)
- Redacted in logs (`***` shown instead of value)

### Layer 4: Workflow Usage Decoding

**Application Secrets (No Decode):**
```yaml
REGISTRY_PASSWORD: ${{ secrets.REGISTRY_PASSWORD }}
  ↓ GitHub decrypts
dckr_pat_****************************
  ↓ Use directly
echo "$REGISTRY_PASSWORD" | docker login --password-stdin
```

**Infrastructure Secrets (Decode Required):**
```yaml
KUBE_CONFIG_B64: ${{ secrets.KUBE_CONFIG }}
  ↓ GitHub decrypts
YXBpVmVyc2lvbjogdjEKY2x1c3RlcnM6...
  ↓ Workflow decodes
echo "$KUBE_CONFIG_B64" | base64 -d > ~/.kube/config
  ↓ Result
apiVersion: v1
clusters:
...
```

---

## Critical Secret Protection Logic

**Script:** `propagate-to-repo.sh` (lines 64-82)

```bash
CRITICAL_SECRETS=("KUBE_CONFIG" "CONTABO_API_PASSWORD" "CONTABO_CLIENT_SECRET")

for SECRET_NAME in "${SECRETS_TO_PROPAGATE[@]}"; do
  # Check if this is a critical secret that already exists
  if [[ " ${CRITICAL_SECRETS[*]} " =~ " ${SECRET_NAME} " ]]; then
    if gh secret list --repo "$TARGET_REPO" --json name -q '.[].name' 2>/dev/null | grep -q "^${SECRET_NAME}$"; then
      echo "[INFO] $SECRET_NAME is a critical secret and already exists in $TARGET_REPO - skipping to prevent overwrite"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
  fi
  
  # ... proceed with propagation if not critical or doesn't exist
done
```

**Purpose:**
- Infrastructure secrets (KUBE_CONFIG, Contabo credentials) are environment-specific
- Prevent auto-sync from overwriting manually-configured values
- Allow initial propagation but skip updates if already set

**Behavior:**
1. **First time (secret doesn't exist):** Propagate from PROPAGATE_SECRETS (may be wrong for environment)
2. **Subsequent runs (secret exists):** Skip propagation, preserve manually-updated value
3. **User fixes KUBE_CONFIG manually:** Updates stay protected from next auto-sync

**Why needed:**
- devops-k8s secrets.txt has ONE kubeconfig (from one cluster)
- Different environments may need different kubeconfigsdifferent environments may need different kubeconfigsdifferent environments may need different kubeconfigsdifferent environments may need different kubeconfigsdifferent environments may need different kubeconfigsdifferent environments may need different kubeconfigsdifferent environments may need different kubeconfigsdifferent environments may need different kubeconfigsdifferent environments may need different kubeconfigsdifferent environments may need different kubeconfigsdifferent environments may need different kubeconfigs
- Auto-sync would overwrite production kubeconfig with dev cluster config → deployment fails
- Protection allows manual override per repository

---

## Common Issues and Resolutions

### Issue 1: "unauthorized: incorrect username or password" (Docker login)

**Root Cause:**
- REGISTRY_PASSWORD in GitHub secret is old/incorrect
- PROPAGATE_SECRETS not updated after password change in source file

**Diagnosis:**
```bash
# Check local source
cat "D:/KubeSecrets/git-secrets/Bengo-Hub__devops-k8s/secrets.txt" | grep -A1 "REGISTRY_PASSWORD"
# Output: dckr_pat_**************************** (36 chars) ✓

# Test local login
echo "dckr_pat_****************************" | docker login -u codevertex --password-stdin
# Output: Login Succeeded ✓

# Check GitHub secret (in workflow logs)
echo "[DEBUG] REGISTRY_PASSWORD length: ${#REGISTRY_PASSWORD} chars"
# Output: 28 chars ✗ (different from source!)
```

**Resolution:**
1. Update PROPAGATE_SECRETS: `./set-propagate-secrets.sh` (re-reads source file)
2. Trigger propagate-secrets workflow (refreshes target repo secrets)
3. Or manually update: `gh secret set REGISTRY_PASSWORD --repo Bengo-Hub/isp-billing-backend --body "dckr_pat..."`

**Prevention:**
- Run `set-propagate-secrets.sh` whenever source file changes
- Automate PROPAGATE_SECRETS updates via scheduled workflow

---

### Issue 2: "Failed to connect to cluster. Check your KUBE_CONFIG"

**Root Cause:**
- KUBE_CONFIG value is for wrong cluster/environment
- Value is not base64-encoded
- Value is double base64-encoded (encoded twice by mistake)
- Value has line breaks (base64 with wrapping)

**Diagnosis:**
```bash
# Check secret length (should be ~5000-6000 chars for typical kubeconfig)
echo "[DEBUG] KUBE_CONFIG length: ${#KUBE_CONFIG_B64} chars"

# Try decode
echo "$KUBE_CONFIG_B64" | base64 -d | head -5
# Expected output:
# apiVersion: v1
# clusters:
# - cluster:
#     certificate-authority-data: LS0tLS...
#     server: https://77.237.232.66:6443

# If you see: "apiVersion: v1..." → Good (base64 decoded successfully)
# If you see: "YXBpVmVyc2lvbjogdjEK..." → Double encoded (decode again)
# If decode fails: "Invalid base64" → Not base64 or corrupted
```

**Resolution (User fixed this):**
```bash
# On Contabo VPS:
ssh root@77.237.232.66
cat /etc/kubernetes/admin.conf | base64 -w 0
# Copy output (will be ~5000 chars, no line breaks)

# Update GitHub secret:
gh secret set KUBE_CONFIG --repo Bengo-Hub/devops-k8s --body "YXBpVmVyc2lvbjo..."

# Or update local source and re-sync:
# 1. Edit D:/KubeSecrets/git-secrets/Bengo-Hub__devops-k8s/secrets.txt
# 2. Find KUBE_CONFIG section, replace value
# 3. Run: ./set-propagate-secrets.sh
# 4. Trigger propagate-secrets workflow
```

**User's Fix (confirmed working):**
> "i just update the kubeconfig with the base64 value from my contabo vps and now the workflow runs"

**What happened:**
- Old KUBE_CONFIG value was from different cluster or old certificate
- Fresh base64 from current VPS has correct cluster endpoint and valid certificates
- Workflow now decodes correctly and connects successfully

---

### Issue 3: Secret propagation times out

**Root Cause:**
- propagate-secrets workflow not triggering (dispatch accepted but workflow doesn't run)
- Possible causes: GH_PAT lacks `workflow` scope, workflow syntax errors, GitHub indexing delay

**Diagnosis:**
```bash
# Check workflow logs
gh run  --repo Bengo-Hub/devops-k8s

# Check GH_PAT scopes (needs: repo, workflow)
gh auth status
# Or check https://github.com/settings/tokens

# Manually trigger propagate-secrets workflow
gh workflow run propagate-secrets.yml \
  --repo Bengo-Hub/devops-k8s \
  -f target_repo="Bengo-Hub/isp-billing-backend" \
  -f secrets="REGISTRY_USERNAME,REGISTRY_PASSWORD,GIT_TOKEN"
```

**Resolution:**
- Verify GH_PAT has `workflow` scope
- Fix any workflow syntax errors (recent fix: removed invalid `secrets: write` permission)
- Use manual `workflow_dispatch` trigger for testing
- Check GitHub Actions tab for workflow runs

---

## Best Practices

### 1. Secret Source Management

**DO:**
- ✅ Keep master secrets file in secure location (D:/KubeSecrets/...)
- ✅ Use consistent format (YAML-like with `secret:` / `value:` pairs)
- ✅ Pre-encode KUBE_CONFIG as base64 before adding to file
- ✅ Document which secrets are base64 vs plain text
- ✅ Version control `.gitignore` to exclude secrets directory

**DON'T:**
- ❌ Store secrets file in git repository
- ❌ Mix encoding formats (e.g., some base64, some plain text for same secret type)
- ❌ Forget to update PROPAGATE_SECRETS after source file changes
- ❌ Share secrets file via insecure channels (email, Slack, etc.)

### 2. PROPAGATE_SECRETS Updates

**When to update:**
- Credential rotation (password change, token refresh)
- New cluster provisioned (new KUBE_CONFIG)
- New service added (new database password)
- Secret format change (base64 encoding added/removed)

**How to update:**
```bash
# 1. Edit local source file
vim "D:/KubeSecrets/git-secrets/Bengo-Hub__devops-k8s/secrets.txt"

# 2. Re-encode and set PROPAGATE_SECRETS
cd devops-k8s
./scripts/tools/set-propagate-secrets.sh

# 3. Verify update
gh secret list --repo Bengo-Hub/devops-k8s | grep PROPAGATE_SECRETS
# Check updated_at timestamp

# 4. Trigger propagation to target repos (optional - happens automatically on next sync request)
gh workflow run propagate-secrets.yml \
  --repo Bengo-Hub/devops-k8s \
  -f target_repo="Bengo-Hub/isp-billing-backend" \
  -f secrets="REGISTRY_PASSWORD"  # Only update changed secrets
```

### 3. Target Repo Secret Management

**Application Repos (Auto-Sync Enabled):**
- Secrets: REGISTRY_USERNAME, REGISTRY_PASSWORD, GIT_TOKEN, POSTGRES_PASSWORD, REDIS_PASSWORD
- Strategy: Always sync from PROPAGATE_SECRETS (single source of truth)
- Overwrite: OK (values should be consistent across repos)

**Infrastructure Repos (Protected Secrets):**
- Secrets: KUBE_CONFIG, CONTABO_API_PASSWORD, CONTABO_CLIENT_SECRET
- Strategy: Manual per-environment configuration
- Overwrite: BLOCKED (critical secrets protection)
- First-time setup: Propagate once, then protect

## Next Steps

### For New Service Repos

1. **Add auto-sync to build script:**
   ```bash
   # In build.sh or deploy script
   source <(curl -s https://raw.githubusercontent.com/Bengo-Hub/devops-k8s/main/scripts/tools/check-and-sync-secrets.sh)
   
   # Sync application secrets only
   if ! check_and_sync_secrets "REGISTRY_USERNAME" "REGISTRY_PASSWORD" "GIT_TOKEN"; then
     echo "ERROR: Failed to sync required secrets"
     exit 1
   fi
   ```

2. **Exclude infrastructure secrets from auto-sync:**
   - DO NOT include KUBE_CONFIG in auto-sync list
   - Set KUBE_CONFIG manually for target environment
   - Use critical secret protection

3. **Set environment-specific secrets manually:**
   ```bash
   # For each environment's cluster
   ssh environment-vps
   cat ~/.kube/config | base64 -w 0
   
   gh secret set KUBE_CONFIG --repo Bengo-Hub/service-name --body "YXBpVmVy..."
   ```

### For Existing Repos

1. **Audit current secrets:**
   ```bash
   gh secret list --repo Bengo-Hub/repo-name
   ```

2. **Identify mismatches:**
   - Compare lengths against source file
   - Test credentials (Docker login, database connection, etc.)

3. **Refresh stale secrets:**
   - Trigger auto-sync via build workflow
   - Or manually trigger propagate-secrets workflow
   - Or use `gh secret set` for individual updates

---

## Reference Commands

```bash
# View local source file
cat "D:/KubeSecrets/git-secrets/Bengo-Hub__devops-k8s/secrets.txt"

# Update PROPAGATE_SECRETS from source
cd devops-k8s
./scripts/tools/set-propagate-secrets.sh

# Check PROPAGATE_SECRETS status
gh secret list --repo Bengo-Hub/devops-k8s | grep PROPAGATE_SECRETS

# Manually propagate secrets to target repo
./scripts/tools/propagate-to-repo.sh Bengo-Hub/isp-billing-backend \
  REGISTRY_USERNAME REGISTRY_PASSWORD GIT_TOKEN POSTGRES_PASSWORD

# Trigger propagate workflow (remote dispatch method)
curl -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GH_PAT" \
  https://api.github.com/repos/Bengo-Hub/devops-k8s/dispatches \
  -d '{
    "event_type": "propagate-secrets",
    "client_payload": {
      "target_repo": "Bengo-Hub/isp-billing-backend",
      "secrets": ["REGISTRY_PASSWORD", "GIT_TOKEN"]
    }
  }'

# Manual workflow dispatch (for testing)
gh workflow run propagate-secrets.yml \
  --repo Bengo-Hub/devops-k8s \
  -f target_repo="Bengo-Hub/isp-billing-backend" \
  -f secrets="REGISTRY_USERNAME,REGISTRY_PASSWORD"

# Check secret in target repo
gh secret list --repo Bengo-Hub/isp-billing-backend | grep REGISTRY_PASSWORD

# Set secret manually (bypass propagation)
echo "dckr_pat_****************************" | \
  gh secret set REGISTRY_PASSWORD --repo Bengo-Hub/isp-billing-backend --body -

# Generate fresh KUBE_CONFIG from VPS
ssh root@77.237.232.66 'cat /etc/kubernetes/admin.conf | base64 -w 0'
# Then: gh secret set KUBE_CONFIG --repo ... --body "<output>"
```

---

## Conclusion

The secret propagation system uses **layered encoding** for different purposes:

1. **Source file:** Plain text EXCEPT KUBE_CONFIG (pre-encoded base64 for workflow convenience)
2. **PROPAGATE_SECRETS:** Entire file base64-encoded (transport/storage mechanism)
3. **GitHub secrets:** Encrypted by GitHub (automatic, transparent to workflows)
4. **Workflow usage:** Plain text for most secrets, base64 decoded for KUBE_CONFIG

**User's issue resolution:**
- KUBE_CONFIG was wrong value (old/different cluster)
- Updating with fresh base64 from Contabo VPS fixed provision workflow
- Workflows now decode correctly and connect to cluster

**Key insight:**
Setting KUBE_CONFIG at repo-level is OK as long as the VALUE is correct for that repository's target environment. The critical secret protection prevents auto-propagation from overwriting manually-configured environment-specific values.
