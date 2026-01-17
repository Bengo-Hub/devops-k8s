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
| `NAMESPACE` | Kubernetes namespace | `my-service` (service-specific) |
| `ENV_SECRET_NAME` | Kubernetes secret name | `my-service-env` (service-specific) |
| `REGISTRY_SERVER` | Container registry | `docker.io` |
| `REGISTRY_NAMESPACE` | Registry namespace | `codevertex` |
| `APP_NAME` | Application identifier | `my-service` (service-specific) |
| `GIT_USER` | Git commit author name | Your name |
| `GIT_EMAIL` | Git commit author email | your.email@example.com |
| `DEVOPS_REPO` | DevOps repository path | `Bengo-Hub/devops-k8s` |

### ArgoCD Application Configuration

#### Application Manifest Structure
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-service  # Service-specific name (e.g., ordering-backend, erp-api, treasury-app)
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
          repository: docker.io/codevertex/my-service
          tag: <specific-commit-id>
        # ... other configuration
  destination:
    server: https://kubernetes.default.svc
    namespace: my-service  # Service-specific namespace
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

---

## Argo CD Installation and Configuration

### Prerequisites

- Kubernetes cluster running (see `contabo-setup-kubeadm.md` for VPS setup)
- kubectl configured with cluster access
- GitHub SSH deploy key for devops-k8s repo

### Installation

#### 1. Install Argo CD

```bash
# Create namespace
kubectl create namespace argocd

# Install Argo CD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for pods to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s
```

#### 2. Access Argo CD UI

**Option A: Port Forward (Development)**
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Access at https://localhost:8080
```

**Option B: Ingress (Production)**

Create `argocd-ingress.yaml`:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - argocd.masterspace.co.ke
    secretName: argocd-tls
  rules:
  - host: argocd.masterspace.co.ke
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 443
```

Apply: `kubectl apply -f argocd-ingress.yaml`

#### 3. Get Initial Admin Password

```bash
# Get initial password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

# Login (username: admin)
argocd login localhost:8080 --username admin --password <PASSWORD>

# Change password
argocd account update-password
```

### Configuration

#### 4. Configure Repository Access

**Generate SSH Deploy Key for devops-k8s:**
```bash
# On your local machine
ssh-keygen -t ed25519 -C "devops@codevertex" -f ~/.ssh/contabo_deploy_key -N "codevertex"
```

**Add public key to GitHub repo:**
- Settings > Deploy keys > Add deploy key
- Paste contents of `~/.ssh/contabo_deploy_key.pub`
- ✓ Allow write access if using automated commits

**Add Repo to Argo CD via UI:**
1. Settings > Repositories > Connect Repo
2. Choose "VIA SSH"
3. Repository URL: `git@github.com:Bengo-Hub/devops-k8s.git`
4. SSH private key: Paste contents of `~/.ssh/argocd_deploy_key`
5. Click "Connect"

**Or via CLI:**
```bash
argocd repo add git@github.com:Bengo-Hub/devops-k8s.git \
  --ssh-private-key-path ~/.ssh/argocd_deploy_key
```

#### 5. Enable Auto-Sync and Self-Heal

Applications in this repo already have auto-sync enabled in their manifests:
```yaml
syncPolicy:
  automated:
    prune: true
    selfHeal: true
```

To modify after deployment:
```bash
argocd app set erp-api --sync-policy automated --auto-prune --self-heal
```

#### 6. App of Apps Pattern (Optional)

For managing multiple environments or apps, create a root app:

`apps/root-app.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git@github.com:Bengo-Hub/devops-k8s.git
    targetRevision: main
    path: apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Apply: `kubectl apply -f apps/root-app.yaml`

### Core Infrastructure via Argo CD

The following cluster-wide components are managed as Argo CD Applications under `apps/`:

- `apps/monitoring/app.yaml`: kube-prometheus-stack (Prometheus, Grafana, Alertmanager)
- `apps/metrics-server/app.yaml`: metrics-server (required for HPA)
- `apps/keda/app.yaml`: KEDA (event/queue-driven autoscaling)
- `apps/postgresql/app.yaml`: Bitnami PostgreSQL (shared infra)
- `apps/redis/app.yaml`: Bitnami Redis (shared infra)
- `apps/rabbitmq/app.yaml`: Bitnami RabbitMQ (shared infra)

These appear in the Argo CD UI when `apps/root-app.yaml` is applied (App-of-Apps). Ensure these are Healthy/Synced for autoscaling and monitoring to function.

### Argo CD Metrics in Grafana/Prometheus

- ServiceMonitors for Argo CD server and repo-server are provided at:
  - `manifests/monitoring/argocd-servicemonitor.yaml`
- After monitoring stack is synced, check Prometheus targets and import an Argo CD dashboard in Grafana if desired.

### Monitoring Deployments

**Via UI:**
- Visit https://argocd.masterspace.co.ke
- View application health, sync status, resource tree

**Via CLI:**
```bash
# Watch application status
argocd app get erp-api --refresh

# View logs
argocd app logs erp-api

# Rollback
argocd app rollback erp-api <REVISION>
```

### Argo CD Troubleshooting

**Sync Failures:**
```bash
# Check sync status and errors
argocd app get erp-api

# Force sync ignoring differences
argocd app sync erp-api --force

# Diff local vs live
argocd app diff erp-api
```

**Repository Connection Issues:**
```bash
# Test repo connection
argocd repo list

# Re-add repo if needed
argocd repo rm git@github.com:Bengo-Hub/devops-k8s.git
argocd repo add git@github.com:Bengo-Hub/devops-k8s.git --ssh-private-key-path ~/.ssh/argocd_deploy_key
```

**Image Pull Errors:**
Ensure Docker Hub credentials are in the namespace:
```bash
kubectl create secret docker-registry regcred \
  --docker-server=docker.io \
  --docker-username=codevertex \
  --docker-password=<TOKEN> \
  -n erp
```

### Argo CD Best Practices

- Use separate Argo CD projects for dev/staging/prod
- Enable RBAC to restrict user access
- Configure notifications (Slack, email) for sync failures
- Regularly backup Argo CD configuration
- Use image updater for automated image tag updates

---

## Centralized Infra & Autoscaling Reuse

- Core infra is managed via Argo CD apps and deployed to the `infra` namespace:
  - Monitoring: `apps/monitoring/app.yaml` (deployed to `infra` namespace)
  - Metrics: `apps/metrics-server/app.yaml` (deployed to `kube-system` namespace)
  - Event autoscaling: `apps/keda/app.yaml` (deployed to `infra` namespace)
  - Databases: `apps/postgresql/app.yaml`, `apps/redis/app.yaml`, `apps/rabbitmq/app.yaml` (all deployed to `infra` namespace)
- Ensure these are Healthy/Synced so HPA/VPA/KEDA and monitoring function across all apps.
- All shared infrastructure services (databases, monitoring, autoscaling) are accessible from any app namespace via service DNS in the `infra` namespace.

### Using the Shared Helm Chart Features

All apps using `charts/app` inherit:
- HPA: `templates/hpa.yaml` driven by `autoscaling.*` in values.
- VPA: `templates/vpa.yaml` toggled by `verticalPodAutoscaling.*`.
- KEDA: `templates/keda-scaledobject.yaml` toggled by `keda.*`.

Example values override:
```yaml
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 60
  targetMemoryUtilizationPercentage: 70

verticalPodAutoscaling:
  enabled: true
  updateMode: "Recreate"
  recommendationMode: false

keda:
  enabled: true
  minReplicas: 2
  maxReplicas: 20
  triggers:
    - type: redis
      metadata:
        address: "redis-master.infra.svc:6379"
        listName: "celery"
        listLength: "100"
      authenticationRef:
        name: redis-auth
```

Create a corresponding `TriggerAuthentication` in the app namespace pointing to broker credentials.

### Connecting to Shared Databases/Brokers

- **PostgreSQL, Redis, RabbitMQ** are deployed to the `infra` namespace as shared infrastructure.
- **Important**: While the database services are shared, each service has its own **unique database** on the PostgreSQL instance.
- Service DNS (same for all services):
  - PostgreSQL: `postgresql.infra.svc.cluster.local:5432`
  - Redis: `redis-master.infra.svc.cluster.local:6379`
  - RabbitMQ: `rabbitmq.infra.svc.cluster.local:5672`
- **Database naming**: Each service uses its own database name (e.g., `cafe`, `erp`, `treasury`, `notifications`) on the shared PostgreSQL service.
- Set these connection strings in your app secrets/env and align pools/timeouts; HPA will scale app pods while PriorityClass ensures DBs stay scheduled under pressure.

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

### Complete Manual Deployment Guides

For detailed manual deployment procedures that cover the **entire deployment process from start to finish**, refer to:

- **ERP API Manual Deployment**: [`bengobox-erp-api/docs/manual-deployment-guide.md`](https://github.com/Bengo-Hub/bengobox-erp-api/blob/main/docs/manual-deployment-guide.md)
- **ERP UI Manual Deployment**: [`bengobox-erp-ui/docs/manual-deployment-guide.md`](https://github.com/Bengo-Hub/bengobox-erp-ui/blob/main/docs/manual-deployment-guide.md)

### Key Features of Updated Guides

#### ✅ **Complete Step-by-Step Process**
- **Phase 1**: Prerequisites verification (tools, access, repositories)
- **Phase 2**: Initial ArgoCD application deployment
- **Phase 3**: Application sync monitoring with real-time feedback
- **Phase 4**: Post-deployment verification and testing
- **Phase 5**: Comprehensive troubleshooting and maintenance

#### ✅ **Beginner-Friendly Structure**
- **No assumptions** about prior deployment state
- **Clear prerequisites** with verification steps
- **Expected outputs** shown for each command
- **Timeline guidance** for deployment phases
- **Emergency procedures** for stuck deployments

#### ✅ **Comprehensive Coverage**
- **Initial deployment** from "no services" state
- **Certificate management** and domain assignment
- **LoadBalancer troubleshooting**
- **Network connectivity testing**
- **Resource monitoring and health checks**

### Prerequisites
- Access to the Contabo VPS server
- kubectl configured to access your K8s cluster
- Access to container registry (Docker Hub)
- Git access to repositories
- ArgoCD CLI installed and configured

### 1. Manual Application Deployment

#### Apply ArgoCD Applications
```bash
# Navigate to devops-k8s directory
cd /path/to/devops-k8s

# Apply ArgoCD applications (replace with your service names)
kubectl apply -f apps/my-service/app.yaml -n argocd
# Example: kubectl apply -f apps/ordering-backend/app.yaml -n argocd
# Example: kubectl apply -f apps/erp-api/app.yaml -n argocd

# Verify applications are created
kubectl get applications.argoproj.io -n argocd
```

#### Monitor Deployment Progress
```bash
# Watch application status
kubectl get applications.argoproj.io -n argocd -w

# Get detailed application information (replace with your service name)
argocd app get my-service
# Example: argocd app get ordering-backend

# Check if applications are syncing
kubectl get applications.argoproj.io -n argocd -o jsonpath='{.items[*].status.sync.status}'
```

### 2. Manual Resource Management

#### Check Current Resources
```bash
# Check all resources in your service namespace (replace 'my-service' with your namespace)
kubectl get all,ingress,secrets,pvc -n my-service
# Example: kubectl get all,ingress,secrets,pvc -n ordering

# Check specific resource types
kubectl get deployments -n my-service
kubectl get services -n my-service
kubectl get ingress -n my-service
```

#### View Application Logs
```bash
# Get pod names
kubectl get pods -n my-service

# View logs for specific pods (replace with your deployment name)
kubectl logs -f deployment/my-service-app -n my-service
# Example: kubectl logs -f deployment/ordering-backend -n ordering
```

#### Check Ingress Configuration
```bash
# Describe ingress for troubleshooting
kubectl describe ingress -n my-service

# Check if ingress is properly configured
kubectl get ingress -n my-service -o yaml
```

### 3. Manual Database Operations

#### Check Database Status
```bash
# Check PostgreSQL deployment (databases are in infra namespace)
kubectl get deployments -n infra -l app.kubernetes.io/name=postgresql

# Check Redis deployment (databases are in infra namespace)
kubectl get deployments -n infra -l app.kubernetes.io/name=redis

# Check database services (databases are in infra namespace)
kubectl get services -n infra -l app.kubernetes.io/name=postgresql
kubectl get services -n infra -l app.kubernetes.io/name=redis
```

#### Database Connection Testing
```bash
# Get database credentials from your service secret (replace with your service name)
kubectl get secret my-service-env -n my-service -o yaml
# Example: kubectl get secret ordering-backend-env -n ordering -o yaml

# Test database connectivity (replace with your database name)
# Each service has its own database on the shared PostgreSQL instance
kubectl run postgres-client --rm -i --tty --image postgres:13 -- psql -h postgresql.infra.svc.cluster.local -U postgres -d my_database
# Example: kubectl run postgres-client --rm -i --tty --image postgres:13 -- psql -h postgresql.infra.svc.cluster.local -U postgres -d cafe
```

### 4. Manual Certificate Management

#### Check Certificate Status
```bash
# Check cert-manager certificates (replace with your service namespace)
kubectl get certificates -n my-service
# Example: kubectl get certificates -n ordering

# Check certificate details (replace with your certificate name)
kubectl describe certificate my-service-tls -n my-service
# Example: kubectl describe certificate cafe-masterspace-tls -n ordering

# Check if certificates are ready (replace with your service namespace)
kubectl get certificates -n my-service -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}'
# Example: kubectl get certificates -n ordering -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}'
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
