# Per-Service Database Setup Guide

## Overview

This guide explains how per-service database settings are handled for shared infrastructure resources (PostgreSQL, Redis, RabbitMQ). Each service has its own unique database on the shared PostgreSQL instance, while using a common admin user for database management.

## Architecture

### Shared Infrastructure with Per-Service Databases

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

## Key Concepts

### 1. Common Admin User

- **Username**: `admin_user` (configurable via `POSTGRES_ADMIN_USER`)
- **Purpose**: Create and manage databases for all services
- **Privileges**: SUPERUSER, CREATEDB
- **Password Source**: 
  - `POSTGRES_ADMIN_PASSWORD` environment variable (GitHub secret)
  - Falls back to `POSTGRES_PASSWORD` if not set
  - Stored in Kubernetes secret: `postgresql` in `infra` namespace

### 2. Per-Service Databases

Each service has:
- **Unique database name**: e.g., `cafe`, `erp`, `treasury`
- **Service-specific user**: e.g., `cafe_user`, `erp_user`
- **Isolated data**: Each service's data is completely isolated

### 3. Password Management

- **Admin User Password**: Managed via GitHub secrets (`POSTGRES_ADMIN_PASSWORD` or `POSTGRES_PASSWORD`)
- **Service User Passwords**: Managed per-service via their own secrets
- **Redis Password**: Common password for all services (`REDIS_PASSWORD`)

## Setup Process

### Step 1: Install Shared PostgreSQL (One-Time)

The PostgreSQL installation creates the common `admin_user`:

```bash
# From devops-k8s repository
POSTGRES_PASSWORD="your-secure-password" \
POSTGRES_ADMIN_PASSWORD="your-admin-password" \
./scripts/install-databases.sh
```

Or via ArgoCD (automated):
- The `apps/postgresql/app.yaml` creates `admin_user` with superuser privileges
- Password is set via `POSTGRES_ADMIN_PASSWORD` or `POSTGRES_PASSWORD` environment variables

### Step 2: Create Per-Service Database

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

### Step 3: Configure Service Secrets

Each service stores its database credentials in its own namespace:

```bash
# Example: cafe-backend
kubectl -n cafe create secret generic cafe-backend-env \
  --from-literal=CAFE_POSTGRES_URL="postgresql://cafe_user:PASSWORD@postgresql.infra.svc.cluster.local:5432/cafe" \
  --from-literal=CAFE_REDIS_ADDR="redis-master.infra.svc.cluster.local:6379"
```

## Integration with Build Scripts

### Automatic Database Creation

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

### Example: cafe-backend build.sh

```bash
#!/usr/bin/env bash
APP_NAME=cafe-backend
NAMESPACE=cafe
SETUP_DATABASES=true

# ... build and deploy code ...

# Create service database if needed
if [[ "$SETUP_DATABASES" == "true" && -n "${KUBE_CONFIG:-}" ]]; then
    # Wait for PostgreSQL to be ready
    kubectl -n infra rollout status statefulset/postgresql --timeout=180s || true
    
    # Create database for this service
    SERVICE_DB_NAME=cafe \
    APP_NAME=cafe-backend \
    ./devops-k8s/scripts/create-service-database.sh || log_warning "Database creation failed or already exists"
fi
```

## Environment Variables

### GitHub Secrets (Organization/Repository Level)

```yaml
# Required for shared infrastructure
POSTGRES_PASSWORD: "secure-password-for-postgres-superuser"
POSTGRES_ADMIN_PASSWORD: "secure-password-for-admin-user"  # Optional, falls back to POSTGRES_PASSWORD
REDIS_PASSWORD: "secure-password-for-redis"
RABBITMQ_PASSWORD: "secure-password-for-rabbitmq"  # Optional
```

### Service-Specific Variables

```bash
# Per-service database configuration
SERVICE_DB_NAME=cafe              # Database name (auto-inferred from APP_NAME if not set)
SERVICE_DB_USER=cafe_user          # Database user (auto-inferred if not set)
APP_NAME=cafe-backend              # Used to infer SERVICE_DB_NAME
NAMESPACE=cafe                     # Used to infer SERVICE_DB_NAME if APP_NAME not set
```

## Database Creation Script

### Usage

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

### What It Does

1. **Waits for PostgreSQL**: Ensures PostgreSQL is ready before proceeding
2. **Retrieves Admin Password**: Gets password from env var or Kubernetes secret
3. **Creates Database**: Creates the service database if it doesn't exist
4. **Creates User**: Creates the service-specific user if it doesn't exist
5. **Grants Privileges**: Grants all necessary privileges to the service user

### Idempotent Operation

The script is safe to run multiple times:
- Checks if database exists before creating
- Checks if user exists before creating
- Updates privileges if needed

## Connection Strings

### PostgreSQL

```bash
# Using service-specific user
postgresql://cafe_user:PASSWORD@postgresql.infra.svc.cluster.local:5432/cafe

# Using admin user (for management tasks)
postgresql://admin_user:ADMIN_PASSWORD@postgresql.infra.svc.cluster.local:5432/postgres
```

### Redis

```bash
# All services use the same Redis instance with different DB numbers
redis://:REDIS_PASSWORD@redis-master.infra.svc.cluster.local:6379/0  # cafe uses DB 0
redis://:REDIS_PASSWORD@redis-master.infra.svc.cluster.local:6379/1  # erp uses DB 1
```

## Troubleshooting

### Database Creation Fails

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

### Password Not Found

```bash
# Set password explicitly
export POSTGRES_ADMIN_PASSWORD="your-password"

# Or retrieve from secret
export POSTGRES_ADMIN_PASSWORD=$(kubectl -n infra get secret postgresql -o jsonpath='{.data.admin-user-password}' | base64 -d)
```

### Service Can't Connect

1. Verify database exists:
   ```bash
   kubectl -n infra exec -it postgresql-0 -- psql -U admin_user -l | grep cafe
   ```

2. Verify user exists:
   ```bash
   kubectl -n infra exec -it postgresql-0 -- psql -U admin_user -d postgres -c "\du" | grep cafe_user
   ```

3. Check service secret:
   ```bash
   kubectl -n cafe get secret cafe-backend-env -o yaml
   ```

## Best Practices

1. **Use Admin User Only for Management**: Services should use their own service-specific users, not the admin user
2. **Store Passwords in Secrets**: Never hardcode passwords; use GitHub secrets and Kubernetes secrets
3. **Idempotent Operations**: Database creation scripts should be safe to run multiple times
4. **Isolate Service Data**: Each service should only access its own database
5. **Monitor Database Usage**: Track database sizes and connections per service

## Migration from Old Setup

If you're migrating from a setup where each service had its own PostgreSQL instance:

1. **Export Data**: Export data from old databases
2. **Create Service Databases**: Use `create-service-database.sh` for each service
3. **Import Data**: Import data into new service databases
4. **Update Connection Strings**: Update service secrets with new connection strings
5. **Test**: Verify each service can connect and operate correctly

