# ERP-API Deployment

Django-based ERP backend service with automated database migrations.

## Auto-Migration Configuration

The ERP-API service is configured with **dual migration strategies** for maximum reliability:

### 1. Helm Hook Migrations (Pre-Install/Pre-Upgrade)
- Runs as a Kubernetes Job before deployment
- Executes during `helm install` or `helm upgrade`
- Defined in: `charts/app/templates/migrate-hook.yaml`
- **Hook annotations:** `pre-install`, `pre-upgrade`
- **Hook weight:** 0 (runs before deployment)

### 2. InitContainer Migrations (Every Pod Startup)
- Runs automatically when each pod starts
- Makes the service **independent and self-healing**
- Defined in: `charts/app/templates/deployment.yaml`
- **Enabled via:** `migrations.runOnStartup: true`

## Migration Behavior

Both migration methods use Django's `manage.py migrate` with:
- `--fake-initial`: Safe for existing databases
- `--noinput`: Non-interactive execution
- Fallback to regular `migrate` if fake-initial fails

**Database Connection:**
- Uses Django's built-in `manage.py check --database default`
- No external dependencies (no apt-get, no psql installation)
- Runs as non-root user (secure)
- 60 retry attempts with 2-second intervals (2 minutes total)

## Configuration

In `values.yaml`:

```yaml
migrations:
  enabled: true          # Enable Helm hook migrations
  runOnStartup: true     # Enable initContainer migrations
  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 2Gi
```

## Database Credentials

All database credentials are loaded from Kubernetes secret:
- Secret name: `erp-api-env`
- Required keys: `DATABASE_URL` (or `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`)

The service uses `envFromSecret` to load all environment variables automatically.

## Why Dual Migration Strategy?

1. **Helm Hook:** Runs migrations during deployment changes
2. **InitContainer:** Ensures migrations run on pod restarts, scaling events, and node failures

This makes the service **truly independent** - each pod can start without relying on external migration jobs.

## Troubleshooting

### Migration Job Fails

Check the migration job logs:
```bash
kubectl logs -n erp job/erp-api-migrate-<commit-hash>
```

### Database Connection Issues

1. Verify PostgreSQL is running:
```bash
kubectl get pods -n infra -l app=postgresql
```

2. Check secret exists:
```bash
kubectl get secret erp-api-env -n erp
kubectl describe secret erp-api-env -n erp
```

3. Verify service connectivity:
```bash
kubectl run -it --rm debug --image=postgres:14 --restart=Never -n erp -- \
  psql -h postgresql.infra.svc.cluster.local -U <user> -d <db>
```

### View Migration Status

```bash
# From within a running pod
kubectl exec -it -n erp deployment/erp-api-app -- python manage.py showmigrations

# Or check which migrations are applied
kubectl exec -it -n erp deployment/erp-api-app -- python manage.py showmigrations --list
```

## Seeding

Seeding is **disabled** for ERP-API. Use Django management commands manually if needed:

```bash
kubectl exec -it -n erp deployment/erp-api-app -- python manage.py seed_employees
kubectl exec -it -n erp deployment/erp-api-app -- python manage.py setup_ess_settings
```

## Health Checks

- **Readiness:** `/api/v1/core/health/` (30s delay, 10s interval)
- **Liveness:** `/api/v1/core/health/` (60s delay, 20s interval)

Pods won't receive traffic until migrations complete and health checks pass.

## Persistence

- **Media Files:** 20Gi PVC mounted at `/app/media`
- **Storage Class:** `local-path`
- **Access Mode:** `ReadWriteOnce`

## Celery Workers

The deployment includes:
- **Celery Worker:** Async task processing (4 concurrency)
- **Celery Beat:** Scheduled tasks (DatabaseScheduler)

Both Celery components use the same database and auto-migrations.

## Resources

**Main App:**
- Requests: 300m CPU, 1Gi Memory
- Limits: 2000m CPU, 3Gi Memory

**Celery Worker:**
- Requests: 200m CPU, 768Mi Memory
- Limits: 1000m CPU, 2Gi Memory

**Celery Beat:**
- Requests: 100m CPU, 256Mi Memory
- Limits: 500m CPU, 512Mi Memory

## Autoscaling

**HPA:**
- Min: 1 replica
- Max: 6 replicas
- Target CPU: 70%
- Target Memory: 75%

**VPA:**
- Enabled with `Recreate` mode
- Auto-adjusts resource requests/limits

## Ingress

- **Domain:** `erpapi.masterspace.co.ke`
- **TLS:** Automated via cert-manager (Let's Encrypt)
- **WebSocket:** Enabled for Django Channels

## Monitoring

- Prometheus metrics enabled
- ServiceMonitor configured
- Custom metrics for intelligent scaling
