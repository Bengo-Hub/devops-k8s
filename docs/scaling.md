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
