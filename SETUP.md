Quick Setup Guide
=================

This guide provides a fast-track setup for the entire DevOps infrastructure.

Prerequisites
-------------
- Contabo VPS with SSH access
- kubectl installed locally
- Helm 3 installed locally
- GitHub organization secrets configured

Step 1: Choose Kubernetes Distribution
---------------------------------------

**Read First:** `docs/k8s-comparison.md` to decide between k3s and kubeadm.

**Quick Recommendation:**
- **4-8GB VPS:** Use k3s (recommended for most users)
- **16GB+ VPS or multi-node:** Use kubeadm (recommended for your 48GB VPS)

Step 2: Initial VPS Setup
-------------------------

### Option A: k3s (Recommended for Contabo 4-8GB VPS)

Follow `docs/contabo-setup.md` for complete setup including:
- SSH key configuration
- Docker installation
- k3s (lightweight Kubernetes) installation
- NGINX Ingress Controller
- Basic firewall setup

**Pros:** Lower resource usage, faster setup, simpler operations
**Best for:** Single-node VPS deployments

### Option B: kubeadm (For larger VPS or multi-node)

Follow `docs/contabo-setup-kubeadm.md` for complete setup including:
- SSH key configuration
- containerd installation
- Full Kubernetes with kubeadm
- Calico or Flannel CNI
- NGINX Ingress Controller

**Pros:** Full upstream K8s, better for multi-node, more community support
**Best for:** Enterprise production, multi-node clusters

Quick command reference (k3s):
```bash
# SSH into VPS
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP

# Install k3s
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -
```

Quick command reference (kubeadm):
```bash
# SSH into VPS
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP

# Follow full guide in docs/contabo-setup-kubeadm.md
# Requires containerd, kubeadm, kubelet, kubectl installation
```

Step 3: Install Databases
-------------------------

The ERP system requires PostgreSQL and Redis. Choose your deployment strategy:

### Option A: In-Cluster Databases (Recommended) ⭐

```bash
# Install PostgreSQL + Redis into cluster
./scripts/install-databases.sh

# This will output connection credentials
# Update BengoERP/bengobox-erp-api/kubeSecrets/devENV.yaml with the passwords
# Apply the secret
kubectl apply -f BengoERP/bengobox-erp-api/kubeSecrets/devENV.yaml
```

**Pros:** Auto-scaling, health checks, K8s-managed persistence
**See:** `docs/database-setup.md` for detailed guide

### Option B: External VPS Databases

```bash
# SSH into VPS and install manually
# See docs/database-setup.md Option 2

# Update BengoERP/bengobox-erp-api/kubeSecrets/devENV.yaml
# with external database connection strings
kubectl apply -f BengoERP/bengobox-erp-api/kubeSecrets/devENV.yaml
```

Step 4: Install Core Infrastructure
-----------------------------------

### cert-manager (TLS Certificates)
```bash
# From your local machine with kubectl configured
./scripts/install-cert-manager.sh

# Or manually:
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
kubectl apply -f manifests/cert-manager-clusterissuer.yaml
```

### Argo CD (GitOps)
```bash
./scripts/install-argocd.sh

# Apply Argo CD ingress (optional, for web access)
kubectl apply -f manifests/argocd-ingress.yaml

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### Monitoring Stack (Prometheus + Grafana)
```bash
./scripts/install-monitoring.sh

# Apply ERP-specific alerts
kubectl apply -f manifests/monitoring/erp-alerts.yaml

# Configure Alertmanager (update email password first)
kubectl apply -f manifests/monitoring/alertmanager-config.yaml
```

Step 5: Configure Argo CD Repository
------------------------------------

```bash
# Generate SSH deploy key
ssh-keygen -t ed25519 -C "argocd@codevertex" -f ~/.ssh/argocd_deploy_key -N ""

# Add public key to GitHub repo:
# github.com/codevertex/devops-k8s > Settings > Deploy keys
cat ~/.ssh/argocd_deploy_key.pub

# Add repo to Argo CD
argocd repo add git@github.com:codevertex/devops-k8s.git \
  --ssh-private-key-path ~/.ssh/argocd_deploy_key
```

Step 6: Deploy Applications
---------------------------

### Deploy ERP API
```bash
kubectl apply -f apps/erp-api/app.yaml

# Check status
argocd app get erp-api
kubectl get pods -n erp
```

### Deploy ERP UI
```bash
kubectl apply -f apps/erp-ui/app.yaml

# Check status
argocd app get erp-ui
kubectl get pods -n erp
```

### Or use App of Apps pattern
```bash
kubectl apply -f apps/root-app.yaml
```

Step 7: Configure DNS
---------------------

Point these domains to your VPS IP:
- `erpapi.masterspace.co.ke` → VPS_IP
- `erp.masterspace.co.ke` → VPS_IP
- `argocd.masterspace.co.ke` → VPS_IP (optional)
- `grafana.masterspace.co.ke` → VPS_IP (optional)

cert-manager will automatically provision TLS certificates.

Step 8: Verify Deployment
-------------------------

```bash
# Check all pods
kubectl get pods -A

# Check ingresses
kubectl get ingress -A

# Check certificates
kubectl get certificate -A

# Test ERP API health
curl https://erpapi.masterspace.co.ke/api/v1/core/health/

# Test ERP UI health
curl https://erp.masterspace.co.ke/health
```

Step 9: Configure Monitoring
----------------------------

### Access Grafana
```bash
# Get password
kubectl get secret -n monitoring prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 -d

# Port forward (or use ingress)
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80

# Visit http://localhost:3000
# Username: admin
```

### Import Dashboards
1. Login to Grafana
2. Go to Dashboards > Import
3. Import these IDs:
   - 315 (Kubernetes cluster monitoring)
   - 6417 (Kubernetes cluster overview)
   - 1860 (Node Exporter Full)

### Configure Alertmanager Email
Edit `manifests/monitoring/alertmanager-config.yaml` and update:
- `auth_password` with Gmail app password
- Apply: `kubectl apply -f manifests/monitoring/alertmanager-config.yaml`

Step 10: GitHub Actions Setup
----------------------------

Ensure these organization secrets are set:
- `CONTABO_CLIENT_ID`
- `CONTABO_CLIENT_SECRET`
- `CONTABO_API_USERNAME`
- `CONTABO_API_PASSWORD`
- `SSH_PRIVATE_KEY`
- `KUBE_CONFIG`
- `REGISTRY_USERNAME` (codevertex)
- `REGISTRY_PASSWORD` (Docker Hub token)

See `docs/github-secrets.md` for details.

Troubleshooting
---------------

### Pods not starting
```bash
kubectl describe pod POD_NAME -n NAMESPACE
kubectl logs POD_NAME -n NAMESPACE
```

### Certificate not issued
```bash
kubectl describe certificate CERT_NAME -n NAMESPACE
kubectl describe certificaterequest -n NAMESPACE
kubectl logs -n cert-manager deployment/cert-manager
```

### Argo CD sync issues
```bash
argocd app get APP_NAME
argocd app sync APP_NAME --force
```

### Monitoring not scraping
```bash
kubectl get servicemonitor -n monitoring
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
# Visit http://localhost:9090/targets
```

Next Steps
----------

- Review `docs/` for detailed documentation
- Configure backup strategy
- Set up CI/CD pipelines for your apps
- Configure horizontal pod autoscaling
- Set up log aggregation with Loki

Support
-------

- Documentation: `docs/README.md`
- Issues: GitHub Issues
- Contact: codevertexitsolutions@gmail.com
- Website: https://www.codevertexitsolutions.com

