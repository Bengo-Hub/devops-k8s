# Vertical Pod Autoscaler (VPA) Manifests

This directory contains Vertical Pod Autoscaler installation manifests and configurations.

## Installation

### Option 1: Using the Install Script (Recommended)

```bash
kubectl apply -f vpa-v1.1.2.yaml
```

### Option 2: Latest Version from GitHub

```bash
kubectl apply -f https://github.com/kubernetes/autoscaler/releases/download/vertical-pod-autoscaler-1.1.2/vpa-v1.1.2.yaml
```

## Verification

Check VPA components are running:

```bash
kubectl get pods -n kube-system | grep vpa
```

Expected output:
```
vpa-admission-controller-xxx   1/1     Running
vpa-recommender-xxx           1/1     Running
vpa-updater-xxx               1/1     Running
```

## Usage

VPA can operate in three modes:

1. **"Off"** (Recommendation only) - Generates recommendations but doesn't apply them
2. **"Initial"** - Applies recommendations only at pod creation
3. **"Recreate"** - Applies recommendations by recreating pods when needed
4. **"Auto"** - Automatically applies recommendations (requires VPA Admission Controller)

## Example VPA Resource

See `example-vpa.yaml` for a sample VPA configuration.

## Important Notes

- VPA and HPA should not target the same metrics (CPU/Memory) on the same deployment
- Use VPA for resource optimization, HPA for scaling based on load
- In production, start with "Off" mode to observe recommendations before enabling auto-updates
- Our Helm chart automatically creates VPA resources when `verticalPodAutoscaling.enabled: true`

## Documentation

- [Official VPA Documentation](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler)
- [BengoERP Scaling Guide](../docs/scaling.md)

