Database Setup Guide
===================

The ERP system requires PostgreSQL (primary database) and Redis (cache + Celery broker). This guide covers both in-cluster Kubernetes deployment (recommended) and external database options.

Database Requirements
--------------------

### ERP API Stack:
- **PostgreSQL** - Primary relational database
- **Redis** - Cache, sessions, and Celery message broker

### NOT Required:
- MongoDB (not used by this ERP system)

---

Deployment Options
-----------------

### Option 1: In-Cluster (Recommended) ⭐

**Pros:**
✅ Easy scaling with Kubernetes
✅ Automatic health checks and restarts
✅ Persistent volumes managed by K8s
✅ Service discovery via DNS
✅ Resource limits and quotas
✅ Backup via volume snapshots

**Cons:**
❌ Requires persistent storage setup
❌ More complex initial configuration

**Best For:**
- Production deployments
- Multiple environments (dev/staging/prod)
- Teams comfortable with K8s

---

### Option 2: External VPS Database

**Pros:**
✅ Simpler setup initially
✅ Can use existing databases
✅ Independent scaling
✅ Easier backups (traditional tools)

**Cons:**
❌ Manual configuration required
❌ Network latency (if not on same VPS)
❌ Harder to scale automatically
❌ More manual maintenance

**Best For:**
- Development/testing
- Migration from existing setup
- Small deployments

---

## Option 1: In-Cluster Deployment (Recommended)

### Architecture

```
┌─────────────────────────────────────────┐
│          Kubernetes Cluster             │
│                                         │
│  ┌──────────┐       ┌──────────┐      │
│  │ ERP API  │──────▶│PostgreSQL│      │
│  │          │       │ StatefulSet│     │
│  │          │       └──────────┘      │
│  │          │             │           │
│  │          │       ┌──────────┐      │
│  │          │──────▶│  Redis   │      │
│  └──────────┘       │Deployment│      │
│                     └──────────┘      │
│                           │           │
│                     ┌──────────┐      │
│                     │Persistent│      │
│                     │ Volumes  │      │
│                     └──────────┘      │
└─────────────────────────────────────────┘
```

### Quick Install (Automated)

From the devops-k8s repository root:

```bash
# Run the automated installation script
./scripts/install-databases.sh

# With custom namespace and database name (optional)
DB_NAMESPACE=myapp PG_DATABASE=myapp_db ./scripts/install-databases.sh
```

The script will:
- Check for kubectl connectivity
- Add Bitnami Helm repository
- Create namespace (default: erp)
- Install PostgreSQL with production config (20GB storage, optimized settings)
- Install Redis with production config (8GB storage, LRU eviction)
- Display connection strings and credentials
- Provide next steps for secret configuration

**Default Configuration:**
- Namespace: `infra` (shared infrastructure namespace)
- PostgreSQL Database: `bengo_erp`
- PostgreSQL Host: `postgresql.infra.svc.cluster.local:5432`
- Redis Host: `redis-master.infra.svc.cluster.local:6379`

---

### Manual Installation (Alternative)

### 1. PostgreSQL Deployment

We'll use Bitnami PostgreSQL Helm chart for production-ready setup.

#### Install PostgreSQL

```bash
# Add Bitnami repo
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Create namespace (if not exists)
kubectl create namespace infra --dry-run=client -o yaml | kubectl apply -f -

# Install PostgreSQL
helm install postgresql bitnami/postgresql \
  -n infra \
  -f manifests/databases/postgresql-values.yaml \
  --timeout=10m \
  --wait
```

#### Get PostgreSQL Credentials

```bash
# Get password
export POSTGRES_PASSWORD=$(kubectl get secret postgresql \
  -n infra \
  -o jsonpath="{.data.postgres-password}" | base64 -d)

echo "PostgreSQL Password: $POSTGRES_PASSWORD"

# Connection string format:
# postgresql://postgres:PASSWORD@postgresql.infra.svc.cluster.local:5432/bengo_erp
```

### 2. Redis Deployment

```bash
# Install Redis
helm install redis bitnami/redis \
  -n infra \
  -f manifests/databases/redis-values.yaml \
  --timeout=10m \
  --wait
```

#### Get Redis Credentials

```bash
# Get password
export REDIS_PASSWORD=$(kubectl get secret redis \
  -n infra \
  -o jsonpath="{.data.redis-password}" | base64 -d)

echo "Redis Password: $REDIS_PASSWORD"

# Connection string format:
# redis://:PASSWORD@redis-master.infra.svc.cluster.local:6379/0
```

### 3. Update Application Secrets

After installation, the script outputs connection strings. Update your app's secret:

```bash
# Example output from install-databases.sh:
# PostgreSQL: postgresql://postgres:abc123xyz@postgresql.infra.svc.cluster.local:5432/bengo_erp
# Redis: redis://:xyz789abc@redis-master.infra.svc.cluster.local:6379/0

# Update BengoERP/bengobox-erp-api/kubeSecrets/devENV.yaml with these values
# Then apply:
kubectl apply -f BengoERP/bengobox-erp-api/kubeSecrets/devENV.yaml
```

**Note:** The automated script displays the exact credentials you need to copy.

### 4. Initialize Database

Create initialization job to set up the database schema:

```bash
# Apply database init job
kubectl apply -f manifests/databases/erp-db-init-job.yaml

# Wait for completion
kubectl wait --for=condition=complete job/erp-db-init -n erp --timeout=300s

# Check logs
kubectl logs job/erp-db-init -n erp
```

**Note:** Update the job manifest with your actual image tag before applying.

### 5. Alternative: Manual Secret Update

If not using the automated script output, update `BengoERP/bengobox-erp-api/kubeSecrets/devENV.yaml` manually:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: erp-api-env
  namespace: erp
type: Opaque
stringData:
  # PostgreSQL - In-cluster
  DATABASE_URL: "postgresql://postgres:CHANGE_ME@postgresql.infra.svc.cluster.local:5432/bengo_erp"
  DB_HOST: "postgresql.infra.svc.cluster.local"
  DB_PORT: "5432"
  DB_NAME: "bengo_erp"
  DB_USER: "postgres"
  DB_PASSWORD: "CHANGE_ME"
  
  # Redis - In-cluster
  REDIS_URL: "redis://:CHANGE_ME@redis-master.infra.svc.cluster.local:6379/0"
  CELERY_BROKER_URL: "redis://:CHANGE_ME@redis-master.infra.svc.cluster.local:6379/0"
  CELERY_RESULT_BACKEND: "redis://:CHANGE_ME@redis-master.infra.svc.cluster.local:6379/0"
  
  # Django
  DJANGO_SECRET_KEY: "CHANGE_ME_TO_RANDOM_50_CHAR_STRING"
  DEBUG: "False"
  ALLOWED_HOSTS: "erpapi.masterspace.co.ke,localhost,127.0.0.1"
```

**IMPORTANT:** Replace `CHANGE_ME` with actual passwords from the install-databases.sh output or from manual installation steps.

### 6. Apply Updated Secret

```bash
# Apply to cluster
kubectl apply -f BengoERP/bengobox-erp-api/kubeSecrets/devENV.yaml

# Verify
kubectl get secret erp-api-env -n erp -o yaml
```

---

## Automated Setup via CI/CD

The reusable GitHub Actions workflow can automatically provision databases when enabled:

```yaml
# In your app's .github/workflows/deploy.yml
jobs:
  deploy:
    uses: Bengo-Hub/devops-k8s/.github/workflows/reusable-build-deploy.yml@main
    with:
      app_name: erp-api
      deploy: true
      namespace: erp
      setup_databases: true       # Enable automated DB setup
      db_types: postgres,redis    # Databases to install
      env_secret_name: erp-api-env
    secrets:
      KUBE_CONFIG: ${{ secrets.KUBE_CONFIG }}
      POSTGRES_PASSWORD: ${{ secrets.POSTGRES_PASSWORD }}  # Optional; auto-generated if omitted
      REDIS_PASSWORD: ${{ secrets.REDIS_PASSWORD }}        # Optional; auto-generated if omitted
```

**How It Works:**
1. Workflow installs PostgreSQL and Redis via Bitnami Helm charts
2. Generates passwords (or uses provided secrets)
3. Creates/updates Kubernetes Secret with DATABASE_URL, REDIS_URL, etc.
4. Your application pods automatically pick up the connection strings

**Benefits:**
- Zero manual configuration
- Idempotent (safe to re-run)
- Passwords auto-generated securely
- Connection strings injected automatically

---

## Option 2: External VPS Database

For databases running on the same VPS or external server.

### 1. Install PostgreSQL on VPS

```bash
# SSH into VPS
ssh root@YOUR_VPS_IP

# Install PostgreSQL
apt-get update
apt-get install -y postgresql postgresql-contrib

# Start and enable
systemctl start postgresql
systemctl enable postgresql

# Create database and user
sudo -u postgres psql <<EOF
CREATE DATABASE bengo_erp;
CREATE USER erp_user WITH PASSWORD 'CHANGE_ME_STRONG_PASSWORD';
GRANT ALL PRIVILEGES ON DATABASE bengo_erp TO erp_user;
ALTER DATABASE bengo_erp OWNER TO erp_user;
\q
EOF

# Configure remote access (if K8s is on different server)
echo "host all all 0.0.0.0/0 md5" >> /etc/postgresql/*/main/pg_hba.conf
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/*/main/postgresql.conf

# Restart PostgreSQL
systemctl restart postgresql
```

### 2. Install Redis on VPS

```bash
# Install Redis
apt-get install -y redis-server

# Configure for remote access (optional)
sed -i 's/bind 127.0.0.1/bind 0.0.0.0/' /etc/redis/redis.conf

# Set password
echo "requirepass CHANGE_ME_REDIS_PASSWORD" >> /etc/redis/redis.conf

# Restart Redis
systemctl restart redis-server
systemctl enable redis-server
```

### 3. Update ERP API Secret (External DB)

Update `BengoERP/bengobox-erp-api/kubeSecrets/devENV.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: erp-api-env
  namespace: erp
type: Opaque
stringData:
  # PostgreSQL - External VPS
  DATABASE_URL: "postgresql://erp_user:PASSWORD@VPS_IP_OR_HOSTNAME:5432/bengo_erp"
  DB_HOST: "VPS_IP_OR_HOSTNAME"
  DB_PORT: "5432"
  DB_NAME: "bengo_erp"
  DB_USER: "erp_user"
  DB_PASSWORD: "PASSWORD"
  
  # Redis - External VPS
  REDIS_URL: "redis://:REDIS_PASSWORD@VPS_IP_OR_HOSTNAME:6379/0"
  CELERY_BROKER_URL: "redis://:REDIS_PASSWORD@VPS_IP_OR_HOSTNAME:6379/0"
  CELERY_RESULT_BACKEND: "redis://:REDIS_PASSWORD@VPS_IP_OR_HOSTNAME:6379/0"
  
  # Django
  DJANGO_SECRET_KEY: "CHANGE_ME_TO_RANDOM_50_CHAR_STRING"
  DEBUG: "False"
  ALLOWED_HOSTS: "erpapi.masterspace.co.ke,localhost,127.0.0.1"
```

---

## Automated Setup via GitHub Actions

The workflow can optionally bootstrap databases. Add to workflow inputs:

```yaml
# In .github/workflows/deploy.yml
jobs:
  deploy:
    uses: codevertex/devops-k8s/.github/workflows/reusable-build-deploy.yml@main
    with:
      app_name: erp-api
      deploy: true
      namespace: erp
      # Database setup (optional)
      setup_databases: true  # Will install PostgreSQL + Redis if enabled
    secrets:
      KUBE_CONFIG: ${{ secrets.KUBE_CONFIG }}
      # Database passwords (generated or provided)
      POSTGRES_PASSWORD: ${{ secrets.POSTGRES_PASSWORD }}
      REDIS_PASSWORD: ${{ secrets.REDIS_PASSWORD }}
```

---

## Database Management

### Backups (In-Cluster)

```bash
# Backup PostgreSQL
kubectl exec -n erp postgresql-0 -- \
  pg_dump -U postgres bengo_erp > backup-$(date +%Y%m%d).sql

# Restore PostgreSQL
kubectl exec -i -n erp postgresql-0 -- \
  psql -U postgres bengo_erp < backup-20250109.sql
```

### Backups (External VPS)

```bash
# Create backup script
cat > /root/backup-erp-db.sh <<'EOF'
#!/bin/bash
DATE=$(date +%Y%m%d_%H%M%S)
pg_dump -U erp_user bengo_erp | gzip > /backup/bengo_erp_$DATE.sql.gz
# Keep only last 7 days
find /backup -name "bengo_erp_*.sql.gz" -mtime +7 -delete
EOF

chmod +x /root/backup-erp-db.sh

# Add to cron (daily at 2 AM)
echo "0 2 * * * /root/backup-erp-db.sh" | crontab -
```

### Monitoring

```bash
# PostgreSQL stats
kubectl exec -n erp postgresql-0 -- \
  psql -U postgres -c "SELECT * FROM pg_stat_database WHERE datname='bengo_erp';"

# Redis info
kubectl exec -n erp redis-master-0 -- redis-cli INFO
```

### Scaling

```bash
# PostgreSQL read replicas (in-cluster)
helm upgrade postgresql bitnami/postgresql \
  -n erp \
  --set readReplicas.replicaCount=2

# Redis replicas
helm upgrade redis bitnami/redis \
  -n erp \
  --set replica.replicaCount=3
```

---

## Connection Strings Reference

### In-Cluster (Service DNS)

```bash
# PostgreSQL
postgresql://postgres:PASSWORD@postgresql.infra.svc.cluster.local:5432/bengo_erp

# Redis (cache - db 0)
redis://:PASSWORD@redis-master.infra.svc.cluster.local:6379/0

# Redis (Celery - db 1)
redis://:PASSWORD@redis-master.infra.svc.cluster.local:6379/1
```

### External VPS

```bash
# PostgreSQL
postgresql://erp_user:PASSWORD@VPS_IP:5432/bengo_erp

# Redis
redis://:PASSWORD@VPS_IP:6379/0
```

### Localhost (Development)

```bash
# PostgreSQL
postgresql://postgres:postgres@localhost:5432/bengo_erp

# Redis
redis://localhost:6379/0
```

---

## Troubleshooting

### Cannot connect to PostgreSQL

```bash
# Check pod status
kubectl get pods -n erp -l app.kubernetes.io/name=postgresql

# Check service
kubectl get svc -n erp postgresql

# Test connection from API pod
kubectl exec -n erp deployment/erp-api -- \
  python manage.py dbshell
```

### Cannot connect to Redis

```bash
# Check Redis
kubectl get pods -n erp -l app.kubernetes.io/name=redis

# Test connection
kubectl exec -n erp deployment/erp-api -- \
  python -c "import redis; r=redis.from_url('redis://:PASSWORD@redis-master.infra.svc.cluster.local:6379/0'); print(r.ping())"
```

### Database initialization fails

```bash
# Check init job logs
kubectl logs job/erp-db-init -n erp

# Manually run migrations
kubectl exec -n erp deployment/erp-api -- \
  python manage.py migrate
```

---

## Security Best Practices

1. **Strong Passwords**: Generate with `openssl rand -base64 32`
2. **Network Policies**: Restrict database access to ERP pods only
3. **Encryption**: Enable SSL/TLS for PostgreSQL connections
4. **Secrets Management**: Use Sealed Secrets or external secret managers
5. **Regular Updates**: Keep database versions patched
6. **Backup Testing**: Regularly test restore procedures

---

---

## Recommendation

**For Production:** Use **Option 1 (In-Cluster)** with the automated script because:
- Easier to scale
- Better integration with K8s
- Automatic health checks
- Simpler service discovery
- Better resource management

**For Development/Testing:** Either option works, external might be faster to set up initially.

The devops-k8s repo provides Helm value files and automation to make Option 1 straightforward.

