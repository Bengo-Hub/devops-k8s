Production Readiness Checklist
===============================

## ✅ Infrastructure Setup (Completed)

### Kubernetes Cluster
- [x] Kubernetes installed on Contabo VPS (77.237.232.66)
- [x] kubectl configured with KUBE_CONFIG
- [x] Storage provisioner (local-path) installed
- [x] NGINX Ingress Controller with hostNetwork
- [x] cert-manager with Let's Encrypt (letsencrypt-prod)

### Core Services
- [x] Argo CD deployed (argocd.masterspace.co.ke)
- [x] Prometheus + Grafana monitoring (grafana.masterspace.co.ke)
- [x] PostgreSQL in-cluster (infra namespace)
- [x] Redis in-cluster (infra namespace)

### Credentials
- [x] PostgreSQL: `postgres:TFRodWXeeh@postgresql.infra.svc.cluster.local:5432/bengo_erp`
- [x] Redis: `:6rBAAUdugT@redis-master.infra.svc.cluster.local:6379`

---

## ✅ Application Configuration (Completed)

### ERP API (bengobox-erp-api)
- [x] Dockerfile with multi-stage build
- [x] Health check endpoint: `/api/v1/core/health/`
- [x] build.sh with Trivy scans
- [x] kubeSecrets/devENV.yaml with DB credentials
- [x] GitHub workflow calling reusable pipeline
- [x] Helm values in devops-k8s/apps/erp-api/values.yaml
- [x] Autoscaling: 2-10 replicas (CPU 70%, Memory 80%)
- [x] Resources: 250m-2000m CPU, 512Mi-2Gi memory
- [x] Domain: erpapi.masterspace.co.ke

### ERP UI (bengobox-erp-ui)
- [x] Dockerfile with multi-stage build
- [x] Health check endpoint: `/health` or `/`
- [x] build.sh with Trivy scans
- [x] kubeSecrets/devENV.yaml with API URL
- [x] GitHub workflow calling reusable pipeline
- [x] Helm values in devops-k8s/apps/erp-ui/values.yaml
- [x] Autoscaling: 2-8 replicas (CPU 70%, Memory 80%)
- [x] Resources: 100m-1000m CPU, 256Mi-1Gi memory
- [x] Domain: erp.masterspace.co.ke

---

## ✅ DevOps Pipeline (Completed)

### Reusable Workflow Features
- [x] Docker build with BuildKit
- [x] Trivy security scans (filesystem + image)
- [x] Multi-registry support (Docker Hub default)
- [x] Automated database setup (PostgreSQL, Redis)
- [x] Auto-generated secrets (JWT, DB passwords)
- [x] Kubernetes secret management
- [x] **Database migrations** (Django apps)
- [x] Helm values update in devops-k8s repo
- [x] Argo CD GitOps sync
- [x] Contabo API integration with SSH fallback

### GitHub Secrets (Organization Level)
- [x] REGISTRY_USERNAME (codevertex)
- [x] REGISTRY_PASSWORD (Docker Hub token)
- [x] KUBE_CONFIG (base64 kubeconfig)
- [x] SSH_PRIVATE_KEY (VPS access)
- [x] CONTABO_CLIENT_ID (optional)
- [x] CONTABO_CLIENT_SECRET (optional)
- [x] CONTABO_API_USERNAME (optional)
- [x] CONTABO_API_PASSWORD (optional)

---

## ✅ Automation Scripts (Completed)

### Installation Scripts (All Idempotent)
- [x] `scripts/infrastructure/install-storage-provisioner.sh` - Local-path PVC provisioner
- [x] `scripts/infrastructure/configure-ingress-controller.sh` - NGINX with hostNetwork
- [x] `scripts/infrastructure/install-cert-manager.sh` - TLS certificate automation
- [x] `scripts/infrastructure/install-argocd.sh` - GitOps deployment
- [x] `scripts/monitoring/install-monitoring.sh` - Prometheus + Grafana
- [x] `scripts/infrastructure/install-databases.sh` - PostgreSQL (with pgvector) + Redis

### Utility Scripts
- [x] `scripts/check-services.sh` - Service health check
- [x] `scripts/debug-grafana-404.sh` - Ingress troubleshooting

### CI/CD Workflows
- [x] `.github/workflows/provision.yml` - Auto-provision cluster services
- [x] `.github/workflows/reusable-build-deploy.yml` - Build, scan, deploy apps

---

## ⚠️ Manual Steps Required

### 1. Update Production Secrets
Edit `BengoERP/bengobox-erp-api/kubeSecrets/devENV.yaml`:
- [ ] Replace `DJANGO_SECRET_KEY` with: `openssl rand -base64 50`
- [ ] Replace `JWT_SECRET` with: `openssl rand -base64 32`
- [ ] Replace `SECRET_KEY` with: `openssl rand -base64 32`
- [ ] Update `EMAIL_HOST_PASSWORD` with Gmail App Password

### 2. Apply Secrets to Cluster
```bash
kubectl apply -f BengoERP/bengobox-erp-api/kubeSecrets/devENV.yaml
kubectl apply -f BengoERP/bengobox-erp-ui/kubeSecrets/devENV.yaml
```

### 3. Deploy Applications via Argo CD
```bash
kubectl apply -f devops-k8s/apps/erp-api/app.yaml
kubectl apply -f devops-k8s/apps/erp-ui/app.yaml
```

### 4. Verify Deployments
```bash
# Check Argo CD apps
kubectl get applications -n argocd

# Check pods
kubectl get pods -n erp

# Check ingresses
kubectl get ingress -n erp

# Check certificates
kubectl get certificate -n erp
```

### 5. DNS Configuration
Ensure these domains point to **77.237.232.66**:
- [ ] argocd.masterspace.co.ke
- [ ] grafana.masterspace.co.ke
- [ ] erpapi.masterspace.co.ke
- [ ] erp.masterspace.co.ke

---

## 📊 Monitoring & Observability

### Access URLs
- **Grafana:** https://grafana.masterspace.co.ke
  - Username: admin
  - Password: `kubectl get secret -n monitoring prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 -d`

- **Argo CD:** https://argocd.masterspace.co.ke
  - Username: admin
  - Password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`

- **Prometheus:** Port-forward only
  - `kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090`

### Grafana Dashboards to Import
- 315 - Kubernetes cluster monitoring
- 6417 - Kubernetes cluster
- 1860 - Node exporter full

---

## 🔒 Security Best Practices

### Implemented
- [x] Non-root containers
- [x] Multi-stage Docker builds
- [x] Trivy security scans (FS + Image)
- [x] TLS certificates (Let's Encrypt)
- [x] Kubernetes Secrets (not ConfigMaps)
- [x] Resource limits and requests
- [x] Health checks in all containers
- [x] Network policies ready (not applied)

### Recommended Next Steps
- [ ] Enable network policies
- [ ] Set up backup automation (Velero)
- [ ] Configure log aggregation (ELK/Loki)
- [ ] Set up disaster recovery plan
- [ ] Enable pod security standards
- [ ] Configure OPA/Gatekeeper policies

---

## 📈 Scaling Configuration

### Horizontal Pod Autoscaling (HPA)
**ERP API:**
- Min: 2 replicas
- Max: 10 replicas
- Triggers: CPU > 70% OR Memory > 80%

**ERP UI:**
- Min: 2 replicas
- Max: 8 replicas
- Triggers: CPU > 70% OR Memory > 80%

### Vertical Pod Autoscaling (VPA)
- Optional VPA manifests available: `manifests/vpa/vpa-setup.yaml`
- Recommendation mode (safe for production)

### Cluster Capacity (48GB VPS)
- Available: ~42GB RAM, ~10 CPU cores
- Current allocation: ~20-25 pods max
- Monitoring: ~4GB RAM, 2 CPU
- Databases: ~3GB RAM, 1.5 CPU
- Apps: Remaining capacity

---

## 🚀 Deployment Process

### Automated (via GitHub Actions)
1. Push to `main` or `master` branch
2. Workflow triggers automatically
3. Build Docker image with commit SHA tag
4. Run Trivy security scans
5. Push to Docker Hub (Bengo-Hub namespace)
6. Apply Kubernetes secrets
7. **Run database migrations** (ERP API only)
8. Update Helm values in devops-k8s repo
9. Argo CD auto-syncs deployment

### Manual (via kubectl)
```bash
# Update image tag in values
cd devops-k8s
yq -yi '.image.tag = "abc12345"' apps/erp-api/values.yaml

# Commit and push
git add apps/erp-api/values.yaml
git commit -m "erp-api:abc12345 released"
git push

# Argo CD will auto-sync within 3 minutes
```

---

## 🔍 Troubleshooting

### Common Issues

**1. Ingress 404 Error**
- Check: `kubectl describe ingress -n <namespace>`
- Verify: DNS points to 77.237.232.66
- Test: `curl -H "Host: domain.com" http://77.237.232.66/`
- Fix: Run `scripts/debug-grafana-404.sh`

**2. Certificate Not Ready**
- Check: `kubectl describe certificate -n <namespace>`
- Verify: DNS resolves correctly
- Test: `kubectl get certificaterequest -n <namespace>`
- Fix: Delete certificate to retry: `kubectl delete certificate <name> -n <namespace>`

**3. Pods Pending (PVC)**
- Check: `kubectl get pvc -n <namespace>`
- Verify: Storage class exists: `kubectl get storageclass`
- Fix: Run `scripts/infrastructure/install-storage-provisioner.sh`

**4. Helm "name still in use"**
- Check: `helm list -n <namespace>`
- Fix: Use `helm upgrade --install` (already in scripts)
- Nuclear: `helm uninstall <release> -n <namespace>`

**5. Database Connection Errors**
- Check: Pods running: `kubectl get pods -n erp`
- Verify: Secrets applied: `kubectl get secret erp-api-env -n erp`
- Test: `kubectl exec -n erp postgresql-0 -- psql -U postgres -d bengo_erp -c "SELECT 1"`

---

## 📝 Notes

### stringData vs data in Secrets
- **stringData:** Plain text, Kubernetes auto-converts to base64
- **data:** Already base64-encoded values
- **Current:** Using `stringData` for easier maintenance
- **Kubernetes:** Stores as base64 internally regardless

### Database Passwords
- Generated during `scripts/infrastructure/install-databases.sh`
- Stored in Kubernetes Secrets
- Retrieved: `kubectl get secret postgresql -n infra -o jsonpath="{.data.admin-user-password}" | base64 -d` (admin_user) or `{.data.postgres-password}` (postgres superuser)

### Image Tags
- Format: 8-character git commit SHA (e.g., `abc12345`)
- Updated automatically by CI/CD
- Argo CD syncs within 3 minutes

---

## 🎯 Next Actions

1. **Update production secrets** in devENV.yaml files
2. **Apply secrets** to cluster
3. **Deploy apps** via Argo CD
4. **Verify DNS** propagation
5. **Test applications** end-to-end
6. **Monitor** via Grafana dashboards
7. **Set up alerts** in Alertmanager

---

## 📚 Documentation

All documentation available in `docs/`:
- [SETUP.md](SETUP.md) - Quick start guide
- [docs/README.md](docs/README.md) - Full documentation index
- [docs/pipelines.md](docs/pipelines.md) - CI/CD workflows
- [docs/pipelines.md](docs/pipelines.md) - GitOps setup (see Argo CD Installation section)
- [docs/monitoring.md](docs/monitoring.md) - Prometheus + Grafana
- [docs/database-setup.md](docs/database-setup.md) - PostgreSQL + Redis
- [docs/scaling.md](docs/scaling.md) - HPA + VPA
- [docs/provisioning.md](docs/provisioning.md) - Hosting environments (see Hosting Environments section)
- [docs/OPERATIONS-RUNBOOK.md](docs/OPERATIONS-RUNBOOK.md) - Security best practices (see Security Procedures section)

---

**Status:** Production-ready infrastructure deployed and configured. Applications ready for deployment.

