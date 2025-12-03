# Seed Hook Usage Guide

## Overview

The `seed-hook.yaml` template provides a reusable Kubernetes Job for seeding initial data in services during deployment.

## Features

- ✅ **Automatic Seeding**: Runs after migrations (post-install, post-upgrade)
- ✅ **Environment Variables**: Inherits from service secret (same as main app)
- ✅ **Flexible Configuration**: Supports custom commands or auto-detection
- ✅ **Resource Limits**: Configurable CPU/memory limits
- ✅ **Hook Lifecycle**: Helm hooks with proper ordering (weight: 5, after migrations)
- ✅ **Auto-Cleanup**: TTL 600s after completion

## Configuration

### Basic Setup (Auto-Detection)

Add to your service's `values.yaml`:

```yaml
seed:
  enabled: true
  binaryName: auth-seed  # Optional: defaults to <service-name>-seed
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
```

The hook will automatically try:
1. `/usr/local/bin/<binaryName>` (e.g., `/usr/local/bin/auth-seed`)
2. `/app/seed`
3. `python /app/manage.py seed` (Django)
4. `php /app/artisan db:seed` (Laravel)

### Custom Command

For services with custom seed logic:

```yaml
seed:
  enabled: true
  command:
    - /usr/local/bin/my-custom-seed
    - --environment=production
    - --verbose
  env:
    - name: SEED_ADMIN_PASSWORD
      value: "ChangeMe123!"
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
```

### Advanced: Python/Django Example

```yaml
seed:
  enabled: true
  command:
    - python
    - manage.py
    - loaddata
    - initial_data.json
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 1Gi
```

### Advanced: Shell Script Example

```yaml
seed:
  enabled: true
  command:
    - bash
    - -c
    - |
      set -e
      echo "Custom seeding logic"
      /app/scripts/seed-tenants.sh
      /app/scripts/seed-users.sh
      echo "Seeding complete"
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
```

## Service-Specific Examples

### Auth Service

```yaml
# devops-k8s/apps/auth-service/values.yaml
seed:
  enabled: true
  binaryName: auth-seed  # Binary built in Dockerfile
  env:
    - name: SEED_ADMIN_PASSWORD
      valueFrom:
        secretKeyRef:
          name: auth-admin-password
          key: password
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
```

### ERP API (Django)

```yaml
# devops-k8s/apps/erp-api/values.yaml
seed:
  enabled: true
  command:
    - python
    - manage.py
    - seed_initial_data
  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 1Gi
```

### Inventory Service (Go)

```yaml
# devops-k8s/apps/inventory-service/values.yaml
seed:
  enabled: true
  binaryName: inventory-seed
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
```

## Dockerfile Requirements

Ensure your service's Dockerfile builds the seed binary:

### Go Example:

```dockerfile
FROM golang:1.24-alpine AS builder
WORKDIR /app
COPY . .

# Build both server and seed binaries
RUN CGO_ENABLED=0 go build -o /bin/app ./cmd/server && \
    CGO_ENABLED=0 go build -o /bin/app-seed ./cmd/seed

FROM alpine:3.20
COPY --from=builder /bin/app /usr/local/bin/app
COPY --from=builder /bin/app-seed /usr/local/bin/app-seed

ENTRYPOINT ["/usr/local/bin/app"]
```

### Python/Django Example:

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .

# Seed command: python manage.py seed
# (Define custom management command in app/management/commands/seed.py)
```

## Verification

### Check Seed Job Status:

```bash
# List seed jobs
kubectl get jobs -n <namespace> -l component=seed

# Check logs
kubectl logs -n <namespace> job/<service-name>-seed-<tag>

# Describe job
kubectl describe job -n <namespace> <service-name>-seed-<tag>
```

### Expected Output:

```
=========================================
auth-service - Seeding
=========================================
Namespace: auth
Release: auth-service
Image: docker.io/codevertex/auth-service:abc12345

✓ Running seed binary: /usr/local/bin/auth-seed
seed completed: admin=admin@codevertexitsolutions.com tenant=codevertex password=ChangeMe123!
✓ Seed job completed successfully
```

## Troubleshooting

### Seed Job Not Running

1. **Check if enabled:**
   ```yaml
   seed:
     enabled: true  # Must be true
   ```

2. **Verify Helm hooks:**
   ```bash
   kubectl get jobs -n <namespace> --show-labels
   # Look for: helm.sh/hook=post-install,post-upgrade
   ```

### Seed Binary Not Found

1. **Verify binary exists in image:**
   ```bash
   kubectl run -it --rm debug --image=<your-image> -- sh
   ls -la /usr/local/bin/
   ```

2. **Update binaryName:**
   ```yaml
   seed:
     binaryName: my-actual-seed-binary-name
   ```

### Environment Variables Missing

Ensure `envFromSecret` is set:
```yaml
envFromSecret: <service-name>-env
seed:
  enabled: true
  # env vars automatically loaded from secret
```

### Job Fails with Exit Code 1

Check logs:
```bash
kubectl logs -n <namespace> job/<service-name>-seed-<tag>
```

Common issues:
- Database not ready (should be handled by migration hook)
- Missing environment variables
- Incorrect seed logic

## Best Practices

1. **Idempotent Seeding**: Seed logic should handle existing data gracefully
   ```go
   // Good: Check if exists first
   user, err := db.GetUserByEmail(email)
   if err == nil {
       log.Printf("User %s already exists, skipping", email)
       return nil
   }
   // Create only if doesn't exist
   return db.CreateUser(email, password)
   ```

2. **Use Environment Variables**: Don't hardcode passwords
   ```yaml
   seed:
     env:
       - name: SEED_ADMIN_PASSWORD
         valueFrom:
           secretKeyRef:
             name: admin-password
             key: password
   ```

3. **Log Clearly**: Help operators understand what was seeded
   ```bash
   echo "✓ Created tenant: ${TENANT_NAME}"
   echo "✓ Created admin user: ${ADMIN_EMAIL}"
   echo "⚠️  Default password: ${DEFAULT_PASSWORD} (CHANGE IMMEDIATELY)"
   ```

4. **Keep Seed Logic in Service**: Don't put seed logic in devops-k8s
   - ✅ Service repo: `cmd/seed/main.go`
   - ❌ DevOps repo: `scripts/seed-auth.sh`

5. **Test Locally**: Test seed command before deploying
   ```bash
   # Local testing
   docker run --rm \
     -e DATABASE_URL=postgresql://... \
     myimage:latest \
     /usr/local/bin/my-seed
   ```

## Migration vs Seed

| Aspect | Migration | Seed |
|--------|-----------|------|
| **Purpose** | Schema changes | Initial data |
| **When** | Every deployment | First deployment or reset |
| **Idempotent** | Must be | Should be |
| **Hook Weight** | 0 (first) | 5 (after migrations) |
| **Frequency** | Always runs | Only when enabled |

## Summary

The seed hook provides:
- ✅ Consistent seeding across all services
- ✅ Automatic execution after migrations
- ✅ Environment variable inheritance
- ✅ Flexible command configuration
- ✅ Resource management
- ✅ Proper Helm lifecycle integration

Enable it in your service by adding `seed.enabled: true` to values.yaml!

