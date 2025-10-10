Onboarding a Repository
-----------------------

This guide walks through adding a new application repository to the Bengo-Hub organization for automated CI/CD deployment.

Prerequisites
-------------
- Application repository in Bengo-Hub organization
- Dockerfile at repo root
- Access to GitHub organization secrets

Quick Onboarding Steps
----------------------

1) **Add `build.sh`** at the repo root for local testing (scan, build, optional deploy). Example:

```bash
#!/usr/bin/env bash
set -euo pipefail

TRIVY_ECODE=${TRIVY_ECODE:-1}
DEPLOY=${DEPLOY:-false}

if [[ -z ${GITHUB_SHA:-} ]]; then
  GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD)
else
  GIT_COMMIT_ID=${GITHUB_SHA::8}
fi

IMAGE_REPO=${IMAGE_REPO:-docker.io/Bengo-Hub/my-app}

echo "[INFO] Trivy FS scan"
trivy fs . --exit-code $TRIVY_ECODE || true

echo "[INFO] Docker build $IMAGE_REPO:$GIT_COMMIT_ID"
DOCKER_BUILDKIT=1 docker build . -t "$IMAGE_REPO:$GIT_COMMIT_ID"

echo "[INFO] Trivy Image scan"
trivy image "$IMAGE_REPO:$GIT_COMMIT_ID" --exit-code $TRIVY_ECODE || true

if [[ "$DEPLOY" == "true" ]]; then
  echo "[INFO] Pushing image"
  docker push "$IMAGE_REPO:$GIT_COMMIT_ID"

  if [[ -n ${KUBE_CONFIG:-} ]]; then
    echo "[INFO] Applying kube secrets"
    mkdir -p ~/.kube
    echo "$KUBE_CONFIG" | base64 -d > ~/.kube/config
    kubectl apply -f kubeSecrets/devENV.yaml || true
  fi
fi

echo "[SUCCESS] Completed. Tag: $GIT_COMMIT_ID"
```

2) **Create `kubeSecrets/devENV.yaml`** Secret manifest with your app's environment variables:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-app-env
  namespace: my-namespace
type: Opaque
stringData:
  # Database (if using automated setup, these will be auto-populated)
  DATABASE_URL: "postgresql://postgres:PASSWORD@postgresql.my-namespace.svc.cluster.local:5432/mydb"
  REDIS_URL: "redis://:PASSWORD@redis-master.my-namespace.svc.cluster.local:6379/0"
  
  # App-specific variables
  JWT_SECRET: ""  # Auto-generated if empty
  DEBUG: "False"
  ALLOWED_HOSTS: "myapp.domain.com"
```

3) **Add `.github/workflows/deploy.yml`** that calls the reusable workflow:

```yaml
name: Build and Deploy My App
on:
  push:
    branches: [ main, master ]

jobs:
  deploy:
    permissions:
      contents: write
      id-token: write
    uses: Bengo-Hub/devops-k8s/.github/workflows/reusable-build-deploy.yml@main
    with:
      app_name: my-app
      registry_server: docker.io
      registry_namespace: Bengo-Hub
      values_file_path: apps/my-app/values.yaml
      deploy: true
      namespace: my-namespace
      # Optional: Auto-setup databases
      setup_databases: true
      db_types: postgres,redis
      env_secret_name: my-app-env
    secrets:
      REGISTRY_USERNAME: ${{ secrets.REGISTRY_USERNAME }}
      REGISTRY_PASSWORD: ${{ secrets.REGISTRY_PASSWORD }}
      KUBE_CONFIG: ${{ secrets.KUBE_CONFIG }}
      # Optional: Provide DB passwords or let them auto-generate
      POSTGRES_PASSWORD: ${{ secrets.POSTGRES_PASSWORD }}
      REDIS_PASSWORD: ${{ secrets.REDIS_PASSWORD }}
```

4) **Register your app in devops-k8s** repo:

Create `apps/my-app/values.yaml`:
```yaml
image:
  repository: docker.io/Bengo-Hub/my-app
  tag: latest

service:
  port: 80
  targetPort: 8000

resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 1000m
    memory: 1Gi

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70
  targetMemoryUtilizationPercentage: 80

ingress:
  enabled: true
  className: nginx
  hosts:
    - host: myapp.domain.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - hosts:
        - myapp.domain.com
      secretName: myapp-tls

envFromSecret: my-app-env
```

Create `apps/my-app/app.yaml` (Argo CD Application):
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git@github.com:Bengo-Hub/devops-k8s.git
    targetRevision: main
    path: charts/app
    helm:
      valueFiles:
        - ../../apps/my-app/values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: my-namespace
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

5) **Apply Argo CD Application**:

```bash
kubectl apply -f apps/my-app/app.yaml
```

Complete Onboarding Checklist
-----------------------------

- [ ] `build.sh` added to app repo
- [ ] `kubeSecrets/devENV.yaml` created with environment variables
- [ ] `.github/workflows/deploy.yml` added
- [ ] `apps/my-app/values.yaml` created in devops-k8s
- [ ] `apps/my-app/app.yaml` created in devops-k8s
- [ ] Argo CD application applied to cluster
- [ ] DNS pointed to VPS IP (77.237.232.66)
- [ ] First deployment tested

GitHub Secrets Required
-----------------------

Ensure these are set at organization level:
- `REGISTRY_USERNAME` (Bengo-Hub)
- `REGISTRY_PASSWORD` (Docker Hub token)
- `KUBE_CONFIG` (base64 kubeconfig from VPS)
- `SSH_PRIVATE_KEY` (for VPS access)
- Optional: `POSTGRES_PASSWORD`, `REDIS_PASSWORD` (auto-generated if omitted)
- Optional: `CONTABO_CLIENT_ID`, `CONTABO_CLIENT_SECRET`, `CONTABO_API_USERNAME`, `CONTABO_API_PASSWORD`

Next Steps After Onboarding
---------------------------

1. Push to main/master branch to trigger first deployment
2. Monitor workflow: https://github.com/Bengo-Hub/my-app/actions
3. Check Argo CD: https://argocd.masterspace.co.ke
4. Verify deployment: `kubectl get pods -n my-namespace`
5. Check application logs: `kubectl logs -n my-namespace deployment/my-app`
6. Visit your application: https://myapp.domain.com


