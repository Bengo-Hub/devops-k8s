GitHub Secrets
--------------

Organization-level (recommended):
- REGISTRY_USERNAME: Docker Hub username (codevertex)
- REGISTRY_PASSWORD: Docker Hub token/password
- KUBE_CONFIG: base64-encoded kubeconfig with apply permissions (for K8s deploy)
- SSH_PRIVATE_KEY: SSH key for VPS deployments over SSH (optional for K8s)
- DOCKER_SSH_KEY: base64 private key for docker build ssh forwarding (optional)

Contabo API (optional, for provider=contabo):
- CONTABO_CLIENT_ID: OAuth2 client id
- CONTABO_CLIENT_SECRET: OAuth2 client secret
- CONTABO_API_USERNAME: Contabo account username
- CONTABO_API_PASSWORD: Contabo account password
- Optional inputs (can be set in workflow `with:`; defaults shown):
  - contabo_instance_id (default: 202846760)
  - contabo_ip (default: 77.237.232.66)
  - contabo_datacenter (default: European Union 2)
  - contabo_region (default: EU)

Database automation (optional; auto-generated if omitted):
- POSTGRES_PASSWORD: PostgreSQL superuser password
- POSTGRES_ADMIN_PASSWORD: PostgreSQL admin_user password (for per-service DB management)
- REDIS_PASSWORD: Redis password
- MONGO_PASSWORD: MongoDB root password
- MYSQL_PASSWORD: MySQL root password

Infrastructure configuration (optional; defaults shown):
- VPS_IP: VPS IP address (default: YOUR_VPS_IP)
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


