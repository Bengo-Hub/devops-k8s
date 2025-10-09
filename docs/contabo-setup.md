Contabo VPS Setup Guide
=======================

This guide walks through setting up a Contabo VPS for Kubernetes deployments, including SSH keys, Docker, and K8s installation.

Prerequisites
-------------
- Contabo VPS instance (4GB+ RAM recommended for K8s)
- Contabo client ID and secret
- Contabo API username and password
- Local SSH client

Table of Contents
-----------------
1. Contabo API Setup
2. SSH Key Configuration
3. Initial Server Setup
4. Docker Installation
5. Kubernetes Installation (k3s)
6. NGINX Ingress Controller
7. cert-manager
8. Verification

---

1. Contabo API Setup
--------------------

### Get API Credentials

1. Login to https://my.contabo.com
2. Navigate to Account > Security
3. Create OAuth2 Client:
   - Click "Create OAuth2 Client"
   - Note down `Client ID` and `Client Secret`
4. API User Credentials:
   - Use your Contabo username and password
   - Store these as GitHub org secrets

### Test API Access

```bash
# Get OAuth token
curl -X POST https://auth.contabo.com/oauth2/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=password&username=YOUR_USERNAME&password=YOUR_PASSWORD&client_id=CLIENT_ID&client_secret=CLIENT_SECRET&scope=openid"

# Example response
{
  "access_token": "eyJhbGc...",
  "expires_in": 3600,
  "token_type": "Bearer"
}

# List instances
curl -H "Authorization: Bearer ACCESS_TOKEN" \
  https://api.contabo.com/v1/compute/instances
```

### Store in GitHub Secrets

Organization-level secrets:
- `CONTABO_CLIENT_ID`
- `CONTABO_CLIENT_SECRET`
- `CONTABO_API_USERNAME`
- `CONTABO_API_PASSWORD`

---

2. SSH Key Configuration
------------------------

### Generate SSH Key Pair

```bash
# On your local machine
ssh-keygen -t ed25519 -C "devops@codevertex" -f ~/.ssh/contabo_deploy_key -N ""

# This creates:
# - ~/.ssh/contabo_deploy_key (private key)
# - ~/.ssh/contabo_deploy_key.pub (public key)
```

### Add Public Key to Contabo VPS

#### Option A: Via Contabo Control Panel
1. Login to https://my.contabo.com
2. Select your instance
3. Go to "Access" tab
4. Click "Add SSH Key"
5. Paste contents of `~/.ssh/contabo_deploy_key.pub`
6. Save

#### Option B: Via API (Advanced)
```bash
# Get instance ID
INSTANCE_ID=$(curl -H "Authorization: Bearer ACCESS_TOKEN" \
  https://api.contabo.com/v1/compute/instances | jq -r '.data[0].instanceId')

# Upload SSH key (Note: Contabo API doesn't directly support SSH key upload,
# use control panel or manual method below)
```

#### Option C: Manual (After First Login)
```bash
# SSH into server with password (first time)
ssh root@YOUR_VPS_IP

# Create .ssh directory if not exists
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Add your public key
echo "YOUR_PUBLIC_KEY_CONTENT" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# Disable password auth (optional, for security)
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd
```

### Test SSH Connection

```bash
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP
```

### Store Private Key in GitHub Secrets

```bash
# Base64 encode (for GitHub secret)
cat ~/.ssh/contabo_deploy_key | base64 -w 0

# Or without encoding (paste content directly)
cat ~/.ssh/contabo_deploy_key
```

Store as GitHub org secret: `SSH_PRIVATE_KEY`

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
  software-properties-common

# Set timezone
timedatectl set-timezone UTC

# Set hostname
hostnamectl set-hostname erp-k8s-prod

# Configure firewall
ufw allow 22/tcp    # SSH
ufw allow 80/tcp    # HTTP
ufw allow 443/tcp   # HTTPS
ufw allow 6443/tcp  # Kubernetes API
ufw --force enable
```

---

4. Docker Installation
----------------------

### Install Docker

```bash
# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Set up repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Start Docker
systemctl enable docker
systemctl start docker

# Verify
docker run hello-world
```

### Configure Docker (Optional)

```bash
# Create daemon.json for optimization
cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
EOF

systemctl restart docker
```

### Docker Login (for Private Registries)

```bash
# Login to Docker Hub
docker login -u codevertex -p YOUR_DOCKER_TOKEN

# Or store credentials
echo "YOUR_DOCKER_TOKEN" | docker login -u codevertex --password-stdin
```

---

5. Kubernetes Installation (k3s)
--------------------------------

We use k3s for lightweight K8s on single-node VPS.

### Install k3s

```bash
# Install k3s with Traefik disabled (we'll use NGINX)
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -

# Wait for node to be ready
kubectl wait --for=condition=Ready node --all --timeout=300s

# Verify
kubectl get nodes
kubectl get pods -A
```

### Configure kubectl Access

```bash
# Get kubeconfig
cat /etc/rancher/k3s/k3s.yaml

# For local kubectl access, copy to your machine:
# Replace 127.0.0.1 with your VPS IP
scp -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP:/etc/rancher/k3s/k3s.yaml ~/.kube/contabo-config
sed -i 's/127.0.0.1/YOUR_VPS_IP/g' ~/.kube/contabo-config

# Use it
export KUBECONFIG=~/.kube/contabo-config
kubectl get nodes
```

### Store Kubeconfig in GitHub Secret

```bash
# Base64 encode kubeconfig
cat /etc/rancher/k3s/k3s.yaml | base64 -w 0
```

Store as GitHub org secret: `KUBE_CONFIG`

---

6. NGINX Ingress Controller
---------------------------

```bash
# Install NGINX Ingress
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/cloud/deploy.yaml

# Wait for deployment
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

# Verify
kubectl get svc -n ingress-nginx
```

### Configure External IP (Contabo)

k3s with NGINX ingress on Contabo typically uses NodePort or HostNetwork.

```bash
# Check ingress service
kubectl get svc -n ingress-nginx ingress-nginx-controller

# If using NodePort, note the ports (usually 80:3xxxx, 443:3xxxx)
# Point your DNS to VPS_IP:NodePort or configure firewall forwarding

# Alternative: Patch to use HostNetwork
kubectl patch deployment ingress-nginx-controller \
  -n ingress-nginx \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/hostNetwork", "value": true}]'
```

---

7. cert-manager
---------------

Install cert-manager for automatic TLS certificates.

```bash
# Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Wait for pods
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/instance=cert-manager \
  -n cert-manager \
  --timeout=120s

# Create ClusterIssuer for Let's Encrypt
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
```

---

8. Verification
---------------

### Check All Components

```bash
# Nodes
kubectl get nodes

# System pods
kubectl get pods -n kube-system

# Ingress
kubectl get pods -n ingress-nginx

# cert-manager
kubectl get pods -n cert-manager

# Storage classes
kubectl get sc
```

### Deploy Test Application

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-world
  namespace: default
spec:
  replicas: 1
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

Automation via GitHub Actions
-----------------------------

The reusable workflow in this repo automates:
1. Contabo API: Fetch instance IP, ensure it's running
2. SSH Deploy: Connect and pull/run Docker images
3. Kube Secret Apply: If KUBE_CONFIG provided

Example workflow usage in `bengobox-erp-api/.github/workflows/deploy.yml`:
```yaml
jobs:
  deploy:
    uses: codevertex/devops-k8s/.github/workflows/reusable-build-deploy.yml@main
    with:
      app_name: erp-api
      provider: contabo
      contabo_api: true
      contabo_instance_id: YOUR_INSTANCE_ID
      deploy: true
      namespace: erp
    secrets:
      CONTABO_CLIENT_ID: ${{ secrets.CONTABO_CLIENT_ID }}
      CONTABO_CLIENT_SECRET: ${{ secrets.CONTABO_CLIENT_SECRET }}
      CONTABO_API_USERNAME: ${{ secrets.CONTABO_API_USERNAME }}
      CONTABO_API_PASSWORD: ${{ secrets.CONTABO_API_PASSWORD }}
      SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
      KUBE_CONFIG: ${{ secrets.KUBE_CONFIG }}
      REGISTRY_USERNAME: ${{ secrets.REGISTRY_USERNAME }}
      REGISTRY_PASSWORD: ${{ secrets.REGISTRY_PASSWORD }}
```

---

Troubleshooting
---------------

### SSH Connection Issues
```bash
# Test SSH connection
ssh -v -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP

# Check SSH logs on server
journalctl -u ssh -f
```

### Docker Issues
```bash
# Check Docker status
systemctl status docker

# View logs
journalctl -u docker -f
```

### Kubernetes Issues
```bash
# k3s logs
journalctl -u k3s -f

# Check node
kubectl describe node

# Check pods
kubectl get pods -A
kubectl describe pod POD_NAME -n NAMESPACE
```

### Contabo API Issues
```bash
# Test token generation
curl -X POST https://auth.contabo.com/oauth2/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=password&username=USER&password=PASS&client_id=ID&client_secret=SECRET&scope=openid" | jq

# List instances
curl -H "Authorization: Bearer TOKEN" https://api.contabo.com/v1/compute/instances | jq
```

---

Maintenance
-----------

### Update System Packages
```bash
apt-get update && apt-get upgrade -y
reboot  # if kernel updated
```

### Update k3s
```bash
curl -sfL https://get.k3s.io | sh -
```

### Backup Kubernetes Resources
```bash
# Export all resources
kubectl get all --all-namespaces -o yaml > k8s-backup.yaml

# Backup etcd (k3s uses SQLite by default)
cp /var/lib/rancher/k3s/server/db/state.db /backup/
```

### Monitor Resource Usage
```bash
# System
htop
df -h
free -h

# Kubernetes
kubectl top nodes
kubectl top pods -A
```

