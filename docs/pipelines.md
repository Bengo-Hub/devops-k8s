Pipelines
---------

This repo provides a reusable GitHub Actions workflow `.github/workflows/reusable-build-deploy.yml`.

Inputs
------
- app_name: logical app identifier
- registry_server: container registry server (default docker.io)
- registry_namespace: registry namespace/user (default codevertex)
- docker_context: build context (default `.`)
- dockerfile: path to Dockerfile (default `Dockerfile`)
- image_repository: optional full image repo override (e.g. `docker.io/codevertex/erp-api`)
- deploy: boolean to push image and update values
- values_file_path: path to values file in this repo (e.g. `apps/erp-api/values.yaml`)
- chart_repo_path: path to chart (default `charts/app`)
- namespace: k8s namespace
- ssh_deploy: true to deploy via SSH to VPS (Contabo, on-prem)
- ssh_host, ssh_user, ssh_port, ssh_deploy_command: SSH deployment parameters

Secrets
-------
- REGISTRY_USERNAME, REGISTRY_PASSWORD: optional for private registry
- KUBE_CONFIG: base64 kubeconfig (optional)
- SSH_PRIVATE_KEY / DOCKER_SSH_KEY: optional for private git/registry

Behavior
--------
1. Trivy scans source and image.
2. Builds Docker image with short SHA tag.
3. Optionally pushes image, updates `values.yaml` with the new tag, commits to `main`.
4. Optionally applies `kubeSecrets/devENV.yaml` if provided with KUBE_CONFIG.
5. Argo CD detects changes and syncs.

Example Caller (Kubernetes)
--------------
Add to your repo at `.github/workflows/deploy.yml`:

```yaml
name: Build and Deploy
on:
  push:
    branches: [ main ]

jobs:
  deploy:
    uses: codevertex/devops-k8s/.github/workflows/reusable-build-deploy.yml@main
    with:
      app_name: erp-api
      registry_server: docker.io
      registry_namespace: codevertex
      values_file_path: apps/erp-api/values.yaml
      deploy: true
      namespace: erp
Example Caller (SSH to VPS)
---------------------------

```yaml
jobs:
  deploy:
    uses: codevertex/devops-k8s/.github/workflows/reusable-build-deploy.yml@main
    with:
      app_name: erp-api
      registry_server: docker.io
      registry_namespace: codevertex
      deploy: true
      ssh_deploy: true
      ssh_host: ${{ secrets.VPS_HOST }}
      ssh_user: ${{ secrets.VPS_USER }}
      ssh_port: '22'
    secrets:
      REGISTRY_USERNAME: ${{ secrets.DOCKERHUB_USERNAME }}
      REGISTRY_PASSWORD: ${{ secrets.DOCKERHUB_TOKEN }}
      SSH_PRIVATE_KEY: ${{ secrets.VPS_SSH_KEY }}
```
    secrets:
      REGISTRY_USERNAME: ${{ secrets.REGISTRY_USERNAME }}
      REGISTRY_PASSWORD: ${{ secrets.REGISTRY_PASSWORD }}
      KUBE_CONFIG: ${{ secrets.KUBE_CONFIG }}
```


