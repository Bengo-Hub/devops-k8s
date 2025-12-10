# Common Issues Prevention Guide

This document outlines preventive measures for recurring deployment issues discovered on Dec 10, 2025.

## 🚨 Critical Issues & Prevention

### 1. Helm Template Nil Pointer Errors

**Issue:** Missing optional fields cause template rendering failures:
```
Error: template: app/templates/deployment.yaml:39:74: executing "app/templates/deployment.yaml" 
at <.Values.migrations.runOnStartup>: nil pointer evaluating interface {}.runOnStartup
```

**Root Cause:** Chart template references `.Values.migrations.runOnStartup` without checking if `.Values.migrations` exists.

**Prevention:**
- ✅ **FIXED:** Chart template now uses safe navigation: `(and .Values.migrations .Values.migrations.runOnStartup)`
- ✅ All app values.yaml files MUST include `migrations` section (even if disabled)

**Required in ALL values.yaml:**
```yaml
migrations:
  enabled: false  # or true
  runOnStartup: false  # or true (only for services with DB migrations)
```

---

### 2. VPA Eviction Loop (Pod Churn)

**Issue:** VPA repeatedly evicts pods when metrics-server is unavailable, causing constant pod recreation.

**Symptoms:**
- Pods stuck in `Pending` state
- Events show: `Pod was evicted by VPA Updater to apply resource recommendation`
- Deployments never stabilize
- `kubectl top nodes` returns `error: Metrics API not available`

**Root Cause:** 
- VPA configured with `updateMode: "Auto"` but metrics-server not providing data
- VPA cannot calculate recommendations, enters eviction loop

**Prevention:**

#### When to Enable VPA:
- ✅ Metrics-server is running and providing data (`kubectl top nodes` works)
- ✅ Service has stable traffic patterns
- ✅ You want automated resource adjustments

#### When to Disable VPA:
- ❌ Metrics-server is down or unstable
- ❌ Service is low-priority or inactive
- ❌ You prefer manual resource tuning
- ❌ Service has highly variable workloads

**Safe VPA Configuration:**
```yaml
# For active services with working metrics-server
verticalPodAutoscaling:
  enabled: true
  updateMode: "Auto"  # Or "Recreate", never use "Initial"
  minCPU: 100m
  maxCPU: 1000m
  minMemory: 128Mi
  maxMemory: 2Gi
  controlledResources: ["cpu", "memory"]
  controlledValues: RequestsAndLimits
  recommendationMode: false

# For inactive/low-priority services
verticalPodAutoscaling:
  enabled: false
  updateMode: "Off"
  # ... rest can stay same
```

**Emergency Fix:**
```bash
# Disable VPA for problematic service
kubectl delete vpa -n <namespace> <service-name>

# Fix values.yaml
yq e '.verticalPodAutoscaling.enabled = false' -i apps/<service>/values.yaml
git commit -m "fix: disable VPA to stop eviction loop"
```

---

### 3. Pod Limit Exhaustion (110 pods/node)

**Issue:** Node refuses to schedule new pods when limit reached.

**Symptoms:**
```
Warning  FailedScheduling  nodes are available: 1 Too many pods. 
preemption: 0/1 nodes are available: 1 No preemption victims found
```

**Root Cause:**
- Default kubelet `maxPods: 110` per node
- Monitoring duplicates (multiple Prometheus/Grafana stacks)
- High replica counts on HPA
- Services stuck in `Terminating` state

**Prevention:**

#### Monitor Pod Count:
```bash
# Check current pod count
kubectl get pods --all-namespaces --no-headers | wc -l

# Check by namespace
kubectl get pods --all-namespaces --no-headers | \
  awk '{print $1}' | sort | uniq -c | sort -rn
```

#### Resource Allocation Strategy:
```yaml
# Tier 1: Critical Services (PostgreSQL, ERP API)
resources:
  requests:
    cpu: 400m-500m
    memory: 1.5Gi-2Gi
autoscaling:
  maxReplicas: 3-4  # Conservative

# Tier 2: Active Services
resources:
  requests:
    cpu: 100m-200m
    memory: 256Mi-512Mi
autoscaling:
  maxReplicas: 2-3

# Tier 3: Inactive/Standby
resources:
  requests:
    cpu: 30m-50m
    memory: 96Mi-128Mi
autoscaling:
  maxReplicas: 1-2  # Minimal
```

#### Prevent Duplicates:
Before deploying monitoring:
```bash
# Check existing Prometheus operators
kubectl get deployment --all-namespaces | grep prometheus-operator

# Check existing Grafana
kubectl get deployment --all-namespaces | grep grafana

# Check existing Alertmanager
kubectl get statefulset --all-namespaces | grep alertmanager
```

**Emergency Cleanup:**
```bash
# Force delete terminating pods
kubectl delete pod <pod-name> -n <namespace> --force --grace-period=0

# Scale down non-critical services
kubectl scale deployment <name> -n <namespace> --replicas=1
```

---

### 4. Secret Setup Failures (Database Connectivity)

**Issue:** `setup_env_secrets.sh` fails with "Environment secret setup failed"

**Root Cause:**
- Password mismatch between K8s secret and actual database
- Connection test pod times out (30s default)
- Wrong namespace lookups

**Prevention:**

#### Database Credential Source of Truth:
Always retrieve credentials from the **live database secret** (NOT env vars):

```bash
# PostgreSQL (shared in 'erp' namespace)
POSTGRES_PASSWORD=$(kubectl -n erp get secret postgresql \
  -o jsonpath='{.data.postgres-password}' | base64 -d)

# Redis (shared in 'erp' namespace)
REDIS_PASSWORD=$(kubectl -n erp get secret redis \
  -o jsonpath='{.data.redis-password}' | base64 -d)

# RabbitMQ (dedicated per namespace)
RABBITMQ_PASSWORD=$(kubectl -n $NAMESPACE get secret rabbitmq \
  -o jsonpath='{.data.rabbitmq-password}' | base64 -d)
```

#### Connection Verification:
```bash
# Test PostgreSQL connection
kubectl run -n $NAMESPACE pg-test-conn --rm -i --restart=Never \
  --image=postgres:15-alpine --timeout=30s \
  --env="PGPASSWORD=$POSTGRES_PASSWORD" \
  --command -- psql -h postgresql.erp.svc.cluster.local \
  -U postgres -d postgres -c "SELECT 1;"
```

**If test fails:**
```bash
# Option A: Reset DB password to match K8s secret (RECOMMENDED)
kubectl exec -n erp postgresql-0 -- psql -U postgres \
  -c "ALTER USER postgres WITH PASSWORD '$POSTGRES_PASSWORD';"

# Option B: Update K8s secret to match DB (if DB is correct)
kubectl -n erp create secret generic postgresql \
  --from-literal=postgres-password="$NEW_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
```

---

### 5. Metrics-Server Unavailability

**Issue:** HPAs show `<unknown>` for CPU/Memory targets.

**Symptoms:**
```bash
$ kubectl top nodes
error: Metrics API not available
```

**Root Cause:**
- metrics-server pod crashed or stuck
- Incorrect TLS configuration
- Pod on wrong node without network

**Prevention:**

#### Required Args:
```yaml
args:
  - --secure-port=10250
  - --cert-dir=/tmp
  - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
  - --kubelet-use-node-status-port
  - --metric-resolution=15s
  - --kubelet-insecure-tls  # Required for self-signed certs
```

#### Health Check:
```bash
# Check metrics-server pod
kubectl get pods -n kube-system -l k8s-app=metrics-server

# Test API endpoint
kubectl get --raw "/apis/metrics.k8s.io/v1beta1/nodes"

# Force restart if stuck
kubectl rollout restart deployment metrics-server -n kube-system
```

**Recovery:**
```bash
# Delete crashed pod
kubectl delete pod -n kube-system -l k8s-app=metrics-server

# Wait 30s for new pod
sleep 30

# Verify
kubectl top nodes
```

---

## 📋 Pre-Deployment Checklist

Before applying changes to production:

### 1. Values.yaml Validation
```bash
# Check all required fields exist
yq e '.migrations' apps/*/values.yaml
yq e '.verticalPodAutoscaling.enabled' apps/*/values.yaml

# Validate Helm templates
helm template . --name-template test --namespace test \
  --values apps/<service>/values.yaml \
  --debug --dry-run
```

### 2. Resource Limits Check
```bash
# Calculate total requested resources
kubectl get pods --all-namespaces -o json | \
  jq -r '.items[].spec.containers[].resources.requests | "\(.cpu // "0") \(.memory // "0")"' | \
  awk '{cpu+=$1; mem+=$2} END {print "CPU:", cpu, "Memory:", mem}'

# Check pod count
ACTIVE_PODS=$(kubectl get pods --all-namespaces --no-headers | \
  grep -cv "Terminating\|Completed")
echo "Active pods: $ACTIVE_PODS/110"
```

### 3. VPA Health Check
```bash
# Verify metrics-server before enabling VPA
kubectl top nodes || echo "⚠️ Metrics unavailable - DO NOT enable VPA"

# Check existing VPA resources
kubectl get vpa --all-namespaces
```

### 4. Duplicate Resource Check
```bash
# Check for duplicate operators
kubectl get deployment --all-namespaces | \
  grep -E "prometheus-operator|grafana" | \
  awk '{ns[$1]++} END {for (n in ns) if (ns[n] > 1) print "⚠️ Duplicates in", n}'
```

---

## 🔄 Monitoring & Alerts

Set up alerts for these issues:

```yaml
# Alert: Pod count approaching limit
- alert: PodLimitNearExhaustion
  expr: sum(kube_pod_info) > 100
  for: 5m
  annotations:
    summary: "Pod count: {{ $value }}/110 (danger threshold)"

# Alert: Metrics server down
- alert: MetricsServerUnavailable
  expr: up{job="metrics-server"} == 0
  for: 2m
  annotations:
    summary: "Metrics server unavailable - disable VPA!"

# Alert: High pod eviction rate
- alert: HighPodEvictionRate
  expr: rate(kube_pod_status_phase{phase="Failed"}[5m]) > 0.1
  annotations:
    summary: "High pod eviction rate - check VPA"
```

---

## 📚 Reference Documents

- [VPS-RESOURCE-ALLOCATION.md](./VPS-RESOURCE-ALLOCATION.md) - Resource prioritization strategy
- [OPERATIONS-RUNBOOK.md](./OPERATIONS-RUNBOOK.md) - Operational procedures
- [PRODUCTION-CHECKLIST.md](./PRODUCTION-CHECKLIST.md) - Deployment checklist

---

## 🔧 Quick Reference Commands

```bash
# Emergency: Disable all VPAs
kubectl delete vpa --all --all-namespaces

# Emergency: Scale down non-critical
for ns in pos inventory logistics ticketing subscription; do
  kubectl scale deployment --all -n $ns --replicas=1
done

# Emergency: Clean terminating pods
kubectl get pods --all-namespaces --field-selector status.phase=Terminating \
  -o json | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' | \
  xargs -n 2 sh -c 'kubectl delete pod $1 -n $0 --force --grace-period=0'

# Emergency: Free up pod slots
kubectl delete pods --all-namespaces --field-selector status.phase=Failed

# Check cluster health
kubectl get nodes
kubectl top nodes
kubectl get pods --all-namespaces | grep -v Running
```

---

**Last Updated:** December 10, 2025  
**Maintainer:** DevOps Team  
**Review Frequency:** After any major incident
