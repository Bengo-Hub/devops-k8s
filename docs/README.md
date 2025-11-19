Documentation Index
-------------------

**Getting Started** (Follow in Order)

1. **Access Setup (Manual - One-Time)**
   - **comprehensive-access-setup.md** 🔐 - Complete guide for SSH keys, GitHub PAT/token, Contabo API
   - **comprehensive-access-setup.md** 🔐 - Complete guide (includes SSH keys and testing)

2. **Cluster Setup (Automated - One-Time)**
   - **CLUSTER-SETUP-WORKFLOW.md** ⚙️ - Complete workflow guide (Manual Access → Automated Cluster → Automated Provisioning)
   - **contabo-setup-kubeadm.md** 📘 - Detailed Kubernetes cluster setup guide (Ubuntu 24.04, kubeadm)
   - **ETCD-OPTIMIZATION.md** 🔧 - Prevent etcd space issues (auto-compaction configuration)

3. **Provisioning (Automated - Repeatable)**
   - **provisioning.md** 🚀 - Automated infrastructure provisioning workflow
   - **github-secrets.md** 🔐 - Complete GitHub secrets configuration guide

**Additional Resources**
- Hosting environments and providers: hosting.md
- Onboarding a repository: onboarding.md

**Deployment**
- Pipelines and workflows: pipelines.md
- Argo CD setup and GitOps: argocd.md
- GitHub secrets required: github-secrets.md
- Environments and secrets: env-vars.md
- **comprehensive-access-setup.md** 🔐 - Access setup (SSH, GitHub PAT, Contabo API)
- **SSH keys setup:** See comprehensive-access-setup.md 🔑

**Infrastructure**
- **Database setup (PostgreSQL + Redis):** database-setup.md
- Certificates and domains: certificates.md
- API gateway and ingress: domains-gateway.md
- Image registry and SBOM: image-registry.md

**Operations**
- **operations runbook:** OPERATIONS-RUNBOOK.md 📋
- **health checks & rolling updates:** health-checks-and-rolling-updates.md 🔄
- **troubleshooting image tag drift:** troubleshooting-image-tag-drift.md 🔍
- **VPS access testing:** See comprehensive-access-setup.md ✅
- Monitoring and alerts (Prometheus, Grafana): monitoring.md
- Scaling (HPA, VPA): scaling.md
- Security best practices: security.md
- **etcd optimization:** ETCD-OPTIMIZATION.md 🔧
- **reprovisioning guide:** REPROVISIONING-GUIDE.md 🔄


