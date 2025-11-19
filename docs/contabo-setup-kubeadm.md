Contabo VPS Setup with Full Kubernetes (kubeadm)
================================================

This guide walks through setting up a Contabo VPS with Kubernetes using kubeadm.

**Note:** This is the recommended setup for all Contabo VPS tiers (4GB+ RAM).

Prerequisites
-------------
- Contabo VPS with 4GB+ RAM (8GB+ recommended)
- Ubuntu 24.04 LTS (Noble Numbat)
- Root or sudo access
- Contabo client ID and secret (for API automation)

## Quick Start (Automated Setup)

**After manual access setup (SSH keys, GitHub PAT/token configured):**

Run the orchestrated setup script that automates all cluster setup steps:

```bash
# On your VPS (via SSH)
cd /path/to/devops-k8s
chmod +x scripts/cluster/*.sh
./scripts/cluster/setup-cluster.sh
```

This script will automatically:
1. ✅ Set up initial VPS configuration
2. ✅ Install and configure containerd
3. ✅ Install Kubernetes and initialize cluster
4. ✅ Configure Calico CNI
5. ✅ Set up etcd auto-compaction
6. ✅ Generate kubeconfig for GitHub secrets

**Manual Steps Required First:**
- SSH access to VPS configured (see [Comprehensive Access Setup](./comprehensive-access-setup.md))
- GitHub PAT/token created and stored in GitHub secrets
- SSH keys added to GitHub secrets (`SSH_PRIVATE_KEY`, `DOCKER_SSH_KEY`)

**After running setup-cluster.sh:**
- Copy the generated base64 kubeconfig
- Add it as GitHub organization secret: `KUBE_CONFIG`
- Run the provisioning workflow to install infrastructure

---

Table of Contents
-----------------
1. Contabo API Setup
2. SSH Key Configuration
3. Initial Server Setup
4. Container Runtime (containerd)
5. Kubernetes Installation (kubeadm)
6. Cluster Initialization
7. Pod Network (Calico CNI) & etcd Configuration
8. Kubeconfig Setup for Remote Access
9. NGINX Ingress Controller
10. cert-manager
11. Verification & Troubleshooting
12. Next Steps

---

1. Contabo API Setup
--------------------

See section 1 below for Contabo API setup instructions.

Store these as GitHub org secrets:
- `CONTABO_CLIENT_ID`
- `CONTABO_CLIENT_SECRET`
- `CONTABO_API_USERNAME`
- `CONTABO_API_PASSWORD`

---

2. SSH Key Configuration
------------------------

See section 2 below for SSH key configuration instructions.

```bash
# On your local machine
ssh-keygen -t ed25519 -C "devops@codevertex" -f ~/.ssh/contabo_deploy_key -N "codevertex"
```
# Add public key to Contabo via control panel or API
# Store private key in GitHub secret: SSH_PRIVATE_KEY

---

3. Initial Server Setup
-----------------------

SSH into your VPS and run:

```bash
# Update system
apt-get update && apt-get upgrade -y

# Install essential tools
apt-get install -y \
  curl \
  wget \
  git \
  vim \
  htop \
  ca-certificates \
  gnupg \
  lsb-release \
  software-properties-common \
  apt-transport-https

# Disable swap (required for Kubernetes)
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Load kernel modules
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Set sysctl params
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

# Set timezone
timedatectl set-timezone UTC

# Set hostname
hostnamectl set-hostname k8s-master

# Configure firewall
ufw allow 22/tcp       # SSH
ufw allow 80/tcp       # HTTP
ufw allow 443/tcp      # HTTPS
ufw allow 6443/tcp     # Kubernetes API
ufw allow 2379:2380/tcp # etcd
ufw allow 10250/tcp    # Kubelet
ufw allow 10251/tcp    # kube-scheduler
ufw allow 10252/tcp    # kube-controller
ufw allow 10255/tcp    # Read-only Kubelet
ufw --force enable
```

---

4. Container Runtime (containerd)
---------------------------------

```bash
# Add Docker repository (for containerd)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install containerd
apt-get update
apt-get install -y containerd.io

# Configure containerd
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml

# Enable SystemdCgroup
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Restart containerd
systemctl restart containerd
systemctl enable containerd

# Verify
systemctl status containerd
```

---

5. Kubernetes Installation (kubeadm)
------------------------------------

```bash
# Add Kubernetes repository (using latest stable v1.30 for Ubuntu 24.04)
KUBERNETES_VERSION="1.30"
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list

# Install Kubernetes components
apt-get update
apt-get install -y kubelet kubeadm kubectl

# Hold versions (prevent auto-upgrade)
apt-mark hold kubelet kubeadm kubectl

# Enable kubelet
systemctl enable --now kubelet

# Verify versions
kubeadm version
kubelet --version
kubectl version --client
```

**Note:** Ubuntu 24.04 LTS supports Kubernetes 1.30+. The above uses v1.30 which is compatible with Ubuntu 24.04's kernel (6.8) and toolchain.

---

6. Cluster Initialization
-------------------------

```bash
# Initialize cluster (Ubuntu 24.04 compatible)
CLUSTER_NAME="mss-prod"
POD_NETWORK_CIDR="192.168.0.0/16"
APISERVER_ADVERTISE_ADDRESS=$(hostname -I | awk '{print $1}')

kubeadm init \
  --pod-network-cidr="${POD_NETWORK_CIDR}" \
  --apiserver-advertise-address="${APISERVER_ADVERTISE_ADDRESS}" \
  --kubernetes-version="v1.30.0"

# The output will show a join command for worker nodes (save this!)
# For single-node setup, we'll taint the master to allow pods

# Configure kubectl for root
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# Verify cluster
kubectl get nodes
# Should show master node in NotReady state (needs CNI)

# Allow pods on master node (single-node setup)
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

### Configure kubectl on VPS

```bash
# Configure kubectl for root user
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# Also configure for ubuntu user if it exists
if id "ubuntu" &>/dev/null; then
    mkdir -p /home/ubuntu/.kube
    cp -i /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
    chown -R ubuntu:ubuntu /home/ubuntu/.kube
fi
```

### Get kubeconfig for Remote Access

**On VPS:**

```bash
# Update kubeconfig with public IP (replace YOUR_VPS_IP with actual IP)
VPS_IP="YOUR_VPS_IP"
sed -i "s|server: https://.*:6443|server: https://${VPS_IP}:6443|" $HOME/.kube/config

# Get base64-encoded kubeconfig for GitHub secret
cat $HOME/.kube/config | base64 -w 0 2>/dev/null || cat $HOME/.kube/config | base64
```

**Copy the entire base64 output** - you'll need it for GitHub secrets.

**On local machine (optional):**

```bash
# Save kubeconfig to local file
vim ~/.kube/contabo-kubeadm-config
# Paste the kubeconfig content (with updated server IP)

# Test connection
export KUBECONFIG=~/.kube/contabo-kubeadm-config
kubectl get nodes
```

### Store Kubeconfig in GitHub Secret

1. Go to GitHub → Settings → Secrets and variables → Actions
2. Add new secret: `KUBE_CONFIG`
3. Paste the base64-encoded kubeconfig from above
4. Save

**See:** `docs/github-secrets.md` for complete secret configuration guide

---

7. Pod Network (Calico CNI)
---------------------------

```bash
# Check if Calico is already installed
if kubectl get pods -n calico-system >/dev/null 2>&1; then
    echo "✓ Calico CNI already installed"
    kubectl get pods -n calico-system
else
    # Install Calico operator (latest version compatible with Kubernetes 1.30)
    kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml

    # Wait for operator to be ready
    kubectl wait --for=condition=available --timeout=120s deployment/tigera-operator -n tigera-operator || true

    # Install Calico custom resources
    kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/custom-resources.yaml

    # Wait for Calico pods to be ready
    echo "Waiting for Calico pods to be ready..."
    sleep 30
    for i in {1..30}; do
        if kubectl get pods -n calico-system | grep -q Running; then
            break
        fi
        echo "  Waiting for Calico... (${i}/30)"
        sleep 5
    done
fi

# Verify node is Ready
kubectl get nodes
# Should show: k8s-master   Ready    control-plane   5m   v1.30.x
```

### Configure etcd Auto-Compaction (Prevent Space Issues)

**IMPORTANT:** Configure automatic compaction to prevent `etcdserver: mvcc: database space exceeded` errors:

```bash
# Backup original etcd manifest
cp /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/manifests/etcd.yaml.backup

# Edit etcd manifest to add auto-compaction flags
vim /etc/kubernetes/manifests/etcd.yaml
```

Add these flags to the etcd container command section:

```yaml
spec:
  containers:
  - command:
    - etcd
    - --auto-compaction-mode=revision
    - --auto-compaction-retention=1000  # Keep last 1000 revisions
    - --quota-backend-bytes=8589934592  # 8GB quota (adjust based on disk size)
```

**Note:** kubelet will automatically reload the manifest. The etcd pod will restart with the new configuration.

**Verify etcd pod restarts:**
```bash
kubectl get pods -n kube-system -l component=etcd --watch
```

**See:** `docs/ETCD-OPTIMIZATION.md` for detailed etcd optimization guide and troubleshooting

### Alternative: Flannel CNI (lighter)

```bash
# If you prefer Flannel (uses less resources)
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

---

8. NGINX Ingress Controller
---------------------------

```bash
# Install NGINX Ingress Controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/cloud/deploy.yaml

# Wait for deployment
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

# Check service
kubectl get svc -n ingress-nginx

# For single-node VPS, patch to use hostNetwork
kubectl patch deployment ingress-nginx-controller \
  -n ingress-nginx \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/hostNetwork", "value": true}]'

# Verify
kubectl get pods -n ingress-nginx
```

---

9. cert-manager
---------------

```bash
# Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Wait for pods
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/instance=cert-manager \
  -n cert-manager \
  --timeout=120s

# Create Let's Encrypt ClusterIssuer
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: info@codevertexitsolutions.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
EOF

# Verify
kubectl get clusterissuer
```

---

10. Verification
----------------

### Verify Kubernetes Cluster

```bash
# Check nodes (should show Ready status)
kubectl get nodes
# Should show: k8s-master   Ready    control-plane   <time>   v1.30.x

# Check all system pods (should all be Running)
kubectl get pods -A

# Check component status
kubectl get cs
```

### Test Remote Access

From your local machine (with kubeconfig configured):

```bash
# Set kubeconfig
export KUBECONFIG=~/.kube/contabo-kubeadm-config

# Test connection
kubectl get nodes
kubectl get pods -A
```

### Troubleshooting

**Issue: Node Not Ready**

```bash
# Check kubelet status
systemctl status kubelet

# Check kubelet logs
journalctl -u kubelet -f

# Check Calico pods
kubectl get pods -n calico-system
kubectl logs -n calico-system -l k8s-app=calico-node
```

**Issue: Cannot Connect to Cluster Remotely**

1. Verify firewall allows port 6443:
   ```bash
   ufw status
   ```

2. Verify kubeconfig server address matches VPS IP:
   ```bash
   kubectl config view | grep server
   ```

3. Test connectivity:
   ```bash
   curl -k https://YOUR_VPS_IP:6443
   ```

**Issue: etcd Database Space Exceeded**

If you encounter `etcdserver: mvcc: database space exceeded`:

```bash
# Run etcd space fix script (if available)
./scripts/cluster/fix-etcd-space.sh

# Or manually compact etcd
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  compact $(date +%s)
```

**Prevention:** Configure automatic compaction during cluster setup (see Step 7 above). See `docs/ETCD-OPTIMIZATION.md` for detailed instructions.

---

## Next Steps

After completing cluster setup and configuring GitHub secrets:

### 1. Configure GitHub Secrets

See `docs/github-secrets.md` for complete secret configuration guide. Required:
- `KUBE_CONFIG` - Base64-encoded kubeconfig
- Optional: Contabo API secrets for automated VPS management

### 2. Run Automated Provisioning Workflow

1. Go to: `https://github.com/YOUR_ORG/devops-k8s/actions`
2. Select: **"Provision Cluster Infrastructure"**
3. Click: **"Run workflow"** → **"Run workflow"**

The workflow will automatically install:
- Storage provisioner
- PostgreSQL & Redis (shared infrastructure)
- RabbitMQ (shared infrastructure)
- NGINX Ingress Controller
- cert-manager
- Argo CD
- Monitoring stack (Prometheus + Grafana)
- Vertical Pod Autoscaler (VPA)

**See:** `docs/provisioning.md` for detailed provisioning workflow documentation

### 3. Configure DNS (Optional but Recommended)

Point your domains to your VPS IP:
- `argocd.masterspace.co.ke` → YOUR_VPS_IP
- `grafana.masterspace.co.ke` → YOUR_VPS_IP
- `erpapi.masterspace.co.ke` → YOUR_VPS_IP
- `erp.masterspace.co.ke` → YOUR_VPS_IP

cert-manager will automatically provision TLS certificates.

### 4. Verify Infrastructure

```bash
# Check infrastructure pods
kubectl get pods -n infra
kubectl get pods -n argocd

# Check ingresses
kubectl get ingress -A

# Check certificates
kubectl get certificate -A
```

### 5. Access Services

**Argo CD:**
- URL: `https://argocd.masterspace.co.ke`
- Get admin password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`

**Grafana:**
- URL: `https://grafana.masterspace.co.ke`
- Get admin password: `kubectl get secret -n infra prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 -d`

### 6. Deploy Applications

Applications are automatically deployed via Argo CD if `apps/*/app.yaml` files exist.

To verify:
```bash
kubectl get applications -n argocd
```

To deploy manually:
```bash
kubectl apply -f apps/root-app.yaml
```

---

## Related Documentation

**Setup Workflow (Follow in Order):**
1. **Access Setup:** [Comprehensive Access Setup](./comprehensive-access-setup.md) - Manual access configuration (SSH, GitHub PAT)
2. **Cluster Setup:** [Cluster Setup Workflow](./CLUSTER-SETUP-WORKFLOW.md) - Complete workflow guide
3. **Provisioning:** [Provisioning Guide](./provisioning.md) - Automated infrastructure provisioning

**Quick Reference:**
- [Quick Setup Guide](../SETUP.md) - Fast-track deployment guide
- [GitHub Secrets](./github-secrets.md) - Complete secret configuration
- [etcd Optimization](./ETCD-OPTIMIZATION.md) - Prevent etcd space issues

**Infrastructure:**
- [Database Setup](./database-setup.md) - Database configuration details
- [Argo CD Setup](./argocd.md) - Argo CD configuration
- [Monitoring Setup](./monitoring.md) - Monitoring stack details

---

## Support

- Documentation: `docs/README.md`
- Issues: GitHub Issues
- Contact: codevertexitsolutions@gmail.com
- Website: https://www.codevertexitsolutions.com

# Deploy test app
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-world
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hello
  template:
    metadata:
      labels:
        app: hello
    spec:
      containers:
      - name: hello
        image: gcr.io/google-samples/hello-app:1.0
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: hello-world
spec:
  selector:
    app: hello
  ports:
  - port: 80
    targetPort: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello-world
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - test.masterspace.co.ke
    secretName: hello-tls
  rules:
  - host: test.masterspace.co.ke
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: hello-world
            port:
              number: 80
EOF

# Wait and test
kubectl wait --for=condition=available deployment/hello-world --timeout=60s
curl https://test.masterspace.co.ke
```

---

Cluster Maintenance
-------------------

### Upgrade Kubernetes

```bash
# Check available versions
apt-cache madison kubeadm

# Upgrade kubeadm (Ubuntu 24.04 compatible)
apt-mark unhold kubeadm
apt-get update && apt-get install -y kubeadm=1.30.x-00
apt-mark hold kubeadm

# Plan upgrade
kubeadm upgrade plan

# Apply upgrade
kubeadm upgrade apply v1.30.x

# Upgrade kubelet and kubectl
apt-mark unhold kubelet kubectl
apt-get update && apt-get install -y kubelet=1.30.x-00 kubectl=1.30.x-00
apt-mark hold kubelet kubectl

# Restart kubelet
systemctl daemon-reload
systemctl restart kubelet
```

### Backup etcd

```bash
# Install etcdctl
ETCD_VERSION=v3.5.9
wget https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz
tar xzf etcd-${ETCD_VERSION}-linux-amd64.tar.gz
mv etcd-${ETCD_VERSION}-linux-amd64/etcdctl /usr/local/bin/
rm -rf etcd-${ETCD_VERSION}-linux-amd64*

# Backup etcd
mkdir -p /backup

ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /backup/etcd-snapshot-$(date +%Y%m%d).db

# Verify backup
ETCDCTL_API=3 etcdctl snapshot status /backup/etcd-snapshot-*.db
```

---

Troubleshooting
---------------

### Pods stuck in Pending

```bash
kubectl describe pod POD_NAME
kubectl get events -A --sort-by='.lastTimestamp'
```

### Node NotReady

```bash
kubectl describe node
journalctl -u kubelet -f
```

### Networking issues

```bash
# Check Calico
kubectl get pods -n calico-system
kubectl logs -n calico-system -l k8s-app=calico-node

# Check kube-proxy
kubectl get pods -n kube-system -l k8s-app=kube-proxy
```

### Reset cluster (caution!)

```bash
kubeadm reset
rm -rf /etc/cni/net.d
rm -rf $HOME/.kube/config
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
```

---

Resource Monitoring
-------------------

```bash
# Node resources
kubectl top nodes

# Pod resources
kubectl top pods -A

# System resources
htop
free -h
df -h

# Kubelet logs
journalctl -u kubelet -f
```

---

## Next Steps

After cluster setup:
1. Copy the base64 kubeconfig output from the setup script
2. Add it as GitHub organization secret: `KUBE_CONFIG`
3. Run automated provisioning workflow (see `docs/provisioning.md`)
4. Deploy ERP apps: `kubectl apply -f apps/erp-api/app.yaml`

**Complete Workflow:**
- **[Cluster Setup Workflow](./CLUSTER-SETUP-WORKFLOW.md)** ⚙️ - Complete workflow guide
- **[Provisioning Guide](./provisioning.md)** 🚀 - Infrastructure provisioning

