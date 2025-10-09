Scaling
-------

Horizontal (HPA)
----------------
Enabled by default using CPU utilization. Configure in values:

```yaml
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70
```

Vertical
--------
Adjust `.values.resources` requests/limits. Optionally install VPA in the cluster for automated recommendations.


