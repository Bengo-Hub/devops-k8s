# BengoERP DevOps Operations Runbook

## Overview

This runbook provides comprehensive operational procedures for managing BengoERP deployments in the Kubernetes environment. It includes troubleshooting guides, maintenance procedures, and emergency response protocols.

## Table of Contents

1. [Deployment Procedures](#deployment-procedures)
2. [Monitoring and Alerting](#monitoring-and-alerting)
3. [Troubleshooting](#troubleshooting)
4. [Maintenance Procedures](#maintenance-procedures)
5. [Emergency Procedures](#emergency-procedures)
6. [Performance Tuning](#performance-tuning)
7. [Security Procedures](#security-procedures)

## Deployment Procedures

### Standard Deployment

#### Pre-deployment Checklist
- [ ] Verify all tests pass in CI/CD pipeline
- [ ] Confirm database migrations are ready
- [ ] Check available resources in cluster
- [ ] Verify monitoring stack is operational
- [ ] Confirm backup procedures are in place

#### Deployment Steps

1. **Trigger Deployment**
   ```bash
   # For API deployment
   cd bengobox-erp-api
   git push origin main  # Triggers GitHub Actions workflow

   # For UI deployment
   cd bengobox-erp-ui
   git push origin main  # Triggers GitHub Actions workflow
   ```

2. **Monitor Deployment Progress**
   ```bash
   # Check ArgoCD application status
   kubectl get application erp-api -n argocd -o yaml
   kubectl get application erp-ui -n argocd -o yaml

   # Monitor pod status
   kubectl get pods -n erp --watch

   # Check deployment metrics
   ./scripts/deployment-metrics.sh monitor erp-api
   ```

3. **Verify Deployment Success**
   ```bash
   # Health check
   ./scripts/deployment-metrics.sh health erp-api
   ./scripts/deployment-metrics.sh health erp-ui

   # Application smoke tests
   curl -f https://erpapi.masterspace.co.ke/api/v1/health
   curl -f https://erp.masterspace.co.ke/health
   ```

### Rollback Procedures

#### Automated Rollback
The system automatically triggers rollback if health checks fail:

```bash
# Manual rollback trigger (if needed)
./scripts/deployment-metrics.sh rollback erp-api
```

#### Manual Rollback Steps

1. **Identify Previous Working Version**
   ```bash
   kubectl get application erp-api -n argocd -o jsonpath='{.status.history[1].revision}'
   ```

2. **Trigger Rollback**
   ```bash
   kubectl patch application erp-api -n argocd -p '{"spec":{"source":{"targetRevision":"PREVIOUS_REVISION"}}}'
   ```

3. **Monitor Rollback Progress**
   ```bash
   kubectl get application erp-api -n argocd --watch
   kubectl get pods -n erp -l app=erp-api --watch
   ```

4. **Verify Rollback Success**
   ```bash
   ./scripts/deployment-metrics.sh health erp-api
   ```

## Monitoring and Alerting

### Key Metrics to Monitor

#### Application Metrics
- API response times (target: < 2s for 95th percentile)
- Error rates (target: < 5%)
- Active users (baseline monitoring)
- Database query performance

#### Infrastructure Metrics
- CPU/Memory utilization (target: < 80%)
- Pod readiness (target: 100%)
- HPA scaling events
- VPA recommendations

### Alert Response Procedures

#### High API Error Rate Alert

1. **Acknowledge Alert**
   ```bash
   # Check current error rates
   kubectl exec deployment/erp-api -n erp -- curl -s http://localhost:9090/metrics | grep bengoerp_api_requests_total
   ```

2. **Investigate Root Cause**
   ```bash
   # Check pod logs for errors
   kubectl logs -l app=erp-api -n erp --tail=100

   # Check application health
   kubectl exec deployment/erp-api -n erp -- curl -f http://localhost:4000/api/v1/health
   ```

3. **Mitigate Issue**
   - Scale up if resource constrained
   - Check database connectivity
   - Review recent deployments for breaking changes

4. **Resolve and Document**
   - Apply fixes
   - Update monitoring thresholds if needed
   - Document incident in runbook

#### Database Connection Issues

1. **Check Database Status**
   ```bash
   kubectl get pods -n erp -l app=postgresql
   kubectl logs deployment/postgresql -n erp
   ```

2. **Verify Connectivity**
   ```bash
   kubectl exec deployment/erp-api -n erp -- nc -zv postgresql 5432
   ```

3. **Restart Services if Needed**
   ```bash
   kubectl rollout restart deployment/erp-api -n erp
   ```

## Troubleshooting

### Common Issues and Solutions

#### Ingress 503 (Service Temporarily Unavailable)

**Likely causes**: Service has no endpoints (selector/label mismatch), backend pod not listening on expected port, or ingress routing to wrong service/port.

**On the VPS, run:**
```bash
# 1) Verify ingress routing
kubectl -n erp get ingress
kubectl -n erp describe ingress erp-ui || true

# 2) Check service and endpoints
kubectl -n erp get svc erp-ui -o wide
kubectl -n erp get endpoints erp-ui -o wide

# If endpoints are empty => label/selector mismatch or pods not Ready
kubectl -n erp describe svc erp-ui | sed -n '/Selector/,$p' | head -5
kubectl -n erp get pods --show-labels | grep erp-ui || kubectl -n erp get pods --show-labels

# 3) Verify pod is listening on the targetPort (default 3000)
kubectl -n erp logs deploy/erp-ui --tail=100 || true
kubectl -n erp exec deploy/erp-ui -- sh -lc 'wget -qO- http://127.0.0.1:3000/health || curl -sf http://127.0.0.1:3000/health || true'

# 4) Ingress controller logs – look for "no endpoints" or upstream errors
kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=200 | grep -E "endpoint|upstream|no.*endpoints|unavailable" -i || true

# 5) Confirm DNS resolves to VPS IP and TLS is valid
nslookup erp.masterspace.co.ke || dig +short erp.masterspace.co.ke
openssl s_client -servername erp.masterspace.co.ke -connect erp.masterspace.co.ke:443 -brief </dev/null | head -5
```

**If endpoints are empty:**
1) Compare Service selector vs Pod labels and fix mismatch (most common root cause).
2) Sync Helm release via ArgoCD (ensures Deployment/Service labels align):
```bash
argocd app sync erp-ui
```
3) Reconcile labels quickly (temporary):
```bash
SEL=$(kubectl -n erp get svc erp-ui -o jsonpath='{.spec.selector.app}')
kubectl -n erp label deploy erp-ui app="$SEL" --overwrite
```

**If pod not listening:**
1) Check container logs for startup errors.
2) Ensure container listens on port 3000 and chart targetPort matches.
3) Redeploy:
```bash
kubectl -n erp rollout restart deploy/erp-ui
```

**If ingress misroutes:**
1) Verify ingress backend service name and port (should be the Service name and port 80).
2) Ensure ingress class is nginx and cert-manager issuer is correct.

#### Pod Crashes

**Symptoms**: Pods are restarting frequently or not starting

**Diagnosis**:
```bash
# Check pod status and events
kubectl describe pod <pod-name> -n erp

# Check logs for error messages
kubectl logs <pod-name> -n erp --previous

# Check resource limits
kubectl top pod <pod-name> -n erp
```

**Common Solutions**:
- Adjust resource requests/limits in values.yaml
- Check for liveness/readiness probe issues
- Verify environment variables and secrets

#### HPA Not Scaling

**Symptoms**: HPA not responding to load changes

**Diagnosis**:
```bash
# Check HPA status
kubectl describe hpa erp-api -n erp

# Verify metrics server
kubectl get deployment metrics-server -n kube-system

# Check custom metrics availability
kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1
```

**Common Solutions**:
- Ensure metrics server is running
- Check custom metrics are properly exposed
- Verify HPA configuration in values.yaml

#### VPA Not Updating Resources

**Symptoms**: VPA recommendations not being applied

**Diagnosis**:
```bash
# Check VPA status
kubectl describe vpa erp-api -n erp

# Check admission controller
kubectl get mutatingwebhookconfigurations | grep vpa
```

**Common Solutions**:
- Ensure VPA admission controller is installed
- Check resource limits don't conflict with requests
- Verify VPA is enabled in the namespace

#### ArgoCD Sync Issues

**Symptoms**: Applications not syncing or showing errors

**Diagnosis**:
```bash
# Check application status
kubectl get application -n argocd -o yaml

# Check sync status
kubectl describe application erp-api -n argocd

# Check git repository access
kubectl exec deployment/argocd-repo-server -n argocd -- git ls-remote https://github.com/Bengo-Hub/devops-k8s.git
```

**Common Solutions**:
- Check git credentials and repository access
- Verify values.yaml syntax
- Review ArgoCD application configuration

## Maintenance Procedures

### Database Maintenance

#### Backup Procedures

1. **Automated Backups**
   ```bash
   # Trigger manual backup if needed
   kubectl exec deployment/postgresql -n erp -- pg_dump -U postgres appdb > backup_$(date +%Y%m%d_%H%M%S).sql
   ```

2. **Backup Verification**
   ```bash
   # Test backup integrity
   kubectl exec deployment/postgresql -n erp -- psql -U postgres -d appdb -c "SELECT COUNT(*) FROM information_schema.tables;"
   ```

#### Log Rotation

1. **Application Logs**
   ```bash
   # Check current log size
   kubectl exec deployment/erp-api -n erp -- du -sh /var/log/app/

   # Rotate logs if needed (application-specific)
   kubectl exec deployment/erp-api -n erp -- logrotate /etc/logrotate.d/app
   ```

2. **System Logs**
   ```bash
   # Check journal size
   kubectl exec deployment/erp-api -n erp -- journalctl --disk-usage

   # Rotate system logs
   kubectl exec deployment/erp-api -n erp -- journalctl --rotate
   ```

### Certificate Management

#### SSL Certificate Renewal

1. **Check Certificate Expiry**
   ```bash
   kubectl get certificates -n erp
   kubectl describe certificate erp-tls -n erp
   ```

2. **Manual Renewal (if needed)**
   ```bash
   # Trigger cert-manager renewal
   kubectl annotate certificate erp-tls -n erp cert-manager.io/issue-temporary-certificate=true
   ```

#### Certificate Troubleshooting

1. **Check cert-manager Status**
   ```bash
   kubectl get pods -n cert-manager
   kubectl logs -n cert-manager deployment/cert-manager
   ```

2. **Verify DNS and ACME Challenge**
   ```bash
   # Test DNS resolution
   nslookup erpapi.masterspace.co.ke

   # Check ACME challenge
   kubectl get challenges -n erp
   ```

### Resource Optimization

#### Right-sizing Resources

1. **Monitor Resource Usage**
   ```bash
   # Check current resource utilization
   kubectl top pods -n erp

   # Review VPA recommendations
   kubectl describe vpa erp-api -n erp
   ```

2. **Apply Resource Adjustments**
   ```bash
   # Update values.yaml with new resource limits
   yq eval '.resources.limits.cpu = "1000m"' -i apps/erp-api/values.yaml
   yq eval '.resources.limits.memory = "2Gi"' -i apps/erp-api/values.yaml

   # Commit and push changes
   git add apps/erp-api/values.yaml
   git commit -m "Optimize resource limits for erp-api"
   git push
   ```

#### HPA Tuning

1. **Analyze Scaling Patterns**
   ```bash
   # Review HPA metrics
   kubectl describe hpa erp-api -n erp

   # Check scaling events in Grafana
   # Navigate to HPA dashboard and analyze scaling patterns
   ```

2. **Optimize Scaling Parameters**
   ```bash
   # Adjust scaling thresholds based on analysis
   yq eval '.autoscaling.targetCPUUtilizationPercentage = 60' -i apps/erp-api/values.yaml
   yq eval '.autoscaling.minReplicas = 3' -i apps/erp-api/values.yaml
   ```

## Emergency Procedures

### Service Outage Response

#### Level 1: Partial Service Degradation

**Symptoms**: Some endpoints slow or failing, but service partially operational

**Response**:
1. **Immediate Actions**
   ```bash
   # Check service health
   curl -f https://erpapi.masterspace.co.ke/api/v1/health || echo "API health check failed"

   # Check pod status
   kubectl get pods -n erp -l app=erp-api

   # Check recent logs for errors
   kubectl logs -l app=erp-api -n erp --tail=50
   ```

2. **Investigation**
   - Check error rates and response times
   - Identify affected components
   - Review recent changes/deployments

3. **Mitigation**
   - Scale up if resource constrained
   - Restart failing pods
   - Check database connectivity

#### Level 2: Complete Service Outage

**Symptoms**: All services down, complete loss of functionality

**Response**:
1. **Immediate Actions**
   ```bash
   # Check cluster status
   kubectl cluster-info

   # Check node status
   kubectl get nodes

   # Check all application pods
   kubectl get pods -n erp --all-namespaces
   ```

2. **Emergency Contacts**
   - Notify on-call engineer
   - Alert development team
   - Inform stakeholders

3. **Recovery Steps**
   ```bash
   # Attempt automated recovery
   kubectl rollout restart deployment/erp-api -n erp
   kubectl rollout restart deployment/erp-ui -n erp

   # Check if automated rollback is needed
   ./scripts/deployment-metrics.sh rollback erp-api
   ./scripts/deployment-metrics.sh rollback erp-ui
   ```

4. **Post-Incident**
   - Document root cause
   - Implement preventive measures
   - Update runbook with lessons learned

### Data Recovery

#### Database Recovery

1. **Check Database Status**
   ```bash
   kubectl exec deployment/postgresql -n erp -- pg_isready -U postgres
   ```

2. **Restore from Backup (if needed)**
   ```bash
   # Stop application
   kubectl scale deployment erp-api -n erp --replicas=0

   # Restore database
   kubectl exec deployment/postgresql -n erp -- psql -U postgres -d appdb < /backup/latest_backup.sql

   # Restart application
   kubectl scale deployment erp-api -n erp --replicas=2
   ```

#### File System Recovery

1. **Check Persistent Volumes**
   ```bash
   kubectl get pv
   kubectl get pvc -n erp
   ```

2. **Restore from Backup**
   ```bash
   # Restore application data
   kubectl cp /backup/app_data deployment/erp-api:/app/data -n erp
   ```

## Performance Tuning

### Database Optimization

#### Query Performance

1. **Monitor Slow Queries**
   ```bash
   # Enable query logging (temporary)
   kubectl exec deployment/postgresql -n erp -- psql -U postgres -c "ALTER SYSTEM SET log_min_duration_statement = 1000;"

   # Check slow query log
   kubectl exec deployment/postgresql -n erp -- tail -f /var/log/postgresql/postgresql.log | grep "duration: "
   ```

2. **Create Indexes**
   ```bash
   # Connect to database and create indexes based on slow query analysis
   kubectl exec deployment/postgresql -n erp -- psql -U postgres -d appdb -c "CREATE INDEX CONCURRENTLY idx_example ON table_name(column_name);"
   ```

#### Connection Pooling

1. **Monitor Connection Usage**
   ```bash
   kubectl exec deployment/postgresql -n erp -- psql -U postgres -c "SELECT count(*) FROM pg_stat_activity WHERE state = 'active';"
   ```

2. **Adjust Pool Settings**
   ```bash
   # Update connection pool configuration if needed
   kubectl patch configmap erp-api-config -n erp -p '{"data":{"DB_POOL_SIZE":"20"}}'
   ```

### Application Optimization

#### Memory Management

1. **Monitor Memory Usage**
   ```bash
   kubectl top pods -n erp
   kubectl describe nodes | grep -A 10 "Allocated resources"
   ```

2. **Optimize Memory Settings**
   ```bash
   # Adjust JVM or runtime memory settings if applicable
   yq eval '.resources.requests.memory = "256Mi"' -i apps/erp-api/values.yaml
   ```

#### Cache Optimization

1. **Monitor Cache Performance**
   ```bash
   # Check Redis performance
   kubectl exec deployment/redis -n erp -- redis-cli INFO | grep -E "(hit|miss)"
   ```

2. **Tune Cache Settings**
   ```bash
   # Adjust cache TTL and size limits based on monitoring data
   kubectl patch configmap erp-api-config -n erp -p '{"data":{"CACHE_TTL":"3600"}}'
   ```

## Security Procedures

### Access Management

#### SSH Key Rotation

1. **Generate New SSH Keys**
   ```bash
   ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa_deployment -N "codevertex"
   ```

2. **Update GitHub Secrets**
   ```bash
   # Update DOCKER_SSH_KEY in GitHub repository secrets
   gh secret set DOCKER_SSH_KEY < ~/.ssh/id_rsa_deployment.pub
   ```

3. **Rotate Kubernetes Access**
   ```bash
   # Update KUBE_CONFIG secret if needed
   kubectl get secret generic erp-deploy-token -n erp -o yaml > kubeconfig_backup.yaml
   # Generate new kubeconfig and update secret
   ```

#### Certificate Management

1. **Monitor Certificate Expiry**
   ```bash
   kubectl get certificates -n erp --sort-by=.metadata.creationTimestamp
   ```

2. **Automated Renewal**
   - cert-manager handles automatic renewal
   - Monitor for renewal failures
   - Set up alerts for certificates expiring within 30 days

### Security Monitoring

#### Vulnerability Scanning

1. **Container Image Scanning**
   ```bash
   # Scan images for vulnerabilities
   trivy image docker.io/codevertex/erp-api:latest
   trivy image docker.io/codevertex/erp-ui:latest
   ```

2. **Kubernetes Security**
   ```bash
   # Check for security issues
   kubectl get pods -n erp -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.securityContext}{"\n"}{end}'
   ```

#### Access Auditing

1. **Review Access Logs**
   ```bash
   # Check API access logs
   kubectl logs -l app=erp-api -n erp | grep -E "(401|403|404)"

   # Check Kubernetes audit logs
   kubectl logs -n kube-system audit-audit -f | head -20
   ```

## Contact Information

### Emergency Contacts
- **On-call Engineer**: +254-XXX-XXXXXX
- **DevOps Team Lead**: devops@bengoerp.com
- **Infrastructure Team**: infra@bengoerp.com

### Escalation Procedures
1. **Level 1**: On-call engineer notification
2. **Level 2**: DevOps team lead escalation
3. **Level 3**: Infrastructure team involvement
4. **Level 4**: External vendor support

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2024-01-XX | DevOps Team | Initial runbook creation |
| 1.1 | 2024-01-XX | DevOps Team | Added monitoring procedures |

---

*This runbook is maintained by the DevOps team. For updates or corrections, please contact devops@bengoerp.com.*
