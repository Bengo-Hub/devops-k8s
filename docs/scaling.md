Scaling
-------

## Horizontal Pod Autoscaler (HPA)

The application chart includes a sophisticated HPA configuration with multiple scaling strategies and custom metrics support.

### Basic Configuration

```yaml
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70
  targetMemoryUtilizationPercentage: 80
```

### Advanced Scaling Policies

The HPA supports advanced scaling behaviors with stabilization windows and multiple policies:

```yaml
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70
  targetMemoryUtilizationPercentage: 80
  # Scale-down behavior (conservative)
  scaleDown:
    stabilizationWindowSeconds: 300  # 5 minutes
    policies:
      - type: Percent
        value: 10      # Scale down by max 10%
        periodSeconds: 60
      - type: Pods
        value: 1       # Or scale down by max 1 pod
        periodSeconds: 60
    selectPolicy: Min  # Use the most conservative policy
  # Scale-up behavior (aggressive)
  scaleUp:
    stabilizationWindowSeconds: 60   # 1 minute
    policies:
      - type: Percent
        value: 50      # Scale up by max 50%
        periodSeconds: 60
      - type: Pods
        value: 2       # Or scale up by max 2 pods
        periodSeconds: 60
    selectPolicy: Max  # Use the most aggressive policy
```

### Custom Metrics

You can add custom metrics for more sophisticated scaling:

```yaml
autoscaling:
  customMetrics:
    - type: Pods
      metricName: http_requests_per_second
      targetType: AverageValue
      targetAverageValue: 100
    - type: Object
      metricName: requests_per_second
      describedObject:
        apiVersion: apps/v1
        kind: Deployment
        name: erp-api
      targetType: Value
      targetValue: 1000
```

### Monitoring HPA

View HPA status:

```bash
kubectl get hpa
kubectl describe hpa <app-name>
```

## Vertical Pod Autoscaler (VPA)

VPA automatically adjusts CPU and memory requests/limits based on usage patterns.

### Installation

Install VPA using the provided script:

```bash
# Install VPA components
./scripts/install-vpa.sh

# Verify installation
kubectl get pods -n kube-system | grep vpa
```

### Enable VPA in Applications

```yaml
verticalPodAutoscaling:
  enabled: true
  updateMode: "Recreate"  # Options: "Off", "Initial", "Recreate", "Auto"
  minCPU: 100m
  maxCPU: 2000m
  minMemory: 128Mi
  maxMemory: 2048Mi
  controlledResources: ["cpu", "memory"]
  controlledValues: RequestsAndLimits  # Update both requests and limits
  recommendationMode: false  # Set true for recommendation-only mode
```

### VPA Modes

- **Off**: Only provide recommendations, don't auto-update (safest for production start)
- **Initial**: Only sets resources on pod creation
- **Recreate**: Updates resources by recreating pods (recommended for production)
- **Auto**: Continuously updates resources in-place (requires VPA Admission Controller)

### Recommendation Mode

When `recommendationMode: true`, VPA operates in "Off" mode regardless of `updateMode` setting, providing recommendations without applying them. This is ideal for:
- Initial VPA deployment
- Validating VPA recommendations
- Testing resource optimization strategies

### Monitor VPA

```bash
# View VPA resources
kubectl get vpa --all-namespaces

# Get detailed VPA information
kubectl describe vpa <app-name> -n <namespace>

# View VPA recommendations
kubectl get vpa <app-name> -n <namespace> -o yaml | grep -A 20 "recommendation:"
```

## Best Practices

### HPA Recommendations
- **Set appropriate min/max replicas** based on your application needs
- **Use stabilization windows** to prevent thrashing
- **Monitor scaling events** in Grafana dashboards
- **Configure alerts** for scaling failures

### VPA Recommendations
- **Start with Initial mode** for conservative resource management
- **Monitor resource usage** before enabling Auto mode
- **Set reasonable min/max bounds** to prevent resource starvation
- **Use with HPA** for comprehensive scaling strategy

### Combined HPA + VPA Strategy
1. Use HPA for handling traffic spikes
2. Use VPA for optimizing resource efficiency
3. Monitor both scaling systems together
4. Set up alerts for scaling events

## Advanced Custom Metrics Configuration

### Application-Specific Metrics

For BengoERP applications, implement these custom metrics in your application code:

#### API Metrics Example
```yaml
autoscaling:
  customMetrics:
    - type: Pods
      metricName: http_requests_per_second
      targetType: AverageValue
      targetAverageValue: 50
    - type: Pods
      metricName: database_connection_pool_usage
      targetType: AverageValue
      targetAverageValue: 80
    - type: Pods
      metricName: api_response_time_p95
      targetType: AverageValue
      targetAverageValue: 500  # milliseconds
```

#### UI Metrics Example
```yaml
autoscaling:
  customMetrics:
    - type: Pods
      metricName: active_users_per_minute
      targetType: AverageValue
      targetAverageValue: 100
    - type: Pods
      metricName: frontend_error_rate
      targetType: AverageValue
      targetAverageValue: 1  # 1% error rate
```

### Setting Up Custom Metrics

1. **Expose Metrics Endpoint**: Ensure your application exposes metrics in Prometheus format
2. **Configure Prometheus**: Set up Prometheus to scrape your application metrics
3. **Create MetricServer Rules**: Define how to aggregate metrics for HPA
4. **Test Scaling**: Verify that HPA responds correctly to metric changes

## VPA Advanced Configuration and Safety

### VPA Update Policies

```yaml
verticalPodAutoscaling:
  enabled: true
  updateMode: "Recreate"  # Safer for production
  minCPU: 100m
  maxCPU: 2000m
  minMemory: 128Mi
  maxMemory: 4096Mi
  # Safety mechanisms
  recommendationMode: true  # Only provide recommendations initially
  controlledResources: ["cpu", "memory"]
  # Resource policy for different container types
  resourcePolicy:
    containerPolicies:
      - containerName: web
        minAllowed:
          cpu: 100m
          memory: 128Mi
        maxAllowed:
          cpu: 1000m
          memory: 2048Mi
      - containerName: worker
        minAllowed:
          cpu: 200m
          memory: 256Mi
        maxAllowed:
          cpu: 2000m
          memory: 4096Mi
```

### VPA Safety Best Practices

1. **Start with Recommendation Mode**: Enable `recommendationMode: true` initially
2. **Monitor Resource Usage**: Track VPA recommendations before applying them
3. **Gradual Rollout**: Apply VPA recommendations in small increments
4. **Set Resource Limits**: Always define min/max bounds to prevent resource starvation
5. **Alert on Anomalies**: Set up alerts for unusual resource recommendations

### Troubleshooting VPA

Common issues and solutions:

- **Pods not updating**: Check VPA admission controller is installed
- **Resource conflicts**: Verify resource requests don't exceed limits
- **Performance issues**: Monitor if VPA is causing too frequent pod restarts

## Multi-Environment Scaling Strategies

### Environment-Specific Configurations

#### Development Environment
```yaml
# Minimal scaling for cost efficiency
autoscaling:
  enabled: true
  minReplicas: 1
  maxReplicas: 3
  targetCPUUtilizationPercentage: 80

verticalPodAutoscaling:
  enabled: false  # Disable for dev to save resources
```

#### Staging Environment
```yaml
# Moderate scaling for testing
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 6
  targetCPUUtilizationPercentage: 70

verticalPodAutoscaling:
  enabled: true
  updateMode: "Initial"  # Conservative updates
  recommendationMode: true
```

#### Production Environment
```yaml
# Aggressive scaling for high availability
autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 20
  targetCPUUtilizationPercentage: 60  # More responsive scaling

verticalPodAutoscaling:
  enabled: true
  updateMode: "Recreate"  # Apply optimizations immediately
  recommendationMode: false  # Apply recommendations automatically
```

### Environment-Specific Monitoring

1. **Alert Thresholds**: Different alerting rules per environment
2. **Scaling Metrics**: Environment-specific scaling triggers
3. **Resource Budgets**: Different resource limits per environment
4. **Rollback Strategies**: Faster rollbacks in production

## Monitoring and Alerting Setup

### Key Metrics to Monitor

1. **HPA Metrics**:
   - Current/desired replicas
   - CPU/memory utilization
   - Scaling events and reasons
   - Cooldown periods

2. **VPA Metrics**:
   - Resource recommendations
   - Update frequency
   - Resource efficiency gains
   - Eviction events

3. **Application Metrics**:
   - Response times
   - Error rates
   - Throughput
   - Resource usage patterns

### Setting Up Alerts

```yaml
# Example PrometheusRule for scaling alerts
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: scaling-alerts
spec:
  groups:
  - name: scaling
    rules:
    - alert: HPAUnhealthy
      expr: kube_hpa_status_condition{condition="ScalingActive",status="false"} == 1
      for: 5m
      labels:
        severity: warning
    - alert: VPANotUpdating
      expr: vpa_container_recommendations > 0 and vpa_container_updates < 1
      for: 1h
      labels:
        severity: warning
```

## Performance Tuning Guide

### HPA Tuning

1. **Stabilization Windows**:
   - Scale-down: 300s (prevents thrashing)
   - Scale-up: 60s (responsive to load increases)

2. **Target Utilization**:
   - CPU: 60-70% (balance responsiveness vs stability)
   - Memory: 70-80% (memory is harder to predict)

3. **Replica Bounds**:
   - Min: At least 2 for HA, but consider costs
   - Max: Based on infrastructure limits and load testing

### VPA Tuning

1. **Update Modes**:
   - **Initial**: Safe for initial deployment
   - **Recreate**: Good for optimizing resource usage
   - **Auto**: Most aggressive, use with caution

2. **Resource Bounds**:
   - Set based on application profiling
   - Include buffer for spikes
   - Monitor for over/under-provisioning

## Resource Sizing Policy (single production node)

Production runs on one node (12 vCPU, 48 GiB). Requests decide what can be scheduled and each pod's share of CPU under contention. Limits only cap bursts. The target is CPU and memory requests near 60% of the node, leaving room for surge rollouts and HPA scale-out.

### Measuring

`scripts/cluster/capacity-report.sh` is read-only and prints requests against live use per pod, throttling per container, HPA status, ingress traffic per upstream and JetStream consumer state. There is no Prometheus on this cluster, so this report and the VPA recommendations are the sizing signals.

```powershell
Get-Content scripts/cluster/capacity-report.sh -Raw | ssh mss-prod "sed '1s/^\xEF\xBB\xBF//' | tr -d '\r' | bash -s -- pods"
```

Sections: `node`, `pods`, `throttle`, `hpa`, `traffic`, `nats`. Measure during the daily peak (around 17:00 UTC) as well as off peak, because night readings understate daytime CPU.

### Tiers

| Tier | Services | CPU request | Notes |
|---|---|---|---|
| Hot | pos-api, auth-api, inventory-api | 100m to 150m | Largest share under contention, HPA room to 4 or 6 pods |
| Hot UI | pos-ui, inventory-ui | 50m | CPU limit 1000m |
| Normal | treasury-api, erp-api, maskani-api, ordering-backend, ordering-frontend, truload | 50m and up | Scalable HPAs, so requests stay above the scale-out point |
| Idle | Other UIs and fixed size APIs | 25m | Limits unchanged, so bursts are unaffected |
| Platform | postgres, redis, nats, ingress, stalwart | Set per workload | Changed off peak only |

### Rules

- **HPA targets are a percentage of the request.** Lowering a request on an app whose HPA can scale makes it scale earlier. Memory requests only drop to 128Mi where min and max replicas are equal. truload-backend must stay well above 512Mi: its working set of about 350Mi per pod pinned it at 4 replicas at that value.
- **Init containers count.** A pod reserves the larger of its containers' total and its largest init container, so check both when a cut does not change the node totals.
- **Git must state a value to change it.** ArgoCD's client-side three-way diff never removes a live field that git does not set. Stale values from old manual patches stay until git names the field.
- **Low limits throttle more than low requests.** A workload that bursts briefly needs a limit that fits the burst, even when its average use is tiny.
- **Count exec probes.** An exec probe that starts the app (for example `celery inspect ping`) costs a full interpreter start each time. isp-billing's two celery probes cost ~70m of constant CPU at 30s and 60s; both now run every 5 minutes.
- **Removing a field can fail even under server-side apply.** Workloads first created before an Application used server-side apply still carry an old `argocd-application-controller` Update entry in managedFields. That stale owner keeps part of a field when git drops it (a probe lost its handler and the sync failed). Change such fields' values in git rather than removing them, or clear the stale managedFields entry first.
- **Host port workloads cannot surge.** metrics-server and ingress-nginx use `maxSurge: 0`, and wireguard uses `Recreate`. Any change to the ingress-nginx pod spec has previously caused a deadlock on its host ports, so it needs a planned window and the recovery steps at hand.

### VPA

All VPAs run in `Off` mode with floors of 10m and 32Mi, so recommendations show real use over about 8 days and no pods are changed. Recommendations are input for a decision, not a value to apply directly: they do not know about HPA targets.

### JetStream streams and consumers

Both CronJobs live in `manifests/nats-stream-retention-job.yaml` and apply to every stream they find on the server, so a new service needs no entry anywhere.

- **Streams** (`nats-stream-retention`, every 6 hours): at most 7 days and 512MiB each, 14 days and 256MiB for `*-dlq`. Limits only tighten, so an app that keeps a stream for 3 days keeps 3 days. JetStream allows 10GiB per server and every R3 stream sits on every server, which is why the byte cap is 512MiB. Streams stay R3.
- **Consumers** (`nats-consumer-replicas`, every 10 minutes): R1, because all three nats pods share the node and R3 consumer raft traffic cost about a quarter of real node CPU (NATS fell from ~830m to ~80m). An R1 consumer pauses while its nats pod restarts and resumes from disk afterwards.
- **Orphaned durables expire on their own.** Every durable gets a 7 day InactiveThreshold, so one whose subscriber is gone (feature switched off, durable renamed, code removed) is deleted by the server after 7 days without a subscriber. Nothing is lost: the stream has already dropped anything older. A service that is down longer gets a fresh durable with its own deliver policy.
- Do not set `nats.ConsumerReplicas` in service code: nats.go rejects a bind when the value differs from the existing durable.
- To find a subscriber that should be running but is not, run the `nats` section of `capacity-report.sh` and check any unbound durable against its owning service's code and against the other consumers on the same subject.

### Applying changes

- `apps/*/values.yaml` and manifests under an Application sync through ArgoCD.
- `apps/**/app.yaml` and `manifests/**` also trigger `.github/workflows/provision.yml`, which applies Application changes and `manifests/argocd-cm.yaml`.
- `scripts/cluster/set-system-resource-requests.sh` covers components outside ArgoCD (ArgoCD itself, coredns, kube-proxy, cert-manager, calico) and must be re-run after `kubeadm upgrade`.

## Cost Optimization Strategies

### Right-Sizing with VPA

1. **Monitor Recommendations**: Use VPA in recommendation mode for 2-4 weeks
2. **Analyze Patterns**: Identify peak and baseline resource usage
3. **Set Optimal Bounds**: Adjust min/max based on observed patterns
4. **Enable Auto Mode**: Apply recommendations automatically

### HPA Cost Optimization

1. **Scale-to-Zero**: Consider enabling for non-critical workloads
2. **Scheduled Scaling**: Use cron-based scaling for predictable workloads
3. **Budget-Based Scaling**: Scale based on cost budgets and time windows

## Troubleshooting Guide

### HPA Issues

**Problem**: HPA not scaling
- Check metrics server is running: `kubectl get deployment metrics-server -n kube-system`
- Verify custom metrics are available: `kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1`
- Check HPA status: `kubectl describe hpa <hpa-name>`

**Problem**: HPA scaling too aggressively
- Increase stabilization windows
- Lower target utilization percentages
- Add custom metrics for better signals

### VPA Issues

**Problem**: VPA not updating resources
- Check VPA admission controller: `kubectl get mutatingwebhookconfigurations`
- Verify VPA is enabled in your namespace
- Check VPA status: `kubectl describe vpa <vpa-name>`

**Problem**: Resource conflicts after VPA updates
- Adjust resource limits in deployment
- Review VPA recommendations before applying
- Consider using different update modes

### Multi-Environment Issues

**Problem**: Inconsistent scaling behavior across environments
- Standardize metric collection and alerting
- Use consistent resource bounds where possible
- Implement environment-specific overrides carefully

## Integration with CI/CD

### Automated Scaling Configuration

The build scripts automatically update scaling configurations:

```bash
# Example from build.sh
yq -yi ".autoscaling.targetCPUUtilizationPercentage = 70" "$VALUES_FILE_PATH"
yq -yi ".verticalPodAutoscaling.enabled = true" "$VALUES_FILE_PATH"
```

### Validation in CI/CD

Add validation steps to your deployment pipeline:

```yaml
# In GitHub Actions workflow
- name: Validate scaling configuration
  run: |
    kubectl apply --dry-run=client -f scaling-config.yaml
    # Validate HPA and VPA configurations
```

This comprehensive scaling documentation ensures optimal resource utilization and application performance across all deployment environments.

## Queue-driven Autoscaling (KEDA)

KEDA scales consumers (e.g., Celery workers) based on queue depth or external events.

### Install KEDA

KEDA is deployed via ArgoCD (`apps/keda/app.yaml`) and exposes the `ScaledObject` CRD.

### Enable KEDA for an App

1. Ensure the application chart values enable KEDA and provide triggers:

```yaml
keda:
  enabled: true
  minReplicas: 2
  maxReplicas: 20
  triggers:
    - type: redis
      metadata:
        address: "redis-master.infra.svc:6379"
        listName: "celery"
        listLength: "100"
      authenticationRef:
        name: redis-auth
```

2. Create a `TriggerAuthentication` with broker credentials:

```yaml
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: redis-auth
  namespace: <app-namespace>
spec:
  secretTargetRef:
    - parameter: password
      name: redis-credentials
      key: redis-password
```

3. Validate scaling:

```bash
kubectl get scaledobject -A
kubectl describe scaledobject <name> -n <namespace>
```

### Notes
- Prefer `TriggerAuthentication` with Secrets; avoid embedding credentials in values.
- For RabbitMQ, use the `rabbitmq` trigger with `queueName` and `host` parameters.
- Combine KEDA (depth-based) with HPA (CPU/memory) where appropriate.