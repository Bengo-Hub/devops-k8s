GitHub Secrets
--------------

Organization-level (recommended):
- REGISTRY_USERNAME: Docker Hub username (default: codevertex)
- REGISTRY_PASSWORD: Docker Hub token/password (required for authenticated pulls)
- REGISTRY_EMAIL: Docker Hub email (default: info@codevertexitsolutions.com)
- KUBE_CONFIG: base64-encoded kubeconfig with apply permissions (for K8s deploy)
- SSH_PRIVATE_KEY: SSH key for VPS deployments over SSH (optional for K8s)
- DOCKER_SSH_KEY: base64 private key for docker build ssh forwarding (optional)
- SSH_HOST: VPS IP address (Priority 1 - takes precedence over Contabo API)
- SSH_USER: SSH username for VPS access (optional, defaults to root)
- GIT_USER: Git commit author name (optional, for Git operations)
- GIT_EMAIL: Git commit author email (optional, for Git operations)

Contabo API (optional, enables automated VPS management):
- CONTABO_CLIENT_ID: OAuth2 client id
- CONTABO_CLIENT_SECRET: OAuth2 client secret
- CONTABO_API_USERNAME: Contabo account username
- CONTABO_API_PASSWORD: Contabo account password
- CONTABO_INSTANCE_ID: Contabo VPS instance ID (e.g., 14285715)
  - Found in Contabo control panel → Your instance → Details
  - Default: 14285715 (if not set)

**VPS IP Priority (for provisioning workflow):**
1. **SSH_HOST** secret (highest priority - if set, used directly)
2. Contabo API lookup (if Contabo credentials configured)
3. Manual configuration required (if neither available)

**Note:** Contabo API enables:
- Automatic VPS IP lookup
- VPS status checking
- VPS start/stop operations

**How to Get Contabo API Credentials:**
1. Login to https://my.contabo.com
2. Navigate to Account > Security
3. Create OAuth2 Client:
   - Click "Create OAuth2 Client"
   - Note down `Client ID` and `Client Secret`
4. Use your Contabo account username and password for API authentication
5. Find your VPS instance ID in Contabo control panel → Your instance → Details

Database automation (optional; auto-generated if omitted):
- POSTGRES_PASSWORD: PostgreSQL superuser password
- POSTGRES_ADMIN_PASSWORD: PostgreSQL admin_user password (for per-service DB management)
- REDIS_PASSWORD: Redis password
- MONGO_PASSWORD: MongoDB root password
- MYSQL_PASSWORD: MySQL root password

Infrastructure configuration (optional; defaults shown):
- SSH_HOST: VPS IP address (Priority 1 - takes precedence over Contabo API)
  - Alternative to Contabo API for VPS IP
  - If set, Contabo API lookup is skipped
- ARGOCD_DOMAIN: ArgoCD domain (default: argocd.masterspace.co.ke)
- GRAFANA_DOMAIN: Grafana domain (default: grafana.masterspace.co.ke)
- DB_NAMESPACE: Namespace for shared databases (default: infra)
- MONITORING_NAMESPACE: Namespace for monitoring stack (default: infra)
- RABBITMQ_NAMESPACE: Namespace for RabbitMQ (default: infra)
- RABBITMQ_PASSWORD: RabbitMQ password (default: rabbitmq)

Cleanup (opt-in only):
- ENABLE_CLEANUP: Set to 'true' to enable cluster cleanup (default: false, NEVER runs by default)

Contact emails:
- Org email: codevertexitsolutions@gmail.com
- Business email: info@codevertexitsolutions.com
Website: https://www.codevertexitsolutions.com

**Repository-level secrets (for application deployment workflows):**
- `GH_PAT`: GitHub Personal Access Token for cross-repo Git operations
  - Used by application workflows to clone/push to devops-k8s repository
  - Required for updating Helm values in devops-k8s repo from application repos
  - Scope: `repo` (full control)
- `DEVOPS_K8S_ACCESS_TOKEN`: Alternative name for GitHub PAT (same as GH_PAT)
  - Used interchangeably with GH_PAT in some workflows
  - Provides access to devops-k8s repository for Git operations

**Note:** These repository secrets are used by application deployment workflows (erp-api, erp-ui, etc.) to update Helm values in the devops-k8s repository. The provision.yml workflow runs in devops-k8s repo and doesn't require these tokens.

Per-repo overrides are supported by defining the same secrets at the repository level.

---

## Related Documentation

**⚠️ IMPORTANT: Setup Order**
1. **[Access Setup](comprehensive-access-setup.md)** 🔐 - Manual access configuration (SSH, GitHub PAT, Contabo API)
2. **[Cluster Setup Workflow](CLUSTER-SETUP-WORKFLOW.md)** ⚙️ - Complete automated cluster setup (generates kubeconfig)
3. **Kubeconfig Setup (THIS DOCUMENT)** 🔐 - Extract and store kubeconfig (happens AFTER cluster setup)
4. **[Provisioning](provisioning.md)** 🚀 - Infrastructure provisioning

**Reference:**
- **[Quick Start](../SETUP.md)** - Fast-track setup guide
- **[Kubernetes Setup](contabo-setup-kubeadm.md)** 📘 - Detailed cluster setup

---

## Complete Setup Guide

**⚠️ IMPORTANT: Setup Order**
1. Complete **Access Setup** (see `docs/comprehensive-access-setup.md`)
2. Complete **Cluster Setup** (see `docs/CLUSTER-SETUP-WORKFLOW.md`) - This generates kubeconfig
3. **Extract Kubeconfig** (THIS SECTION - happens AFTER cluster setup)
4. Store kubeconfig in GitHub secrets
5. Run **Provisioning** (see `docs/provisioning.md`)

After configuring Kubernetes cluster (see `docs/CLUSTER-SETUP-WORKFLOW.md` and `docs/contabo-setup-kubeadm.md`), follow these steps:

### 1. Get Kubeconfig

**On your VPS:**

```bash
# Update kubeconfig with public IP
VPS_IP="YOUR_VPS_IP"
sed -i "s|server: https://.*:6443|server: https://${VPS_IP}:6443|" $HOME/.kube/config

# Get base64-encoded kubeconfig (MUST be single line, no breaks)
cat $HOME/.kube/config | base64 -w 0 2>/dev/null || cat $HOME/.kube/config | base64 | tr -d '\n'
```

**⚠️ IMPORTANT:** 
- Copy the **ENTIRE** base64 output (it's all on one line)
- Make sure there are **NO line breaks** or spaces in the secret
- The output should be one continuous string of characters
- If GitHub adds line breaks when pasting, remove them manually

### 2. Configure GitHub Secrets

Go to GitHub → Settings → Secrets and variables → Actions (Organization or Repository level)

**Required Secrets:**

1. **KUBE_CONFIG** (Required)
   - Value: The base64-encoded kubeconfig from above
   - Copy the entire base64 output

**Optional Secrets (with defaults):**

2. **SSH_HOST** (Optional - Priority 1)
   - Value: Your VPS IP address (e.g., `77.237.232.66`)
   - **Priority:** If set, this takes precedence over Contabo API lookup

3. **SSH_PRIVATE_KEY** (Optional)
   - **Value:** Base64-encoded SSH private key content (entire key including BEGIN/END lines)
   - **Purpose:** SSH access to VPS for deployment operations
   - **How to generate and set up:**
     
     **Step 1: Generate SSH Key Pair**
     ```bash
     # Linux/Mac
     ssh-keygen -t ed25519 -C "devops@codevertex" -f ~/.ssh/contabo_deploy_key -N "codevertex"
     ```
     ```powershell
     # Windows PowerShell
     ssh-keygen -t ed25519 -C "devops@codevertex" -f $env:USERPROFILE\.ssh\contabo_deploy_key -N "codevertex"
     ```
     
     **Step 2: Add Public Key to Contabo VPS**
     - Copy public key: `cat ~/.ssh/contabo_deploy_key.pub` (Linux/Mac) or `Get-Content $env:USERPROFILE\.ssh\contabo_deploy_key.pub` (Windows)
     - Add to Contabo Control Panel → Access → SSH Keys
     - **Important:** Use the PUBLIC key (`.pub` file), not the private key
     
     **Step 3: Base64 Encode Private Key**
     ```bash
     # Linux/Mac
     cat ~/.ssh/contabo_deploy_key | base64 -w 0
     ```
     ```powershell
     # Windows PowerShell
     $key = Get-Content $env:USERPROFILE\.ssh\contabo_deploy_key -Raw
     [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($key))
     ```
     
     **Step 4: Add to GitHub Secrets**
     - Copy the base64 output
     - Add as organization secret: `SSH_PRIVATE_KEY`
   
   - **Important:** 
     - ✅ Use **private key** for GitHub secrets (base64-encoded)
     - ✅ Use **public key** for Contabo VPS
     - ❌ Never commit private keys to repositories

4. **DOCKER_SSH_KEY** (Optional)
   - **Value:** Base64-encoded SSH private key content (same key as SSH_PRIVATE_KEY recommended)
   - **Purpose:** Docker builds accessing private GitHub repositories and Git operations
   - **How to set up:**
     
     **Option A: Use Same Key as SSH_PRIVATE_KEY (Recommended)**
     - Use the same base64-encoded private key from `SSH_PRIVATE_KEY`
     - Add public key to GitHub repository as Deploy Key:
       - Repository → Settings → Deploy keys → Add deploy key
       - Paste public key content (from `.pub` file)
       - ✅ Check "Allow write access" (required for git push)
     
     **Option B: Generate Separate Key**
     ```bash
     # Linux/Mac
     ssh-keygen -t ed25519 -C "devops-docker@codevertex" -f ~/.ssh/docker_build_key -N "codevertex"
     cat ~/.ssh/docker_build_key | base64 -w 0
     ```
     ```powershell
     # Windows PowerShell
     ssh-keygen -t ed25519 -C "devops-docker@codevertex" -f $env:USERPROFILE\.ssh\docker_build_key -N "codevertex"
     $key = Get-Content $env:USERPROFILE\.ssh\docker_build_key -Raw
     [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($key))
     ```
   
   - **Fallback:** If `DOCKER_SSH_KEY` is not set, workflows will use `SSH_PRIVATE_KEY`

**Contabo API Secrets (Optional - Priority 2):**

4. **CONTABO_CLIENT_ID** (Optional)
   - Value: Contabo OAuth2 client ID
   - Enables automated VPS IP lookup and status management

5. **CONTABO_CLIENT_SECRET** (Optional)
   - Value: Contabo OAuth2 client secret

6. **CONTABO_API_USERNAME** (Optional)
   - Value: Your Contabo account username

7. **CONTABO_API_PASSWORD** (Optional)
   - Value: Your Contabo account password

8. **CONTABO_INSTANCE_ID** (Optional)
   - Value: Your Contabo VPS instance ID (e.g., `14285715`)
   - Found in Contabo control panel → Your instance → Details
   - Default: `14285715` (if not set)

**Priority Order for VPS IP:**
1. `SSH_HOST` secret (if set)
2. Contabo API lookup (if credentials configured)
3. Manual configuration required (if neither available)

### 3. Next Steps

After configuring secrets:

1. **Run Automated Provisioning:** See `SETUP.md` for workflow execution
2. **Configure DNS:** Point domains to your VPS IP (see `SETUP.md`)
3. **Deploy Applications:** Applications deploy automatically via Argo CD

**See:** `docs/contabo-setup-kubeadm.md` for complete Kubernetes cluster setup guide

---

## Secrets Management: Environment Variables vs Kubernetes Secrets

### 🎯 Critical Concept: Two Distinct Phases

**Phase 1: Infrastructure Provisioning (devops-k8s)**
- **When:** Setting up the cluster infrastructure (databases, monitoring, etc.)
- **Who:** DevOps team or initial setup
- **Where:** `devops-k8s/scripts/infrastructure/install-databases.sh`
- **Process:** Environment Variables → CREATE Kubernetes Secrets

```bash
# Environment variables are used to SET passwords during installation
export POSTGRES_PASSWORD="************"
export REDIS_PASSWORD="************"

# These create Kubernetes secrets:
# - postgresql secret (with postgres-password key)
# - redis secret (with redis-password key)

./scripts/infrastructure/install-databases.sh
```

**Phase 2: Application Deployment (bengobox-erp-api/ui)**
- **When:** Every code push / CI/CD deployment
- **Who:** Automated via GitHub Actions
- **Where:** `BengoERP/bengobox-erp-api/build.sh`
- **Process:** Kubernetes Secrets → READ for Application Config

```bash
# Application retrieves passwords from existing K8s secrets
# (These are the SOURCE OF TRUTH matching the actual databases)

./scripts/setup_env_secrets.sh
# ↓
# Reads: kubectl get secret postgresql -n infra
# Reads: kubectl get secret redis -n infra
# ↓
# Creates: erp-api-env secret with correct passwords
```

### 🔑 Password Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│  Phase 1: Infrastructure Provisioning (ONE TIME)                │
└─────────────────────────────────────────────────────────────────┘

GitHub Secrets              devops-k8s                Kubernetes
     │                           │                         │
     │ POSTGRES_PASSWORD         │                         │
     ├──────────────────────────►│ install-databases.sh    │
     │                            │ (infrastructure/)      │
     │ REDIS_PASSWORD             │         │              │
     │                            │         ▼              │
     │                            │    helm install         │
     │                            │    postgresql           │
     │                            │    --set password=...   │
     │                            │         │              │
     │                            │         ├──────────────►│
     │                            │         │              │ Creates:
     │                            │         │              │ - postgresql secret
     │                            │         │              │ - redis secret
     │                            │    [PASSWORDS NOW      │
     │                            │     STORED IN K8S]     │

┌─────────────────────────────────────────────────────────────────┐
│  Phase 2: Application Deployment (EVERY PUSH)                   │
└─────────────────────────────────────────────────────────────────┘

GitHub Actions              bengobox-erp-api          Kubernetes
     │                           │                         │
     │ (No password needed)      │                         │
     ├──────────────────────────►│ build.sh                │
     │ KUBE_CONFIG               │         │              │
     │                            │         ▼              │
     │                            │ setup_env_secrets.sh   │
     │                            │         │              │
     │                            │  kubectl get secret    │
     │                            │  postgresql -n infra  │
     │                            │         │              │
     │                            │         ◄──────────────┤
     │                            │         │              │ Returns:
     │                            │    [GOT PASSWORD]      │ postgres-password
     │                            │         │              │
     │                            │         ▼              │
     │                            │ Create erp-api-env     │
     │                            │ with retrieved         │
     │                            │ passwords              │
     │                            │         ├──────────────►│
     │                            │                         │ Creates:
     │                            │                         │ - erp-api-env secret
     │                            │                         │   (with DB passwords)
```

### 📋 Why This Matters

**❌ Wrong Approach (What We Fixed):**
```bash
# CI/CD tries to use GitHub secret POSTGRES_PASSWORD
# But this might not match the actual database password!
# Result: Password authentication failed
```

**✅ Correct Approach (Current):**
```bash
# CI/CD retrieves password from postgresql Kubernetes secret
# This is GUARANTEED to match the actual database
# Result: Authentication succeeds
```

### 🔧 Implementation Details

**Infrastructure Scripts (devops-k8s):**
- **File:** `scripts/infrastructure/install-databases.sh`
- **Purpose:** Allow ops team to set passwords OR let Helm generate them
- Environment variables are used to CREATE databases

**Application Scripts (bengobox-erp-api):**
- **File:** `scripts/setup_env_secrets.sh`
- **Purpose:** Ensure app uses correct password matching actual database
- ALWAYS retrieve from Kubernetes (source of truth)

### 🔍 Debugging Password Issues

**Check What Password is Stored:**
```bash
# Get PostgreSQL admin_user password from Kubernetes (recommended)
kubectl get secret postgresql -n infra \
  -o jsonpath='{.data.admin-user-password}' | base64 -d

# Get PostgreSQL postgres superuser password (if needed)
kubectl get secret postgresql -n infra \
  -o jsonpath='{.data.postgres-password}' | base64 -d

# Get Redis password
kubectl get secret redis -n infra \
  -o jsonpath='{.data.redis-password}' | base64 -d
```

**Check What App is Using:**
```bash
# Get password from app secret
kubectl get secret erp-api-env -n erp \
  -o jsonpath='{.data.DB_PASSWORD}' | base64 -d

# These MUST match!
```

### 🛠️ Troubleshooting

**Issue: "password authentication failed"**

**Diagnosis:**
```bash
# Compare passwords (using admin_user - recommended)
PG_SECRET=$(kubectl get secret postgresql -n infra -o jsonpath='{.data.admin-user-password}' | base64 -d)
APP_SECRET=$(kubectl get secret erp-api-env -n erp -o jsonpath='{.data.DB_PASSWORD}' | base64 -d)

if [[ "$PG_SECRET" == "$APP_SECRET" ]]; then
  echo "✓ Passwords match"
else
  echo "✗ PASSWORD MISMATCH!"
  echo "Database has: $PG_SECRET"
  echo "App is using: $APP_SECRET"
fi
```

**Fix:**
```bash
# Re-run setup_env_secrets.sh to sync passwords
cd BengoERP/bengobox-erp-api
export NAMESPACE=erp
export PG_DATABASE=bengo_erp
export ENV_SECRET_NAME=erp-api-env
./scripts/setup_env_secrets.sh
```

### 📊 Secret Lifecycle

**1. Initial Setup (devops-k8s):**
```bash
# Run once during cluster provisioning
export POSTGRES_PASSWORD="************"
export REDIS_PASSWORD="************"
./scripts/infrastructure/install-databases.sh

# Creates:
# - postgresql secret (source of truth)
# - redis secret (source of truth)
```

**2. Application Deployment (build.sh):**
```bash
# Runs on every git push
# NO password env vars needed
./build.sh

# Process:
# 1. Reads postgresql/redis secrets
# 2. Creates erp-api-env secret with those passwords
# 3. Migrations use erp-api-env (which has correct passwords)
```

**3. Password Rotation (when needed):**
```bash
# Step 1: Update admin_user password (recommended for service database management)
kubectl patch secret postgresql -n infra \
  -p '{"stringData":{"admin-user-password":"NewPassword123!"}}'

# Step 2: Update database itself (admin_user)
kubectl exec -it postgresql-0 -n infra -- \
  env PGPASSWORD="old-password" \
  psql -U admin_user -d postgres -c "ALTER USER admin_user PASSWORD 'NewPassword123!';"

# Or update postgres superuser password (if needed)
kubectl patch secret postgresql -n infra \
  -p '{"stringData":{"postgres-password":"NewPassword123!"}}'

kubectl exec -it postgresql-0 -n infra -- \
  env PGPASSWORD="old-password" \
  psql -U postgres -c "ALTER USER postgres PASSWORD 'NewPassword123!';"

# Step 3: Redeploy app (will auto-sync new password)
git push  # Triggers build.sh → setup_env_secrets.sh → retrieves new password
```

### ✅ Best Practices

**DO:**
- ✅ Use GitHub secrets for infrastructure provisioning passwords
- ✅ Let applications retrieve passwords from Kubernetes
- ✅ Keep database secrets as the source of truth
- ✅ Test password retrieval before deployments

**DON'T:**
- ❌ Put database passwords in application GitHub secrets
- ❌ Hardcode passwords in code or manifests
- ❌ Use env var passwords for existing databases
- ❌ Assume GitHub secret matches K8s secret

### 🔐 Security Notes

**Why Kubernetes Secrets are Source of Truth:**
1. **Single Source** - Database password exists in ONE place
2. **Consistency** - App password MUST match database password
3. **Rotation** - Changing K8s secret automatically updates apps
4. **Audit Trail** - K8s secret changes are logged

**When to Use GitHub Secrets:**
- ✅ Initial database provisioning
- ✅ Registry credentials
- ✅ Git access tokens
- ✅ API keys for external services
- ✅ KUBE_CONFIG for cluster access

**When to Use Kubernetes Secrets:**
- ✅ Database passwords (after provisioning)
- ✅ Service-to-service credentials
- ✅ Application runtime config
- ✅ Dynamic values that change


