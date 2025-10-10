Scaling
-------

Horizontal Pod Autoscaling (HPA)
---------------------------------

HPA is **enabled by default** for all ERP services with production-ready configurations.

### Current Configuration

**ERP API:**
- Min replicas: 2
- Max replicas: 10
- CPU target: 70%
- Memory target: 80%

**ERP UI:**
- Min replicas: 2
- Max replicas: 8
- CPU target: 70%
- Memory target: 80%

### How It Works

The HPA controller monitors CPU and memory usage every 15 seconds:
- **Scale Up**: When average CPU > 70% OR memory > 80% for 30 seconds
- **Scale Down**: When usage is low for 5 minutes (stabilization window)
- **Aggressive Scale Up**: Can double pods instantly or add 2 pods, whichever is greater
- **Gradual Scale Down**: Reduces by 50% per minute max

### Customization

Edit `apps/erp-api/values.yaml` or `apps/erp-ui/values.yaml`:

```yaml
autoscaling:
  enabled: true
  minReplicas: 3        # Minimum pods (for HA)
  maxReplicas: 15       # Maximum pods (based on cluster capacity)
  targetCPUUtilizationPercentage: 60     # Scale up when CPU > 60%
  targetMemoryUtilizationPercentage: 75  # Scale up when memory > 75%
```

### Monitor HPA

```bash
# Watch HPA status
kubectl get hpa -n erp -w

# Detailed HPA info
kubectl describe hpa -n erp

# Check current metrics
kubectl top pods -n erp
```

### Test Autoscaling

```bash
# Generate load on API
kubectl run -n erp load-test --image=busybox --restart=Never -- \
  /bin/sh -c "while true; do wget -q -O- http://erp-api.erp.svc.cluster.local/api/v1/core/health/; done"

# Watch scaling
kubectl get hpa -n erp -w

# Clean up
kubectl delete pod load-test -n erp
```

Vertical Pod Autoscaling (VPA)
-------------------------------

VPA provides resource recommendations and can automatically adjust requests/limits.

### Installation (Optional)

```bash
# Install VPA
kubectl apply -f https://github.com/kubernetes/autoscaler/releases/download/vertical-pod-autoscaler-1.0.0/vpa-v1.0.0.yaml

# Verify
kubectl get pods -n vpa-system
```

### Enable VPA for ERP Services

```bash
# Apply VPA manifests (recommendation mode)
kubectl apply -f manifests/vpa/vpa-setup.yaml

# Check recommendations
kubectl describe vpa -n erp
```

### VPA Modes

1. **"Off"** (Recommendation only) - Default, safe
   - Provides recommendations via `kubectl describe vpa`
   - No automatic changes
   - Review recommendations quarterly

2. **"Initial"** (Apply on pod creation)
   - Sets resources when pod is created
   - Doesn't modify running pods

3. **"Auto"** (Continuous adjustment)
   - Actively restarts pods with new resources
   - Use with caution in production
   - Conflicts with HPA if both target CPU/memory

### Best Practice: HPA + VPA

- **Use HPA** for horizontal scaling (enabled by default)
- **Use VPA** in "Off" mode for recommendations
- Manually adjust resource requests/limits based on VPA recommendations
- Review VPA suggestions monthly and update values files

Resource Management
-------------------

### Current Resources (ERP API)

```yaml
resources:
  requests:
    cpu: 250m      # Guaranteed CPU
    memory: 512Mi  # Guaranteed memory
  limits:
    cpu: 2000m     # Max CPU (burst)
    memory: 2Gi    # Max memory (hard limit)
```

### Current Resources (ERP UI)

```yaml
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 1000m
    memory: 1Gi
```

### Adjusting Resources

1. Review actual usage:
   ```bash
   kubectl top pods -n erp --sort-by=cpu
   kubectl top pods -n erp --sort-by=memory
   ```

2. Update values files based on 80th percentile usage
3. Commit and push to trigger ArgoCD sync

Cluster Capacity Planning
-------------------------

### Your Contabo VPS (48GB RAM, 12 cores)

**Available for workloads** (after system overhead):
- CPU: ~10 cores
- Memory: ~42GB

**Current allocation** (with default configs):
- ERP API: 2-10 pods × (250m-2000m CPU, 512Mi-2Gi RAM)
- ERP UI: 2-8 pods × (100m-1000m CPU, 256Mi-1Gi RAM)
- PostgreSQL: ~2GB RAM, 1 CPU
- Redis: ~1GB RAM, 500m CPU
- Monitoring: ~4GB RAM, 2 CPU

**Estimated max concurrent pods:**
- Conservative: 20-25 pods total
- Aggressive: 30-35 pods total

### Monitor Cluster Resources

```bash
# Node resources
kubectl top nodes

# Resource quotas (optional)
kubectl describe resourcequota -n erp

# Check pod scheduling
kubectl get events -n erp --sort-by='.lastTimestamp'
```

Best Practices
--------------

1. **Set requests = typical usage** (80th percentile)
2. **Set limits = max burst** (2-4x requests)
3. **Keep requests:limits ratio consistent** across replicas
4. **Monitor and adjust quarterly** based on VPA recommendations
5. **Use HPA for traffic spikes** (enabled)
6. **Use VPA for right-sizing** (recommendation mode)
7. **Never disable both** requests and limits
8. **Test scaling** before production traffic


