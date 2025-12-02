# Superset Deployment Checklist

Use this checklist to ensure a successful Apache Superset deployment.

## Pre-Deployment Checklist

### Infrastructure Prerequisites

- [ ] **Kubernetes cluster is running**
  ```bash
  kubectl cluster-info
  ```

- [ ] **ArgoCD is installed and operational**
  ```bash
  kubectl get pods -n argocd
  ```

- [ ] **PostgreSQL is deployed and healthy**
  ```bash
  kubectl get pods -n infra -l app.kubernetes.io/name=postgresql
  ```

- [ ] **Redis is deployed and healthy**
  ```bash
  kubectl get pods -n infra -l app.kubernetes.io/name=redis
  ```

- [ ] **NGINX Ingress Controller is running**
  ```bash
  kubectl get pods -n ingress-nginx
  ```

- [ ] **Cert-Manager is installed (if using TLS)**
  ```bash
  kubectl get pods -n cert-manager
  ```

### Resource Availability

- [ ] **Cluster has sufficient resources**
  ```bash
  kubectl top nodes
  ```
  - Minimum: 4 CPU cores, 8 GB RAM per node
  - Recommended: 8 CPU cores, 16 GB RAM per node

- [ ] **Storage class is available**
  ```bash
  kubectl get storageclass
  ```

### Network Configuration

- [ ] **DNS resolution is working**
  ```bash
  kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup kubernetes.default
  ```

- [ ] **Ingress hostname is configured**
  - Default: `superset.codevertex.local`
  - Update in `app.yaml` if different

---

## Deployment Steps Checklist

### Step 1: Database Setup

- [ ] **Create Superset database and user**
  ```bash
  cd devops-k8s/scripts/infrastructure
  ./create-superset-database.sh
  ```

- [ ] **Verify database creation**
  ```bash
  kubectl exec -n infra <postgres-pod> -- psql -U postgres -c "\l" | grep superset
  ```

- [ ] **Verify user creation**
  ```bash
  kubectl exec -n infra <postgres-pod> -- psql -U postgres -c "\du" | grep superset_user
  ```

### Step 2: Secrets Management

- [ ] **Generate and create Kubernetes secrets**
  ```bash
  cd devops-k8s/scripts/infrastructure
  ./create-superset-secrets.sh
  ```

- [ ] **Save admin credentials securely**
  - Username: _______________
  - Password: _______________
  - Location: _______________

- [ ] **Verify secret creation**
  ```bash
  kubectl get secret superset-secrets -n default
  ```

- [ ] **Backup secrets file created**
  - Location: `devops-k8s/backups/superset-secrets-*.txt`
  - Stored securely: [ ]
  - Original deleted: [ ]

### Step 3: Configuration Review

- [ ] **Review ArgoCD Application manifest**
  ```bash
  cat devops-k8s/apps/superset/app.yaml
  ```
  
  Verify:
  - [ ] Correct namespace
  - [ ] Correct image tag (not `latest`)
  - [ ] Resource limits defined
  - [ ] Health probes configured
  - [ ] Progress deadline set (1200s)

- [ ] **Review Helm values**
  ```bash
  cat devops-k8s/apps/superset/values.yaml
  ```
  
  Verify:
  - [ ] Database connection details
  - [ ] Redis connection details
  - [ ] Ingress configuration
  - [ ] Autoscaling settings

- [ ] **Update ingress hostname if needed**
  - Current: `superset.codevertexitsolutions.co.ke`
  - Updated to: _______________

### Step 4: Deploy Application

- [ ] **Apply ArgoCD Application**
  ```bash
  kubectl apply -f devops-k8s/apps/superset/app.yaml
  ```

- [ ] **Trigger ArgoCD sync**
  ```bash
  argocd app sync superset
  ```

- [ ] **Monitor deployment progress**
  ```bash
  argocd app get superset --watch
  ```

### Step 5: Verification

- [ ] **Check ArgoCD sync status**
  ```bash
  argocd app get superset
  ```
  - Sync Status: Synced
  - Health Status: Healthy

- [ ] **Verify deployments are ready**
  ```bash
  kubectl get deployments -n default | grep superset
  ```
  - [ ] superset: READY
  - [ ] superset-worker: READY
  - [ ] superset-beat: READY

- [ ] **Check pod status**
  ```bash
  kubectl get pods -n default -l app=superset
  ```
  - All pods: Running
  - Restart count: 0

- [ ] **Verify services**
  ```bash
  kubectl get svc -n default superset
  ```
  - Service type: ClusterIP
  - Port: 8088

- [ ] **Check ingress**
  ```bash
  kubectl get ingress -n default superset
  ```
  - Address assigned
  - Host configured

- [ ] **Run health check script**
  ```bash
  cd devops-k8s/scripts/infrastructure
  ./superset-health-check.sh
  ```
  - All checks passed: [ ]

### Step 6: Access and Login

- [ ] **Access Superset UI**
  - URL: https://superset.codevertexitsolutions.co.ke
  - Page loads successfully

- [ ] **Login with admin credentials**
  - Username: admin
  - Password: (from secrets)
  - Login successful: [ ]

- [ ] **Verify database connection**
  - Navigate to: Settings → Database Connections
  - Test connection to databases
  - Connection successful: [ ]

### Step 7: Post-Deployment Configuration

- [ ] **Create service account users**
  - Create users for services that need API access

- [ ] **Configure data sources**
  - Add database connections for your applications

- [ ] **Set up initial dashboards**
  - Create or import dashboards as needed

- [ ] **Configure permissions**
  - Set up roles and permissions

- [ ] **Enable scheduled queries (if needed)**
  - Configure Celery beat schedules

---

## Monitoring Setup Checklist

- [ ] **Set up log aggregation**
  ```bash
  # Example: Install Stern for log viewing
  kubectl logs -n default -l app=superset --tail=100 -f
  ```

- [ ] **Configure metrics collection**
  - Prometheus integration
  - Grafana dashboards

- [ ] **Set up alerts**
  - Pod restarts
  - High resource usage
  - Failed queries

- [ ] **Document access credentials**
  - Location: _______________
  - Backup location: _______________

---

## Troubleshooting Checklist

If deployment fails, check:

### Pod Issues

- [ ] **Check pod status**
  ```bash
  kubectl get pods -n default -l app=superset
  ```

- [ ] **View pod logs**
  ```bash
  kubectl logs -n default <pod-name> --tail=100
  ```

- [ ] **Describe pod for events**
  ```bash
  kubectl describe pod -n default <pod-name>
  ```

- [ ] **Check init container logs**
  ```bash
  kubectl logs -n default <pod-name> -c wait-for-postgres
  kubectl logs -n default <pod-name> -c wait-for-redis
  ```

### Database Issues

- [ ] **Test database connectivity**
  ```bash
  kubectl run -it --rm debug --image=postgres:15 --restart=Never -- \
    psql -h postgresql.infra.svc.cluster.local -U superset_user -d superset
  ```

- [ ] **Check database exists**
  ```bash
  kubectl exec -n infra <postgres-pod> -- psql -U postgres -l | grep superset
  ```

- [ ] **Verify database user**
  ```bash
  kubectl exec -n infra <postgres-pod> -- psql -U postgres -c "\du" | grep superset_user
  ```

### Redis Issues

- [ ] **Test Redis connectivity**
  ```bash
  kubectl run -it --rm debug --image=redis:7 --restart=Never -- \
    redis-cli -h redis-master.infra.svc.cluster.local ping
  ```

- [ ] **Check Redis is running**
  ```bash
  kubectl get pods -n infra -l app.kubernetes.io/name=redis
  ```

### Secret Issues

- [ ] **Verify secret exists**
  ```bash
  kubectl get secret superset-secrets -n default
  ```

- [ ] **Check secret keys**
  ```bash
  kubectl get secret superset-secrets -n default -o jsonpath='{.data}' | jq 'keys'
  ```

- [ ] **Recreate secrets if needed**
  ```bash
  kubectl delete secret superset-secrets -n default
  ./create-superset-secrets.sh
  ```

### Resource Issues

- [ ] **Check node resources**
  ```bash
  kubectl top nodes
  ```

- [ ] **Check pod resource usage**
  ```bash
  kubectl top pods -n default
  ```

- [ ] **Review events for scheduling issues**
  ```bash
  kubectl get events -n default --sort-by='.lastTimestamp' | grep superset
  ```

### Progress Deadline Exceeded

If you get "Deployment exceeded its progress deadline":

- [ ] **Check progress deadline setting**
  - Should be: 1200 seconds (20 minutes)
  - Location: `app.yaml` → `progressDeadlineSeconds`

- [ ] **Check startup probe configuration**
  - Initial delay: 30s
  - Failure threshold: 30 (5 minutes total)

- [ ] **Review database migration logs**
  ```bash
  kubectl logs -n default <pod-name> | grep "db upgrade"
  ```

- [ ] **Manually trigger database upgrade if stuck**
  ```bash
  kubectl exec -n default <pod-name> -- superset db upgrade
  ```

---

## Rollback Checklist

If deployment fails and rollback is needed:

- [ ] **Check rollout history**
  ```bash
  kubectl rollout history deployment superset -n default
  ```

- [ ] **Rollback to previous version**
  ```bash
  kubectl rollout undo deployment superset -n default
  ```

- [ ] **Verify rollback success**
  ```bash
  kubectl rollout status deployment superset -n default
  ```

- [ ] **Delete ArgoCD application (if needed)**
  ```bash
  kubectl delete application superset -n argocd
  ```

---

## Post-Deployment Maintenance

### Daily

- [ ] Monitor pod health
- [ ] Check application logs for errors
- [ ] Verify dashboard accessibility

### Weekly

- [ ] Review resource usage and scaling
- [ ] Check for failed Celery tasks
- [ ] Review query performance

### Monthly

- [ ] Update to latest stable version
- [ ] Rotate passwords and secrets
- [ ] Review and optimize configurations
- [ ] Backup database and configurations

---

## Sign-Off

Deployment completed by: _______________  
Date: _______________  
Version deployed: _______________  
Environment: _______________

Verified by: _______________  
Date: _______________

---

## Additional Resources

- **Deployment Documentation**: `devops-k8s/docs/superset-deployment.md`
- **Health Check Script**: `devops-k8s/scripts/infrastructure/superset-health-check.sh`
- **Official Superset Docs**: https://superset.apache.org/docs/
- **Helm Chart Repository**: https://github.com/apache/superset/tree/master/helm/superset

---

**Notes:**

Use this space for deployment-specific notes:

_______________________________________________________

_______________________________________________________

_______________________________________________________

