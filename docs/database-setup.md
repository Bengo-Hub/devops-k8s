Database Setup Guide
===================

This guide covers setting up shared database infrastructure for all services in the cluster. PostgreSQL and Redis are deployed as shared infrastructure in the `infra` namespace, with each service having its own unique database on the PostgreSQL instance.

> **📖 Per-Service Database Setup**: This guide includes complete per-service database setup details. Each service has its own unique database on the shared PostgreSQL instance, managed using a common admin user.

Database Architecture
--------------------

### Shared Infrastructure:
- **PostgreSQL** - Shared PostgreSQL service/engine deployed in `infra` namespace
  - Each service has its own **unique database** on this shared PostgreSQL instance
  - Example databases: `cafe`, `erp`, `treasury`, `notifications`, etc.
- **Redis** - Shared Redis instance for cache, sessions, and message broker
  - Services can use different Redis databases (0, 1, 2, etc.) for isolation

### Key Concept:
- **Shared Service, Unique Databases**: All services connect to the same PostgreSQL service (`postgresql.infra.svc.cluster.local`), but each service uses its own database name.
- This allows efficient resource utilization while maintaining data isolation between services.

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
┌─────────────────────────────────────────────────────────┐
│          Kubernetes Cluster                            │
│                                                        │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐           │
│  │Service A │  │Service B │  │Service C │           │
│  │(cafe)    │  │(erp)     │  │(treasury)│           │
│  └────┬──────┘  └────┬─────┘  └────┬─────┘           │
│       │             │              │                 │
│       └─────────────┼──────────────┘                 │
│                     │                                 │
│              ┌──────▼──────┐                         │
│              │ PostgreSQL  │                          │
│              │ (infra ns)  │                          │
│              │             │                          │
│              │ Databases:  │                          │
│              │ - cafe      │                          │
│              │ - erp       │                          │
│              │ - treasury  │                          │
│              └──────┬──────┘                          │
│                     │                                 │
│              ┌──────▼──────┐                         │
│              │   Redis     │                          │
│              │ (infra ns)   │                          │
│              │             │                          │
│              │ DB 0: cafe  │                          │
│              │ DB 1: erp   │                          │
│              │ DB 2: ...    │                          │
│              └─────────────┘                          │
│                                                        │
│              ┌──────────┐                             │
│              │Persistent│                             │
│              │ Volumes  │                             │
│              └──────────┘                             │
└─────────────────────────────────────────────────────────┘
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
- Create namespace (default: `infra` for shared infrastructure)
- Install PostgreSQL with production config (20GB storage, optimized settings)
- Install Redis with production config (8GB storage, LRU eviction)
- Display connection strings and credentials
- Provide next steps for secret configuration

**Shared Infrastructure Configuration:**
- Namespace: `infra` (shared infrastructure namespace)
- PostgreSQL Service: `postgresql.infra.svc.cluster.local:5432`
  - Each service creates its own database on this shared PostgreSQL instance
  - Example databases: `cafe`, `erp`, `treasury`, `notifications`
- Redis Service: `redis-master.infra.svc.cluster.local:6379`
  - Services can use different Redis database numbers (0, 1, 2, etc.) for isolation

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
# postgresql://postgres:PASSWORD@postgresql.infra.svc.cluster.local:5432/my_database
# Example: postgresql://postgres:PASSWORD@postgresql.infra.svc.cluster.local:5432/cafe
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
# PostgreSQL: postgresql://postgres:abc123xyz@postgresql.infra.svc.cluster.local:5432/my_database
# Redis: redis://:xyz789abc@redis-master.infra.svc.cluster.local:6379/0

# Update your service's kubeSecrets/devENV.yaml with these values
# Example: Update Cafe/cafe-backend/KubeSecrets/devENV.yaml
# Then apply:
kubectl apply -f your-service/KubeSecrets/devENV.yaml
# Example: kubectl apply -f Cafe/cafe-backend/KubeSecrets/devENV.yaml
```

**Note:** The automated script displays the exact credentials you need to copy.

### 4. Initialize Database

Create initialization job to set up the database schema:

```bash
# Create a database initialization job for your service
# Replace 'my-service' and 'my_database' with your actual service and database names
# Example: For cafe service with 'cafe' database

# Create init job manifest (example)
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: my-service-db-init
  namespace: my-service
spec:
  template:
    spec:
      containers:
      - name: init
        image: my-service:latest
        command: ["/bin/sh", "-c", "your-migration-command"]
      restartPolicy: Never
EOF

# Wait for completion
kubectl wait --for=condition=complete job/my-service-db-init -n my-service --timeout=300s

# Check logs
kubectl logs job/my-service-db-init -n my-service
```

**Note:** Each service should create its own database initialization job. Update the job manifest with your actual image tag and migration commands before applying.

### 5. Alternative: Manual Secret Update

If not using the automated script output, update your service's secret manifest manually (e.g., `kubeSecrets/devENV.yaml`):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-service-env  # Replace with your service name (e.g., cafe-backend-env)
  namespace: my-service  # Replace with your service namespace (e.g., cafe)
type: Opaque
stringData:
  # PostgreSQL - Connect to shared PostgreSQL service, use your service's database
  # Each service has its own database on the shared PostgreSQL instance
  DATABASE_URL: "postgresql://postgres:CHANGE_ME@postgresql.infra.svc.cluster.local:5432/my_database"
  # Example: DATABASE_URL: "postgresql://postgres:CHANGE_ME@postgresql.infra.svc.cluster.local:5432/cafe"
  DB_HOST: "postgresql.infra.svc.cluster.local"
  DB_PORT: "5432"
  DB_NAME: "my_database"  # Replace with your service's database name (e.g., "cafe", "erp", "treasury")
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
# Apply to cluster (replace with your service path)
kubectl apply -f your-service/KubeSecrets/devENV.yaml
# Example: kubectl apply -f Cafe/cafe-backend/KubeSecrets/devENV.yaml

# Verify (replace with your service secret name and namespace)
kubectl get secret my-service-env -n my-service -o yaml
# Example: kubectl get secret cafe-backend-env -n cafe -o yaml
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
      app_name: my-service  # Replace with your service name (e.g., cafe-backend)
      deploy: true
      namespace: my-service  # Replace with your service namespace (e.g., cafe)
      setup_databases: true       # Enable automated DB setup
      db_types: postgres,redis    # Databases to install
      env_secret_name: my-service-env  # Replace with your service secret name
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

# Create database and user (replace with your service name)
sudo -u postgres psql <<EOF
CREATE DATABASE my_service_db;  # Replace with your service database name (e.g., cafe)
CREATE USER my_service_user WITH PASSWORD 'CHANGE_ME_STRONG_PASSWORD';  # Replace with your service user
GRANT ALL PRIVILEGES ON DATABASE my_service_db TO my_service_user;
ALTER DATABASE my_service_db OWNER TO my_service_user;
\q
EOF
# Example for cafe service:
# CREATE DATABASE cafe;
# CREATE USER cafe_user WITH PASSWORD 'CHANGE_ME_STRONG_PASSWORD';

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

### 3. Update Service Secret (External DB)

Update your service's secret manifest (e.g., `KubeSecrets/devENV.yaml`):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-service-env  # Replace with your service name (e.g., cafe-backend-env)
  namespace: my-service  # Replace with your service namespace (e.g., cafe)
type: Opaque
stringData:
  # PostgreSQL - External VPS
  DATABASE_URL: "postgresql://my_service_user:PASSWORD@VPS_IP_OR_HOSTNAME:5432/my_service_db"
  # Example: DATABASE_URL: "postgresql://cafe_user:PASSWORD@VPS_IP_OR_HOSTNAME:5432/cafe"
  DB_HOST: "VPS_IP_OR_HOSTNAME"
  DB_PORT: "5432"
  DB_NAME: "my_service_db"  # Replace with your service database name
  DB_USER: "my_service_user"  # Replace with your service database user
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
      app_name: my-service  # Replace with your service name (e.g., cafe-backend)
      deploy: true
      namespace: my-service  # Replace with your service namespace (e.g., cafe)
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
# Backup PostgreSQL (databases are in infra namespace)
# Replace 'my_database' with your service's database name
kubectl exec -n infra postgresql-0 -- \
  pg_dump -U postgres my_database > backup-$(date +%Y%m%d).sql
# Example: kubectl exec -n infra postgresql-0 -- pg_dump -U postgres cafe > backup-$(date +%Y%m%d).sql

# Restore PostgreSQL (replace with your database name)
kubectl exec -i -n infra postgresql-0 -- \
  psql -U postgres my_database < backup-20250109.sql
# Example: kubectl exec -i -n infra postgresql-0 -- psql -U postgres cafe < backup-20250109.sql
```

### Backups (External VPS)

```bash
# Create backup script (replace with your service database and user names)
cat > /root/backup-my-service-db.sh <<'EOF'
#!/bin/bash
DATE=$(date +%Y%m%d_%H%M%S)
pg_dump -U my_service_user my_service_db | gzip > /backup/my_service_db_$DATE.sql.gz
# Example: pg_dump -U cafe_user cafe | gzip > /backup/cafe_$DATE.sql.gz
# Keep only last 7 days
find /backup -name "my_service_db_*.sql.gz" -mtime +7 -delete
# Example: find /backup -name "cafe_*.sql.gz" -mtime +7 -delete
EOF

chmod +x /root/backup-my-service-db.sh

# Add to cron (daily at 2 AM)
echo "0 2 * * * /root/backup-my-service-db.sh" | crontab -
```

### Monitoring

```bash
# PostgreSQL stats (databases are in infra namespace)
# Replace 'my_database' with your service's database name
kubectl exec -n infra postgresql-0 -- \
  psql -U postgres -c "SELECT * FROM pg_stat_database WHERE datname='my_database';"
# Example: kubectl exec -n infra postgresql-0 -- psql -U postgres -c "SELECT * FROM pg_stat_database WHERE datname='cafe';"

# Redis info (databases are in infra namespace)
kubectl exec -n infra redis-master-0 -- redis-cli INFO
```

### Scaling

```bash
# PostgreSQL read replicas (in-cluster)
helm upgrade postgresql bitnami/postgresql \
  -n erp \
  --set readReplicas.replicaCount=2 \
  --set image.tag=latest \
  --set metrics.image.tag=latest

# Redis replicas
helm upgrade redis bitnami/redis \
  -n erp \
  --set replica.replicaCount=3 \
  --set image.tag=latest \
  --set metrics.image.tag=latest
```

---

## Connection Strings Reference

### In-Cluster (Service DNS)

```bash
# PostgreSQL
postgresql://postgres:PASSWORD@postgresql.infra.svc.cluster.local:5432/my_database
# Example: postgresql://postgres:PASSWORD@postgresql.infra.svc.cluster.local:5432/cafe

# Redis (cache - db 0)
redis://:PASSWORD@redis-master.infra.svc.cluster.local:6379/0

# Redis (Celery - db 1)
redis://:PASSWORD@redis-master.infra.svc.cluster.local:6379/1
```

### External VPS

```bash
# PostgreSQL
postgresql://my_service_user:PASSWORD@VPS_IP:5432/my_service_db
# Example: postgresql://cafe_user:PASSWORD@VPS_IP:5432/cafe

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
# Check pod status (databases are in infra namespace)
kubectl get pods -n infra -l app.kubernetes.io/name=postgresql

# Check service (databases are in infra namespace)
kubectl get svc -n infra postgresql

# Test connection from your service pod (replace with your service namespace and deployment name)
kubectl exec -n my-service deployment/my-service-app -- \
  python manage.py dbshell
# Example: kubectl exec -n cafe deployment/cafe-backend -- python manage.py dbshell
```

### Cannot connect to Redis

```bash
# Check Redis (databases are in infra namespace)
kubectl get pods -n infra -l app.kubernetes.io/name=redis

# Test connection from your service pod (replace with your service namespace and deployment name)
kubectl exec -n my-service deployment/my-service-app -- \
  python -c "import redis; r=redis.from_url('redis://:PASSWORD@redis-master.infra.svc.cluster.local:6379/0'); print(r.ping())"
# Example: kubectl exec -n cafe deployment/cafe-backend -- python -c "import redis; r=redis.from_url('redis://:PASSWORD@redis-master.infra.svc.cluster.local:6379/0'); print(r.ping())"
```

### Database initialization fails

```bash
# Check init job logs (replace with your service init job name and namespace)
kubectl logs job/my-service-db-init -n my-service
# Example: kubectl logs job/cafe-db-init -n cafe

# Manually run migrations (replace with your service namespace and deployment name)
kubectl exec -n my-service deployment/my-service-app -- \
# Example: kubectl exec -n cafe deployment/cafe-backend -- \
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

---

## Per-Service Database Setup

### Architecture Overview

Each service has its own unique database on the shared PostgreSQL instance, while using a common admin user for database management:

```
┌─────────────────────────────────────────────────────────┐
│                    Shared Infrastructure                │
│                      (infra namespace)                   │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  ┌──────────────────────────────────────────────────┐  │
│  │         PostgreSQL (Shared Service)              │  │
│  │  postgresql.infra.svc.cluster.local:5432          │  │
│  ├──────────────────────────────────────────────────┤  │
│  │  Admin User: admin_user (common for all services)│  │
│  │  - Can create databases                          │  │
│  │  - Can manage users                               │  │
│  │  - Password: POSTGRES_ADMIN_PASSWORD or          │  │
│  │              POSTGRES_PASSWORD (from secrets)     │  │
│  ├──────────────────────────────────────────────────┤  │
│  │  Service Databases:                              │  │
│  │  - cafe (cafe_user)                              │  │
│  │  - erp (erp_user)                                │  │
│  │  - treasury (treasury_user)                      │  │
│  │  - notifications (notifications_user)             │  │
│  └──────────────────────────────────────────────────┘  │
│                                                          │
│  ┌──────────────────────────────────────────────────┐  │
│  │         Redis (Shared Service)                   │  │
│  │  redis-master.infra.svc.cluster.local:6379       │  │
│  │  - Common password: REDIS_PASSWORD               │  │
│  │  - Services use different DB numbers (0,1,2...)  │  │
│  └──────────────────────────────────────────────────┘  │
│                                                          │
│  ┌──────────────────────────────────────────────────┐  │
│  │         RabbitMQ (Shared Service)                │  │
│  │  rabbitmq.infra.svc.cluster.local:5672          │  │
│  │  - Common credentials                            │  │
│  └──────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

### Key Concepts

**1. Common Admin User**
- **Username**: `admin_user` (configurable via `POSTGRES_ADMIN_USER`)
- **Purpose**: Create and manage databases for all services
- **Privileges**: SUPERUSER, CREATEDB
- **Password Source**: 
  - `POSTGRES_ADMIN_PASSWORD` environment variable (GitHub secret)
  - Falls back to `POSTGRES_PASSWORD` if not set
  - Stored in Kubernetes secret: `postgresql` in `infra` namespace

**2. Per-Service Databases**
Each service has:
- **Unique database name**: e.g., `cafe`, `erp`, `treasury`
- **Service-specific user**: e.g., `cafe_user`, `erp_user`
- **Isolated data**: Each service's data is completely isolated

**3. Password Management**
- **Admin User Password**: Managed via GitHub secrets (`POSTGRES_ADMIN_PASSWORD` or `POSTGRES_PASSWORD`)
- **Service User Passwords**: Managed per-service via their own secrets
- **Redis Password**: Common password for all services (`REDIS_PASSWORD`)

### Service Database Configuration Reference

| Service | Database Name | Database User | Namespace | Build Script |
|---------|--------------|---------------|-----------|--------------|
| cafe-backend | `cafe` | `cafe_user` | `cafe` | `Cafe/cafe-backend/build.sh` |
| erp-api | `bengo_erp` | `erp_user` | `erp` | `erp/erp-api/build.sh` |
| treasury-app | `treasury` | `treasury_user` | `treasury` | `treasury-app/build.sh` |
| notifications-app | `notifications` | `notifications_user` | `notifications` | `notifications-app/build.sh` |

**Redis Configuration:**
All services use the shared Redis instance in the `infra` namespace. Services can use different Redis database numbers (0, 1, 2...) for isolation:

| Service | Redis DB Number | Redis Address |
|---------|----------------|---------------|
| cafe-backend | 0 (default) | `redis-master.infra.svc.cluster.local:6379` |
| erp-api | 0 (default) | `redis-master.infra.svc.cluster.local:6379` |
| treasury-app | 0 (default) | `redis-master.infra.svc.cluster.local:6379` |
| notifications-app | 0 (default) | `redis-master.infra.svc.cluster.local:6379` |

**RabbitMQ Configuration:**
RabbitMQ is shared infrastructure in the `infra` namespace. Services can use different vhosts for isolation:

| Service | RabbitMQ VHost | RabbitMQ Address |
|---------|---------------|------------------|
| All services | `/` (default) | `rabbitmq.infra.svc.cluster.local:5672` |

### Setup Process

**Step 1: Install Shared PostgreSQL (One-Time)**

The PostgreSQL installation creates the common `admin_user`:

```bash
# From devops-k8s repository
POSTGRES_PASSWORD="your-secure-password" \
POSTGRES_ADMIN_PASSWORD="your-admin-password" \
./scripts/install-databases.sh
```

**Step 2: Create Per-Service Database**

Each service creates its own database during deployment:

```bash
# Option 1: Using the database creation script
SERVICE_DB_NAME=cafe \
APP_NAME=cafe-backend \
POSTGRES_ADMIN_PASSWORD="your-admin-password" \
./devops-k8s/scripts/create-service-database.sh

# Option 2: Via build script (automatic)
# The build script calls create-service-database.sh automatically
```

**Step 3: Configure Service Secrets**

Each service stores its database credentials in its own namespace:

```bash
# Example: cafe-backend
kubectl -n cafe create secret generic cafe-backend-env \
  --from-literal=CAFE_POSTGRES_URL="postgresql://cafe_user:PASSWORD@postgresql.infra.svc.cluster.local:5432/cafe" \
  --from-literal=CAFE_REDIS_ADDR="redis-master.infra.svc.cluster.local:6379"
```

### Integration with Build Scripts

Build scripts automatically create databases if `SETUP_DATABASES=true`:

```bash
# In your service's build.sh
SETUP_DATABASES=true
DB_TYPES=postgres,redis

# The build script will:
# 1. Check if PostgreSQL is ready
# 2. Call create-service-database.sh to create the service database
# 3. Create/update service secrets with connection strings
```

### Database Creation Script

**Usage:**

```bash
# Basic usage (infers database name from APP_NAME or NAMESPACE)
APP_NAME=cafe-backend ./devops-k8s/scripts/create-service-database.sh

# Explicit database name
SERVICE_DB_NAME=cafe SERVICE_DB_USER=cafe_user ./devops-k8s/scripts/create-service-database.sh

# With custom admin password
POSTGRES_ADMIN_PASSWORD="custom-password" \
SERVICE_DB_NAME=cafe \
./devops-k8s/scripts/create-service-database.sh
```

**What It Does:**
1. **Waits for PostgreSQL**: Ensures PostgreSQL is ready before proceeding
2. **Retrieves Admin Password**: Gets password from env var or Kubernetes secret
3. **Creates Database**: Creates the service database if it doesn't exist
4. **Creates User**: Creates the service-specific user if it doesn't exist
5. **Grants Privileges**: Grants all necessary privileges to the service user

**Idempotent Operation:** The script is safe to run multiple times.

### Connection Strings

**PostgreSQL:**
```bash
# Using service-specific user
postgresql://cafe_user:PASSWORD@postgresql.infra.svc.cluster.local:5432/cafe

# Using admin user (for management tasks)
postgresql://admin_user:ADMIN_PASSWORD@postgresql.infra.svc.cluster.local:5432/postgres
```

**Redis:**
```bash
# All services use the same Redis instance with different DB numbers
redis://:REDIS_PASSWORD@redis-master.infra.svc.cluster.local:6379/0  # cafe uses DB 0
redis://:REDIS_PASSWORD@redis-master.infra.svc.cluster.local:6379/1  # erp uses DB 1
```

### Adding a New Service

When adding a new service that uses PostgreSQL:

1. **Define database configuration** in the service's `build.sh`:
   ```bash
   SERVICE_DB_NAME=${SERVICE_DB_NAME:-your_service_name}
   SERVICE_DB_USER=${SERVICE_DB_USER:-your_service_user}
   ```

2. **Add database creation logic** in the service's `build.sh`:
   ```bash
   if [[ "$SETUP_DATABASES" == "true" && -n "${KUBE_CONFIG:-}" ]]; then
     # Wait for PostgreSQL to be ready in infra namespace
     if kubectl -n infra get statefulset postgresql >/dev/null 2>&1; then
       kubectl -n infra rollout status statefulset/postgresql --timeout=180s || true
       
       # Create service database using devops-k8s script
       if [[ -d "$DEVOPS_DIR" && -f "$DEVOPS_DIR/scripts/create-service-database.sh" ]]; then
         SERVICE_DB_NAME="$SERVICE_DB_NAME" \
         APP_NAME="$APP_NAME" \
         NAMESPACE="$NAMESPACE" \
         bash "$DEVOPS_DIR/scripts/create-service-database.sh" || warn "Database creation failed or already exists"
       fi
     fi
   fi
   ```

3. **Update connection strings** to use `infra` namespace:
   ```bash
   postgresql://${SERVICE_DB_USER}:PASSWORD@postgresql.infra.svc.cluster.local:5432/${SERVICE_DB_NAME}
   redis://:PASSWORD@redis-master.infra.svc.cluster.local:6379/0
   ```

### Troubleshooting Per-Service Databases

**Database Creation Fails:**
```bash
# Check PostgreSQL is ready
kubectl -n infra get statefulset postgresql

# Check admin password is available
kubectl -n infra get secret postgresql -o jsonpath='{.data.admin-user-password}' | base64 -d

# Manually create database
kubectl -n infra exec -it postgresql-0 -- \
  env PGPASSWORD="admin-password" \
  psql -U admin_user -d postgres -c "CREATE DATABASE cafe;"
```

**Service Can't Connect:**
1. Verify database exists: `kubectl -n infra exec -it postgresql-0 -- psql -U admin_user -l | grep cafe`
2. Verify user exists: `kubectl -n infra exec -it postgresql-0 -- psql -U admin_user -d postgres -c "\du" | grep cafe_user`
3. Check service secret: `kubectl -n cafe get secret cafe-backend-env -o yaml`

### Best Practices

1. **Use Admin User Only for Management**: Services should use their own service-specific users, not the admin user
2. **Store Passwords in Secrets**: Never hardcode passwords; use GitHub secrets and Kubernetes secrets
3. **Idempotent Operations**: Database creation scripts should be safe to run multiple times
4. **Isolate Service Data**: Each service should only access its own database
5. **Monitor Database Usage**: Track database sizes and connections per service

