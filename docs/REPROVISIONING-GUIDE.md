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
# Cleanup enabled by default (set ENABLE_CLEANUP=false to skip)
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

### Option A: Cleanup Only

```bash
# Cleanup is opt-in only - must explicitly enable
export ENABLE_CLEANUP=true
./scripts/cluster/cleanup-cluster.sh

# Or with force (no confirmation prompt)
export ENABLE_CLEANUP=true
export FORCE_CLEANUP=true
./scripts/cluster/cleanup-cluster.sh
```

The cleanup script will:
1. Uninstall all Helm releases
2. Delete all ArgoCD applications
3. Delete all application namespaces
4. Clean up PVCs, CRDs, and Helm secrets
5. Verify cleanup completion

### Option B: Manual Cleanup

If you prefer manual control:

```bash
# 1. List all namespaces
kubectl get namespaces

# 2. Uninstall Helm releases in each namespace
for ns in erp infra argocd monitoring; do
  helm list -n "$ns" -q | xargs -I {} helm uninstall {} -n "$ns" --wait || true
done

# 3. Delete ArgoCD applications
kubectl delete applications --all -A --wait=true --grace-period=0 || true

# 4. Delete application namespaces
for ns in erp infra argocd monitoring cafe treasury notifications truload; do
  kubectl delete namespace "$ns" --wait=true --grace-period=0 || true
done

# 5. Clean up stuck resources
kubectl get pvc -A | grep -v NAME | awk '{print $1, $2}' | while read ns name; do
  kubectl delete pvc "$name" -n "$ns" --wait=true --grace-period=0 || true
done
```

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
export POSTGRES_PASSWORD="your-password"
export POSTGRES_ADMIN_PASSWORD="your-admin-password"
export REDIS_PASSWORD="your-redis-password"
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
export GRAFANA_DOMAIN=grafana.masterspace.co.ke
export MONITORING_NAMESPACE=infra
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

