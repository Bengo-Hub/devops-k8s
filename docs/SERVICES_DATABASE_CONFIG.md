# Service Database Configuration Reference

This document lists all services and their unique database configurations.

## PostgreSQL Databases

Each service has its own unique database on the shared PostgreSQL instance in the `infra` namespace.

| Service | Database Name | Database User | Namespace | Build Script |
|---------|--------------|---------------|-----------|--------------|
| cafe-backend | `cafe` | `cafe_user` | `cafe` | `Cafe/cafe-backend/build.sh` |
| erp-api | `bengo_erp` | `erp_user` | `erp` | `erp/erp-api/build.sh` |
| treasury-app | `treasury` | `treasury_user` | `treasury` | `treasury-app/build.sh` |
| notifications-app | `notifications` | `notifications_user` | `notifications` | `notifications-app/build.sh` |

## Redis Configuration

All services use the shared Redis instance in the `infra` namespace. Services can use different Redis database numbers (0, 1, 2...) for isolation:

| Service | Redis DB Number | Redis Address |
|---------|----------------|---------------|
| cafe-backend | 0 (default) | `redis-master.infra.svc.cluster.local:6379` |
| erp-api | 0 (default) | `redis-master.infra.svc.cluster.local:6379` |
| treasury-app | 0 (default) | `redis-master.infra.svc.cluster.local:6379` |
| notifications-app | 0 (default) | `redis-master.infra.svc.cluster.local:6379` |

> **Note**: Redis DB numbers are configured per-service via environment variables (e.g., `REDIS_DB=0`). The default is 0 for all services.

## RabbitMQ Configuration

RabbitMQ is shared infrastructure in the `infra` namespace. Services can use different vhosts for isolation:

| Service | RabbitMQ VHost | RabbitMQ Address |
|---------|---------------|------------------|
| All services | `/` (default) | `rabbitmq.infra.svc.cluster.local:5672` |

> **Note**: RabbitMQ vhosts can be configured per-service if needed. Currently, all services use the default vhost `/`.

## Environment Variables

Each service defines its database configuration via environment variables in their build scripts:

### cafe-backend
```bash
SERVICE_DB_NAME=${SERVICE_DB_NAME:-cafe}
SERVICE_DB_USER=${SERVICE_DB_USER:-cafe_user}
```

### erp-api
```bash
SERVICE_DB_NAME=${SERVICE_DB_NAME:-bengo_erp}
SERVICE_DB_USER=${SERVICE_DB_USER:-erp_user}
PG_DATABASE=${PG_DATABASE:-${SERVICE_DB_NAME}}
```

### treasury-app
```bash
SERVICE_DB_NAME=${SERVICE_DB_NAME:-treasury}
SERVICE_DB_USER=${SERVICE_DB_USER:-treasury_user}
```

### notifications-app
```bash
SERVICE_DB_NAME=${SERVICE_DB_NAME:-notifications}
SERVICE_DB_USER=${SERVICE_DB_USER:-notifications_user}
```

## Connection Strings

### PostgreSQL
```bash
# Format: postgresql://USER:PASSWORD@postgresql.infra.svc.cluster.local:5432/DATABASE

# cafe-backend
postgresql://cafe_user:PASSWORD@postgresql.infra.svc.cluster.local:5432/cafe

# erp-api
postgresql://erp_user:PASSWORD@postgresql.infra.svc.cluster.local:5432/bengo_erp

# treasury-app
postgresql://treasury_user:PASSWORD@postgresql.infra.svc.cluster.local:5432/treasury

# notifications-app
postgresql://notifications_user:PASSWORD@postgresql.infra.svc.cluster.local:5432/notifications
```

### Redis
```bash
# Format: redis://:PASSWORD@redis-master.infra.svc.cluster.local:6379/DB_NUMBER

# All services (default DB 0)
redis://:PASSWORD@redis-master.infra.svc.cluster.local:6379/0
```

### RabbitMQ
```bash
# Format: amqp://USER:PASSWORD@rabbitmq.infra.svc.cluster.local:5672/VHOST

# All services (default vhost)
amqp://user:PASSWORD@rabbitmq.infra.svc.cluster.local:5672/
```

## Adding a New Service

When adding a new service that uses PostgreSQL:

1. **Define database configuration** in the service's `build.sh`:
   ```bash
   SERVICE_DB_NAME=${SERVICE_DB_NAME:-your_service_name}
   SERVICE_DB_USER=${SERVICE_DB_USER:-your_service_user}
   ```

2. **Add database creation logic** in the service's `build.sh`:
   ```bash
   # Create per-service database if SETUP_DATABASES is enabled
   if [[ "$SETUP_DATABASES" == "true" && -n "${KUBE_CONFIG:-}" ]]; then
     # Wait for PostgreSQL to be ready in infra namespace
     if kubectl -n infra get statefulset postgresql >/dev/null 2>&1; then
       log "Waiting for PostgreSQL to be ready..."
       kubectl -n infra rollout status statefulset/postgresql --timeout=180s || warn "PostgreSQL not fully ready"
       
       # Create service database using devops-k8s script
       if [[ -d "$DEVOPS_DIR" && -f "$DEVOPS_DIR/scripts/create-service-database.sh" ]]; then
         log "Creating database '${SERVICE_DB_NAME}' for service ${APP_NAME}..."
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

4. **Add service to this document** for reference.

