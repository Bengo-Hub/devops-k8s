Provisioning Deployment Tools (Ansible)
======================================

Overview
--------

Use the provided Ansible playbook `provision.yml` to provision a Contabo (or any Ubuntu 22.04) VPS with all tools required by the BengoERP CI/CD and operations workflows.

What This Installs
------------------

- kubectl v1.28.x (client)
- helm v3.15.x
- argocd CLI v2.13.x
- trivy 0.45.x (security scanning)
- yq v4.x (YAML processing)
- kubeconform (Kubernetes manifest validation)
- Vertical Pod Autoscaler (VPA) manifests v1.2.x (optional apply)
- k9s (Kubernetes TUI)
- stern (multi-pod log tailing)
- Docker Engine and Buildx plugins

Run the Playbook
----------------

Requirements:
- Ansible on your local machine
- Root SSH access to the VPS

```bash
# One-host ad-hoc inventory (prompts for password if -k is provided)
ansible-playbook -i "YOUR_VPS_IP," -u root -k provision.yml

# Or key-based auth (preferred)
ansible-playbook -i "YOUR_VPS_IP," -u root --private-key ~/.ssh/contabo_deploy_key provision.yml
```

Post-Provision Verification
---------------------------

```bash
ssh root@YOUR_VPS_IP \
  "kubectl version --client && helm version && argocd version && trivy --version && yq --version && kubeconform -v"
```

VPA Installation Behavior
-------------------------

- The playbook downloads VPA manifests to `/opt/deployment-tools/vpa-manifests`.
- If kubeconfig is configured on the VPS, it applies VPA automatically.
- Otherwise, you can apply later:

```bash
kubectl apply -f /opt/deployment-tools/vpa-manifests/vpa-v1.2.0.yaml
```

Tool Version Pins
-----------------

Version variables are defined at the top of `provision.yml`:

```yaml
kubectl_version: "v1.28.0"
helm_version: "v3.15.0"
argocd_version: "v2.13.0"
trivy_version: "0.45.0"
yq_version: "v4.35.2"
vpa_version: "1.2.0"
```

Relationship to CI/CD Workflows
-------------------------------

- The GitHub Actions workflows for ERP API/UI assume a working K8s cluster and access via `KUBE_CONFIG`.
- The provisioning workflow (`.github/workflows/provision.yml`) runs in this order:

**Provisioning Order:**
1. Storage Provisioner (local-path or default)
2. **Shared Databases (PostgreSQL & Redis in infra namespace)** ⭐
3. **RabbitMQ (Shared Infrastructure in infra namespace)** ⭐
4. NGINX Ingress Controller
5. cert-manager (TLS certificates)
6. Argo CD (GitOps)
7. Monitoring Stack (Prometheus/Grafana in infra namespace)
8. Vertical Pod Autoscaler (VPA)
9. Git SSH Access Setup

**Shared Infrastructure Installation Details:**
- **PostgreSQL & Redis**: Uses `scripts/install-databases.sh`
  - Installed in `infra` namespace (shared infrastructure)
  - Creates `admin_user` with superuser privileges for managing per-service databases
  - Uses `POSTGRES_PASSWORD`/`POSTGRES_ADMIN_PASSWORD` from GitHub secrets
  - Auto-generates secure passwords if secrets not provided
  - Each service creates its own database during deployment (cafe, bengo_erp, treasury, notifications)
  
- **RabbitMQ**: Uses `scripts/install-rabbitmq.sh`
  - Installed in `infra` namespace (shared infrastructure)
  - Uses `RABBITMQ_PASSWORD` from GitHub secrets
  - All services can use the shared RabbitMQ instance

- **Monitoring**: Installed in `infra` namespace
  - Prometheus and Grafana deployed as shared infrastructure
  - ServiceMonitor resources reference `infra` namespace

**Per-Service Database Creation:**
- Each service's build script automatically creates its database using `create-service-database.sh`
- Databases are created on first deployment, not during provisioning
- See `docs/per-service-database-setup.md` for details

**See:** `docs/secrets-management.md` for password flow details
- Provisioning ensures the VPS has the tooling for manual operations and emergency fixes.
- Automated deployments (build.sh) handle: image build, push, Helm values updates, ArgoCD sync, DB setup, migrations, and health checks.

Troubleshooting
---------------

- If any tool reports not found after provisioning, re-check PATH and installed binary locations (`/usr/local/bin`).
- For ArgoCD CLI TLS issues, use `--grpc-web --insecure` flags as needed.
- Ensure firewall allows required ports (22, 80, 443, 6443).

PostgreSQL Client
-----------------

The playbook and provisioning workflow install the PostgreSQL client tools (`postgresql-client` and `postgresql-client-common`) so you can run `psql` from the VPS or runner:

```bash
psql --version

# Example connection using admin_user (adjust host, db, user, and password as needed)
PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" psql \
  -h postgresql.infra.svc.cluster.local \
  -U admin_user \
  -d postgres \
  -c "SELECT NOW();"

# List all service databases
PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" psql \
  -h postgresql.infra.svc.cluster.local \
  -U admin_user \
  -d postgres \
  -c "\l"
```


