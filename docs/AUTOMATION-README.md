# Cluster Automation & Health Management

This directory contains tools for maintaining cluster health and preventing pod limit exhaustion.

## 🚀 Quick Start

Deploy all automation with one command:

```bash
cd /path/to/devops-k8s
chmod +x scripts/tools/deploy-automation.sh
./scripts/tools/deploy-automation.sh
```

## 📋 What Gets Deployed

### 1. Automated Pod Cleanup (CronJob)

**File**: `manifests/cleanup-cronjob.yaml`

- **Schedule**: Every 30 minutes
- **Actions**:
  - Deletes Failed pods across all namespaces
  - Removes stale Pending pods (>5 minutes old)
  - Scales down deployments with repeated failures
  - Cleans up completed jobs (>1 hour old)
  - Prevents auto-recreation of failed pods

**Manual trigger**:
```bash
kubectl create job --from=cronjob/cleanup-failed-pods -n kube-system manual-cleanup-$(date +%s)
```

**View logs**:
```bash
kubectl logs -n kube-system -l app=pod-cleanup --tail=100
```

### 2. Infrastructure Autoscaling

**File**: `manifests/infrastructure-hpa.yaml`

Configures HPA for:
- **Redis**: 1-2 replicas (CPU 75%, Memory 80%)
- **RabbitMQ**: 1-2 replicas (CPU 70%, Memory 75%)
- **PostgreSQL**: VPA only (vertical scaling)

**Check status**:
```bash
kubectl get hpa -n infra
kubectl get vpa -n infra
```

### 3. Pre-Deployment Health Checks

**File**: `scripts/tools/pre-deploy-health-check.sh`

Validates before deployment:
- ✅ Namespace capacity
- ✅ Cluster pod limit (150 max)
- ✅ No existing failed pods
- ✅ Database connectivity
- ✅ Required secrets exist

**Usage**:
```bash
./scripts/tools/pre-deploy-health-check.sh <app-name> <namespace> [full|quick|skip]
```

**Example**:
```bash
./scripts/tools/pre-deploy-health-check.sh auth-api auth full
```

## 🔧 Updated App Configurations

### Auth-API Connection Pool Settings

**File**: `apps/auth-api/values.yaml`

Added environment variables:
```yaml
- name: AUTH_DB_MAX_OPEN_CONNS
  value: "10"  # Reduced from 20
- name: AUTH_DB_MAX_IDLE_CONNS
  value: "3"   # Reduced from 5
- name: AUTH_DB_CONN_MAX_LIFETIME
  value: "15m"
```

### ERP-API Autoscaling

**File**: `apps/erp-api/values.yaml`

Enhanced HPA with scale-down/scale-up policies:
```yaml
autoscaling:
  enabled: true
  minReplicas: 1
  maxReplicas: 2
  scaleDown:
    stabilizationWindowSeconds: 300
    policies:
      - type: Percent
        value: 50
        periodSeconds: 60
  scaleUp:
    stabilizationWindowSeconds: 60
    policies:
      - type: Percent
        value: 100
        periodSeconds: 30
```

### Superset Autoscaling

**File**: `apps/superset/values.yaml`

Updated to start with 1 replica:
```yaml
replicaCount: 1
autoscaling:
  minReplicas: 1  # Changed from 2
  maxReplicas: 2
```

## 🎯 Default Replica Strategy

All apps now follow this pattern:

| App Type | Min Replicas | Max Replicas | Notes |
|----------|--------------|--------------|-------|
| API Services (auth, erp, etc.) | 1 | 2 | Scale on CPU/Memory |
| Frontend Apps | 1 | 3 | Can scale higher |
| Infrastructure (Redis, RabbitMQ) | 1 | 2 | Conservative scaling |
| PostgreSQL | 1 | N/A | Use VPA only |
| Heavy Apps (Superset) | 1 | 2 | Resource-intensive |

## 🛡️ Auto-Disable Failed Deployments

The cleanup CronJob automatically:

1. Detects deployments with 0 ready pods for >10 minutes
2. Scales them down to 0 replicas
3. Adds annotations:
   ```yaml
   bengobox.dev/auto-disabled: "true"
   bengobox.dev/disabled-reason: "repeated-pod-failures"
   bengobox.dev/disabled-at: "2025-12-11T00:00:00Z"
   ```
4. Prevents auto-recreation until fixed

**Re-enable manually**:
```bash
kubectl scale deployment <name> -n <namespace> --replicas=1
kubectl annotate deployment <name> -n <namespace> bengobox.dev/auto-disabled-
```

**Re-enable via ArgoCD**:
- Fix the underlying issue
- Force sync with "Replace" option
- ArgoCD will restore desired replica count

## 📊 Monitoring

### Check Cluster Health

```bash
# Pod count
kubectl get pods -A --no-headers | wc -l

# Running pods vs limit
kubectl get pods -A --field-selector=status.phase=Running --no-headers | wc -l

# Failed/Pending pods
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

### Check Autoscaling

```bash
# All HPAs
kubectl get hpa -A

# Specific app
kubectl describe hpa auth-api -n auth
```

### Check VPAs

```bash
kubectl get vpa -A
kubectl describe vpa postgresql-vpa -n infra
```

## 🔥 Emergency Procedures

### Cluster at Pod Limit

```bash
# Quick cleanup
./scripts/tools/cleanup-failed-pods.sh

# Or use kubectl directly
kubectl delete pods -A --field-selector=status.phase=Failed --force --grace-period=0
kubectl delete pods -A --field-selector=status.phase=Pending --force --grace-period=0
```

### Scale Down Non-Critical Apps

```bash
# Temporarily reduce replicas
kubectl scale deployment -n truload truload-backend-app --replicas=1
kubectl scale deployment -n erp erp-ui-app --replicas=1
```

### Disable Failed Deployments

```bash
# Find apps with issues
kubectl get deployments -A -o json | jq -r '.items[] | select(.status.readyReplicas == 0) | "\(.metadata.namespace)/\(.metadata.name)"'

# Scale down
kubectl scale deployment <name> -n <namespace> --replicas=0
```

## 🔗 Integration with ArgoCD

### Add PreSync Health Check Hook

Create `scripts/pre-sync-hook.yaml` in each app directory:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ .Release.Name }}-presync-health
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded,HookFailed
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: health-check
          image: bitnami/kubectl:latest
          command:
            - /bin/bash
            - -c
            - |
              # Download and run health check script
              curl -sSL https://raw.githubusercontent.com/your-repo/devops-k8s/main/scripts/tools/pre-deploy-health-check.sh | bash -s {{ .Release.Name }} {{ .Release.Namespace }} quick
```

### ArgoCD Sync Policy for Failed Apps

Update `app.yaml` with:
```yaml
spec:
  syncPolicy:
    automated:
      prune: true
      selfHeal: false  # Don't auto-recreate failed apps
    retry:
      limit: 3  # Stop after 3 failures
      backoff:
        duration: 5m
        factor: 2
        maxDuration: 1h
```

## 📚 Related Scripts

- `scripts/tools/cleanup-failed-pods.sh` - Manual cleanup script
- `scripts/tools/fix-cluster-issues.sh` - Comprehensive cluster repair
- `scripts/diagnostics/diagnose-pending-pods.sh` - Debug pending pods
- `scripts/tools/audit-resources.sh` - Resource usage audit

## 🐛 Troubleshooting

### Cleanup CronJob Not Running

```bash
# Check CronJob
kubectl get cronjob -n kube-system cleanup-failed-pods

# Check recent jobs
kubectl get jobs -n kube-system -l app=pod-cleanup

# Check logs
kubectl logs -n kube-system -l app=pod-cleanup --tail=100
```

### HPA Not Scaling

```bash
# Check metrics server
kubectl top nodes
kubectl top pods -n <namespace>

# Check HPA status
kubectl describe hpa <name> -n <namespace>

# Common issue: metrics-server not running
kubectl get deployment -n kube-system metrics-server
```

### VPA Not Working

```bash
# Check VPA installation
kubectl get deployment -n kube-system vpa-admission-controller

# Check VPA recommendations
kubectl describe vpa <name> -n <namespace>
```

## 📝 Best Practices

1. **Always run health checks before critical deployments**
2. **Monitor cleanup logs weekly**
3. **Review auto-disabled deployments monthly**
4. **Keep max replicas low (1-2) for most apps**
5. **Use VPA for stateful workloads (databases)**
6. **Set proper resource requests/limits**
7. **Enable autoscaling for all production apps**
8. **Test deployments in staging first**

## 🔄 Maintenance Schedule

- **Daily**: Review cleanup logs
- **Weekly**: Check HPA metrics and adjust thresholds
- **Monthly**: Audit auto-disabled deployments
- **Quarterly**: Review and optimize resource allocations
