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

IMAGE_REPO=${IMAGE_REPO:-docker.io/codevertex/my-app}

echo "[INFO] Trivy FS scan"
trivy fs . --exit-code $TRIVY_ECODE || true

echo "[INFO] Docker build $IMAGE_REPO:$GIT_COMMIT_ID"
DOCKER_BUILDKIT=1 docker build . -t "$IMAGE_REPO:$GIT_COMMIT_ID"

echo "[INFO] Trivy Image scan"
trivy image "$IMAGE_REPO:$GIT_COMMIT_ID" --exit-code $TRIVY_ECODE || true

if [[ "$DEPLOY" == "true" ]]; then
  echo "[INFO] Pushing image"
  docker push "$IMAGE_REPO:$GIT_COMMIT_ID"

fi

echo "[SUCCESS] Completed. Tag: $GIT_COMMIT_ID"
```

2) **Secrets: no Secret manifest in the service repo.** The service's Secret
   (`<service>-secrets` or the name in its values) is produced by
   `scripts/infrastructure/create-service-secrets.sh` on the first deploy: it generates the standard
   keys (database and Redis URLs through PgBouncer, `POSTGRES_MIGRATE_URL`, `SECRET_KEY`, the
   service's encryption key and `INTERNAL_SERVICE_KEY` where listed), seals the Secret into
   `manifests/sealed-secrets/<namespace>/` in this repo and waits for it to sync. Extra keys are
   added with `scripts/sealing/seal-keys.sh` (see [secrets-and-keys.md](secrets-and-keys.md));
   never with `kubectl patch` and never as a plain `kind: Secret` in git.

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
  repository: docker.io/codevertex/my-app
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
- [ ] Secret created by `create-service-secrets.sh` on the first deploy (sealed, never a plain manifest)
- [ ] `.github/workflows/deploy.yml` added
- [ ] `apps/my-app/values.yaml` created in devops-k8s
- [ ] `apps/my-app/app.yaml` created in devops-k8s
- [ ] Argo CD application applied to cluster
- [ ] DNS pointed to VPS IP (<ORIGIN_IP>)
- [ ] First deployment tested

GitHub Secrets Required
-----------------------

Ensure these are set at organization level:
- `REGISTRY_USERNAME` (codevertex)
- `REGISTRY_PASSWORD` (Docker Hub token)
- `KUBE_CONFIG` (base64 kubeconfig from VPS)
- `SSH_PRIVATE_KEY` (for VPS access)
- Optional: `POSTGRES_PASSWORD`, `REDIS_PASSWORD` (auto-generated if omitted)
- Optional: `CONTABO_CLIENT_ID`, `CONTABO_CLIENT_SECRET`, `CONTABO_API_USERNAME`, `CONTABO_API_PASSWORD`

### Image Registry Configuration

**Registry Setup:**
- Use a private registry (e.g., `registry.masterspace.co.ke`) or Docker Hub (`docker.io/codevertex`)
- Authenticate with `REGISTRY_USERNAME`/`REGISTRY_PASSWORD` in GitHub Secrets
- Images are tagged with short SHA; `latest` is not used for deploys
- Trivy generates vulnerability reports; integrate with registry scanning when available

**Registry Authentication:**
The workflow automatically authenticates with the registry using GitHub secrets:
- `REGISTRY_USERNAME`: Your registry username (e.g., `codevertex`)
- `REGISTRY_PASSWORD`: Your registry token/password

**Image Tagging:**
- Images are tagged with short commit SHA (8 characters)
- Example: `docker.io/codevertex/my-app:a1b2c3d4`
- Never use `latest` tag for production deployments

Next Steps After Onboarding
---------------------------

1. Push to main/master branch to trigger first deployment
2. Monitor workflow: https://github.com/Bengo-Hub/YOUR_APP_REPO/actions
3. Check Argo CD: https://argocd.masterspace.co.ke
4. Verify deployment: `kubectl get pods -n my-namespace`
5. Check application logs: `kubectl logs -n my-namespace deployment/my-app`
6. Visit your application: https://myapp.domain.com


