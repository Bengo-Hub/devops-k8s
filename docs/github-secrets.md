GitHub Secrets
--------------

Organization-level (recommended):
- REGISTRY_USERNAME: Docker Hub username (codevertex)
- REGISTRY_PASSWORD: Docker Hub token/password
- KUBE_CONFIG: base64-encoded kubeconfig with apply permissions (for K8s deploy)
- SSH_PRIVATE_KEY: SSH key for VPS deployments over SSH (optional for K8s)
- DOCKER_SSH_KEY: base64 private key for docker build ssh forwarding (optional)

Contact emails:
- Org email: codevertexitsolutions@gmail.com
- Business email: info@codevertexitsolutions.com
Website: https://www.codevertexitsolutions.com

Per-repo overrides are supported by defining the same secrets at the repository level.


