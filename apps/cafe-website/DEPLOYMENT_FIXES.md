# Cafe Website Deployment Fixes

## Issues Fixed

### 1. Missing Kubernetes Secret
**Error:** `secret "cafe-website-secrets" not found`

**Root Cause:** The deployment referenced a secret that wasn't created in the cluster.

**Fix Applied:**
- Made secrets optional in the Helm deployment by adding `optional: true` to `secretKeyRef`
- Updated `values.yaml` to have `envSecrets` as optional environment variables
- Created `secrets.yaml` template for optional secret creation
- These secrets (mapboxToken, sentryDsn) are now optional and won't block deployment

### 2. Pod Resource Constraints & Kubelet Timeout
**Error:** `unable to start unit "kubepods-burstable-pod..." Timeout waiting for systemd`

**Root Cause:** Resource limits were causing systemd timeout on container creation

**Fixes Applied:**
- **Reduced memory limits:** From 768Mi to 512Mi (Next.js app doesn't need 768Mi)
- **Reduced request limits:** From 100m CPU to 50m, from 256Mi to 128Mi memory
- **Improved health checks:** Changed from `/healthz` endpoint (doesn't exist on Next.js) to `/` (always available)
- **Increased health check timeouts:** Added proper timeout values and failure thresholds
- **Disabled autoscaling:** For single instance deployment
- **Optimized strategy:** Kept rolling update with maxUnavailable=0 for zero-downtime

## Configuration Changes

### values.yaml Updates
```yaml
# Old
resources:
  limits:
    cpu: 500m
    memory: 768Mi
  requests:
    cpu: 100m
    memory: 256Mi

autoscaling:
  enabled: true
  minReplicas: 1
  maxReplicas: 1

# New
resources:
  limits:
    cpu: 1000m      # Increased for burst capacity
    memory: 512Mi   # Reduced from 768Mi
  requests:
    cpu: 50m        # Reduced from 100m
    memory: 128Mi   # Reduced from 256Mi

autoscaling:
  enabled: false    # Single instance doesn't need autoscaling
```

### Health Check Improvements
```yaml
# Old
healthCheck:
  readiness:
    httpGet:
      path: /healthz  # Endpoint doesn't exist on Next.js
    initialDelaySeconds: 5
    periodSeconds: 10

# New
healthCheck:
  readiness:
    httpGet:
      path: /         # Root path always works
    initialDelaySeconds: 10
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
```

### Optional Secrets
Moved from hard-required secrets to optional:
```yaml
# Old - Would fail if secret didn't exist
env:
  - name: NEXT_PUBLIC_MAPBOX_TOKEN
    valueFrom:
      secretKeyRef:
        name: cafe-website-secrets
        key: mapboxToken

# New - Optional, won't block deployment
envSecrets:
  - name: NEXT_PUBLIC_MAPBOX_TOKEN
    secretKey: mapboxToken
    secretName: cafe-website-secrets
    # Now uses optional: true in deployment
```

## Deployment Steps

### 1. Create the Cafe Namespace (Optional)
```bash
cd devops-k8s/apps/cafe-website
bash setup-namespace.sh
```

### 2. Apply Helm Chart (via ArgoCD or Manual)
The cafe-website will now deploy with:
- **Optional secrets** - Won't fail if `cafe-website-secrets` doesn't exist
- **Lower resource requirements** - Faster pod startup
- **Better health checks** - Proper HTTP endpoint monitoring

### 3. (Optional) Add Secrets Later
If you want to add Mapbox or Sentry tokens:
```bash
kubectl create secret generic cafe-website-secrets \
  --from-literal=mapboxToken='YOUR_TOKEN' \
  --from-literal=sentryDsn='YOUR_DSN' \
  -n cafe
```

Restart the deployment to pick up the new secrets:
```bash
kubectl rollout restart deployment/cafe-website -n cafe
```

## Files Modified

1. **devops-k8s/apps/cafe-website/values.yaml**
   - Optimized resource limits
   - Made secrets optional
   - Improved health checks
   - Disabled unnecessary autoscaling

2. **devops-k8s/charts/app/templates/deployment.yaml**
   - Added support for optional secrets with `optional: true`
   - Improved environment variable handling

3. **devops-k8s/charts/app/templates/secrets.yaml** (NEW)
   - Template for creating optional secrets

4. **Cafe/cafe-website/build.sh**
   - Better error handling for secret creation
   - Won't fail if secrets can't be created

5. **devops-k8s/apps/cafe-website/setup-namespace.sh** (NEW)
   - Helper script for setting up the cafe namespace

## Verification

After deployment, verify with:
```bash
# Check pod status
kubectl get pods -n cafe

# Check logs
kubectl logs -f deployment/cafe-website -n cafe

# Check events
kubectl describe pod -n cafe -l app=cafe-website

# Test connectivity
kubectl port-forward svc/cafe-website 3000:80 -n cafe
# Visit http://localhost:3000
```

## Performance Improvements

- **Faster startup:** Lower memory requests allow quicker pod creation
- **Better health checks:** Proper endpoint path prevents false negatives
- **No secret blocking:** Deployment succeeds even without optional secrets
- **Reduced resource usage:** Lower memory limits (512Mi vs 768Mi)

## Next Steps (Recommended)

1. Monitor pod logs for any environment variable warnings
2. Add secrets once you have Mapbox and Sentry tokens
3. Consider adding HPA (Horizontal Pod Autoscaler) if traffic increases
4. Set up monitoring/alerting for pod restart events
