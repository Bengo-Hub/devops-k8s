Documentation Index
-------------------

**Getting Started** (Follow in Order)

1. **Access Setup (Manual - One-Time)**
   - **comprehensive-access-setup.md** 🔐 - Complete guide for SSH keys, GitHub PAT/token, Contabo API
   - **Prerequisites:** Fresh VPS with Ubuntu 24.04 LTS

2. **Cluster Setup (Automated - One-Time)**
   - **CLUSTER-SETUP-WORKFLOW.md** ⚙️ - Complete workflow guide (Manual Access → Automated Cluster → Automated Provisioning)
   - **contabo-setup-kubeadm.md** 📘 - Detailed Kubernetes cluster setup guide (Ubuntu 24.04, kubeadm)
   - **ETCD-OPTIMIZATION.md** 🔧 - Prevent etcd space issues (auto-compaction configuration)
   - **⚠️ IMPORTANT:** Cluster setup generates kubeconfig automatically

3. **Kubeconfig Setup (After Cluster Setup)**
   - **github-secrets.md** 🔐 - Extract and store kubeconfig in GitHub secrets
   - **⚠️ IMPORTANT:** Kubeconfig is generated DURING cluster setup, extract it AFTER cluster setup completes

4. **Provisioning (Automated - Repeatable)**
   - **provisioning.md** 🚀 - Automated infrastructure provisioning workflow
   - **Prerequisites:** Cluster setup complete, kubeconfig stored in GitHub secrets

**Additional Resources**
- Hosting environments: See provisioning.md
- Onboarding a repository: onboarding.md

**Deployment**
- Pipelines and workflows: pipelines.md
- Argo CD setup and GitOps: See pipelines.md
- GitHub secrets required: github-secrets.md
- Environments and secrets: See onboarding.md
- **comprehensive-access-setup.md** 🔐 - Access setup (SSH, GitHub PAT, Contabo API)
- **SSH keys setup:** See comprehensive-access-setup.md 🔑

**Infrastructure**
- **Database setup (PostgreSQL + Redis):** database-setup.md
- **Data Analytics platform setup (Superset + pgvector):** data-analytics-setup.md
- Certificates, domains, and ingress: domains-gateway.md
- Image registry: See onboarding.md

**Operations**
- **operations runbook:** OPERATIONS-RUNBOOK.md 📋
- **health checks & rolling updates:** health-checks-and-rolling-updates.md 🔄
- **troubleshooting image tag drift:** troubleshooting-image-tag-drift.md 🔍
- **VPS access testing:** See comprehensive-access-setup.md ✅
- Monitoring and alerts (Prometheus, Grafana): monitoring.md
- Scaling (HPA, VPA): scaling.md
- Security best practices: See OPERATIONS-RUNBOOK.md
- **etcd optimization:** ETCD-OPTIMIZATION.md 🔧
- **reprovisioning guide:** REPROVISIONING-GUIDE.md 🔄


