Argo CD Setup
-------------

Argo CD is a declarative GitOps continuous delivery tool for Kubernetes. This guide walks through installation, configuration, and application deployment.

Prerequisites
-------------
- Kubernetes cluster running (see `contabo-setup.md` for VPS setup)
- kubectl configured with cluster access
- GitHub SSH deploy key for devops-k8s repo

Installation
------------

### 1. Install Argo CD

```bash
# Create namespace
kubectl create namespace argocd

# Install Argo CD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for pods to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s
```

### 2. Access Argo CD UI

#### Option A: Port Forward (Development)
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Access at https://localhost:8080
```

#### Option B: Ingress (Production)
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

### 3. Get Initial Admin Password

```bash
# Get initial password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

# Login (username: admin)
argocd login localhost:8080 --username admin --password <PASSWORD>

# Change password
argocd account update-password
```

Configuration
-------------

### 4. Configure Repository Access

#### Generate SSH Deploy Key for devops-k8s
```bash
# On your local machine
ssh-keygen -t ed25519 -C "argocd@codevertex" -f ~/.ssh/argocd_deploy_key -N ""

# Add public key to GitHub repo
# Settings > Deploy keys > Add deploy key
# Paste contents of ~/.ssh/argocd_deploy_key.pub
# ✓ Allow write access if using automated commits
```

#### Add Repo to Argo CD via UI
1. Settings > Repositories > Connect Repo
2. Choose "VIA SSH"
3. Repository URL: `git@github.com:Bengo-Hub/devops-k8s.git`
4. SSH private key: Paste contents of `~/.ssh/argocd_deploy_key`
5. Click "Connect"

#### Or via CLI:
```bash
argocd repo add git@github.com:Bengo-Hub/devops-k8s.git \
  --ssh-private-key-path ~/.ssh/argocd_deploy_key
```

Deploying Applications
----------------------

### 5. Deploy ERP API and UI

```bash
# Apply ERP API application
kubectl apply -f apps/erp-api/app.yaml

# Apply ERP UI application
kubectl apply -f apps/erp-ui/app.yaml

# Check status
argocd app list
argocd app get erp-api
argocd app get erp-ui

# Sync manually (first time or if auto-sync disabled)
argocd app sync erp-api
argocd app sync erp-ui
```

### 6. Enable Auto-Sync and Self-Heal

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

App of Apps Pattern (Optional)
------------------------------

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

Monitoring Deployments
---------------------

### Via UI
- Visit https://argocd.masterspace.co.ke
- View application health, sync status, resource tree

### Via CLI
```bash
# Watch application status
argocd app get erp-api --refresh

# View logs
argocd app logs erp-api

# Rollback
argocd app rollback erp-api <REVISION>
```

Troubleshooting
---------------

### Sync Failures
```bash
# Check sync status and errors
argocd app get erp-api

# Force sync ignoring differences
argocd app sync erp-api --force

# Diff local vs live
argocd app diff erp-api
```

### Repository Connection Issues
```bash
# Test repo connection
argocd repo list

# Re-add repo if needed
argocd repo rm git@github.com:Bengo-Hub/devops-k8s.git
argocd repo add git@github.com:Bengo-Hub/devops-k8s.git --ssh-private-key-path ~/.ssh/argocd_deploy_key
```

### Image Pull Errors
Ensure Docker Hub credentials are in the namespace:
```bash
kubectl create secret docker-registry regcred \
  --docker-server=docker.io \
  --docker-username=codevertex \
  --docker-password=<TOKEN> \
  -n erp
```

Best Practices
--------------
- Use separate Argo CD projects for dev/staging/prod
- Enable RBAC to restrict user access
- Configure notifications (Slack, email) for sync failures
- Regularly backup Argo CD configuration
- Use image updater for automated image tag updates


