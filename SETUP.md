Quick Setup Guide
=================

This guide provides a fast-track setup for the entire DevOps infrastructure.

Prerequisites
-------------
- Contabo VPS with SSH access
- kubectl installed locally
- Helm 3 installed locally
- GitHub organization secrets configured

Step 1: Initial VPS Setup
-------------------------

Follow `docs/contabo-setup.md` for complete VPS preparation including:
- SSH key configuration
- Docker installation
- k3s (Kubernetes) installation
- NGINX Ingress Controller
- Basic firewall setup

Quick command reference:
```bash
# SSH into VPS
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP

# Run initial setup (from contabo-setup.md)
# Update, install Docker, install k3s, etc.
```

Step 2: Install Core Infrastructure
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

Step 3: Configure Argo CD Repository
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

Step 4: Deploy Applications
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

Step 5: Configure DNS
---------------------

Point these domains to your VPS IP:
- `erpapi.masterspace.co.ke` → VPS_IP
- `erp.masterspace.co.ke` → VPS_IP
- `argocd.masterspace.co.ke` → VPS_IP (optional)
- `grafana.masterspace.co.ke` → VPS_IP (optional)

cert-manager will automatically provision TLS certificates.

Step 6: Verify Deployment
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

Step 7: Configure Monitoring
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

Step 8: GitHub Actions Setup
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

