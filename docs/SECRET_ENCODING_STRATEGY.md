# Secret Encoding Strategy

**Last Updated:** February 7, 2026  
**Status:** Active - implemented in propagate-to-repo.sh and workflows

## Overview

This document defines which secrets are pre-encoded (base64) versus plain text, and how each type should be handled throughout the secret propagation pipeline.

---

## Secret Categories

### 1. Pre-Encoded Secrets (Base64)

These secrets are **already base64-encoded** in the source file and should **NOT be re-encoded** during propagation.

| Secret Name | Type | Source Format | Size | Usage Pattern |
|-------------|------|---------------|------|---------------|
| **KUBE_CONFIG** | Kubernetes config | base64 | ~7540 chars | Decode in workflow: `echo "$KUBE_CONFIG" \| base64 -d > ~/.kube/config` |
| **SSH_PRIVATE_KEY** | SSH key | base64 | ~620 chars | Decode in workflow: `echo "$SSH_PRIVATE_KEY" \| base64 -d > ~/.ssh/id_rsa` |
| **DOCKER_SSH_KEY** | SSH key | base64 | ~620 chars | Decode in workflow: `echo "$DOCKER_SSH_KEY" \| base64 -d > ~/.ssh/docker_key` |

**Why pre-encoded:**
- Multi-line content (YAML, PEM files) needs base64 for single-line GitHub secret storage
- Simplifies workflow usage (one decode step instead of multi-line handling)
- Follows industry standards (Kubernetes secrets, SSH keys typically base64-encoded)

**How generated:**
```bash
# KUBE_CONFIG
cat ~/.kube/config | base64 -w 0

# SSH_PRIVATE_KEY
cat ~/.ssh/id_rsa | base64 -w 0

# DOCKER_SSH_KEY
cat ~/.ssh/docker_key | base64 -w 0
```

### 2. Plain Text Secrets

These secrets are stored as **plain text** in the source file and propagated **as-is** (GitHub encrypts automatically).

| Secret Name | Type | Example Format | Usage Pattern |
|-------------|------|----------------|---------------|
| POSTGRES_PASSWORD | Password | `************` | Use directly: `psql -U postgres -p $POSTGRES_PASSWORD` |
| REDIS_PASSWORD | Password | `************` | Use directly: `redis-cli -a $REDIS_PASSWORD` |
| RABBITMQ_PASSWORD | Password | `************` | Use directly in connection string |
| REGISTRY_PASSWORD | Token | `dckr_pat_*****` | Use directly: `docker login -p $REGISTRY_PASSWORD` |
| REGISTRY_USERNAME | Username | `codevertex` | Use directly |
| GIT_TOKEN | Token | `ghp_*****` | Use directly in git auth |
| GIT_APP_SECRET | Secret | `************` | Use directly in OAuth |
| GOOGLE_CLIENT_SECRET | Secret | `************` | Use directly in Google API |
| CONTABO_API_PASSWORD | Password | `************` | Use directly in API calls |
| CONTABO_CLIENT_SECRET | Secret | `************` | Use directly in API calls |
| DEFAULT_TENANT_SLUG | String | `codevertex` | Use directly |
| GLOBAL_ADMIN_EMAIL | Email | `admin@example.com` | Use directly |
| All other secrets | Various | Plain text | Use directly |

**Why plain text:**
- Single-line values that don't need encoding
- Simpler workflow usage (no decode step)
- GitHub encrypts all secrets server-side regardless

---

## Propagation Flow

### Step 1: Source File Storage

**Location:** `D:/KubeSecrets/git-secrets/Bengo-Hub__devops-k8s/secrets.txt`

**Format:**
```yaml
repo: Bengo-Hub/devops-k8s
branch:
---
secret: POSTGRES_PASSWORD
value: ************
---
secret: KUBE_CONFIG
value: YXBpVmVyc2lvbjogdjEKY2x1c3RlcnM6Ci0gY2x1c3RlcjoKICAgIGNlcnRpZmljYX...
---
secret: SSH_PRIVATE_KEY
value: LS0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0KYjNCbGJuTnphQzFy...
---
```

**Storage rules:**
- Plain text secrets: Store raw value (passwords, tokens, emails, etc.)
- Base64 secrets: Store pre-encoded value (KUBE_CONFIG, SSH keys)
- Never mix formats (don't base64-encode passwords)

### Step 2: PROPAGATE_SECRETS Encoding

**Script:** `scripts/tools/set-propagate-secrets.sh`

**Process:**
```bash
# Encode ENTIRE file (plain text + pre-encoded secrets together)
base64 -w0 < secrets.txt | gh secret set PROPAGATE_SECRETS --repo Bengo-Hub/devops-k8s --body -
```

**Result:**
- Input: 10,188 bytes (mixed format file)
- Output: 13,584 chars (base64-encoded container)
- **Important:** This is NOT re-encoding individual secrets, just containerizing the file

### Step 3: Workflow Decode

**Workflow:** `.github/workflows/propagate-secrets.yml`

**Process:**
```yaml
- name: Prepare secrets file
  env:
    PROPAGATE_SECRETS: ${{ secrets.PROPAGATE_SECRETS }}
  run: |
    # Decode container (back to original mixed-format file)
    echo "${PROPAGATE_SECRETS}" | base64 -d > /tmp/propagate-secrets.txt
    # Result: Plain text passwords + base64 KUBE_CONFIG (as originally stored)
```

### Step 4: Secret Propagation

**Script:** `scripts/tools/propagate-to-repo.sh`

**Key logic:**
```bash
# Define which secrets are pre-encoded
BASE64_ENCODED_SECRETS=("KUBE_CONFIG" "SSH_PRIVATE_KEY" "DOCKER_SSH_KEY")

# Check secret type
IS_BASE64_ENCODED=false
if [[ " ${BASE64_ENCODED_SECRETS[*]} " =~ " ${SECRET_NAME} " ]]; then
  IS_BASE64_ENCODED=true
  echo "[DEBUG] $SECRET_NAME is pre-encoded (base64) - propagating as-is"
fi

# Set secret (NO re-encoding)
# - Plain text: Set as-is
# - Base64: Set as-is (workflow will decode)
echo -n "$VALUE" | gh secret set "$SECRET_NAME" --repo "$TARGET_REPO" --body -
```

**Critical rule:** **NEVER re-encode** - propagate values exactly as stored in source file

### Step 5: GitHub Storage

**GitHub Actions Secrets:**
- POSTGRES_PASSWORD: Encrypted(`************`)
- KUBE_CONFIG: Encrypted(`YXBpVmVyc2lvbjogdjEK...`) ← still base64 inside encryption
- SSH_PRIVATE_KEY: Encrypted(`LS0tLS1CRUdJTiBPUEVOU...`) ← still base64 inside encryption

**GitHub's layer:** Server-side encryption (transparent to workflows)

### Step 6: Workflow Usage

#### Plain Text Secrets (Direct Use)

```yaml
- name: Docker login
  env:
    REGISTRY_PASSWORD: ${{ secrets.REGISTRY_PASSWORD }}
  run: |
    # GitHub decrypts → plain text value
    echo "$REGISTRY_PASSWORD" | docker login -u codevertex --password-stdin
```

#### Base64 Secrets (Decode First)

```yaml
- name: Configure kubeconfig
  env:
    KUBE_CONFIG: ${{ secrets.KUBE_CONFIG }}
  run: |
    # GitHub decrypts → base64 string (still encoded)
    # Decode to get original YAML
    echo "$KUBE_CONFIG" | base64 -d > ~/.kube/config
    chmod 600 ~/.kube/config
```

```yaml
- name: Setup SSH key
  env:
    SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
  run: |
    mkdir -p ~/.ssh
    # Decode base64 to PEM format
    echo "$SSH_PRIVATE_KEY" | base64 -d > ~/.ssh/id_rsa
    chmod 600 ~/.ssh/id_rsa
```

---

## Common Mistakes to Avoid

### ❌ Don't: Re-encode Base64 Secrets

```bash
# WRONG - double encoding!
VALUE="${SECRETS_MAP[KUBE_CONFIG]}"  # Already base64
ENCODED=$(echo "$VALUE" | base64)    # Encoding again = WRONG
gh secret set KUBE_CONFIG --body "$ENCODED"

# Result: Workflow gets double-encoded garbage
echo "${{ secrets.KUBE_CONFIG }}" | base64 -d  # Decodes once → still base64 → fails
```

### ❌ Don't: Base64-encode Plain Text Secrets

```bash
# WRONG - unnecessary encoding!
VALUE="${SECRETS_MAP[POSTGRES_PASSWORD]}"  # Plain text: "Vertex2020!"
ENCODED=$(echo "$VALUE" | base64)          # Encoding = WRONG
gh secret set POSTGRES_PASSWORD --body "$ENCODED"

# Result: Workflow gets base64 instead of password
psql -p "${{ secrets.POSTGRES_PASSWORD }}"  # Gets "VmVydGV4MjAyMCEK" instead of "Vertex2020!"
```

### ✅ Do: Propagate Exactly As Stored

```bash
# CORRECT - no encoding, just pass through
VALUE="${SECRETS_MAP[$SECRET_NAME]}"
echo -n "$VALUE" | gh secret set "$SECRET_NAME" --repo "$TARGET_REPO" --body -

# Result:
# - Plain text secrets → workflows get plain text
# - Base64 secrets → workflows get base64 (decode when needed)
```

---

## Pull Secrets from Organization Level

### Current Approach (Propagation)

**Method:** Copy secrets from devops-k8s PROPAGATE_SECRETS to target repos

**Pros:**
- Single source of truth (devops-k8s secrets.txt)
- Auto-sync ensures consistency
- Easy bulk updates

**Cons:**
- Extra step (propagation delay)
- Repo-level storage (duplicated across repos)

### Alternative: Direct Org-Level Access

**Method:** Store secrets at organization level, reference directly in workflows

**Implementation:**
```yaml
# Instead of:
env:
  POSTGRES_PASSWORD: ${{ secrets.POSTGRES_PASSWORD }}  # Repo-level

# Use:
env:
  POSTGRES_PASSWORD: ${{ secrets.POSTGRES_PASSWORD }}  # Org-level (if repo doesn't have it)
```

**GitHub secret priority:**
1. Repository-level (highest)
2. Organization-level (fallback)
3. Environment-level (lowest)

**Recommendation:**
- **Application secrets** (POSTGRES_PASSWORD, REDIS_PASSWORD, REGISTRY_*): Organization-level
- **Infrastructure secrets** (KUBE_CONFIG, SSH keys): Repository-level (environment-specific)
- **Critical secrets** (CONTABO_*, Kubernetes): Manual per-environment

**Migration path:**
1. Set all application secrets at org-level
2. Remove repo-level duplicates (except environment-specific ones)
3. Keep propagation for initial setup only
4. Use org-level as primary source

---

## Encoding Detection Logic

### Automated Detection (Implemented)

**In propagate-to-repo.sh:**
```bash
# Define known base64-encoded secrets
BASE64_ENCODED_SECRETS=("KUBE_CONFIG" "SSH_PRIVATE_KEY" "DOCKER_SSH_KEY")

# Check if secret is in the list
if [[ " ${BASE64_ENCODED_SECRETS[*]} " =~ " ${SECRET_NAME} " ]]; then
  echo "[DEBUG] $SECRET_NAME is pre-encoded (base64) - propagating as-is"
else
  echo "[DEBUG] $SECRET_NAME is plain text - propagating as-is"
fi
```

### Heuristic Detection (Future Enhancement)

**Criteria for base64 detection:**
```bash
is_base64_encoded() {
  local value="$1"
  local length=${#value}
  
  # Heuristics:
  # 1. Length > 100 chars (multi-line content)
  # 2. Only contains base64 charset: [A-Za-z0-9+/=]
  # 3. Length is multiple of 4 (base64 padding rule)
  # 4. No special chars that typically appear in passwords
  
  if [[ $length -gt 100 ]] && 
     [[ "$value" =~ ^[A-Za-z0-9+/=]+$ ]] && 
     [[ $((length % 4)) -eq 0 ]]; then
    return 0  # Likely base64
  else
    return 1  # Likely plain text
  fi
}
```

**Note:** Explicit list (current approach) is more reliable than heuristics

---

## Updating Secret Encoding

### Adding a New Base64 Secret

**Steps:**
1. Generate and encode the secret:
   ```bash
   cat /path/to/multiline/file | base64 -w 0
   ```

2. Add to source file (`secrets.txt`):
   ```yaml
   secret: NEW_BASE64_SECRET
   value: <base64-output-from-step-1>
   ---
   ```

3. Update `propagate-to-repo.sh`:
   ```bash
   BASE64_ENCODED_SECRETS=("KUBE_CONFIG" "SSH_PRIVATE_KEY" "DOCKER_SSH_KEY" "NEW_BASE64_SECRET")
   ```

4. Update PROPAGATE_SECRETS:
   ```bash
   ./scripts/tools/set-propagate-secrets.sh
   ```

5. Propagate to target repos:
   ```bash
   ./scripts/tools/propagate-to-repo.sh Bengo-Hub/target-repo NEW_BASE64_SECRET
   ```

6. Update workflows to decode:
   ```yaml
   - name: Use new secret
     env:
       NEW_BASE64_SECRET: ${{ secrets.NEW_BASE64_SECRET }}
     run: |
       echo "$NEW_BASE64_SECRET" | base64 -d > /path/to/output
   ```

### Converting Plain Text to Base64

**When needed:**
- Secret becomes multi-line (e.g., certificate added)
- Need single-line format for GitHub secret

**Steps:**
1. Encode current value:
   ```bash
   echo "current-plain-text-value" | base64 -w 0
   ```

2. Update source file with encoded value

3. Add to BASE64_ENCODED_SECRETS list

4. Update workflows to include decode step

5. Re-propagate to all repos

### Converting Base64 to Plain Text

**When needed:**
- Secret becomes single-line
- Simplify workflow usage

**Steps:**
1. Decode current value:
   ```bash
   echo "current-base64-value" | base64 -d
   ```

2. Update source file with decoded value

3. Remove from BASE64_ENCODED_SECRETS list

4. Update workflows to remove decode step

5. Re-propagate to all repos

---

## Reference Commands

### Check Secret Encoding in Source File

```bash
# List all secrets with their lengths
grep -A1 '^secret:' D:/KubeSecrets/git-secrets/Bengo-Hub__devops-k8s/secrets.txt | \
  grep -E '^(secret|value):' | \
  paste - - | \
  awk '{print $2, "→ length:", length($4)}'
```

### Verify Secret Value

```bash
# Get secret from source file
SECRET_NAME="KUBE_CONFIG"
awk -v name="$SECRET_NAME" '
  /^secret:/ { if ($2 == name) found=1; next }
  /^value:/ && found { sub(/^value: /, ""); print; found=0 }
' D:/KubeSecrets/git-secrets/Bengo-Hub__devops-k8s/secrets.txt
```

### Test Base64 Decode

```bash
# Try decoding a value
VALUE="YXBpVmVyc2lvbjogdjEK..."
if echo "$VALUE" | base64 -d >/dev/null 2>&1; then
  echo "Valid base64"
  echo "$VALUE" | base64 -d | head -5
else
  echo "Not base64 or corrupted"
fi
```

### Check Secret in GitHub

```bash
# Check if secret exists
gh secret list --repo Bengo-Hub/repo-name | grep SECRET_NAME

# Check secret metadata (length, updated date)
gh api repos/Bengo-Hub/repo-name/actions/secrets/SECRET_NAME

# Check org-level secret
gh api orgs/Bengo-Hub/actions/secrets/SECRET_NAME
```

---

## Troubleshooting

### Issue: Workflow fails with "Invalid base64"

**Diagnosis:**
```bash
# In workflow
echo "[DEBUG] KUBE_CONFIG length: ${#KUBE_CONFIG}"
echo "[DEBUG] First 50 chars: ${KUBE_CONFIG:0:50}"
if ! echo "$KUBE_CONFIG" | base64 -d >/dev/null 2>&1; then
  echo "ERROR: Not valid base64"
fi
```

**Possible causes:**
1. Secret was double-encoded during propagation
2. Secret contains line breaks (use `tr -d '[:space:]'` to clean)
3. Secret was corrupted during copy/paste

**Resolution:**
1. Re-fetch from source file
2. Verify base64 validity locally: `echo "$value" | base64 -d`
3. Re-propagate to GitHub

### Issue: Docker login fails with"unauthorized"

**Diagnosis:**
```bash
# In workflow
echo "[DEBUG] REGISTRY_PASSWORD length: ${#REGISTRY_PASSWORD}"
echo "[DEBUG] First char: ${REGISTRY_PASSWORD:0:1}"
echo "[DEBUG] Last char: ${REGISTRY_PASSWORD: -1}"

# Test login
echo "$REGISTRY_PASSWORD" | docker login -u "$REGISTRY_USERNAME" --password-stdin
```

**Possible causes:**
1. Password was base64-encoded (should be plain text)
2. Password has trailing newline
3. Password is from wrong source

**Resolution:**
1. Check source file: `grep -A1 'REGISTRY_PASSWORD' secrets.txt`
2. Verify plain text: Should be `dckr_pat_...` (36 chars)
3. Re-propagate: `./propagate-to-repo.sh Bengo-Hub/repo REGISTRY_PASSWORD`

### Issue: Kubernetes deployment fails with "Unable to connect to cluster"

**Diagnosis:**
```bash
# In workflow
CLEAN=$(echo "$KUBE_CONFIG" | tr -d '[:space:]')
echo "[DEBUG] Cleaned length: ${#CLEAN}"

# Try decode
if echo "$CLEAN" | base64 -d > /tmp/kubeconfig.yaml; then
  echo "[DEBUG] Decoded successfully"
  head -5 /tmp/kubeconfig.yaml
else
  echo "ERROR: Decode failed"
fi

# Check cluster endpoint
grep 'server:' /tmp/kubeconfig.yaml
```

**Possible causes:**
1. KUBE_CONFIG from wrong cluster
2. Certificates expired
3. Double-encoded

**Resolution:**
1. Get fresh kubeconfig from VPS: `cat ~/.kube/config | base64 -w 0`
2. Update GitHub secret directly: `gh secret set KUBE_CONFIG --repo ... --body "..."`
3. Re-run workflow

---

## Summary

**Golden Rules:**
1. **Identify encoding at source** - know which secrets are base64 vs plain text
2. **Propagate as-is** - never re-encode, never decode during propagation
3. **Decode only in workflows** - workflows handle decoding base64 secrets when needed
4. **Document explicitly** - maintain BASE64_ENCODED_SECRETS list
5. **Test locally first** - verify encoding/decoding before pushing to GitHub

**Secret lifecycle:**
- Source file (mixed format) → PROPAGATE_SECRETS (container) → GitHub (encrypted) → Workflow (decrypt + decode if base64)
- Each step preserves original format until final workflow usage
