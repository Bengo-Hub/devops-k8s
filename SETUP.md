Quick Setup Guide
=================

This guide provides a fast-track setup for the entire DevOps infrastructure.

**⚠️ IMPORTANT:** This guide has been updated. Manual VPS setup is now required before running automated provisioning.

Prerequisites
-------------
- Fresh Contabo VPS (or any Ubuntu 24.04 LTS VPS)
- Root or sudo access
- SSH access to the VPS
- GitHub organization secrets configured

Step 1: Manual Access Setup (REQUIRED FIRST)
--------------------------------------------

**Complete manual access setup first.** This includes:
- SSH key generation and VPS access configuration
- GitHub PAT/token creation and storage
- SSH keys added to GitHub secrets

**📚 Follow:** `docs/comprehensive-access-setup.md` for complete access setup guide

Step 2: Automated Cluster Setup
--------------------------------

**After manual access is configured, run the automated cluster setup:**

```bash
# SSH into your VPS
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP

# Clone or upload devops-k8s repository
cd /opt
git clone https://github.com/YOUR_ORG/devops-k8s.git
cd devops-k8s

# Run orchestrated cluster setup
chmod +x scripts/cluster/*.sh
./scripts/cluster/setup-cluster.sh
```

This script automatically:
- ✅ Sets up initial VPS configuration
- ✅ Installs and configures containerd
- ✅ Installs Kubernetes and initializes cluster
- ✅ Configures Calico CNI
- ✅ Sets up etcd auto-compaction
- ✅ Generates kubeconfig for GitHub secrets

**After cluster setup:**
- Copy the base64 kubeconfig output
- Add it as GitHub organization secret: `KUBE_CONFIG`

**📚 Complete guide:** `docs/contabo-setup-kubeadm.md`

Step 3: Configure GitHub Secrets
---------------------------------

After completing cluster setup, ensure all GitHub secrets are configured:

**Required Secrets:**
- `KUBE_CONFIG` - Base64-encoded kubeconfig from manual setup
- `SSH_PRIVATE_KEY` - SSH private key for VPS access (if needed)

**Optional Secrets (with defaults):**
- `SSH_HOST` - VPS IP address (Priority 1 - takes precedence over Contabo API)
- `POSTGRES_PASSWORD` - PostgreSQL password (auto-generated if not set)
- `POSTGRES_ADMIN_PASSWORD` - PostgreSQL admin user password
- `REDIS_PASSWORD` - Redis password (auto-generated if not set)
- `RABBITMQ_PASSWORD` - RabbitMQ password (default: `rabbitmq`)
- `ARGOCD_DOMAIN` - ArgoCD domain (default: `argocd.masterspace.co.ke`)
- `GRAFANA_DOMAIN` - Grafana domain (default: `grafana.masterspace.co.ke`)
- `DB_NAMESPACE` - Database namespace (default: `infra`)

**Contabo API Secrets (Optional - enables automated VPS management):**
- `CONTABO_CLIENT_ID` - Contabo OAuth2 client ID
- `CONTABO_CLIENT_SECRET` - Contabo OAuth2 client secret
- `CONTABO_API_USERNAME` - Contabo account username
- `CONTABO_API_PASSWORD` - Contabo account password
- `CONTABO_INSTANCE_ID` - Contabo VPS instance ID (default: `14285715`)

**See:** `docs/github-secrets.md` for complete list

Step 4: Run Automated Provisioning Workflow
--------------------------------------------

Once manual setup is complete and secrets are configured:

1. Go to: `https://github.com/YOUR_ORG/devops-k8s/actions`
2. Select: **"Provision Cluster Infrastructure"**
3. Click: **"Run workflow"** → **"Run workflow"**

The workflow will automatically:
- **Get VPS IP** via Contabo API (if configured) or use `SSH_HOST` secret
- **Check etcd space** to prevent "database space exceeded" errors
- Install storage provisioner
- Install PostgreSQL & Redis (shared infrastructure)
- Install RabbitMQ (shared infrastructure)
- Configure NGINX Ingress Controller
- Install cert-manager
- Install Argo CD
- Install monitoring stack (Prometheus + Grafana)
- Install Vertical Pod Autoscaler (VPA)

**Note:** All installation scripts are idempotent (safe to run multiple times).

**Note:** Git SSH access setup requires manual GitHub deploy key configuration (see workflow output).

Step 5: Configure DNS (Optional but Recommended)
--------------------------------------------------

Point your domains to your VPS IP:
- `argocd.masterspace.co.ke` → YOUR_VPS_IP
- `grafana.masterspace.co.ke` → YOUR_VPS_IP
- `erpapi.masterspace.co.ke` → YOUR_VPS_IP
- `erp.masterspace.co.ke` → YOUR_VPS_IP

cert-manager will automatically provision TLS certificates.

Step 6: Deploy Applications
----------------------------

Applications are automatically deployed via Argo CD if `apps/*/app.yaml` files exist.

To verify:
```bash
kubectl get applications -n argocd
```

To deploy manually:
```bash
kubectl apply -f apps/root-app.yaml
```

Step 7: Verify Deployment
--------------------------

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
- Configure etcd auto-compaction (see `docs/ETCD-OPTIMIZATION.md`)
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
