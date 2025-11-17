# Secrets Management - Environment Variables vs Kubernetes Secrets

## 🎯 Critical Concept: Two Distinct Phases

### Phase 1: Infrastructure Provisioning (devops-k8s)
**When:** Setting up the cluster infrastructure (databases, monitoring, etc.)  
**Who:** DevOps team or initial setup  
**Where:** `devops-k8s/scripts/install-databases.sh`

**Environment Variables → CREATE Kubernetes Secrets**

```bash
# Environment variables are used to SET passwords during installation
export POSTGRES_PASSWORD="Vertex2020!"
export REDIS_PASSWORD="Vertex2020!"

# These create Kubernetes secrets:
# - postgresql secret (with postgres-password key)
# - redis secret (with redis-password key)

./scripts/install-databases.sh
```

---

### Phase 2: Application Deployment (bengobox-erp-api/ui)
**When:** Every code push / CI/CD deployment  
**Who:** Automated via GitHub Actions  
**Where:** `BengoERP/bengobox-erp-api/build.sh`

**Kubernetes Secrets → READ for Application Config**

```bash
# Application retrieves passwords from existing K8s secrets
# (These are the SOURCE OF TRUTH matching the actual databases)

./scripts/setup_env_secrets.sh
# ↓
# Reads: kubectl get secret postgresql -n erp
# Reads: kubectl get secret redis -n erp
# ↓
# Creates: erp-api-env secret with correct passwords
```

---

## 🔑 Password Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│  Phase 1: Infrastructure Provisioning (ONE TIME)                │
└─────────────────────────────────────────────────────────────────┘

GitHub Secrets              devops-k8s                Kubernetes
     │                           │                         │
     │ POSTGRES_PASSWORD         │                         │
     ├──────────────────────────►│ install-databases.sh    │
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
     │                            │         │              │
     │                            │    [PASSWORDS NOW      │
     │                            │     STORED IN K8S]     │
     │                            │                         │

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
     │                            │  postgresql -n erp     │
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

---

## 📋 Why This Matters

### ❌ Wrong Approach (What We Fixed):
```bash
# CI/CD tries to use GitHub secret POSTGRES_PASSWORD
# But this might not match the actual database password!
# Result: Password authentication failed
```

### ✅ Correct Approach (Current):
```bash
# CI/CD retrieves password from postgresql Kubernetes secret
# This is GUARANTEED to match the actual database
# Result: Authentication succeeds
```

---

## 🔧 Implementation Details

### Infrastructure Scripts (devops-k8s)

**File:** `scripts/install-databases.sh`

```bash
# Environment variables are used to CREATE databases
if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
  # Use provided password
  helm install postgresql ... --set password="$POSTGRES_PASSWORD"
else
  # Let Helm auto-generate a secure password
  helm install postgresql ... -f values.yaml
fi
```

**Purpose:** Allow ops team to set passwords OR let Helm generate them

---

### Application Scripts (bengobox-erp-api)

**File:** `scripts/setup_env_secrets.sh`

```bash
# ALWAYS retrieve from Kubernetes (source of truth)
APP_DB_PASS=$(kubectl get secret postgresql -n erp \
  -o jsonpath='{.data.postgres-password}' | base64 -d)

# Create app secret with retrieved password
kubectl create secret generic erp-api-env \
  --from-literal=DB_PASSWORD="$APP_DB_PASS" \
  --from-literal=DATABASE_URL="postgresql://postgres:${APP_DB_PASS}@..."
```

**Purpose:** Ensure app uses correct password matching actual database

---

## 🎯 Required GitHub Secrets

### For Infrastructure Provisioning:
```yaml
# Optional - only if you want to set specific passwords
POSTGRES_PASSWORD: "Vertex2020!"  # Used during helm install
REDIS_PASSWORD: "Vertex2020!"      # Used during helm install
```

### For Application Deployment:
```yaml
# NO PASSWORD SECRETS NEEDED!
# Passwords are retrieved from Kubernetes automatically

KUBE_CONFIG: "base64-encoded-kubeconfig"  # Required
REGISTRY_USERNAME: "codevertex"            # Required
REGISTRY_PASSWORD: "@Vertex2020!"          # Required
GH_PAT: "ghp_..."                          # Required for devops-k8s updates
GIT_USER: "Titus Owuor"                    # Required
GIT_EMAIL: "titusowuor30@gmail.com"        # Required
```

---

## 🔍 Debugging Password Issues

### Check What Password is Stored:
```bash
# Get PostgreSQL password from Kubernetes
kubectl get secret postgresql -n erp \
  -o jsonpath='{.data.postgres-password}' | base64 -d

# Get Redis password
kubectl get secret redis -n erp \
  -o jsonpath='{.data.redis-password}' | base64 -d
```

### Check What App is Using:
```bash
# Get password from app secret
kubectl get secret erp-api-env -n erp \
  -o jsonpath='{.data.DB_PASSWORD}' | base64 -d

# These MUST match!
```

### Test Connection:
```bash
# Test PostgreSQL connection with retrieved password
export PG_PASS=$(kubectl get secret postgresql -n infra \
  -o jsonpath='{.data.postgres-password}' | base64 -d)

kubectl run psql-test --rm -it --restart=Never \
  --image=postgres:15 --env PGPASSWORD=$PG_PASS \
  -- psql -h postgresql.infra.svc.cluster.local \
  -U postgres -d bengo_erp -c "SELECT version();"
```

---

## 🛠️ Troubleshooting

### Issue: "password authentication failed"

**Diagnosis:**
```bash
# Compare passwords
PG_SECRET=$(kubectl get secret postgresql -n erp -o jsonpath='{.data.postgres-password}' | base64 -d)
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

### Issue: "PostgreSQL secret not found"

**Diagnosis:**
```bash
kubectl get secrets -n erp | grep postgresql
```

**Fix:**
```bash
# Install databases first
cd devops-k8s
./scripts/install-databases.sh
```

---

## 📊 Secret Lifecycle

### 1. Initial Setup (devops-k8s)
```bash
# Run once during cluster provisioning
export POSTGRES_PASSWORD="Vertex2020!"
export REDIS_PASSWORD="Vertex2020!"
./scripts/install-databases.sh

# Creates:
# - postgresql secret (source of truth)
# - redis secret (source of truth)
```

### 2. Application Deployment (build.sh)
```bash
# Runs on every git push
# NO password env vars needed
./build.sh

# Process:
# 1. Reads postgresql/redis secrets
# 2. Creates erp-api-env secret with those passwords
# 3. Migrations use erp-api-env (which has correct passwords)
```

### 3. Password Rotation (when needed)
```bash
# Step 1: Update database password
kubectl patch secret postgresql -n erp \
  -p '{"stringData":{"postgres-password":"NewPassword123!"}}'

# Step 2: Update database itself
kubectl exec -it postgresql-0 -n erp -- \
  psql -U postgres -c "ALTER USER postgres PASSWORD 'NewPassword123!';"

# Step 3: Redeploy app (will auto-sync new password)
git push  # Triggers build.sh → setup_env_secrets.sh → retrieves new password
```

---

## ✅ Best Practices

### DO:
- ✅ Use GitHub secrets for infrastructure provisioning passwords
- ✅ Let applications retrieve passwords from Kubernetes
- ✅ Keep database secrets as the source of truth
- ✅ Test password retrieval before deployments

### DON'T:
- ❌ Put database passwords in application GitHub secrets
- ❌ Hardcode passwords in code or manifests
- ❌ Use env var passwords for existing databases
- ❌ Assume GitHub secret matches K8s secret

---

## 🔐 Security Notes

### Why Kubernetes Secrets are Source of Truth:

1. **Single Source** - Database password exists in ONE place
2. **Consistency** - App password MUST match database password
3. **Rotation** - Changing K8s secret automatically updates apps
4. **Audit Trail** - K8s secret changes are logged

### When to Use GitHub Secrets:

- ✅ Initial database provisioning
- ✅ Registry credentials
- ✅ Git access tokens
- ✅ API keys for external services
- ✅ KUBE_CONFIG for cluster access

### When to Use Kubernetes Secrets:

- ✅ Database passwords (after provisioning)
- ✅ Service-to-service credentials
- ✅ Application runtime config
- ✅ Dynamic values that change

---

## 📖 Related Documentation

- [Database Setup Guide](./database-setup.md)
- [Provisioning Guide](./provisioning.md)
- [Manual Deployment](../BengoERP/bengobox-erp-api/docs/manual-deployment-guide.md)

---

**Last Updated:** 2025-10-29  
**Status:** ✅ Production-ready  
**Next Review:** After successful deployment

