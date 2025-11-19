# Cluster Setup Workflow

## Overview

This document explains the complete workflow for setting up a Kubernetes cluster, from manual access configuration to automated provisioning.

## Workflow Summary

```
Manual Access Setup → Automated Cluster Setup → Automated Provisioning
     (One-time)          (One-time)              (Repeatable)
```

## Step-by-Step Process

### Phase 1: Manual Access Setup (One-Time)

**Purpose:** Configure all access credentials required for automation.

**Steps:**

1. **SSH Key Setup**
   - Generate SSH key pair
   - Add public key to Contabo VPS
   - Store private key in GitHub secrets (`SSH_PRIVATE_KEY`, `DOCKER_SSH_KEY`)

2. **GitHub Access**
   - Create GitHub Personal Access Token (PAT)
   - Store in GitHub secrets (`DEVOPS_K8S_ACCESS_TOKEN`, `GITHUB_TOKEN`)

3. **Contabo API** (Optional but recommended)
   - Create OAuth2 client
   - Store credentials in GitHub secrets (`CONTABO_CLIENT_ID`, `CONTABO_CLIENT_SECRET`, etc.)

**Documentation:** See `docs/comprehensive-access-setup.md`

**Time Required:** ~15-30 minutes

---

### Phase 2: Automated Cluster Setup (One-Time)

**Purpose:** Set up the Kubernetes cluster on the VPS.

**Prerequisites:**
- ✅ SSH access to VPS configured
- ✅ GitHub PAT/token configured
- ✅ SSH keys in GitHub secrets

**Process:**

1. **SSH into VPS:**
   ```bash
   ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP
   ```

2. **Clone/Upload devops-k8s repository:**
   ```bash
   cd /opt
   git clone https://github.com/YOUR_ORG/devops-k8s.git
   cd devops-k8s
   ```

3. **Run orchestrated setup:**
   ```bash
   chmod +x scripts/cluster/*.sh
   ./scripts/cluster/setup-cluster.sh
   ```

**What the script does automatically:**

1. ✅ **Initial VPS Setup** (`setup-vps.sh`)
   - Updates system packages
   - Disables swap
   - Loads kernel modules
   - Configures sysctl
   - Sets timezone and hostname
   - Configures firewall

2. ✅ **Container Runtime** (`setup-containerd.sh`)
   - Adds Docker repository
   - Installs containerd
   - Configures containerd for Kubernetes
   - Installs crictl

3. ✅ **Kubernetes Cluster** (`setup-kubernetes.sh`)
   - Adds Kubernetes repository
   - Installs kubelet, kubeadm, kubectl
   - Initializes cluster with kubeadm
   - Configures kubectl
   - Removes master node taint
   - Installs Calico CNI

4. ✅ **etcd Configuration**
   - Configures auto-compaction
   - Sets quota and retention

5. ✅ **Kubeconfig Generation**
   - Updates kubeconfig with public IP
   - Outputs base64-encoded kubeconfig

**After script completes:**

1. Copy the base64 kubeconfig output
2. Add it as GitHub organization secret: `KUBE_CONFIG`

**Documentation:** See `docs/contabo-setup-kubeadm.md`

**Time Required:** ~15-20 minutes (automated)

---

### Phase 3: Automated Provisioning (Repeatable)

**Purpose:** Install and configure all infrastructure components.

**Prerequisites:**
- ✅ Kubernetes cluster running
- ✅ `KUBE_CONFIG` secret configured
- ✅ All access secrets configured

**Process:**

1. **Run GitHub Actions workflow:**
   - Go to: `https://github.com/YOUR_ORG/devops-k8s/actions`
   - Select: **"Provision Cluster Infrastructure"**
   - Click: **"Run workflow"** → **"Run workflow"**

**What the workflow does automatically:**

1. ✅ Gets VPS IP (via Contabo API or SSH_HOST secret)
2. ✅ Checks etcd space
3. ✅ Installs storage provisioner
4. ✅ Installs PostgreSQL & Redis
5. ✅ Installs RabbitMQ
6. ✅ Configures NGINX Ingress Controller
7. ✅ Installs cert-manager
8. ✅ Installs Argo CD
9. ✅ Installs monitoring stack (Prometheus + Grafana)
10. ✅ Installs Vertical Pod Autoscaler (VPA)
11. ✅ Sets up Git SSH access

**Documentation:** See `docs/provisioning.md`

**Time Required:** ~20-30 minutes (automated)

---

## Script Organization

### Orchestrated Script

**`scripts/cluster/setup-cluster.sh`** - Main orchestrator
- Runs all setup scripts in correct order
- Handles dependencies between steps
- Provides progress feedback
- Generates kubeconfig output

### Individual Scripts

**`scripts/cluster/setup-vps.sh`** - Initial VPS configuration
- System updates
- Kernel modules
- Sysctl configuration
- Firewall setup

**`scripts/cluster/setup-containerd.sh`** - Container runtime
- containerd installation
- Configuration for Kubernetes
- crictl installation

**`scripts/cluster/setup-kubernetes.sh`** - Kubernetes cluster
- Kubernetes installation
- Cluster initialization
- Calico CNI installation
- Kubeconfig preparation

### Usage Options

**Option 1: Orchestrated (Recommended)**
```bash
./scripts/cluster/setup-cluster.sh
```

**Option 2: Individual Scripts**
```bash
./scripts/cluster/setup-vps.sh
./scripts/cluster/setup-containerd.sh
./scripts/cluster/setup-kubernetes.sh
```

**Option 3: Skip Steps (if already done)**
```bash
SKIP_VPS_SETUP=true ./scripts/cluster/setup-cluster.sh
SKIP_CONTAINERD=true SKIP_KUBERNETES=false ./scripts/cluster/setup-cluster.sh
```

---

## Environment Variables

The setup scripts support these environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLUSTER_NAME` | `mss-prod` | Cluster name |
| `KUBERNETES_VERSION` | `1.30` | Kubernetes version |
| `VPS_IP` | (none) | Public IP for kubeconfig |
| `SKIP_VPS_SETUP` | `false` | Skip VPS setup step |
| `SKIP_CONTAINERD` | `false` | Skip containerd setup |
| `SKIP_KUBERNETES` | `false` | Skip Kubernetes setup |

**Example:**
```bash
VPS_IP="77.237.232.66" CLUSTER_NAME="production" ./scripts/cluster/setup-cluster.sh
```

---

## Verification Checklist

After each phase, verify:

### Phase 1: Access Setup ✅
- [ ] SSH connection works: `ssh -i ~/.ssh/contabo_deploy_key root@VPS_IP`
- [ ] GitHub PAT works: `curl -H "Authorization: Bearer TOKEN" https://api.github.com/user`
- [ ] Contabo API works: Can get access token

### Phase 2: Cluster Setup ✅
- [ ] Cluster initialized: `kubectl get nodes`
- [ ] Node is Ready: `kubectl get nodes` shows Ready status
- [ ] Calico running: `kubectl get pods -n calico-system`
- [ ] Kubeconfig generated: Base64 output available

### Phase 3: Provisioning ✅
- [ ] Storage provisioner: `kubectl get storageclass`
- [ ] Databases running: `kubectl get pods -n infra`
- [ ] Ingress running: `kubectl get pods -n ingress-nginx`
- [ ] Argo CD running: `kubectl get pods -n argocd`
- [ ] Monitoring running: `kubectl get pods -n infra`

---

## Troubleshooting

### Cluster Setup Fails

**Check:**
- VPS has sufficient resources (4GB+ RAM)
- Ubuntu 24.04 LTS installed
- Internet connectivity
- Scripts are executable: `chmod +x scripts/cluster/*.sh`

**Common Issues:**
- Swap not disabled → Run `swapoff -a`
- containerd not running → Check `systemctl status containerd`
- Firewall blocking → Check `ufw status`

### Provisioning Fails

**Check:**
- `KUBE_CONFIG` secret is correct
- Cluster is accessible: `kubectl get nodes`
- GitHub secrets are configured
- Workflow has proper permissions

**Common Issues:**
- Kubeconfig wrong IP → Update server URL in kubeconfig
- Secrets missing → Add required GitHub secrets
- Cluster not ready → Wait for node to be Ready

---

## Related Documentation

**Setup Workflow (Follow in Order):**
1. **Access Setup:** `docs/comprehensive-access-setup.md` - Manual access configuration
2. **Cluster Setup:** `docs/contabo-setup-kubeadm.md` - Detailed Kubernetes setup guide
3. **Provisioning:** `docs/provisioning.md` - Automated infrastructure provisioning

**Quick Reference:**
- **Quick Start:** `SETUP.md` - Fast-track setup guide
- **GitHub Secrets:** `docs/github-secrets.md` - Complete secrets configuration
- **etcd Optimization:** `docs/ETCD-OPTIMIZATION.md` - Prevent etcd space issues
- **SSH Keys:** `docs/ssh-keys-setup.md` - SSH key setup details
- **VPS Testing:** `docs/vps-access-testing-guide.md` - Access verification

---

## Support

For issues or questions:
- **Email:** codevertexitsolutions@gmail.com
- **Website:** https://www.codevertexitsolutions.com
- **GitHub Issues:** Create issues in the devops-k8s repository

