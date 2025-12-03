# ERP-API Deployment

Django-based ERP backend service with automated database migrations.

## Auto-Migration Configuration

The ERP-API service is **fully independent** and handles migrations on its own startup:

### Application-Level Migrations (Entrypoint Script)
- Migrations run inside the main container via `entrypoint.sh`
- Executes on **every container start** (pod restart, scaling, deployment)
- **Maximum reliability:** Each instance is self-contained
- **Defined in:** `erp/erp-api/scripts/entrypoint.sh`
- **Dockerfile:** Uses `CMD ["/usr/local/bin/entrypoint.sh"]`

### InitContainer (Database Readiness Check)
- Quick 3-attempt database connectivity check
- Non-blocking: Allows container to start even if check fails
- Defined in: `charts/app/templates/deployment.yaml`
- **Enabled via:** `migrations.runOnStartup: true`

### Helm Hook Migrations (Disabled)
- **Status:** Disabled (`migrations.enabled: false`)
- **Reason:** App handles migrations independently
- External hooks create unnecessary complexity and failure points

## Migration Behavior

The `entrypoint.sh` script handles migrations with:
- `--fake-initial`: Safe for existing databases
- `--noinput`: Non-interactive execution  
- Fallback to regular `migrate` if fake-initial fails
- **Only 3 connection attempts** with 3-second intervals (9 seconds total)
- Non-blocking: Server starts even if migrations fail

**Database Connection:**
- Uses Django's built-in `manage.py check --database default`
- No external dependencies (no apt-get, no psql)
- Runs as app user (non-root, secure)
- Fast startup with minimal wait time

## Configuration

In `values.yaml`:

```yaml
migrations:
  enabled: false         # Helm hooks disabled (app is independent)
  runOnStartup: true     # Enable initContainer DB check
  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 2Gi
```

**Note:** Migrations are handled by the application's entrypoint script, not external jobs.

## Database Credentials

All database credentials are loaded from Kubernetes secret:
- Secret name: `erp-api-env`
- Required keys: `DATABASE_URL` (or `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`)

The service uses `envFromSecret` to load all environment variables automatically.

## Why Application-Level Migrations?

**Advantages:**
1. **True Independence:** No external job dependencies
2. **Self-Healing:** Each pod migrates on its own
3. **Faster Deployments:** No waiting for Helm hooks
4. **Simpler Architecture:** One migration path, not three
5. **Better for Autoscaling:** New pods handle their own setup

**How It Works:**
- Container starts → `entrypoint.sh` runs
- Checks database (3 attempts, 9 seconds)
- Runs migrations (idempotent)
- Collects static files
- Starts Daphne server

**Idempotency:**
Django's `migrate` command is idempotent - safe to run multiple times. Each pod running migrations won't cause conflicts.

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
