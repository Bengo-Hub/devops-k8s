GitHub Secrets
--------------

Organization-level (recommended):
- REGISTRY_USERNAME: Docker Hub username (codevertex)
- REGISTRY_PASSWORD: Docker Hub token/password
- KUBE_CONFIG: base64-encoded kubeconfig with apply permissions (for K8s deploy)
- SSH_PRIVATE_KEY: SSH key for VPS deployments over SSH (optional for K8s)
- DOCKER_SSH_KEY: base64 private key for docker build ssh forwarding (optional)

Contabo API (optional, enables automated VPS management):
- CONTABO_CLIENT_ID: OAuth2 client id
- CONTABO_CLIENT_SECRET: OAuth2 client secret
- CONTABO_API_USERNAME: Contabo account username
- CONTABO_API_PASSWORD: Contabo account password
- CONTABO_INSTANCE_ID: Contabo VPS instance ID (e.g., 14285715)
  - Found in Contabo control panel → Your instance → Details
  - Default: 14285715 (if not set)

**VPS IP Priority (for provisioning workflow):**
1. **SSH_HOST** secret (highest priority - if set, used directly)
2. Contabo API lookup (if Contabo credentials configured)
3. Manual configuration required (if neither available)

**Note:** Contabo API enables:
- Automatic VPS IP lookup
- VPS status checking
- VPS start/stop operations

**How to Get Contabo API Credentials:**
1. Login to https://my.contabo.com
2. Navigate to Account > Security
3. Create OAuth2 Client:
   - Click "Create OAuth2 Client"
   - Note down `Client ID` and `Client Secret`
4. Use your Contabo account username and password for API authentication
5. Find your VPS instance ID in Contabo control panel → Your instance → Details

Database automation (optional; auto-generated if omitted):
- POSTGRES_PASSWORD: PostgreSQL superuser password
- POSTGRES_ADMIN_PASSWORD: PostgreSQL admin_user password (for per-service DB management)
- REDIS_PASSWORD: Redis password
- MONGO_PASSWORD: MongoDB root password
- MYSQL_PASSWORD: MySQL root password

Infrastructure configuration (optional; defaults shown):
- SSH_HOST: VPS IP address (Priority 1 - takes precedence over Contabo API)
  - Alternative to Contabo API for VPS IP
  - If set, Contabo API lookup is skipped
- ARGOCD_DOMAIN: ArgoCD domain (default: argocd.masterspace.co.ke)
- GRAFANA_DOMAIN: Grafana domain (default: grafana.masterspace.co.ke)
- DB_NAMESPACE: Namespace for shared databases (default: infra)
- MONITORING_NAMESPACE: Namespace for monitoring stack (default: infra)
- RABBITMQ_NAMESPACE: Namespace for RabbitMQ (default: infra)
- RABBITMQ_PASSWORD: RabbitMQ password (default: rabbitmq)

Cleanup (opt-in only):
- ENABLE_CLEANUP: Set to 'true' to enable cluster cleanup (default: false, NEVER runs by default)

Contact emails:
- Org email: codevertexitsolutions@gmail.com
- Business email: info@codevertexitsolutions.com
Website: https://www.codevertexitsolutions.com

Per-repo overrides are supported by defining the same secrets at the repository level.

---

## Complete Setup Guide

After configuring Kubernetes cluster (see `docs/contabo-setup-kubeadm.md`), follow these steps:

### 1. Get Kubeconfig

**On your VPS:**

```bash
# Update kubeconfig with public IP
VPS_IP="YOUR_VPS_IP"
sed -i "s|server: https://.*:6443|server: https://${VPS_IP}:6443|" $HOME/.kube/config

# Get base64-encoded kubeconfig
cat $HOME/.kube/config | base64 -w 0 2>/dev/null || cat $HOME/.kube/config | base64
```

### 2. Configure GitHub Secrets

Go to GitHub → Settings → Secrets and variables → Actions (Organization or Repository level)

**Required Secrets:**

1. **KUBE_CONFIG** (Required)
   - Value: The base64-encoded kubeconfig from above
   - Copy the entire base64 output

**Optional Secrets (with defaults):**

2. **SSH_HOST** (Optional - Priority 1)
   - Value: Your VPS IP address (e.g., `77.237.232.66`)
   - **Priority:** If set, this takes precedence over Contabo API lookup

3. **SSH_PRIVATE_KEY** (Optional)
   - Value: Your SSH private key content (entire key including BEGIN/END lines)
   - Only needed if manual SSH access required

**Contabo API Secrets (Optional - Priority 2):**

4. **CONTABO_CLIENT_ID** (Optional)
   - Value: Contabo OAuth2 client ID
   - Enables automated VPS IP lookup and status management

5. **CONTABO_CLIENT_SECRET** (Optional)
   - Value: Contabo OAuth2 client secret

6. **CONTABO_API_USERNAME** (Optional)
   - Value: Your Contabo account username

7. **CONTABO_API_PASSWORD** (Optional)
   - Value: Your Contabo account password

8. **CONTABO_INSTANCE_ID** (Optional)
   - Value: Your Contabo VPS instance ID (e.g., `14285715`)
   - Found in Contabo control panel → Your instance → Details
   - Default: `14285715` (if not set)

**Priority Order for VPS IP:**
1. `SSH_HOST` secret (if set)
2. Contabo API lookup (if credentials configured)
3. Manual configuration required (if neither available)

### 3. Next Steps

After configuring secrets:

1. **Run Automated Provisioning:** See `SETUP.md` for workflow execution
2. **Configure DNS:** Point domains to your VPS IP (see `SETUP.md`)
3. **Deploy Applications:** Applications deploy automatically via Argo CD

**See:** `docs/contabo-setup-kubeadm.md` for complete Kubernetes cluster setup guide


