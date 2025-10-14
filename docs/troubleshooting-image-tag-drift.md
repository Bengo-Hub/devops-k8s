# Troubleshooting: Image Tag Drift (values.yaml vs running pods)

## Problem: Pods use wrong image tag despite values.yaml being updated

**Symptoms**:
```bash
# values.yaml shows correct tag
$ yq e '.image.tag' apps/erp-ui/values.yaml
8333e8cd

# But pods are running different tag
$ kubectl -n erp get pods -l app=erp-ui-app -o jsonpath='{.items[0].spec.containers[0].image}'
docker.io/codevertex/erp-ui:latest
```

## Root Causes & Fixes

### 1. ArgoCD Uses Inline Values Instead of valueFiles

**Problem**: ArgoCD Application has inline Helm values that override the external values.yaml file.

**Check**:
```bash
kubectl -n argocd get application erp-ui -o jsonpath='{.spec.source.helm}'
```

**Bad (causes drift)**:
```yaml
helm:
  values: |
    image:
      repository: docker.io/codevertex/erp-ui
      tag: latest  # ← This overrides apps/erp-ui/values.yaml!
```

**Good (allows build.sh updates)**:
```yaml
helm:
  valueFiles:
    - ../../apps/erp-ui/values.yaml  # ← Reads from external file
```

**Fix**:
```bash
cd devops-k8s

# Update app.yaml to use valueFiles
yq e -i 'del(.spec.source.helm.values) | .spec.source.helm.valueFiles = ["../../apps/erp-ui/values.yaml"]' apps/erp-ui/app.yaml

# Commit and push
git add apps/erp-ui/app.yaml
git commit -m "fix: use valueFiles instead of inline values for erp-ui"
git push origin main

# Force ArgoCD to re-sync
argocd app sync erp-ui --force --replace
```

**Verification**:
```bash
# Helm should now render correct tag
argocd app manifests erp-ui | grep -A 2 "kind: Deployment" | grep "image:"
# Should show: image: "docker.io/codevertex/erp-ui:8333e8cd"
```

---

### 2. ArgoCD Not Auto-Syncing After Git Push

**Problem**: Auto-sync is disabled or delayed (3-minute polling interval).

**Check**:
```bash
kubectl -n argocd get application erp-ui -o jsonpath='{.spec.syncPolicy.automated}'
```

**Should show**:
```json
{"prune":true,"selfHeal":true}
```

**Fix if missing**:
```bash
kubectl -n argocd patch application erp-ui --type merge -p '{
  "spec": {
    "syncPolicy": {
      "automated": {
        "prune": true,
        "selfHeal": true
      }
    }
  }
}'
```

**Manual sync if auto-sync is delayed**:
```bash
# Refresh (re-check git)
argocd app get erp-ui --refresh

# Force sync
argocd app sync erp-ui --force
```

---

### 3. Helm Chart Has Default "latest" Tag

**Problem**: Chart template uses `{{ .Values.image.tag | default "latest" }}`, so missing values resolve to `latest`.

**Check**:
```bash
grep -n "image:" devops-k8s/charts/app/templates/deployment.yaml
```

**Bad**:
```yaml
image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default \"latest\" }}"
```

**Good**:
```yaml
image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
```

**Fix**:
```bash
# Remove default "latest" from chart
sed -i 's/| default "latest"//g' devops-k8s/charts/app/templates/deployment.yaml
```

---

### 4. Multiple Values Files (Priority Issue)

**Problem**: ArgoCD uses multiple values files and later ones override earlier ones.

**Check**:
```bash
kubectl -n argocd get application erp-ui -o jsonpath='{.spec.source.helm.valueFiles}'
```

**Example**:
```yaml
valueFiles:
  - ../../apps/erp-ui/values.yaml      # tag: 8333e8cd
  - ../../environments/prod.yaml        # tag: latest ← OVERRIDES!
```

**Fix**: Remove conflicting values files or ensure correct priority.

---

### 5. Manual kubectl Edits Override ArgoCD

**Problem**: Someone ran `kubectl set image` or manually edited the Deployment, creating drift.

**Check**:
```bash
# Look for manual edit annotations
kubectl -n erp get deploy erp-ui-app -o jsonpath='{.metadata.annotations}' | jq
```

**Fix**:
```bash
# Tell ArgoCD to hard replace (ignore manual edits)
argocd app sync erp-ui --force --replace

# Or delete and let ArgoCD recreate
kubectl -n erp delete deploy erp-ui-app
argocd app sync erp-ui
```

---

### 6. ArgoCD Sync Failed Silently

**Problem**: Sync operation failed but didn't surface an error.

**Check**:
```bash
# View app status
argocd app get erp-ui

# Check for errors
kubectl -n argocd get application erp-ui -o jsonpath='{.status.conditions}'

# View controller logs
kubectl -n argocd logs deploy/argocd-application-controller --tail=100 | grep erp-ui
```

**Common errors**:
- `ComparisonError`: Chart rendering failed
- `SyncError`: Apply failed (e.g., immutable field conflict)
- `OutOfSync`: Detected changes but didn't apply

**Fix**:
```bash
# Add Replace syncOption for immutable fields
kubectl -n argocd patch application erp-ui --type merge -p '{
  "spec": {
    "syncPolicy": {
      "syncOptions": ["CreateNamespace=true", "Replace=true"]
    }
  }
}'

# Force sync
argocd app sync erp-ui --force --replace
```

---

### 7. Deployment Updated But Pods Not Rolled Out

**Problem**: Deployment spec is correct, but pods weren't restarted.

**Check**:
```bash
# Check Deployment image
kubectl -n erp get deploy erp-ui-app -o jsonpath='{.spec.template.spec.containers[0].image}'
# Shows: docker.io/codevertex/erp-ui:8333e8cd ✅

# Check pod image
kubectl -n erp get pods -l app=erp-ui-app -o jsonpath='{.items[0].spec.containers[0].image}'
# Shows: docker.io/codevertex/erp-ui:latest ❌
```

**Root cause**: Deployment spec changed, but rollout didn't trigger (rare Kubernetes bug or paused rollout).

**Fix**:
```bash
# Force new rollout
kubectl -n erp rollout restart deploy/erp-ui-app

# Wait for completion
kubectl -n erp rollout status deploy/erp-ui-app --timeout=5m

# Verify pods now use correct image
kubectl -n erp get pods -l app=erp-ui-app -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
```

---

## Complete Diagnostic Script

Run this to diagnose the entire chain:

```bash
#!/bin/bash
set -e

APP_NAME="erp-ui"
NAMESPACE="erp"
VALUES_PATH="apps/${APP_NAME}/values.yaml"

echo "=== 1. Check values.yaml image tag ==="
cd ~/devops-k8s
git fetch origin main && git reset --hard origin/main
yq e '.image' "$VALUES_PATH"

echo ""
echo "=== 2. Check ArgoCD app source configuration ==="
kubectl -n argocd get application "$APP_NAME" -o jsonpath='{.spec.source.helm}' | jq

echo ""
echo "=== 3. Check ArgoCD sync status ==="
argocd app get "$APP_NAME" --refresh | grep -E "Sync Status|Health Status|Last Sync"

echo ""
echo "=== 4. Check rendered Helm manifests ==="
argocd app manifests "$APP_NAME" | grep -A 2 "kind: Deployment" | grep "image:"

echo ""
echo "=== 5. Check Deployment spec in cluster ==="
kubectl -n "$NAMESPACE" get deploy "${APP_NAME}-app" -o jsonpath='{.spec.template.spec.containers[0].image}'
echo ""

echo ""
echo "=== 6. Check actual running pods ==="
kubectl -n "$NAMESPACE" get pods -l "app=${APP_NAME}-app" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'

echo ""
echo "=== 7. Check for image pull errors ==="
kubectl -n "$NAMESPACE" get events --sort-by='.lastTimestamp' | grep -i "pull\|image" | tail -n 10
```

Save as `debug-image-drift.sh` and run when you suspect drift.

---

## Prevention

### In build.sh
- ✅ Verify ArgoCD app uses `valueFiles` (not inline `values`)
- ✅ Use `yq` with env injection for safe updates
- ✅ Verify push succeeded before exiting
- ✅ Force ArgoCD refresh after push

### In ArgoCD app.yaml
- ✅ Use `valueFiles` instead of inline `values`
- ✅ Enable auto-sync: `automated: {prune: true, selfHeal: true}`
- ✅ Add `Replace=true` to `syncOptions` for immutable field handling

### In Helm chart
- ✅ No default "latest" tags in templates
- ✅ Always use `.Values.image.tag` without fallback
- ✅ Properly map `.Values.image.pullSecrets` to pod spec

### Regular Checks
```bash
# Weekly audit: values.yaml vs cluster reality
for app in erp-ui erp-api; do
  VALUES_TAG=$(yq e '.image.tag' "apps/${app}/values.yaml")
  CLUSTER_TAG=$(kubectl -n erp get deploy "${app}-app" -o jsonpath='{.spec.template.spec.containers[0].image}' | cut -d: -f2)
  if [[ "$VALUES_TAG" != "$CLUSTER_TAG" ]]; then
    echo "⚠️  DRIFT DETECTED: $app (values: $VALUES_TAG, cluster: $CLUSTER_TAG)"
  else
    echo "✅ $app in sync"
  fi
done
```

---

## Quick Fix Checklist

When pods use wrong tag:

1. ☐ Check `apps/<app>/app.yaml` uses `valueFiles` (not inline `values`)
2. ☐ Verify `apps/<app>/values.yaml` has correct tag
3. ☐ Check `argocd app manifests <app>` renders correct image
4. ☐ Force sync: `argocd app sync <app> --force --replace`
5. ☐ Verify Deployment updated: `kubectl get deploy <app>-app -o yaml | grep image:`
6. ☐ Restart if needed: `kubectl rollout restart deploy/<app>-app`
7. ☐ Monitor rollout: `kubectl rollout status deploy/<app>-app`

