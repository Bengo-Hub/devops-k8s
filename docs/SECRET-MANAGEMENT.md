# Secret Management Best Practices for ArgoCD Deployments

## Overview

This document explains how to manage Kubernetes secrets in an ArgoCD-managed cluster to prevent deployment failures and conflicts during syncs.

## The Challenge

When using ArgoCD with Helm charts, there are two potential sources for secrets:
1. **Pre-provisioned secrets** created by DevOps scripts
2. **Helm-generated secrets** created automatically by charts

If both exist, they can conflict, causing:
- Deployment failures during ArgoCD sync
- Secrets being recreated with default/wrong values
- Application errors (like Superset's SECRET_KEY issues)

## Solution: Pre-Create Secrets Pattern

### Pattern Used by PostgreSQL, Redis, RabbitMQ

These services follow a proven pattern that prevents ArgoCD conflicts:

```bash
# 1. Create secret BEFORE ArgoCD syncs
if ! kubectl get secret <service-name> -n <namespace> >/dev/null 2>&1; then
    kubectl create secret generic <service-name> \
        -n <namespace> \
        --from-literal=<key>="<value>"
else
    log_info "Secret already exists - reusing"
fi

# 2. Deploy the application (ArgoCD or kubectl apply)
# The pre-created secret is used, Helm doesn't create a new one
```

**Key Principles:**
1. ✅ **Check before create**: Always check if secret exists
2. ✅ **Idempotent**: Script can run multiple times safely
3. ✅ **Reuse existing**: Never delete and recreate unless explicitly requested
4. ✅ **No labels**: Don't add ArgoCD/Helm tracking labels to pre-created secrets

### Why PostgreSQL/Redis Don't Have Conflicts

**Timeline:**
```
1. Provision workflow runs → install-databases.sh
2. Creates postgresql/redis secrets (no ArgoCD labels)
3. ArgoCD bootstraps
4. ArgoCD sees secrets exist, doesn't try to manage them
5. Deployments reference existing secrets
```

**Result**: Secrets are "external" to ArgoCD - never tracked, never recreated.

## Superset Implementation

### Problem (Before Fix)

Superset had TWO secrets with different purposes:

1. **superset-secrets**: Created by `create-superset-secrets.sh`
   - Comprehensive credentials for all use cases
   - Created during provision workflow

2. **superset-env**: Auto-created by Helm chart
   - Expected by chart for environment variables
   - Created with DEFAULT VALUES (`superset-postgresql`, `superset-redis`)
   - Had ArgoCD tracking annotation: `argocd.argoproj.io/tracking-id`

**Conflict Scenario:**
```
1. Provision creates superset-secrets ✓
2. ArgoCD syncs → Helm creates superset-env with defaults ✗
3. Manual fix: Delete superset-env, create with correct values ✓
4. ArgoCD syncs again → Recreates superset-env with defaults ✗
5. Deployment fails (wrong database host) ✗
```

### Solution (After Fix)

Update `create-superset-secrets.sh` to pre-create BOTH secrets:

```bash
# Create superset-secrets (comprehensive)
kubectl create secret generic superset-secrets \
    --namespace="${NAMESPACE}" \
    --from-literal=DATABASE_PASSWORD="${DATABASE_PASSWORD}" \
    --from-literal=SECRET_KEY="${SECRET_KEY}" \
    # ... all credentials

# ALSO create superset-env (Helm expects this)
# Pre-creating prevents Helm from creating with defaults
kubectl create secret generic superset-env \
    --namespace="${NAMESPACE}" \
    --from-literal=DB_HOST="postgresql.infra.svc.cluster.local" \
    --from-literal=DB_PASS="${DATABASE_PASSWORD}" \
    --from-literal=SECRET_KEY="${SECRET_KEY}" \
    --from-literal=SUPERSET_SECRET_KEY="${SECRET_KEY}" \
    # ... correct values
```

**Result**: Both secrets exist before ArgoCD syncs, Helm finds them and doesn't recreate.

## When ArgoCD Tracks Secrets

ArgoCD tracks resources when:

1. **Helm chart creates them** during initial sync
2. **They have ArgoCD annotations**: `argocd.argoproj.io/tracking-id`
3. **They're defined in Helm templates** (`templates/secret.yaml`)

**How to prevent tracking:**
- Create secrets BEFORE first ArgoCD sync
- Don't add `argocd.argoproj.io/*` annotations
- Use generic `kubectl create secret` (not Helm templates)

## Best Practices Summary

### ✅ DO

1. **Create secrets during provision workflow** (before ArgoCD)
2. **Check if secret exists** before creating
3. **Reuse existing secrets** (idempotent scripts)
4. **Use single source of truth** (GitHub secrets → provision scripts → K8s secrets)
5. **Document secret keys** in script comments
6. **Backup credentials** to secure location

### ❌ DON'T

1. **Don't let Helm create secrets** if you need custom values
2. **Don't add ArgoCD tracking annotations** to pre-created secrets
3. **Don't delete and recreate** secrets unnecessarily
4. **Don't commit secrets** to version control
5. **Don't use different passwords** across environments

## Implementation Checklist

When adding a new service that needs secrets:

- [ ] Create secret generation script in `scripts/infrastructure/`
- [ ] Add to provision workflow BEFORE ArgoCD bootstrap
- [ ] Check if secret exists (idempotent)
- [ ] Use `POSTGRES_PASSWORD` as master password (consistency)
- [ ] Generate strong SECRET_KEY if needed (64+ characters)
- [ ] Add backup to `backups/` directory
- [ ] Document required GitHub secrets in README
- [ ] Test: Run provision twice, verify secret not recreated
- [ ] Test: ArgoCD sync, verify no conflicts

## Troubleshooting

### Secret keeps getting recreated with wrong values

**Symptoms:**
- Secret exists with correct values
- ArgoCD sync recreates it with defaults
- Application fails after sync

**Diagnosis:**
```bash
# Check if ArgoCD tracks the secret
kubectl get secret <name> -n <namespace> -o yaml | grep argocd

# If you see argocd.argoproj.io/tracking-id → ArgoCD manages it
```

**Fix:**
1. Delete the secret
2. Remove it from Helm chart templates (or disable creation)
3. Pre-create it in provision workflow
4. ArgoCD sync won't recreate it

### Application can't read secret values

**Symptoms:**
- Secret exists
- Application logs show empty/nil values
- Environment variables not set

**Diagnosis:**
```bash
# Check pod environment
kubectl exec -n <namespace> <pod> -- env | grep <KEY>

# Check secret keys
kubectl get secret <name> -n <namespace> -o jsonpath='{.data}' | base64 -d
```

**Common Causes:**
1. **Wrong secret name** in deployment `envFromSecret`
2. **Different key names** (DB_HOST vs DATABASE_HOST)
3. **Secret in different namespace**
4. **Base64 encoding issues**

## Examples

### PostgreSQL Pattern (Reference Implementation)

[Location: `scripts/infrastructure/install-databases.sh` lines 73-89]

```bash
if ! kubectl get secret postgresql -n "${NAMESPACE}" >/dev/null 2>&1; then
    log_info "Creating PostgreSQL secret..."
    kubectl create secret generic postgresql \
        -n "${NAMESPACE}" \
        --from-literal=password="${POSTGRES_PASS}" \
        --from-literal=postgres-password="${POSTGRES_PASS}"
    log_success "PostgreSQL secret created"
else
    log_info "PostgreSQL secret already exists - reusing"
fi
```

### Superset Pattern (Updated Implementation)

[Location: `scripts/infrastructure/create-superset-secrets.sh` lines 128-198]

```bash
# Create superset-secrets
kubectl create secret generic superset-secrets ...

# Also create superset-env (prevents Helm conflict)
if ! kubectl get secret superset-env -n "${NAMESPACE}" >/dev/null 2>&1; then
    kubectl create secret generic superset-env \
        --namespace="${NAMESPACE}" \
        --from-literal=DB_HOST="postgresql.infra.svc.cluster.local" \
        --from-literal=SECRET_KEY="${SECRET_KEY}" \
        # ... all required keys
fi
```

## Related Documentation

- [Provision Workflow](../.github/workflows/provision.yml)
- [Database Installation](../scripts/infrastructure/install-databases.sh)
- [Superset Secrets](../scripts/infrastructure/create-superset-secrets.sh)
- [ArgoCD Best Practices](https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/)

## Commit History

- **2026-01-18**: Added superset-env pre-creation to prevent Helm conflicts (commit f4b9542)
- **2026-01-18**: Fixed Superset SECRET_KEY configuration (commit 32f5739)
- **2026-01-18**: Initial audit of deployment files (commit 2cb3b724)
