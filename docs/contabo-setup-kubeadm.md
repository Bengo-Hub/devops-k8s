Contabo VPS Setup with Full Kubernetes (kubeadm)
================================================

This guide walks through setting up a Contabo VPS with full Kubernetes using kubeadm instead of k3s.

**Note:** For resource-constrained VPS (4-8GB RAM), consider k3s instead. See `k8s-comparison.md` for guidance.

Prerequisites
-------------
- Contabo VPS with 4GB+ RAM (8GB+ recommended)
- Ubuntu 22.04 LTS
- Root or sudo access
- Contabo client ID and secret (for API automation)

Table of Contents
-----------------
1. Contabo API Setup
2. SSH Key Configuration
3. Initial Server Setup
4. Container Runtime (containerd)
5. Kubernetes Installation (kubeadm)
6. Cluster Initialization
7. Pod Network (Calico CNI)
8. NGINX Ingress Controller
9. cert-manager
10. Verification

---

1. Contabo API Setup
--------------------

(Same as k3s guide - see `contabo-setup.md` section 1)

Store these as GitHub org secrets:
- `CONTABO_CLIENT_ID`
- `CONTABO_CLIENT_SECRET`
- `CONTABO_API_USERNAME`
- `CONTABO_API_PASSWORD`

---

2. SSH Key Configuration
------------------------

(Same as k3s guide - see `contabo-setup.md` section 2)

```bash
# Generate SSH key
ssh-keygen -t ed25519 -C "devops@codevertex" -f ~/.ssh/contabo_deploy_key -N ""

# Add public key to Contabo via control panel or API
# Store private key in GitHub secret: SSH_PRIVATE_KEY
```

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
# Add Kubernetes repository
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list

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

---

6. Cluster Initialization
-------------------------

```bash
# Initialize cluster
kubeadm init \
  --pod-network-cidr=192.168.0.0/16 \
  --apiserver-advertise-address=$(hostname -I | awk '{print $1}')

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

### Get kubeconfig for remote access

```bash
# On VPS, get kubeconfig
cat /etc/kubernetes/admin.conf

# On local machine, save to file
# Replace server: https://INTERNAL_IP with your VPS public IP
vim ~/.kube/contabo-kubeadm-config

# Update server address
sed -i 's|server: https://.*:6443|server: https://YOUR_VPS_IP:6443|' ~/.kube/contabo-kubeadm-config

# Test
export KUBECONFIG=~/.kube/contabo-kubeadm-config
kubectl get nodes
```

### Store Kubeconfig in GitHub Secret

```bash
# Base64 encode kubeconfig (with updated server IP)
cat ~/.kube/contabo-kubeadm-config | base64 -w 0
```

Store as GitHub org secret: `KUBE_CONFIG`

---

7. Pod Network (Calico CNI)
---------------------------

```bash
# Install Calico operator
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/tigera-operator.yaml

# Install Calico custom resources
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/custom-resources.yaml

# Wait for Calico pods
watch kubectl get pods -n calico-system

# Verify node is Ready
kubectl get nodes
# Should show: k8s-master   Ready    control-plane   5m   v1.28.x
```

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

```bash
# Check all system pods
kubectl get pods -A

# Check nodes
kubectl get nodes -o wide

# Check component status
kubectl get cs

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

# Upgrade kubeadm
apt-mark unhold kubeadm
apt-get update && apt-get install -y kubeadm=1.28.x-00
apt-mark hold kubeadm

# Plan upgrade
kubeadm upgrade plan

# Apply upgrade
kubeadm upgrade apply v1.28.x

# Upgrade kubelet and kubectl
apt-mark unhold kubelet kubectl
apt-get update && apt-get install -y kubelet=1.28.x-00 kubectl=1.28.x-00
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

Comparison with k3s
-------------------

See `docs/k8s-comparison.md` for detailed comparison and recommendation.

**kubeadm advantages:**
- Full upstream Kubernetes
- Better for multi-node
- More control over components

**kubeadm disadvantages:**
- Higher resource usage (~2GB overhead)
- More complex setup and maintenance
- Longer installation time

---

Next Steps
----------

After cluster setup:
1. Install Argo CD: `scripts/install-argocd.sh`
2. Install monitoring: `scripts/install-monitoring.sh`
3. Deploy ERP apps: `kubectl apply -f apps/erp-api/app.yaml`

All other guides (Argo CD, monitoring, etc.) work the same with kubeadm as with k3s.

