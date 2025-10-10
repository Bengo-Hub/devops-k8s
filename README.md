DevOps for Kubernetes - Monorepo
=================================

This repository contains reusable DevOps assets for deploying applications to a Kubernetes cluster using GitHub Actions, Helm, and Argo CD. Any repository in your GitHub organization can onboard by adding a simple `build.sh`, a `kubeSecrets/devENV.yaml`, and a short workflow that calls the reusable pipeline defined here.

🚀 **Quick Start**: See [SETUP.md](SETUP.md) for fast-track deployment guide.

📖 **Full Documentation**: Browse [docs/](docs/README.md) for comprehensive guides.

Quick Links
-----------
- **Getting Started**
  - docs overview: [docs/README.md](docs/README.md)
  - **K8s choice (k3s vs kubeadm):** [docs/k8s-comparison.md](docs/k8s-comparison.md) ⭐
  - Contabo VPS with k3s (recommended): [docs/contabo-setup.md](docs/contabo-setup.md)
  - Contabo VPS with kubeadm (alternative): [docs/contabo-setup-kubeadm.md](docs/contabo-setup-kubeadm.md)
  - hosting environments and providers: [docs/hosting.md](docs/hosting.md)
  - onboarding a repo: [docs/onboarding.md](docs/onboarding.md)

- **Deployment**
  - pipelines and workflows: [docs/pipelines.md](docs/pipelines.md)
  - Argo CD setup and GitOps: [docs/argocd.md](docs/argocd.md)
  - GitHub secrets required: [docs/github-secrets.md](docs/github-secrets.md)
  - environments and secrets: [docs/env-vars.md](docs/env-vars.md)

- **Infrastructure**
  - **database setup (PostgreSQL + Redis):** [docs/database-setup.md](docs/database-setup.md)
  - certificates and domains: [docs/certificates.md](docs/certificates.md)
  - API gateway and ingress: [docs/domains-gateway.md](docs/domains-gateway.md)
  - image registry and SBOM: [docs/image-registry.md](docs/image-registry.md)

- **Operations**
  - monitoring and alerts (Prometheus, Grafana): [docs/monitoring.md](docs/monitoring.md)
  - scaling (HPA, VPA): [docs/scaling.md](docs/scaling.md)
  - security best practices: [docs/security.md](docs/security.md)


