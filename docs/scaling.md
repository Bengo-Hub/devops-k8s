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

### Enable VPA

```yaml
verticalPodAutoscaling:
  enabled: true
  updateMode: Auto  # or "Initial" or "Recreate"
  minCPU: 100m
  maxCPU: 2000m
  minMemory: 128Mi
  maxMemory: 2048Mi
```

### VPA Modes

- **Auto**: Continuously updates resource recommendations
- **Initial**: Only sets resources on pod creation
- **Recreate**: Updates resources by recreating pods

### Monitor VPA

```bash
kubectl get vpa
kubectl describe vpa <app-name>
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
