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
Secrets (org-level recommended):
- CONTABO_CLIENT_ID, CONTABO_CLIENT_SECRET
- CONTABO_API_USERNAME, CONTABO_API_PASSWORD
- SSH_PRIVATE_KEY (fallback and provisioning)
- REGISTRY_USERNAME, REGISTRY_PASSWORD

Inputs to workflow:
- provider: contabo (default)
- contabo_api: true (default)
- contabo_instance_id: target instance id

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

Best Practices
--------------
- Keep SSH hardening enabled; use non-root user.
- Use firewalls/security groups to limit SSH and HTTP.
- Rotate API credentials routinely.
- Prefer ArgoCD GitOps for Kubernetes rollouts; use SSH only for non-K8s targets.


