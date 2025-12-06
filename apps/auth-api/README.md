# Auth API Deployment

SSO and Authentication service for BengoBox platform.

## Overview

The Auth Service provides centralized authentication, authorization, and single sign-on (SSO) capabilities for all BengoBox services.

## Prerequisites

Before deploying the Auth Service, ensure:

1. **PostgreSQL is running** (in `infra` namespace)
2. **Redis is running** (in `infra` namespace)
3. **ArgoCD is deployed** and operational
4. **NGINX Ingress Controller** is installed

## Quick Deployment

### Step 1: Create Database

```bash
cd devops-k8s/scripts/infrastructure

# Create auth service database
SERVICE_DB_NAME=auth SERVICE_DB_USER=auth_user ./create-service-database.sh
```

### Step 2: Create Secrets

```bash
# Create auth service secrets
SERVICE_NAME=auth-api NAMESPACE=auth ./create-service-secrets.sh

# Save the displayed credentials securely!
```

### Step 3: Deploy with ArgoCD

```bash
# Apply ArgoCD Application
kubectl apply -f devops-k8s/apps/auth-api/app.yaml

# Sync the application
argocd app sync auth-api

# Monitor deployment
argocd app get auth-api --watch
```

### Step 4: Verify Deployment

```bash
# Check pods
kubectl get pods -n auth

# Check deployment
kubectl get deployment -n auth auth-api

# Check service
kubectl get svc -n auth auth-api

# Check ingress
kubectl get ingress -n auth auth-api

# Check logs
kubectl logs -n auth -l app=auth-api --tail=100 -f
```

## Configuration

### Environment Variables

The service requires the following environment variables (managed via secrets):

- `AUTH_API_ENV` - Environment (production)
- `AUTH_API_PORT` - Service port (4101)
- `AUTH_POSTGRES_URL` - PostgreSQL connection string
- `AUTH_REDIS_ADDR` - Redis address
- `AUTH_REDIS_PASSWORD` - Redis password (optional)

### Database Configuration

- **Database Name**: `auth`
- **Database User**: `auth_user`
- **Host**: `postgresql.infra.svc.cluster.local`
- **Port**: `5432`

### Redis Configuration

- **Host**: `redis-master.infra.svc.cluster.local`
- **Port**: `6379`

## Scaling

The Auth API is configured with Horizontal Pod Autoscaling:

- **Min Replicas**: 2
- **Max Replicas**: 6
- **CPU Target**: 70%
- **Memory Target**: 75%

### Manual Scaling

```bash
# Scale to specific replica count
kubectl scale deployment auth-api -n auth --replicas=4

# Check HPA status
kubectl get hpa -n auth
```

## Resource Allocation

### Per Pod

- **CPU Request**: 200m
- **CPU Limit**: 1000m (1 core)
- **Memory Request**: 256Mi
- **Memory Limit**: 1Gi

### Total (Initial Deployment)

- **2 pods**: 400m CPU, 512Mi RAM

## Health Checks

The service exposes a health endpoint:

- **Endpoint**: `/healthz`
- **Startup Probe**: 2.5 minutes max (15 failures × 10s)
- **Readiness Probe**: 60 seconds tolerance
- **Liveness Probe**: 100 seconds tolerance

## Access

### Internal (Cluster)

```
http://auth-service.auth.svc.cluster.local:4101
```

### External (Ingress)

```
https://sso.codevertexitsolutions.com
```

## Monitoring

### Metrics

The service exposes Prometheus metrics:

- **Endpoint**: `/metrics`
- **Port**: 9090

### Logs

```bash
# View logs
kubectl logs -n auth -l app=auth-api --tail=100 -f

# View logs from specific pod
kubectl logs -n auth <pod-name> -f
```

### Events

```bash
# Check recent events
kubectl get events -n auth --sort-by='.lastTimestamp'
```

## Troubleshooting

### Pod Not Starting

```bash
# Check pod status
kubectl describe pod -n auth <pod-name>

# Check logs
kubectl logs -n auth <pod-name>

# Check events
kubectl get events -n auth
```

### Secret Not Found Error

```bash
# Verify secret exists
kubectl get secret auth-service-secrets -n auth

# If missing, recreate:
cd devops-k8s/scripts/infrastructure
SERVICE_NAME=auth-service NAMESPACE=auth ./create-service-secrets.sh
```

### Database Connection Issues

```bash
# Test database connectivity
kubectl run -it --rm debug --image=postgres:15 --restart=Never -- \
  psql -h postgresql.infra.svc.cluster.local -U auth_user -d auth

# Verify database exists
kubectl exec -n infra <postgres-pod> -- psql -U postgres -l | grep auth
```

### Redis Connection Issues

```bash
# Test Redis connectivity
kubectl run -it --rm debug --image=redis:7 --restart=Never -- \
  redis-cli -h redis-master.infra.svc.cluster.local ping
```

## Maintenance

### Update Image

```bash
# Edit values.yaml and change the tag
# Then sync with ArgoCD
argocd app sync auth-service

# Or restart deployment
kubectl rollout restart deployment auth-service -n auth
```

### Rollback

```bash
# Check rollout history
kubectl rollout history deployment auth-service -n auth

# Rollback to previous version
kubectl rollout undo deployment auth-service -n auth
```

### Database Migrations

If the service requires database migrations:

```bash
# Run migration job (if service supports it)
kubectl exec -n auth <auth-api-pod> -- /app/migrate

# Or create a migration job
kubectl create job auth-migrate --image=docker.io/codevertex/auth-api:latest \
  -n auth -- /app/migrate
```

## Security

### Secrets Management

- All sensitive data stored in Kubernetes secrets
- Secrets are never committed to version control
- Rotate passwords every 90 days

### Network Policies

Consider adding network policies to restrict traffic:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: auth-api-netpol
  namespace: auth
spec:
  podSelector:
    matchLabels:
      app: auth-api
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector: {}
      ports:
        - protocol: TCP
          port: 4101
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              name: infra
      ports:
        - protocol: TCP
          port: 5432  # PostgreSQL
        - protocol: TCP
          port: 6379  # Redis
```

### Rate Limiting

The ingress is configured with rate limiting:

- **RPS Limit**: 20 requests per second
- **Connection Limit**: 100 concurrent connections

## Files

- `app.yaml` - ArgoCD Application manifest
- `values.yaml` - Helm chart values
- `README.md` - This documentation

