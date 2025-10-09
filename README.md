DevOps for Kubernetes - Monorepo
=================================

This repository contains reusable DevOps assets for deploying applications to a Kubernetes cluster using GitHub Actions, Helm, and Argo CD. Any repository in your GitHub organization can onboard by adding a simple `setup.sh`, a `kubeSecrets/devENV.yaml`, and a short workflow that calls the reusable pipeline defined here.

Quick Links
-----------
- docs overview: docs/README.md
- pipelines: docs/pipelines.md
- environments and secrets: docs/env-vars.md
- certificates and domains: docs/certificates.md
- security: docs/security.md
- scaling: docs/scaling.md
- API gateway and ingress: docs/domains-gateway.md
- monitoring and alerts: docs/monitoring.md
- Argo CD setup: docs/argocd.md
- image registry and SBOM: docs/image-registry.md
- GitHub secrets required: docs/github-secrets.md
- onboarding a repo: docs/onboarding.md


