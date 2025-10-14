# Health Checks and Rolling Updates

This document explains how BengoERP deployments achieve zero-downtime with automated health validation and progressive rollouts.

## Overview

Every deployment in the cluster uses:
- **Readiness probes** - determines when pods can receive traffic
- **Liveness probes** - detects and restarts unhealthy containers
- **Rolling update strategy** - gradually replaces old pods with new ones
- **ArgoCD automation** - detects value changes and syncs automatically

## Health Check Endpoints

### Required for Every Service

Each application **must** implement a `/health` endpoint that:
- Returns HTTP 200 when healthy
- Returns 4xx/5xx when unhealthy
- Responds within timeout (3-5 seconds)
- Checks critical dependencies (DB, Redis, etc.)

### ERP UI Health Endpoint

**Path**: `/health`  
**Implementation**: `server.js`

```javascript
app.get('/health', (req, res) => {
  res.status(200).json({
    status: 'healthy',
    timestamp: new Date().toISOString(),
    service: 'erp-ui',
    version: '1.0.0'
  });
});
```

**Probe Configuration**:
```yaml
readiness:
  httpGet:
    path: /health
    port: http
  initialDelaySeconds: 10
  periodSeconds: 10
  failureThreshold: 3

liveness:
  httpGet:
    path: /health
    port: http
  initialDelaySeconds: 30
  periodSeconds: 15
  failureThreshold: 3
```

### ERP API Health Endpoint

**Path**: `/api/v1/core/health/`  
**Implementation**: Django view in `core/views.py`

**Expected Response**:
```json
{
  "status": "healthy",
  "database": "connected",
  "redis": "connected",
  "timestamp": "2025-10-14T10:30:00Z"
}
```

**Probe Configuration**:
```yaml
readiness:
  httpGet:
    path: /api/v1/core/health/
    port: http
  initialDelaySeconds: 15
  periodSeconds: 10
  failureThreshold: 3

liveness:
  httpGet:
    path: /api/v1/core/health/
    port: http
    initialDelaySeconds: 45
    periodSeconds: 20
    failureThreshold: 3
```

## Rolling Update Strategy

### Zero-Downtime Configuration

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1          # Create 1 new pod at a time
    maxUnavailable: 0    # Keep all current pods running
```

**How it works**:
1. New pod created (total: replicas + 1)
2. New pod starts, runs readiness probe
3. After readiness passes, Service adds new pod to endpoints
4. Traffic gradually shifts to new pod
5. Old pod removed
6. Repeat for next replica

**Timeline** (2-replica deployment):
```
T+0s:   Old pods: 2 running, New pods: 0
T+10s:  Old pods: 2 running, New pods: 1 (starting)
T+25s:  Old pods: 2 running, New pods: 1 (ready) ← readiness passed
T+30s:  Old pods: 1 running, New pods: 1 ← old pod terminated
T+40s:  Old pods: 1 running, New pods: 2 (starting)
T+55s:  Old pods: 1 running, New pods: 2 (ready)
T+60s:  Old pods: 0, New pods: 2 ← rollout complete
```

### Rollout Safety

**Automatic pause if**:
- Readiness probe fails 3+ times consecutively
- New pods crash/restart repeatedly
- Progress deadline exceeded (default: 10 minutes)

**Old pods remain**:
- Serving traffic during entire rollout
- Only removed after new pods pass readiness
- Rollback possible at any time

## Readiness vs Liveness Probes

### Readiness Probe

**Purpose**: Is the pod ready to serve traffic?

**When it fails**:
- Pod removed from Service endpoints
- No traffic routed to this pod
- Pod stays running (not restarted)
- Keeps checking until passes

**Use for**:
- Database connection checks
- Warm-up periods
- Temporary unavailability

### Liveness Probe

**Purpose**: Is the pod still alive?

**When it fails**:
- Pod is killed and restarted
- Pod removed from Service during restart
- Helps recover from deadlocks, hangs

**Use for**:
- Application crash detection
- Unresponsive processes
- Resource exhaustion

### Best Practices

**Timing**:
- Liveness `initialDelaySeconds` > Readiness (allow startup time)
- Liveness `period` > Readiness (less aggressive checking)
- Readiness `failureThreshold`: 3 (allow temporary issues)
- Liveness `failureThreshold`: 3 (avoid restart loops)

**Health Endpoint Guidelines**:
- Keep checks lightweight (< 1 second)
- Check critical dependencies only
- Return quickly on failure (don't retry internally)
- Include version/build info for debugging

## Monitoring Rollouts

### Watch Real-Time Progress

```bash
# Monitor rollout status
kubectl -n erp rollout status deploy/erp-api-app
kubectl -n erp rollout status deploy/erp-ui-app

# Watch pods being replaced
kubectl -n erp get pods -w

# Check rollout history
kubectl -n erp rollout history deploy/erp-api-app
```

### Check Health Status

```bash
# View probe configuration
kubectl -n erp describe pod <pod-name> | grep -A 10 "Liveness\|Readiness"

# Check current endpoints (should show all ready pods)
kubectl -n erp get endpoints erp-api-app -o wide
kubectl -n erp get endpoints erp-ui-app -o wide

# Test health endpoints directly
kubectl -n erp exec deploy/erp-api-app -- curl -sf http://localhost:4000/api/v1/core/health/
kubectl -n erp exec deploy/erp-ui-app -- curl -sf http://localhost:3000/health
```

### Rollout Events

```bash
# Check deployment events
kubectl -n erp describe deploy erp-api-app | tail -n 20
kubectl -n erp describe deploy erp-ui-app | tail -n 20

# View pod events (for failures)
kubectl -n erp get events --sort-by='.lastTimestamp' | grep -i "erp-api\|erp-ui"
```

## Rollback Procedures

### Automatic Rollback

Kubernetes will automatically pause rollouts if:
- New pods fail readiness repeatedly
- Progress deadline exceeded

### Manual Rollback

```bash
# Rollback to previous revision
kubectl -n erp rollout undo deploy/erp-api-app
kubectl -n erp rollout undo deploy/erp-ui-app

# Rollback to specific revision
kubectl -n erp rollout history deploy/erp-api-app  # see revision numbers
kubectl -n erp rollout undo deploy/erp-api-app --to-revision=3
```

### ArgoCD Rollback

```bash
# View app history
argocd app history erp-api

# Rollback to previous version
argocd app rollback erp-api --revision <previous>

# Or edit values.yaml in devops-k8s and ArgoCD will sync
```

## Troubleshooting

### Pods Stuck in NotReady

**Check readiness probe failures**:
```bash
kubectl -n erp describe pod <pod-name> | grep -A 5 "Readiness"
kubectl -n erp logs <pod-name> --tail=100
```

**Common causes**:
- Health endpoint not responding (check path, port)
- App not listening on expected port
- Database connection failing
- Slow startup (increase `initialDelaySeconds`)

### Rollout Stuck

```bash
# Check rollout status
kubectl -n erp rollout status deploy/erp-api-app --timeout=60s

# If stuck, view deployment conditions
kubectl -n erp get deploy erp-api-app -o yaml | grep -A 10 "conditions:"
```

**Fix**:
```bash
# Pause rollout to investigate
kubectl -n erp rollout pause deploy/erp-api-app

# After fixing issue, resume
kubectl -n erp rollout resume deploy/erp-api-app

# Or rollback
kubectl -n erp rollout undo deploy/erp-api-app
```

### CrashLoopBackOff During Rollout

**Investigate**:
```bash
# View logs from failing container
kubectl -n erp logs <pod-name> --previous

# Check events
kubectl -n erp describe pod <pod-name>
```

**Common issues**:
- Environment variables missing/incorrect
- Database credentials wrong
- Image pull failed (check imagePullSecrets)
- Health endpoint crashing the app

## Production Deployment Checklist

Before deploying to production:

- [ ] Health endpoint implemented and tested
- [ ] Readiness probe configured with appropriate delays
- [ ] Liveness probe configured (less aggressive than readiness)
- [ ] Rolling update strategy set (maxUnavailable: 0 for zero downtime)
- [ ] imagePullSecrets configured if using private registry
- [ ] Database migrations run successfully
- [ ] Environment secrets populated
- [ ] ArgoCD application has Replace=true syncOption
- [ ] Monitoring/alerts configured for deployment failures

## Integration with CI/CD

The automated workflows handle all of this automatically:

1. **Build phase**: Creates image with health checks implemented
2. **Pre-deployment**: Creates/updates registry credentials in cluster
3. **Values update**: Pushes new tag to devops-k8s using PAT
4. **ArgoCD sync**: Detects change and triggers rolling update
5. **Health validation**: Kubernetes validates each new pod
6. **Traffic switch**: Service routes to healthy pods only
7. **Cleanup**: Old pods removed after new ones are ready

**Manual intervention needed only for**:
- Rollback (if automated rollout fails)
- Debugging pod failures
- Adjusting probe settings

## References

- [Kubernetes Liveness/Readiness Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
- [ArgoCD Sync Options](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/)
- [Rolling Update Strategy](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-update-deployment)

