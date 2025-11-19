DevOps for Kubernetes - Monorepo
=================================

This repository contains reusable DevOps assets for deploying applications to a Kubernetes cluster using GitHub Actions, Helm, and Argo CD. Any repository in your GitHub organization can onboard by adding a simple `build.sh`, a `kubeSecrets/devENV.yaml`, and a short workflow that calls the reusable pipeline defined here.

🚀 **Quick Start**: See [SETUP.md](SETUP.md) for fast-track deployment guide.

⚠️ **IMPORTANT**: Follow the setup workflow in order:
1. **Manual Access Setup** → [docs/comprehensive-access-setup.md](docs/comprehensive-access-setup.md) 🔐
2. **Automated Cluster Setup** → [docs/CLUSTER-SETUP-WORKFLOW.md](docs/CLUSTER-SETUP-WORKFLOW.md) ⚙️
3. **Automated Provisioning** → [docs/provisioning.md](docs/provisioning.md) 🚀

✅ **Production Checklist**: See [PRODUCTION-CHECKLIST.md](PRODUCTION-CHECKLIST.md) for deployment status and manual steps.

📖 **Full Documentation**: Browse [docs/](docs/README.md) for comprehensive guides.

Quick Links
-----------
- **Getting Started** (Follow in Order)
  - docs overview: [docs/README.md](docs/README.md)
  - **1. Access Setup (Manual):** [docs/comprehensive-access-setup.md](docs/comprehensive-access-setup.md) 🔐 - SSH keys, GitHub PAT/token
  - **2. Cluster Setup (Automated):** [docs/CLUSTER-SETUP-WORKFLOW.md](docs/CLUSTER-SETUP-WORKFLOW.md) ⚙️ - Complete setup workflow guide
  - **3. Cluster Details:** [docs/contabo-setup-kubeadm.md](docs/contabo-setup-kubeadm.md) 📘 - Detailed Kubernetes setup
  - **4. Provisioning (Automated):** [docs/provisioning.md](docs/provisioning.md) 🚀 - Infrastructure provisioning workflow
  - hosting environments and providers: [docs/hosting.md](docs/hosting.md)
  - onboarding a repo: [docs/onboarding.md](docs/onboarding.md)

- **Deployment**
  - pipelines and workflows: [docs/pipelines.md](docs/pipelines.md)
  - Argo CD setup and GitOps: [docs/argocd.md](docs/argocd.md)
  - GitHub secrets required: [docs/github-secrets.md](docs/github-secrets.md)
  - environments and secrets: [docs/env-vars.md](docs/env-vars.md)
  - **comprehensive access setup:** [docs/comprehensive-access-setup.md](docs/comprehensive-access-setup.md) 🔐
  - **SSH keys setup:** [docs/ssh-keys-setup.md](docs/ssh-keys-setup.md) 🔑

- **Infrastructure**
  - **database setup (PostgreSQL + Redis):** [docs/database-setup.md](docs/database-setup.md)
  - certificates and domains: [docs/certificates.md](docs/certificates.md)
  - API gateway and ingress: [docs/domains-gateway.md](docs/domains-gateway.md)
  - image registry and SBOM: [docs/image-registry.md](docs/image-registry.md)

- **Operations**
  - **operations runbook:** [docs/OPERATIONS-RUNBOOK.md](docs/OPERATIONS-RUNBOOK.md) 📋
  - **health checks & rolling updates:** [docs/health-checks-and-rolling-updates.md](docs/health-checks-and-rolling-updates.md) 🔄
  - **troubleshooting image tag drift:** [docs/troubleshooting-image-tag-drift.md](docs/troubleshooting-image-tag-drift.md) 🔍
  - **etcd optimization:** [docs/ETCD-OPTIMIZATION.md](docs/ETCD-OPTIMIZATION.md) - Prevent etcd space issues 🔧
  - monitoring and alerts (Prometheus, Grafana): [docs/monitoring.md](docs/monitoring.md)
  - scaling (HPA, VPA): [docs/scaling.md](docs/scaling.md)
  - security best practices: [docs/security.md](docs/security.md)
  - **VPS access testing guide:** [docs/vps-access-testing-guide.md](docs/vps-access-testing-guide.md) ✅


