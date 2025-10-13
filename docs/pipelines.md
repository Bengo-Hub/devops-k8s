Pipelines
---------

This repo provides multiple deployment approaches for different use cases:

## 1. Application-Specific Deployment (Recommended)

For applications that need full control over their deployment process, use the **deploy.yml approach** where each application manages its own build and deployment logic through build.sh scripts.

### Features
- **Self-contained**: Each application controls its complete build and deployment process
- **Highly flexible**: Easy to customize per application requirements
- **Comprehensive logging**: Detailed colored output and error handling
- **Security scanning**: Built-in Trivy filesystem and image scanning
- **Multi-environment support**: Configurable for different deployment scenarios
- **Database automation**: Automatic setup and configuration
- **Kubernetes integration**: Direct management of K8s resources and Helm charts

### Setup Requirements
Each application needs:
- `.github/workflows/deploy.yml` - GitHub Actions workflow that calls build.sh
- `build.sh` - Complete deployment script with all phases
- `kubeSecrets/devENV.yaml` - Kubernetes secrets configuration

### Example Application Structure
```
your-app/
├── .github/workflows/
│   └── deploy.yml             # Calls build.sh script
├── build.sh                   # Complete deployment logic
├── kubeSecrets/
│   └── devENV.yaml            # Dynamic secrets (no hardcoded values)
└── Dockerfile
```

### Deployment Flow
1. **Build Phase**: Security scanning, Docker build with SSH support, container vulnerability scanning
2. **Deploy Phase**: Registry authentication, image push, database setup, K8s secrets, ArgoCD manifest updates
3. **ArgoCD Sync**: Automated detection of git changes triggers application deployment
4. **Resource Creation**: Applications, services, ingress, and certificates deployed to K8s cluster
5. **Service URLs**: Ingress URLs made available for application access

### ArgoCD Integration

The deployment process integrates with ArgoCD for automated application management:

#### ArgoCD Application Structure
```
devops-k8s/apps/
├── erp-api/
│   ├── app.yaml          # ArgoCD Application manifest
│   └── values.yaml       # Helm values (updated by build.sh)
└── erp-ui/
    ├── app.yaml          # ArgoCD Application manifest
    └── values.yaml       # Helm values (updated by build.sh)
```

#### Automated Sync Process
1. **build.sh** updates ArgoCD application manifests with new image tags
2. **Git push** triggers ArgoCD change detection
3. **ArgoCD** automatically syncs applications using updated manifests
4. **Applications** deploy to `erp` namespace with new container images
5. **Service URLs** become available through ingress resources

### Build Script Features (build.sh)
The build.sh script handles the complete deployment process:

#### Core Phases
- **Prerequisites Check**: Validates required tools (git, docker, kubectl, helm, etc.)
- **Security Scanning**: Trivy filesystem and container image scanning
- **Docker Build**: SSH-aware container building with fallback support
- **Registry Operations**: Authentication and image push to container registry
- **Database Setup**: Automatic PostgreSQL and Redis installation via Helm
- **Kubernetes Integration**: Namespace creation, secret management, JWT configuration
- **ArgoCD Manifest Updates**: Updates application manifests with new image tags
- **Git Operations**: Commits and pushes changes to trigger ArgoCD sync
- **Service URL Retrieval**: Waits for and displays application URLs
- **Database Migrations**: Django migration job execution (API only)
- **Deployment Summary**: Comprehensive status reporting

#### Environment Variables
| Variable | Purpose | Default |
|----------|---------|---------|
| `DEPLOY` | Enable/disable deployment phase | `true` |
| `SETUP_DATABASES` | Enable/disable database setup | `true` (API), `false` (UI) |
| `DB_TYPES` | Comma-separated database list | `postgres,redis` |
| `NAMESPACE` | Kubernetes namespace | `erp` |
| `ENV_SECRET_NAME` | Kubernetes secret name | `erp-api-env` / `erp-ui-env` |
| `REGISTRY_SERVER` | Container registry | `docker.io` |
| `REGISTRY_NAMESPACE` | Registry namespace | `codevertex` |
| `APP_NAME` | Application identifier | `erp-api` / `erp-ui` |
| `GIT_USER` | Git commit author name | `Titus Owuor` |
| `GIT_EMAIL` | Git commit author email | `titusowuor30@gmail.com` |
| `DEVOPS_REPO` | DevOps repository path | `Bengo-Hub/devops-k8s` |

### ArgoCD Application Configuration

#### Application Manifest Structure
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: erp-api  # or erp-ui
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Bengo-Hub/devops-k8s.git
    targetRevision: main
    path: charts/app
    helm:
      values: |
        # Embedded Helm values with image tags
        image:
          repository: docker.io/codevertex/erp-api
          tag: <specific-commit-id>
        # ... other configuration
  destination:
    server: https://kubernetes.default.svc
    namespace: erp
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

#### Sync Behavior
- **Automated**: Applications sync automatically when source changes are detected
- **Self-Healing**: Applications automatically recover from failures
- **Prune**: Removes resources that are no longer defined in the manifests

## Security Best Practices

### Dynamic Secret Generation
- **Application approach**: Secrets are managed through GitHub repository secrets
- **devENV.yaml**: Use placeholder values like `__DYNAMIC_PASSWORD__` that get replaced during deployment
- **Never commit**: Hardcoded secrets to version control

### Secret Management
- Store sensitive values in GitHub repository secrets
- Use different secrets for different environments
- Rotate secrets regularly
- Use strong, randomly generated passwords

## Migration Guide

### Current Architecture (build.sh-based)

The current recommended approach uses build.sh scripts that contain all deployment logic:

1. **deploy.yml**: Simple workflow that calls build.sh with environment variables
2. **build.sh**: Complete deployment script handling all phases
3. **Environment variables**: Configuration passed from deploy.yml to build.sh
4. **GitHub secrets**: Sensitive data stored securely in repository secrets

### Benefits of Current Approach
- ✅ **Simplified**: Single script handles complete deployment
- ✅ **Self-contained**: All logic in one place per application
- ✅ **Easy debugging**: Clear execution flow and error reporting
- ✅ **Flexible**: Easy to modify per application needs
- ✅ **GitHub-native**: Full integration with Actions environment

### Troubleshooting

#### Common Issues
- **Git Authentication**: SSH keys must have write access to devops-k8s repository; HTTPS tokens must be valid
- **ArgoCD Sync**: Applications may take time to sync; check ArgoCD interface for status
- **Service URLs**: URLs may not be immediately available; ArgoCD needs time to deploy resources
- **Kubeconfig**: Base64 encoded kubeconfig should be valid and current
- **YQ Syntax**: Ensure using `yq eval` with `-i` flag for in-place editing

#### Debug Mode
Add `set -x` at the top of build.sh for detailed execution tracing:
```bash
#!/usr/bin/env bash
set -x  # Enable debug mode
# ... rest of script
```

#### Manual Troubleshooting Steps
1. **Check ArgoCD Application Status**:
   ```bash
   kubectl get applications.argoproj.io -n argocd
   argocd app get erp-api
   argocd app get erp-ui
   ```

2. **Check K8s Resources**:
   ```bash
   kubectl get all,ingress,secrets -n erp
   kubectl describe application erp-api -n argocd
   ```

3. **Check Application Events**:
   ```bash
   kubectl get events -n argocd --field-selector involvedObject.name=erp-api
   ```

4. **Force Sync if Needed**:
   ```bash
   argocd app sync erp-api
   argocd app sync erp-ui
   ```

## Manual Deployment Guide (Contabo VPS)

For scenarios where you need to deploy manually or troubleshoot issues outside of GitHub Actions.

### Application-Specific Guides

For detailed manual deployment procedures specific to each application, refer to:

- **ERP API Manual Deployment**: [`bengobox-erp-api/docs/manual-deployment-guide.md`](https://github.com/Bengo-Hub/bengobox-erp-api/blob/main/docs/manual-deployment-guide.md)
- **ERP UI Manual Deployment**: [`bengobox-erp-ui/docs/manual-deployment-guide.md`](https://github.com/Bengo-Hub/bengobox-erp-ui/blob/main/docs/manual-deployment-guide.md)

### Prerequisites
- Access to the Contabo VPS server
- kubectl configured to access your K8s cluster
- Access to container registry (Docker Hub)
- Git access to repositories

### 1. Manual Application Deployment

#### Apply ArgoCD Applications
```bash
# Navigate to devops-k8s directory
cd /path/to/devops-k8s

# Apply ArgoCD applications
kubectl apply -f apps/erp-api/app.yaml -n argocd
kubectl apply -f apps/erp-ui/app.yaml -n argocd

# Verify applications are created
kubectl get applications.argoproj.io -n argocd
```

#### Monitor Deployment Progress
```bash
# Watch application status
kubectl get applications.argoproj.io -n argocd -w

# Get detailed application information
argocd app get erp-api
argocd app get erp-ui

# Check if applications are syncing
kubectl get applications.argoproj.io -n argocd -o jsonpath='{.items[*].status.sync.status}'
```

### 2. Manual Resource Management

#### Check Current Resources
```bash
# Check all resources in erp namespace
kubectl get all,ingress,secrets,pvc -n erp

# Check specific resource types
kubectl get deployments -n erp
kubectl get services -n erp
kubectl get ingress -n erp
```

#### View Application Logs
```bash
# Get pod names
kubectl get pods -n erp

# View logs for specific pods
kubectl logs -f deployment/erp-api -n erp
kubectl logs -f deployment/erp-ui -n erp
```

#### Check Ingress Configuration
```bash
# Describe ingress for troubleshooting
kubectl describe ingress -n erp

# Check if ingress is properly configured
kubectl get ingress -n erp -o yaml
```

### 3. Manual Database Operations

#### Check Database Status
```bash
# Check PostgreSQL deployment
kubectl get deployments -n erp -l app.kubernetes.io/name=postgresql

# Check Redis deployment
kubectl get deployments -n erp -l app.kubernetes.io/name=redis

# Check database services
kubectl get services -n erp -l app.kubernetes.io/name=postgresql
kubectl get services -n erp -l app.kubernetes.io/name=redis
```

#### Database Connection Testing
```bash
# Get database credentials (be careful with sensitive data)
kubectl get secret erp-api-env -n erp -o yaml

# Test database connectivity (replace with actual credentials)
kubectl run postgres-client --rm -i --tty --image postgres:13 -- psql -h postgresql.erp.svc.cluster.local -U postgres -d appdb
```

### 4. Manual Certificate Management

#### Check Certificate Status
```bash
# Check cert-manager certificates
kubectl get certificates -n erp

# Check certificate details
kubectl describe certificate erp-masterspace-tls -n erp

# Check if certificates are ready
kubectl get certificates -n erp -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}'
```

#### Renew Certificates Manually
```bash
# Force certificate renewal if needed
kubectl annotate certificate erp-masterspace-tls -n erp cert-manager.io/issue-temporary-certificate="true"
```

### 5. Manual Application Updates

#### Update Application Image Tags
```bash
# Edit ArgoCD application to update image tag
kubectl edit application erp-api -n argocd

# Or patch the application
kubectl patch application erp-api -n argocd --type='merge' -p='{"spec":{"source":{"helm":{"values":"image:\n  tag: new-tag-here\n"}}}}'
```

#### Force Application Sync
```bash
# Force sync an application
argocd app sync erp-api --force

# Sync with pruning (removes outdated resources)
argocd app sync erp-api --prune
```

### 6. Troubleshooting Commands

#### Common Troubleshooting Steps
```bash
# Check ArgoCD server status
kubectl get pods -n argocd

# Check ArgoCD application controller logs
kubectl logs -f deployment/argocd-application-controller -n argocd

# Check for stuck applications
kubectl get applications.argoproj.io -n argocd -o jsonpath='{.items[?(@.status.sync.status=="Unknown")].metadata.name}'

# Check application events
kubectl get events -n argocd --field-selector involvedObject.kind=Application
```

#### Network Troubleshooting
```bash
# Check if services are accessible
kubectl port-forward svc/erp-api 8000:80 -n erp
kubectl port-forward svc/erp-ui 3000:80 -n erp

# Test service connectivity
curl http://localhost:8000/health  # API health check
curl http://localhost:3000         # UI accessibility check
```

### 7. Emergency Procedures

#### Rollback Application
```bash
# Sync to previous revision
argocd app rollback erp-api <revision-number>

# Get available revisions
argocd app history erp-api
```

#### Scale Applications
```bash
# Scale deployments manually if needed
kubectl scale deployment erp-api -n erp --replicas=0  # Scale down
kubectl scale deployment erp-api -n erp --replicas=2  # Scale up
```

#### Restart Applications
```bash
# Restart deployments
kubectl rollout restart deployment/erp-api -n erp
kubectl rollout restart deployment/erp-ui -n erp
```

### 8. Monitoring and Health Checks

#### Application Health
```bash
# Check application health status
kubectl get applications.argoproj.io -n argocd -o jsonpath='{.items[*].status.health.status}'

# Get detailed health information
argocd app get erp-api --health
```

#### Resource Usage
```bash
# Check resource usage
kubectl top pods -n erp
kubectl top nodes

# Check persistent volume usage
kubectl get pv -o yaml
```

This manual deployment guide provides comprehensive procedures for deploying and troubleshooting the ERP applications outside of the automated GitHub Actions workflow.
