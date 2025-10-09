Onboarding a Repository
----------------------

1) Add `setup.sh` at the repo root to mirror build steps (scan, build, optional deploy). Example:

```bash
#!/usr/bin/env bash
set -euo pipefail

export DEPLOY=${DEPLOY:-false}
export TRIVY_ECODE=${TRIVY_ECODE:-1}

if [[ -z ${GITHUB_SHA:-} ]]; then GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD); else GIT_COMMIT_ID=${GITHUB_SHA::8}; fi

trivy fs . --exit-code $TRIVY_ECODE || true

DOCKER_BUILDKIT=1 docker build . -t "$IMAGE_REPO:$GIT_COMMIT_ID"
trivy image "$IMAGE_REPO:$GIT_COMMIT_ID" --exit-code $TRIVY_ECODE || true

if [[ "$DEPLOY" == "true" ]]; then
  docker push "$IMAGE_REPO:$GIT_COMMIT_ID"
fi
```

2) Create `kubeSecrets/devENV.yaml` Secret manifest.

3) Add `.github/workflows/deploy.yml` that calls the reusable workflow.

4) Ensure your app is registered in this repo under `apps/<app>/values.yaml` and (optionally) an Argo CD `apps/<app>/app.yaml`.


