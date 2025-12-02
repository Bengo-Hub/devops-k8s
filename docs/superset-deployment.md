# Apache Superset Deployment Guide

## Overview

This document provides comprehensive guidance for deploying Apache Superset in Kubernetes using ArgoCD. It includes troubleshooting steps for common deployment issues, especially the "Deployment exceeded its progress deadline" error.

## Table of Contents

1. [Architecture](#architecture)
2. [Prerequisites](#prerequisites)
3. [Deployment Process](#deployment-process)
4. [Configuration Details](#configuration-details)
5. [Troubleshooting](#troubleshooting)
6. [Scaling and Performance](#scaling-and-performance)
7. [Monitoring and Maintenance](#monitoring-and-maintenance)
8. [Security Best Practices](#security-best-practices)

---

## Architecture

### Components

Apache Superset deployment consists of:

1. **Superset Web Server** (2-6 replicas with HPA)
   - Serves the web UI and REST API
   - Handles user authentication and authorization
   - Processes synchronous queries

2. **Celery Workers** (2-8 replicas with HPA)
   - Execute asynchronous queries
   - Handle long-running tasks
   - Process scheduled reports

3. **Celery Beat** (1 replica)
   - Manages scheduled tasks
   - Triggers periodic jobs (cache warming, reports)

4. **External Dependencies**
   - PostgreSQL (shared instance in `infra` namespace)
   - Redis (shared instance in `infra` namespace)

### Network Architecture

```
User → Ingress (NGINX) → Superset Service → Superset Pods
                                            ↓
                          PostgreSQL (infra namespace)
                          Redis (infra namespace)
```

---

## Prerequisites

### Infrastructure Requirements

Before deploying Superset, ensure the following are ready:

#### 1. PostgreSQL Instance
```bash
# Verify PostgreSQL is running
kubectl get pods -n infra -l app.kubernetes.io/name=postgresql

# Should show: Running
```

#### 2. Redis Instance
```bash
# Verify Redis is running
kubectl get pods -n infra -l app.kubernetes.io/name=redis

# Should show: Running
```

#### 3. ArgoCD
```bash
# Verify ArgoCD is running
kubectl get pods -n argocd

# All pods should be Running
```

#### 4. NGINX Ingress Controller
```bash
# Verify Ingress Controller
kubectl get pods -n ingress-nginx
```

### Resource Requirements

Ensure your cluster has sufficient resources:

- **Minimum Resources (per node)**:
  - CPU: 4 cores
  - Memory: 8 GB
  - Storage: 50 GB

- **Recommended for Production**:
  - CPU: 8 cores
  - Memory: 16 GB
  - Storage: 100 GB

---

## Deployment Process

### Step 1: Create Superset Database

First, create the dedicated database and user for Superset:

```bash
cd devops-k8s/scripts/infrastructure

# Create database and user
./create-superset-database.sh
```

This script:
- Creates `superset` database
- Creates `superset_user` with full permissions
- Creates `superset_readonly` for read-only access
- Enables pgvector extension
- Grants necessary permissions

**Expected Output:**
```
✓ Database: superset
✓ User: superset_user
✓ Read-only User: superset_readonly
```

### Step 2: Create Kubernetes Secrets

Generate and create the required secrets:

```bash
# Create Superset secrets
./create-superset-secrets.sh
```

This script creates a secret named `superset-secrets` with:
- `DATABASE_PASSWORD` - Database password
- `SECRET_KEY` - Flask secret key for session management
- `ADMIN_USERNAME` - Admin username (default: admin)
- `ADMIN_PASSWORD` - Auto-generated admin password
- `ADMIN_EMAIL` - Admin email
- Database connection details
- Redis connection details

**IMPORTANT:** Save the admin credentials displayed after script execution!

### Step 3: Verify Configuration

Check the Superset configuration files:

```bash
# Review the ArgoCD Application manifest
cat devops-k8s/apps/superset/app.yaml

# Review the values file
cat devops-k8s/apps/superset/values.yaml
```

### Step 4: Deploy with ArgoCD

Deploy Superset using ArgoCD:

```bash
# Apply the ArgoCD Application
kubectl apply -f devops-k8s/apps/superset/app.yaml

# Wait for ArgoCD to sync
argocd app sync superset

# Monitor the deployment
argocd app get superset --watch
```

### Step 5: Verify Deployment

Check deployment status:

```bash
# Check pods
kubectl get pods -n default -l app=superset

# Check deployment status
kubectl get deployment -n default superset

# Check services
kubectl get svc -n default superset

# Check ingress
kubectl get ingress -n default superset
```

Expected output after successful deployment:
```
NAME                          READY   STATUS    RESTARTS   AGE
superset-6d8f9c8b7d-abc12     1/1     Running   0          5m
superset-6d8f9c8b7d-def34     1/1     Running   0          5m
superset-worker-5d7f8c9-gh56  1/1     Running   0          5m
superset-worker-5d7f8c9-ij78  1/1     Running   0          5m
superset-beat-7f8d9e0-kl90    1/1     Running   0          5m
```

### Step 6: Access Superset

Once deployed, access Superset:

```bash
# Get the ingress URL
kubectl get ingress -n default superset

# Access via browser
# URL: https://superset.codevertexitsolutions.co.ke
```

**Default Credentials:**
- Username: `admin`
- Password: (from create-superset-secrets.sh output)

---

## Configuration Details

### Health Checks

#### Startup Probe
```yaml
startupProbe:
  httpGet:
    path: /health
    port: http
  initialDelaySeconds: 30
  periodSeconds: 10
  failureThreshold: 30  # 5 minutes total
```
- **Purpose**: Gives Superset time to initialize (database migrations, etc.)
- **Total Time**: 5 minutes (30 checks × 10s)
- **Why Needed**: Superset initialization can take 2-4 minutes

#### Readiness Probe
```yaml
readinessProbe:
  httpGet:
    path: /health
    port: http
  initialDelaySeconds: 60
  periodSeconds: 10
  failureThreshold: 6
```
- **Purpose**: Determines when pod can receive traffic
- **Checks**: Every 10 seconds
- **Failure Tolerance**: 60 seconds of failures

#### Liveness Probe
```yaml
livenessProbe:
  httpGet:
    path: /health
    port: http
  initialDelaySeconds: 120
  periodSeconds: 20
  failureThreshold: 5
```
- **Purpose**: Restarts pod if unhealthy
- **Checks**: Every 20 seconds
- **Failure Tolerance**: 100 seconds of failures

### Resource Allocation

#### Web Server Pods
```yaml
resources:
  requests:
    cpu: 500m        # 0.5 CPU cores
    memory: 1Gi      # 1 GB RAM
  limits:
    cpu: 2000m       # 2 CPU cores
    memory: 4Gi      # 4 GB RAM
```

#### Worker Pods
```yaml
resources:
  requests:
    cpu: 200m        # 0.2 CPU cores
    memory: 512Mi    # 512 MB RAM
  limits:
    cpu: 1000m       # 1 CPU core
    memory: 2Gi      # 2 GB RAM
```

### Autoscaling Configuration

#### Horizontal Pod Autoscaler (HPA)

**Web Server:**
```yaml
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 6
  targetCPUUtilizationPercentage: 70
  targetMemoryUtilizationPercentage: 75
```

**Workers:**
```yaml
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 8
  targetCPUUtilizationPercentage: 70
```

### Progress Deadline

```yaml
progressDeadlineSeconds: 1200  # 20 minutes
```

- **Default Kubernetes**: 600 seconds (10 minutes)
- **Superset Requirement**: 1200 seconds (20 minutes)
- **Why**: Database migrations and initialization can take 5-10 minutes

---

## Troubleshooting

### Common Issue: "Deployment exceeded its progress deadline"

#### Root Causes and Solutions

##### 1. Database Migration Timeout

**Symptoms:**
- Pods stuck in `Init` or `CrashLoopBackOff`
- Logs show database migration errors

**Solution:**
```bash
# Check init container logs
kubectl logs -n default <pod-name> -c wait-for-postgres

# Check migration logs
kubectl logs -n default <pod-name> -c superset-init

# Manually run migrations (if needed)
kubectl exec -n default <pod-name> -- superset db upgrade
```

##### 2. Missing or Incorrect Secrets

**Symptoms:**
- Pods fail to start
- Environment variable errors in logs

**Solution:**
```bash
# Verify secret exists
kubectl get secret superset-secrets -n default

# Check secret contents (keys only)
kubectl get secret superset-secrets -n default -o yaml

# Recreate secrets if needed
cd devops-k8s/scripts/infrastructure
./create-superset-secrets.sh
```

##### 3. Database Connection Issues

**Symptoms:**
- Cannot connect to PostgreSQL
- Connection refused errors

**Solution:**
```bash
# Test database connectivity
kubectl run -it --rm debug --image=postgres:15 --restart=Never -- \
  psql -h postgresql.infra.svc.cluster.local -U superset_user -d superset

# Check PostgreSQL service
kubectl get svc -n infra postgresql

# Verify database exists
kubectl exec -n infra <postgres-pod> -- \
  psql -U postgres -c "\l" | grep superset
```

##### 4. Redis Connection Issues

**Symptoms:**
- Celery workers failing
- Cache errors in logs

**Solution:**
```bash
# Test Redis connectivity
kubectl run -it --rm debug --image=redis:7 --restart=Never -- \
  redis-cli -h redis-master.infra.svc.cluster.local ping

# Check Redis service
kubectl get svc -n infra redis-master

# Verify Redis is accepting connections
kubectl exec -n infra <redis-pod> -- redis-cli ping
```

##### 5. Insufficient Resources

**Symptoms:**
- Pods stuck in `Pending` state
- Events show insufficient CPU/memory

**Solution:**
```bash
# Check node resources
kubectl top nodes

# Check pod resource usage
kubectl top pods -n default

# Describe pod to see events
kubectl describe pod -n default <pod-name>

# Scale down if needed
kubectl scale deployment superset -n default --replicas=1
```

##### 6. Image Pull Issues

**Symptoms:**
- `ImagePullBackOff` or `ErrImagePull`
- Cannot pull Superset image

**Solution:**
```bash
# Check image pull status
kubectl describe pod -n default <pod-name>

# Verify image exists
docker pull apache/superset:3.1.0

# Use alternative registry if needed
# Edit app.yaml and change image repository
```

### Deployment Health Checks

#### Quick Health Check Script

```bash
#!/bin/bash
# superset-health-check.sh

echo "=== Superset Deployment Health Check ==="

echo -e "\n1. Checking pods..."
kubectl get pods -n default -l app=superset

echo -e "\n2. Checking deployments..."
kubectl get deployment -n default superset

echo -e "\n3. Checking HPA..."
kubectl get hpa -n default

echo -e "\n4. Checking services..."
kubectl get svc -n default superset

echo -e "\n5. Checking ingress..."
kubectl get ingress -n default superset

echo -e "\n6. Checking secrets..."
kubectl get secret superset-secrets -n default

echo -e "\n7. Recent pod events..."
kubectl get events -n default --sort-by='.lastTimestamp' | grep superset | tail -10

echo -e "\n8. ArgoCD sync status..."
argocd app get superset --hard-refresh

echo -e "\nHealth check complete!"
```

### Debugging Commands

```bash
# View pod logs (web server)
kubectl logs -n default -l app=superset --tail=100 -f

# View pod logs (worker)
kubectl logs -n default -l app=superset-worker --tail=100 -f

# View pod logs (beat)
kubectl logs -n default -l app=superset-beat --tail=100 -f

# Describe problematic pod
kubectl describe pod -n default <pod-name>

# Get pod events
kubectl get events -n default --field-selector involvedObject.name=<pod-name>

# Check pod resource usage
kubectl top pod -n default <pod-name>

# Interactive shell in pod
kubectl exec -it -n default <pod-name> -- /bin/bash

# Port forward for local access
kubectl port-forward -n default svc/superset 8088:8088
```

---

## Scaling and Performance

### Manual Scaling

```bash
# Scale web servers
kubectl scale deployment superset -n default --replicas=4

# Scale workers
kubectl scale deployment superset-worker -n default --replicas=6
```

### Automatic Scaling

HPA automatically scales based on:
- CPU utilization (target: 70%)
- Memory utilization (target: 75%)

Monitor HPA:
```bash
# Watch HPA metrics
kubectl get hpa -n default --watch

# Describe HPA for details
kubectl describe hpa superset -n default
```

### Performance Tuning

#### Database Connection Pooling

Add to `configOverrides.custom_config`:
```python
SQLALCHEMY_POOL_SIZE = 20
SQLALCHEMY_POOL_TIMEOUT = 30
SQLALCHEMY_POOL_RECYCLE = 3600
SQLALCHEMY_MAX_OVERFLOW = 40
```

#### Cache Configuration

Already configured in values.yaml:
```python
CACHE_CONFIG = {
    'CACHE_TYPE': 'RedisCache',
    'CACHE_DEFAULT_TIMEOUT': 300,
    'CACHE_KEY_PREFIX': 'superset_',
}
```

#### Query Performance

Add to `configOverrides.custom_config`:
```python
SQL_MAX_ROW = 100000
SQLLAB_ASYNC_TIME_LIMIT_SEC = 300
SQLLAB_TIMEOUT = 300
```

---

## Monitoring and Maintenance

### Health Monitoring

```bash
# Check overall health
kubectl get pods -n default -l app=superset -o wide

# Monitor resource usage
kubectl top pods -n default -l app=superset

# Watch for events
kubectl get events -n default --watch | grep superset
```

### Log Aggregation

```bash
# Aggregate logs from all Superset pods
kubectl logs -n default -l app=superset --tail=100 --timestamps

# Follow logs in real-time
stern -n default superset
```

### Backup and Restore

#### Database Backup
```bash
# Backup Superset database
kubectl exec -n infra <postgres-pod> -- \
  pg_dump -U postgres superset > superset-backup-$(date +%Y%m%d).sql

# Restore from backup
kubectl exec -i -n infra <postgres-pod> -- \
  psql -U postgres superset < superset-backup-20231201.sql
```

#### Configuration Backup
```bash
# Backup secrets
kubectl get secret superset-secrets -n default -o yaml > superset-secrets-backup.yaml

# Backup ArgoCD application
kubectl get application superset -n argocd -o yaml > superset-app-backup.yaml
```

### Upgrade Process

```bash
# Update to new version
# Edit app.yaml and change image tag
# Example: tag: "3.1.0" → tag: "3.2.0"

# Sync with ArgoCD
argocd app sync superset

# Monitor rollout
kubectl rollout status deployment superset -n default

# Rollback if needed
kubectl rollout undo deployment superset -n default
```

---

## Security Best Practices

### 1. Secret Management

✅ **Do:**
- Use Kubernetes secrets for all sensitive data
- Rotate passwords regularly (every 90 days)
- Use strong, randomly generated passwords
- Backup secrets in encrypted storage

❌ **Don't:**
- Hard-code passwords in YAML files
- Commit secrets to version control
- Use default or weak passwords
- Share admin credentials

### 2. Network Security

```yaml
# Network Policy (example)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: superset-network-policy
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: superset
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8088
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

### 3. RBAC Configuration

```bash
# Create service account for Superset
kubectl create sa superset -n default

# Bind to ClusterRole (if needed)
kubectl create rolebinding superset-role \
  --clusterrole=view \
  --serviceaccount=default:superset \
  -n default
```

### 4. TLS/SSL Configuration

Ensure TLS is enabled in ingress:
```yaml
ingress:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
  tls:
    - hosts:
        - superset.codevertexitsolutions.co.ke
      secretName: superset-codevertexitsolutions-tls
```

### 5. Security Context

Already configured:
```yaml
securityContext:
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
  runAsNonRoot: true
```

---

## Maintenance Tasks

### Daily

- Monitor pod health and resource usage
- Check application logs for errors
- Verify database connectivity

### Weekly

- Review HPA metrics and scaling events
- Check for failed jobs in Celery
- Review disk usage on persistent volumes
- Analyze query performance

### Monthly

- Update Superset to latest stable version
- Rotate secrets and passwords
- Review and optimize database queries
- Clean up old cache entries
- Backup configuration and data

### Quarterly

- Review and update resource allocations
- Audit user access and permissions
- Test disaster recovery procedures
- Update documentation

---

## Quick Reference

### Important Files

| File | Purpose |
|------|---------|
| `devops-k8s/apps/superset/app.yaml` | ArgoCD Application manifest |
| `devops-k8s/apps/superset/values.yaml` | Helm values (standalone) |
| `devops-k8s/scripts/infrastructure/create-superset-database.sh` | Database setup script |
| `devops-k8s/scripts/infrastructure/create-superset-secrets.sh` | Secret generation script |

### Important Commands

```bash
# Deploy Superset
kubectl apply -f devops-k8s/apps/superset/app.yaml

# Check status
argocd app get superset

# View logs
kubectl logs -n default -l app=superset --tail=100 -f

# Restart deployment
kubectl rollout restart deployment superset -n default

# Scale manually
kubectl scale deployment superset -n default --replicas=3

# Delete and redeploy
kubectl delete -f devops-k8s/apps/superset/app.yaml
kubectl apply -f devops-k8s/apps/superset/app.yaml
```

### Support and Resources

- **Official Superset Docs**: https://superset.apache.org/docs/
- **Helm Chart Docs**: https://github.com/apache/superset/tree/master/helm/superset
- **Kubernetes Docs**: https://kubernetes.io/docs/
- **ArgoCD Docs**: https://argo-cd.readthedocs.io/

---

## Conclusion

This deployment configuration provides a production-ready Apache Superset instance with:

✅ High availability (2-6 replicas with HPA)  
✅ Proper health checks and probes  
✅ Resource limits to prevent OOMKills  
✅ Automatic scaling based on load  
✅ Secure secret management  
✅ Database persistence  
✅ Redis caching  
✅ Celery workers for async processing  
✅ Extended progress deadline for successful deployment  

Follow the deployment process step-by-step to ensure a smooth installation.

