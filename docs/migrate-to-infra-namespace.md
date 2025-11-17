# Migrating Shared Infrastructure to infra Namespace

This guide helps you migrate existing PostgreSQL, Redis, and RabbitMQ installations from their current namespaces to the `infra` namespace.

## Finding Existing Installations

First, identify where your shared infrastructure is currently installed:

```bash
# Run the find script
./scripts/find-existing-infra.sh

# Or manually check
kubectl get statefulset -A | grep -E "postgresql|redis|rabbitmq"
helm list -A | grep -E "postgresql|redis|rabbitmq"
```

## Migration Options

### Option 1: Delete and Recreate (Recommended for Fresh Installs)

If you don't have critical data or can afford downtime:

1. **Backup data** (if needed):
   ```bash
   # PostgreSQL backup
   kubectl exec -n <old-namespace> postgresql-0 -- pg_dumpall -U postgres > backup.sql
   
   # Redis backup
   kubectl exec -n <old-namespace> redis-master-0 -- redis-cli --rdb /tmp/dump.rdb
   kubectl cp <old-namespace>/redis-master-0:/tmp/dump.rdb ./redis-backup.rdb
   ```

2. **Delete old installations**:
   ```bash
   # Uninstall Helm releases
   helm uninstall postgresql -n <old-namespace>
   helm uninstall redis -n <old-namespace>
   helm uninstall rabbitmq -n <old-namespace>
   
   # Delete PVCs if you want to start fresh
   kubectl delete pvc -n <old-namespace> -l app.kubernetes.io/name=postgresql
   kubectl delete pvc -n <old-namespace> -l app.kubernetes.io/name=redis
   kubectl delete pvc -n <old-namespace> -l app.kubernetes.io/name=rabbitmq
   ```

3. **Let ArgoCD recreate in infra namespace**:
   - ArgoCD will automatically sync the PostgreSQL, Redis, and RabbitMQ applications
   - They will be created in the `infra` namespace
   - Services will automatically create their databases on first deployment

### Option 2: Helm Upgrade Migration (For Existing Data)

If you need to preserve data:

1. **Export current Helm values**:
   ```bash
   helm get values postgresql -n <old-namespace> -o yaml > postgresql-values.yaml
   helm get values redis -n <old-namespace> -o yaml > redis-values.yaml
   helm get values rabbitmq -n <old-namespace> -o yaml > rabbitmq-values.yaml
   ```

2. **Backup data** (critical step):
   ```bash
   # PostgreSQL
   kubectl exec -n <old-namespace> postgresql-0 -- pg_dumpall -U postgres > backup-$(date +%Y%m%d).sql
   
   # Redis
   kubectl exec -n <old-namespace> redis-master-0 -- redis-cli SAVE
   kubectl cp <old-namespace>/redis-master-0:/data/dump.rdb ./redis-backup-$(date +%Y%m%d).rdb
   ```

3. **Create infra namespace**:
   ```bash
   kubectl create namespace infra
   ```

4. **Uninstall from old namespace**:
   ```bash
   helm uninstall postgresql -n <old-namespace>
   helm uninstall redis -n <old-namespace>
   helm uninstall rabbitmq -n <old-namespace>
   ```

5. **Install in infra namespace with same values**:
   ```bash
   # PostgreSQL
   helm install postgresql bitnami/postgresql \
     -n infra \
     -f postgresql-values.yaml \
     --set global.defaultFips=false \
     --set fips.openssl=false \
     --set global.postgresql.auth.username=admin_user \
     --set global.postgresql.auth.database=postgres
   
   # Redis
   helm install redis bitnami/redis \
     -n infra \
     -f redis-values.yaml
   
   # RabbitMQ
   helm install rabbitmq bitnami/rabbitmq \
     -n infra \
     -f rabbitmq-values.yaml
   ```

6. **Restore data** (if needed):
   ```bash
   # PostgreSQL restore
   kubectl exec -i -n infra postgresql-0 -- psql -U postgres < backup-YYYYMMDD.sql
   
   # Redis restore
   kubectl cp ./redis-backup-YYYYMMDD.rdb infra/redis-master-0:/data/dump.rdb
   kubectl exec -n infra redis-master-0 -- redis-cli --rdb /data/dump.rdb
   ```

### Option 3: Use Migration Scripts

We provide helper scripts:

```bash
# Find existing installations
./scripts/find-existing-infra.sh

# Get migration instructions
./scripts/migrate-helm-release-namespace.sh
```

## Common Migration Scenarios

### PostgreSQL from `erp` namespace to `infra`

```bash
# 1. Backup
kubectl exec -n erp postgresql-0 -- pg_dumpall -U postgres > backup.sql

# 2. Export values
helm get values postgresql -n erp -o yaml > pg-values.yaml

# 3. Uninstall
helm uninstall postgresql -n erp

# 4. Install in infra (ArgoCD will handle this automatically)
# Or manually:
helm install postgresql bitnami/postgresql \
  -n infra \
  -f pg-values.yaml \
  --set global.defaultFips=false \
  --set fips.openssl=false \
  --set global.postgresql.auth.username=admin_user \
  --set global.postgresql.auth.database=postgres

# 5. Restore if needed
kubectl exec -i -n infra postgresql-0 -- psql -U postgres < backup.sql
```

### Redis from `erp` namespace to `infra`

```bash
# 1. Backup
kubectl exec -n erp redis-master-0 -- redis-cli SAVE
kubectl cp erp/redis-master-0:/data/dump.rdb ./redis-backup.rdb

# 2. Export values
helm get values redis -n erp -o yaml > redis-values.yaml

# 3. Uninstall
helm uninstall redis -n erp

# 4. Install in infra (ArgoCD will handle this automatically)
# Or manually:
helm install redis bitnami/redis -n infra -f redis-values.yaml

# 5. Restore if needed
kubectl cp ./redis-backup.rdb infra/redis-master-0:/data/dump.rdb
kubectl exec -n infra redis-master-0 -- redis-cli --rdb /data/dump.rdb
```

### RabbitMQ from `truload` namespace to `infra`

```bash
# 1. Export definitions
kubectl exec -n truload rabbitmq-0 -- rabbitmqctl export_definitions /tmp/definitions.json
kubectl cp truload/rabbitmq-0:/tmp/definitions.json ./rabbitmq-definitions.json

# 2. Export values
helm get values rabbitmq -n truload -o yaml > rabbitmq-values.yaml

# 3. Uninstall
helm uninstall rabbitmq -n truload

# 4. Install in infra (ArgoCD will handle this automatically)
# Or manually:
helm install rabbitmq bitnami/rabbitmq -n infra -f rabbitmq-values.yaml

# 5. Restore definitions
kubectl cp ./rabbitmq-definitions.json infra/rabbitmq-0:/tmp/definitions.json
kubectl exec -n infra rabbitmq-0 -- rabbitmqctl import_definitions /tmp/definitions.json
```

## Post-Migration Steps

1. **Update ArgoCD Applications**:
   - Ensure `apps/postgresql/app.yaml` points to `infra` namespace
   - Ensure `apps/redis/app.yaml` points to `infra` namespace
   - Ensure `apps/rabbitmq/app.yaml` points to `infra` namespace

2. **Update Service Connection Strings**:
   - Update all service secrets to use `infra` namespace
   - PostgreSQL: `postgresql.infra.svc.cluster.local`
   - Redis: `redis-master.infra.svc.cluster.local`
   - RabbitMQ: `rabbitmq.infra.svc.cluster.local`

3. **Verify Services Can Connect**:
   ```bash
   # Test PostgreSQL connection
   kubectl run psql-test --rm -it --restart=Never \
     --image=postgres:15 \
     --env="PGPASSWORD=\$(kubectl get secret postgresql -n infra -o jsonpath='{.data.postgres-password}' | base64 -d)" \
     -- psql -h postgresql.infra.svc.cluster.local -U postgres -d postgres -c "SELECT version();"
   
   # Test Redis connection
   kubectl run redis-test --rm -it --restart=Never \
     --image=redis:7 \
     --env="REDIS_PASSWORD=\$(kubectl get secret redis -n infra -o jsonpath='{.data.redis-password}' | base64 -d)" \
     -- redis-cli -h redis-master.infra.svc.cluster.local -a "\$REDIS_PASSWORD" ping
   ```

4. **Clean Up Old Namespaces** (optional):
   ```bash
   # Only after verifying everything works
   kubectl delete namespace <old-namespace>
   ```

## Troubleshooting

### FIPS Configuration Error

If you see: `Please configure a value for 'fips.openssl' or 'global.defaultFips'`

**Solution**: Ensure FIPS is explicitly set:
```bash
helm upgrade postgresql bitnami/postgresql \
  -n infra \
  --set global.defaultFips=false \
  --set fips.openssl=false \
  --reuse-values
```

### PVC Migration Issues

StatefulSets use PersistentVolumeClaims that are namespace-specific. You cannot directly move PVCs between namespaces.

**Options**:
1. **Start fresh** (delete old PVCs, let new ones be created)
2. **Copy data** (backup from old, restore to new)
3. **Use storage migration tools** (advanced, not recommended)

### Service Discovery Issues

After migration, services might still reference old namespaces.

**Fix**: Update all connection strings:
- Old: `postgresql.erp.svc.cluster.local`
- New: `postgresql.infra.svc.cluster.local`

## Automated Migration (Using Scripts)

```bash
# 1. Find existing installations
./scripts/find-existing-infra.sh

# 2. Get migration instructions
./scripts/migrate-helm-release-namespace.sh

# 3. Follow the instructions provided by the scripts
```

## Best Practices

1. **Always backup before migration** - Data loss is permanent
2. **Test in non-production first** - Validate the migration process
3. **Use ArgoCD for consistency** - Let GitOps manage the state
4. **Update documentation** - Ensure all docs reflect new namespaces
5. **Monitor after migration** - Watch for connection issues

