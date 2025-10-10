Hosting Environments
--------------------

Overview
--------
The reusable pipeline supports multiple hosting strategies:
- Default: Contabo VPS via API, with automatic SSH fallback
- Generic SSH: Any in-house server or VPS
- Managed cloud K8s: AWS, DigitalOcean, etc., using KUBE_CONFIG

Contabo via API (default)
------------------------

**Your VPS:** 77.237.232.66 (Cloud VPS 40 NVMe, 48GB RAM, 12 cores)

Secrets (org-level recommended):
- CONTABO_CLIENT_ID, CONTABO_CLIENT_SECRET
- CONTABO_API_USERNAME, CONTABO_API_PASSWORD
- SSH_PRIVATE_KEY (fallback and provisioning)
- REGISTRY_USERNAME (Bengo-Hub), REGISTRY_PASSWORD

Inputs to workflow (with defaults):
- provider: contabo (default)
- contabo_api: true (default)
- contabo_instance_id: 202846760 (default)
- contabo_ip: 77.237.232.66 (default)
- contabo_datacenter: European Union 2 (default)
- contabo_region: EU (default)

Behavior:
1. Build, scan, and push image to registry.
2. Use Contabo OAuth2 to acquire token, fetch instance status and public IP.
3. If running, proceed; if not, attempt to start instance.
4. If KUBE_CONFIG is provided, apply kube secrets and rely on ArgoCD.
5. If SSH is enabled or API data is available, connect over SSH to run container (fallback path).

Generic SSH (in-house servers)
------------------------------
Provide:
- SSH_PRIVATE_KEY secret
- inputs.ssh_host, inputs.ssh_user, inputs.ssh_port
- REGISTRY_USERNAME/REGISTRY_PASSWORD
Set inputs:
- provider: ssh
- ssh_deploy: true

Managed Cloud K8s (AWS, DO, etc.)
---------------------------------
Provide KUBE_CONFIG (base64). ArgoCD syncs deployments when values.yaml is updated.

Current Production Setup
-----------------------

**Bengo-Hub Organization:**
- VPS IP: 77.237.232.66
- K8s: Full Kubernetes (kubeadm recommended for 48GB VPS)
- Registry: Docker Hub (docker.io/Bengo-Hub)
- Domains: *.masterspace.co.ke
- Namespace: erp (for ERP apps)

**Deployed Services:**
- Argo CD: https://argocd.masterspace.co.ke
- Grafana: https://grafana.masterspace.co.ke
- ERP API: https://erpapi.masterspace.co.ke
- ERP UI: https://erp.masterspace.co.ke

Best Practices
--------------
- Keep SSH hardening enabled; use non-root user.
- Use firewalls/security groups to limit SSH and HTTP.
- Rotate API credentials routinely.
- Prefer ArgoCD GitOps for Kubernetes rollouts; use SSH only for non-K8s targets.
- Set all secrets at organization level for reuse across repos.


