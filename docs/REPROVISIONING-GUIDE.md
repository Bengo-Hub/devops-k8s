# Complete Cluster Reprovisioning Guide

## Overview

This guide provides step-by-step instructions for completely cleaning and reprovisioning your Kubernetes cluster from scratch. This is useful when:
- Migrating to new infrastructure
- Resolving persistent configuration issues
- Starting fresh with updated configurations
- Moving to the `infra` namespace model

## ⚠️ WARNING

**This process will DELETE ALL:**
- Application namespaces and pods
- Helm releases
- Persistent volumes and data
- ArgoCD applications
- All application data

**Only system namespaces are preserved:**
- `kube-system`
- `kube-public`
- `kube-node-lease`
- `default`

---

## Prerequisites

1. **Access to cluster** via `kubectl`
2. **GitHub Secrets configured:**
   - `KUBE_CONFIG` - Base64 encoded kubeconfig
   - `POSTGRES_PASSWORD` - PostgreSQL password
   - `POSTGRES_ADMIN_PASSWORD` - Admin user password
   - `REDIS_PASSWORD` - Redis password
   - `RABBITMQ_PASSWORD` - RabbitMQ password
3. **Backup any critical data** before proceeding

---

## Step 1: Cleanup Existing Resources

### Recommended: Full Reprovisioning Script

Use the consolidated script to handle cleanup **and** provisioning end-to-end:

```bash
# Cleanup is DISABLED by default (opt-in for safety)
# To enable cleanup:
export ENABLE_CLEANUP=true
./scripts/reprovision-cluster.sh

# To force cleanup without confirmation:
export ENABLE_CLEANUP=true
export FORCE_CLEANUP=true
./scripts/reprovision-cluster.sh
```

This script will:
1. Run `cleanup-cluster.sh` (if `ENABLE_CLEANUP=true`)
2. Install storage provisioner, databases, RabbitMQ, ingress, cert-manager, Argo CD, monitoring, and VPA
3. Bootstrap ArgoCD applications
4. Verify installation at the end

### Option A: Automated Cleanup Script (Recommended)

The automated cleanup script uses a **multi-stage process** to prevent stuck deletions:

```bash
# Cleanup is opt-in only - must explicitly enable
export ENABLE_CLEANUP=true
./scripts/cluster/cleanup-cluster.sh

# Or with force (no confirmation prompt)
export ENABLE_CLEANUP=true
export FORCE_CLEANUP=true
./scripts/cluster/cleanup-cluster.sh
```

**Multi-Stage Cleanup Process:**

1. **Stage 1**: Uninstall all Helm releases
2. **Stage 2**: Disable ArgoCD auto-sync and self-heal (prevents recreation)
3. **Stage 2.1**: Delete all ArgoCD Applications
4. **Stage 2.2**: Remove ArgoCD CRDs
5. **Stage 2.3**: Scale down ArgoCD components (stops resource management)
6. **Stage 2.4**: Scale down monitoring operators (stops recreation loops)
7. **Stage 3**: Enhanced namespace deletion:
   - Scale down all workloads to 0 replicas
   - Remove finalizers from all resources
   - Force delete all pods
   - Remove namespace finalizers
   - Force delete namespaces
8. **Stage 4**: Clean up remaining PVCs, CRDs, and Helm secrets
9. **Stage 5**: Force delete any stuck resources

### Option B: Manual Cleanup (Mirrors Automated Process)

If you prefer manual control, follow this **enhanced cleanup process** to avoid getting stuck:

```bash
# STAGE 1: Uninstall Helm releases
echo "Stage 1: Uninstalling Helm releases..."
for ns in erp infra argocd monitoring cafe treasury notifications truload auth; do
  helm list -n "$ns" -q 2>/dev/null | xargs -I {} helm uninstall {} -n "$ns" --wait 2>/dev/null || true
done

# STAGE 2: Disable ArgoCD auto-sync (prevents recreation)
echo "Stage 2: Disabling ArgoCD auto-sync..."
kubectl get applications -A -o json 2>/dev/null | \
  jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"' | \
  while read -r app; do
    NS=$(echo "$app" | cut -d'/' -f1)
    APP=$(echo "$app" | cut -d'/' -f2)
    echo "  Disabling auto-sync for: $APP"
    kubectl patch application "$APP" -n "$NS" --type=merge \
      -p '{"spec":{"syncPolicy":{"automated":null}}}' 2>/dev/null || true
    kubectl patch application "$APP" -n "$NS" --type=json \
      -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
  done

# STAGE 2.1: Delete ArgoCD Applications
echo "Stage 2.1: Deleting ArgoCD Applications..."
kubectl get applications -A -o json 2>/dev/null | \
  jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"' | \
  while read -r app; do
    NS=$(echo "$app" | cut -d'/' -f1)
    APP=$(echo "$app" | cut -d'/' -f2)
    echo "  Deleting: $APP"
    kubectl delete application "$APP" -n "$NS" --wait=false --grace-period=0 2>/dev/null || true
  done

sleep 5

# STAGE 2.2: Remove ArgoCD CRDs
echo "Stage 2.2: Removing ArgoCD CRDs..."
kubectl delete crd applications.argoproj.io --wait=false --grace-period=0 2>/dev/null || true
kubectl delete crd applicationprojects.argoproj.io --wait=false --grace-period=0 2>/dev/null || true
kubectl delete crd appprojects.argoproj.io --wait=false --grace-period=0 2>/dev/null || true

# STAGE 2.3: Scale down ArgoCD components
echo "Stage 2.3: Scaling down ArgoCD components..."
kubectl scale deployment argocd-server -n argocd --replicas=0 2>/dev/null || true
kubectl scale deployment argocd-repo-server -n argocd --replicas=0 2>/dev/null || true
kubectl scale deployment argocd-application-controller -n argocd --replicas=0 2>/dev/null || true
kubectl scale statefulset argocd-application-controller -n argocd --replicas=0 2>/dev/null || true

# STAGE 2.4: Scale down monitoring operators
echo "Stage 2.4: Scaling down monitoring operators..."
kubectl scale deployment -n monitoring --all --replicas=0 2>/dev/null || true
kubectl scale statefulset -n monitoring --all --replicas=0 2>/dev/null || true

sleep 5

# STAGE 3: Enhanced namespace deletion
echo "Stage 3: Deleting namespaces with enhanced process..."
for ns in erp infra argocd monitoring cafe treasury notifications truload auth inventory logistics pos; do
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "  Processing namespace: $ns"
    
    # Scale down all workloads first
    echo "    Scaling down workloads..."
    kubectl scale deployment -n "$ns" --all --replicas=0 2>/dev/null || true
    kubectl scale statefulset -n "$ns" --all --replicas=0 2>/dev/null || true
    kubectl scale replicaset -n "$ns" --all --replicas=0 2>/dev/null || true
    
    sleep 2
    
    # Remove finalizers from resources
    echo "    Removing finalizers..."
    kubectl get all,pvc,configmap,secret -n "$ns" -o json 2>/dev/null | \
      jq -r '.items[] | select(.metadata.finalizers != null) | "\(.kind)/\(.metadata.name)"' 2>/dev/null | \
      while read -r resource; do
        KIND=$(echo "$resource" | cut -d'/' -f1)
        NAME=$(echo "$resource" | cut -d'/' -f2)
        kubectl patch "$KIND" "$NAME" -n "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
      done || true
    
    # Force delete all pods
    echo "    Force deleting pods..."
    kubectl delete pods --all -n "$ns" --force --grace-period=0 2>/dev/null || true
    
    # Remove namespace finalizers
    kubectl patch namespace "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    
    # Delete namespace
    echo "    Deleting namespace..."
    kubectl delete namespace "$ns" --wait=false --grace-period=0 2>/dev/null || true
  fi
done

# STAGE 4: Clean up remaining resources
echo "Stage 4: Cleaning up remaining resources..."
kubectl get pvc -A -o json 2>/dev/null | \
  jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"' | \
  while read -r pvc; do
    NS=$(echo "$pvc" | cut -d'/' -f1)
    NAME=$(echo "$pvc" | cut -d'/' -f2)
    kubectl delete pvc "$NAME" -n "$NS" --wait=false --grace-period=0 2>/dev/null || true
  done || true

echo "✓ Cleanup complete!"
```

**Why This Enhanced Process?**

- **Prevents stuck deletions**: ArgoCD and operators can't recreate resources
- **No infinite loops**: Scaling to 0 stops recreation before deletion
- **Faster cleanup**: No waiting for graceful shutdowns
- **More reliable**: Handles finalizers and stuck resources properly

---

## Step 2: Verify Cleanup

```bash
# Check remaining namespaces (should only see system namespaces)
kubectl get namespaces

# Check remaining Helm releases (should be empty)
helm list -A

# Check remaining PVCs (should be empty)
kubectl get pvc -A

# Check ArgoCD applications (should be empty)
kubectl get applications -A
```

---

## Step 3: Reprovision Infrastructure

### Option A: GitHub Actions Workflow (Recommended)

1. **Trigger the provisioning workflow:**
   - Go to: https://github.com/Bengo-Hub/devops-k8s/actions
   - Select "Provision Cluster Services"
   - Click "Run workflow" → "Run workflow"

2. **The workflow will automatically:**
   - Install storage provisioner
   - Install PostgreSQL & Redis in `infra` namespace
   - Install RabbitMQ in `infra` namespace
   - Configure NGINX Ingress Controller
   - Install cert-manager
   - Install Argo CD
   - Bootstrap ArgoCD applications
   - Install Monitoring stack in `infra` namespace
   - Install VPA
   - Setup Git SSH access

### Option B: Manual Script Execution

```bash
# 1. Storage provisioner
# Note: This script verifies the provisioner pod is running before declaring success
./scripts/infrastructure/install-storage-provisioner.sh

# 2. Databases (PostgreSQL & Redis)
export NAMESPACE=infra
export PG_DATABASE=postgres
export POSTGRES_PASSWORD="your-password"  # Optional: auto-generated if not set
export POSTGRES_ADMIN_PASSWORD="your-admin-password"  # Optional: falls back to POSTGRES_PASSWORD
export POSTGRES_IMAGE_TAG="latest"  # Optional: defaults to latest (custom pgvector image)
export REDIS_PASSWORD="your-redis-password"  # Optional: auto-generated if not set
./scripts/infrastructure/install-databases.sh

# 3. RabbitMQ
export RABBITMQ_NAMESPACE=infra
export RABBITMQ_PASSWORD="your-rabbitmq-password"
./scripts/infrastructure/install-rabbitmq.sh

# 4. Ingress Controller
# Note: This script automatically handles duplicate pods and orphaned replicasets
./scripts/infrastructure/configure-ingress-controller.sh

# 5. cert-manager
./scripts/infrastructure/install-cert-manager.sh

# 6. Argo CD
export ARGOCD_DOMAIN=argocd.masterspace.co.ke
./scripts/infrastructure/install-argocd.sh

# 7. Monitoring (in infra namespace)
# Note: This script includes automatic stuck Helm operation fixes and ingress conflict resolution
# Script automatically adds Helm to PATH if installed via snap
export GRAFANA_DOMAIN=grafana.masterspace.co.ke
export MONITORING_NAMESPACE=infra
# Ensure Helm is in PATH (may be installed via snap)
export PATH="$PATH:/snap/bin"
./scripts/monitoring/install-monitoring.sh

# 8. VPA
# Note: This script automatically creates TLS secret placeholder if missing
./scripts/infrastructure/install-vpa.sh
```

---

## Step 4: Verify Provisioning

```bash
# Check infrastructure pods
kubectl get pods -n infra

# Expected pods:
# - postgresql-0 (PostgreSQL)
# - redis-master-0 (Redis)
# - redis-replicas-* (Redis replicas)
# - rabbitmq-0 (RabbitMQ)
# - monitoring-* (Prometheus/Grafana)

# Check ArgoCD
kubectl get pods -n argocd

# Check Helm releases
helm list -A

# Check ArgoCD applications
kubectl get applications -n argocd
```

---

## Step 5: Deploy Applications

Applications will be deployed via ArgoCD automatically if `apps/*/app.yaml` files exist.

To verify:

```bash
# Check ArgoCD applications
kubectl get applications -n argocd

# Sync applications manually if needed
argocd app sync <app-name> -n argocd
```

---

## Troubleshooting Common Issues

### Duplicate Ingress-NGINX Pods

If you see multiple ingress-nginx pods or port conflicts:

```bash
# Run the automated fix script
./scripts/tools/fix-cluster-issues.sh

# Or manually:
kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller
kubectl delete pod <duplicate-pod-name> -n ingress-nginx
kubectl scale deployment ingress-nginx-controller -n ingress-nginx --replicas=1
```

### Storage Provisioner Not Running

If PVCs are stuck in Pending state:

```bash
# Check if provisioner is running
kubectl get pods -n local-path-storage

# Reinstall if needed
./scripts/infrastructure/install-storage-provisioner.sh
```

### VPA Admission Controller TLS Secret Missing

If VPA admission controller is stuck in ContainerCreating:

```bash
# Run the automated fix script
./scripts/tools/fix-cluster-issues.sh

# Or manually create placeholder secret
kubectl create secret generic vpa-tls-certs \
  --from-literal=ca.crt="dummy" \
  --from-literal=tls.crt="dummy" \
  --from-literal=tls.key="dummy" \
  -n kube-system
kubectl delete pod -n kube-system -l app=vpa-admission-controller
```

### Monitoring Installation Stuck

If Helm operation is stuck:

```bash
# Run the automated fix script
./scripts/monitoring/fix-stuck-helm-monitoring.sh

# Or check Helm status
helm status prometheus -n infra

# Delete pending secrets
kubectl get secrets -n infra -l owner=helm,status=pending-upgrade -o name | \
  xargs kubectl delete -n infra
```

### Registry Credentials Missing

If pods fail with ImagePullBackOff:

```bash
# Create registry credentials in all namespaces
export REGISTRY_USERNAME=your-username
export REGISTRY_PASSWORD=your-password
for ns in infra erp truload cafe treasury notifications auth inventory logistics pos argocd; do
  kubectl create secret docker-registry registry-credentials \
    --docker-server=docker.io \
    --docker-username=$REGISTRY_USERNAME \
    --docker-password=$REGISTRY_PASSWORD \
    --docker-email=your-email@example.com \
    -n $ns --dry-run=client -o yaml | kubectl apply -f -
done
```

## Troubleshooting

### Issue: Namespace stuck in Terminating

```bash
# Remove finalizers
kubectl get namespace <namespace> -o json | \
  jq '.spec.finalizers = []' | \
  kubectl replace --raw "/api/v1/namespaces/<namespace>/finalize" -f -
```

### Issue: Helm release stuck

```bash
# Delete Helm secrets
kubectl get secrets -n <namespace> -l owner=helm -o name | \
  xargs kubectl delete -n <namespace>

# Force delete release
helm uninstall <release> -n <namespace> --wait --force
```

### Issue: PVC stuck

```bash
# Patch PVC to remove finalizers
kubectl patch pvc <pvc-name> -n <namespace> \
  -p '{"metadata":{"finalizers":[]}}' --type=merge

# Force delete
kubectl delete pvc <pvc-name> -n <namespace> --force --grace-period=0
```

---

## Post-Reprovisioning Checklist

- [ ] All infrastructure pods running (`kubectl get pods -n infra`)
- [ ] PostgreSQL accessible (`kubectl exec -n infra postgresql-0 -- psql -U admin_user -d postgres -c "SELECT 1"`)
- [ ] Redis accessible (`kubectl exec -n infra redis-master-0 -- redis-cli ping`)
- [ ] RabbitMQ accessible (`kubectl get svc -n infra rabbitmq`)
- [ ] ArgoCD accessible (https://argocd.masterspace.co.ke)
- [ ] Grafana accessible (https://grafana.masterspace.co.ke)
- [ ] All ArgoCD applications synced (`kubectl get applications -n argocd`)
- [ ] Ingress working (`kubectl get ingress -A`)
- [ ] Certificates issued (`kubectl get certificate -A`)

---

## Next Steps

1. **Deploy applications** via ArgoCD or build scripts
2. **Create per-service databases** (automatic via build scripts)
3. **Configure DNS** for new domains
4. **Set up monitoring dashboards** in Grafana
5. **Configure alerts** in Alertmanager

---

## Related Documentation

- [Provisioning Guide](./provisioning.md)
- [Database Setup](./database-setup.md)
- [Monitoring Setup](./monitoring.md)
- [ArgoCD Setup](./pipelines.md) - See Argo CD Installation section

