# Helm Scripts Directory

Centralized, reusable scripts for Kubernetes Helm deployment management.

## Contents

### `update-values.sh`

**Purpose:** Standardized script for updating image tags in devops-k8s repository values.yaml files.

**Why:** Eliminates 400+ lines of duplicated code across 16 service build.sh scripts.

**Usage:**

```bash
# As a function (source from build.sh)
source ~/devops-k8s/scripts/helm/update-values.sh
update_helm_values "ordering-backend" "fb45a308" "docker.io/codevertex/ordering-backend"

# As CLI
~/devops-k8s/scripts/helm/update-values.sh \
    --app ordering-backend \
    --tag fb45a308 \
    --repo docker.io/codevertex/ordering-backend
```

**Features:**
- ✅ Token resolution (GH_PAT, GIT_SECRET, GITHUB_TOKEN)
- ✅ Git operations (clone, fetch, checkout, reset)
- ✅ Safe environment variable substitution (strenv)
- ✅ Validation and error handling
- ✅ Clear, consistent logging
- ✅ Flexible configuration via environment variables

**Configuration:**

| Variable | Default | Purpose |
|----------|---------|---------|
| GH_PAT | - | GitHub Personal Access Token (preferred) |
| GIT_SECRET | - | Alternative GitHub token |
| GITHUB_TOKEN | - | GitHub Actions token |
| DEVOPS_REPO | Bengo-Hub/devops-k8s | Target repository |
| DEVOPS_DIR | $HOME/devops-k8s | Local directory |
| GIT_EMAIL | dev@bengobox.com | Commit email |
| GIT_USER | BengoBox Bot | Commit author |

---

## Integration Guide

### For Service Build Scripts

Replace this (23 lines):
```bash
# Old way
TOKEN="${GH_PAT:-${GIT_SECRET:-${GITHUB_TOKEN:-}}}"
CLONE_URL="https://github.com/${DEVOPS_REPO}.git"
[[ -n $TOKEN ]] && CLONE_URL="https://x-access-token:${TOKEN}@github.com/${DEVOPS_REPO}.git"

if [[ ! -d $DEVOPS_DIR ]]; then
  git clone "$CLONE_URL" "$DEVOPS_DIR" || { warn "Unable to clone devops repo"; DEVOPS_DIR=""; }
fi

if [[ -n $DEVOPS_DIR && -d $DEVOPS_DIR ]]; then
  pushd "$DEVOPS_DIR" >/dev/null || true
  git config user.email "$GIT_EMAIL"
  git config user.name "$GIT_USER"
  git fetch origin main || true
  git checkout main || git checkout -b main || true
  git reset --hard origin/main || true
  if [[ -f "$VALUES_FILE_PATH" ]]; then
    IMAGE_REPO_ENV="$IMAGE_REPO" IMAGE_TAG_ENV="$GIT_COMMIT_ID" \
      yq e -i '.image.repository = strenv(IMAGE_REPO_ENV) | .image.tag = strenv(IMAGE_TAG_ENV)' "$VALUES_FILE_PATH"
    git add "$VALUES_FILE_PATH"
    git commit -m "${APP_NAME}:${GIT_COMMIT_ID} released" || true
    [[ -n $TOKEN ]] && git push origin HEAD:main || warn "Skipped pushing values (no token)"
  else
    warn "${VALUES_FILE_PATH} not found in devops repo"
  fi
  popd >/dev/null || true
fi
```

With this (2 lines):
```bash
# New way
source "${HOME}/devops-k8s/scripts/helm/update-values.sh"
update_helm_values "$APP_NAME" "$GIT_COMMIT_ID" "$IMAGE_REPO"
```

---

## Examples

### Example 1: Basic Usage

```bash
#!/bin/bash
set -euo pipefail

APP_NAME="ordering-backend"
IMAGE_REPO="docker.io/codevertex/ordering-backend"
GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD)

# Source the script
source "${HOME}/devops-k8s/scripts/helm/update-values.sh"

# ... docker build and push ...

# Update Helm values
update_helm_values "$APP_NAME" "$GIT_COMMIT_ID" "$IMAGE_REPO"
```

### Example 2: With Error Handling

```bash
#!/bin/bash
set -euo pipefail

# Source with fallback
source "${HOME}/devops-k8s/scripts/helm/update-values.sh" 2>/dev/null || {
    echo "[WARN] update-values.sh not found, skipping helm update"
    exit 0
}

# ... docker operations ...

# Update with error check
if ! update_helm_values "$APP_NAME" "$GIT_COMMIT_ID" "$IMAGE_REPO"; then
    echo "[ERROR] Failed to update Helm values"
    exit 1
fi
```

### Example 3: Manual CLI Usage

```bash
# Update only tag
~/devops-k8s/scripts/helm/update-values.sh \
    --app ordering-backend \
    --tag fb45a308

# Update tag with custom repo
~/devops-k8s/scripts/helm/update-values.sh \
    --app ordering-backend \
    --tag fb45a308 \
    --repo docker.io/codevertex/ordering-backend

# With environment variables
export GIT_EMAIL="deploy@mycompany.com"
export GIT_USER="CI/CD Bot"
~/devops-k8s/scripts/helm/update-values.sh \
    --app ordering-backend \
    --tag fb45a308
```

### Example 4: GitHub Actions

```yaml
name: Build and Deploy
on:
  push:
    branches: [ main ]

jobs:
  deploy:
    runs-on: ubuntu-latest
    
    steps:
      - uses: actions/checkout@v4
      
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3
      
      - name: Build and push image
        run: |
          docker build -t docker.io/codevertex/ordering-backend:${{ github.sha }} .
          docker push docker.io/codevertex/ordering-backend:${{ github.sha }}
      
      - name: Clone devops-k8s
        env:
          GH_PAT: ${{ secrets.GH_PAT }}
        run: |
          git clone https://x-access-token:${GH_PAT}@github.com/Bengo-Hub/devops-k8s.git ~/devops-k8s
      
      - name: Update Helm values
        env:
          GH_PAT: ${{ secrets.GH_PAT }}
        run: |
          ~/devops-k8s/scripts/helm/update-values.sh \
              --app ordering-backend \
              --tag ${GITHUB_SHA:0:8} \
              --repo docker.io/codevertex/ordering-backend
```

---

## Troubleshooting

### Script not found
```bash
# Error: source: no such file or directory: ~/devops-k8s/scripts/helm/update-values.sh
# Fix: Clone devops-k8s repo
git clone https://github.com/Bengo-Hub/devops-k8s.git ~/devops-k8s
```

### yq not installed
```bash
# Error: yq: command not found
# Fix: Install yq
brew install yq          # macOS
apt-get install yq       # Ubuntu/Debian
choco install yq         # Windows (Chocolatey)
```

### Git push fails
```bash
# Error: Failed to push changes - check token permissions
# Fix: Set GitHub token
export GH_PAT="ghp_xxxxx..."  # Full repo access
# Or use another token type:
export GIT_SECRET="..."
export GITHUB_SECRET="..."
```

### Token not detected
```bash
# Warning: No GitHub token (GH_PAT/GIT_SECRET/GITHUB_TOKEN/GITHUB_SECRET) available
# Fix: Set at least one token variable
export GH_PAT="ghp_..."
# Or in CI/CD, add to repository secrets
# GitHub Actions → Settings → Secrets and variables → Repository secrets
```

---

## Documentation

For more information, see:

- [HELM-VALUES-QUICK-REFERENCE.md](../HELM-VALUES-QUICK-REFERENCE.md) - Quick reference guide
- [CENTRALIZED-HELM-VALUES-UPDATE.md](../CENTRALIZED-HELM-VALUES-UPDATE.md) - Detailed usage guide
- [HELM-VALUES-BEFORE-AFTER.md](../HELM-VALUES-BEFORE-AFTER.md) - Before/after comparison
- [../AUDIT-IMAGE-TAG-AUTOMATION.md](../AUDIT-IMAGE-TAG-AUTOMATION.md) - Audit of all services

---

## Benefits

✅ **Eliminates 400+ lines of duplicated code**  
✅ **Single source of truth for Helm updates**  
✅ **Consistent error handling and logging**  
✅ **Safe environment variable substitution**  
✅ **Works with all CI/CD systems**  
✅ **Backwards compatible**  

---

## Contributing

When updating `update-values.sh`:
1. Test with `--help` flag
2. Test as function in build.sh context
3. Test with different token types
4. Verify error messages are clear
5. Update documentation if needed
