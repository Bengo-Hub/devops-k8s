# Complete Deployment Access Setup Guide

## Overview

This comprehensive guide provides all the information needed to set up access for the BengoERP deployment pipeline. It covers GitHub authentication, SSH access, Kubernetes configuration, and Contabo VPS setup.

## Table of Contents

1. [GitHub Access Setup](#1-github-access-setup)
2. [SSH Key Configuration](#2-ssh-key-configuration)
3. [Kubernetes Access Setup](#3-kubernetes-access-setup)
4. [Contabo API Setup](#4-contabo-api-setup)
5. [Testing and Verification](#5-testing-and-verification)
6. [Troubleshooting](#6-troubleshooting)
7. [Security Best Practices](#7-security-best-practices)

## 1. GitHub Access Setup

### 1.1 Create GitHub Personal Access Token

1. **Navigate to GitHub Settings:**
   - Go to GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)

2. **Generate New Token:**
   - Click "Generate new token (classic)"
   - Name: `BengoERP DevOps K8s Access`
   - Expiration: "No expiration" (or set a long duration)
   - Scopes: Select these permissions:
     - `repo` (Full control of private repositories)
     - `workflow` (Update GitHub Action workflows)
     - `admin:org` (Full control of organizations and teams)

3. **Store Token Securely:**
   - Copy the token immediately (it won't be shown again)
   - Store in a secure password manager

### 1.2 Repository-Specific Secrets Setup

For the ERP UI repository (`bengobox-erpi-ui`), add these repository secrets in GitHub:

**Go to Repository → Settings → Secrets and variables → Actions**

Add these secrets:

| Secret Name | Description | Source |
|-------------|-------------|---------|
| `DEVOPS_K8S_ACCESS_TOKEN` | GitHub PAT for devops repo access | Generated above |
| `DOCKER_SSH_KEY` | Base64-encoded SSH private key for Docker builds (optional) | Generate SSH key pair |
| `KUBE_CONFIG` | Base64-encoded kubeconfig for Kubernetes access | From VPS kubeconfig |
| `REGISTRY_USERNAME` | Docker Hub username | `codevertex` |
| `REGISTRY_PASSWORD` | Docker Hub access token | From Docker Hub |
| `SSH_PRIVATE_KEY` | Base64-encoded SSH private key for VPS access | From SSH key pair |
| `GIT_USER` | Git username | `Titus Owuor` |
| `GIT_EMAIL` | Git email | `titusowuor30@gmail.com` |
| `GITHUB_TOKEN` | Fallback GitHub token | Same as DEVOPS_K8S_ACCESS_TOKEN |

## 2. SSH Key Configuration

### 2.1 Generate SSH Key Pair for VPS Access

```bash
# On your local machine
ssh-keygen -t ed25519 -C "devops@codevertex" -f ~/.ssh/contabo_deploy_key -N "codevertex"
```
# This creates:
# - ~/.ssh/contabo_deploy_key (private key)
# - ~/.ssh/contabo_deploy_key.pub (public key)

### 2.2 Add Public Key to Contabo VPS

#### Option A: Via Contabo Control Panel (Recommended)

1. **Login to Contabo:**
   - Go to https://my.contabo.com
   - Select your VPS instance

2. **Add SSH Key:**
   - Go to "Access" tab
   - Click "Add SSH Key"
   - Paste the contents of `~/.ssh/contabo_deploy_key.pub`
   - Save

#### Option B: Manual Setup (After First Login)

```bash
# SSH into server with password (first time only)
ssh root@YOUR_VPS_IP

# Create .ssh directory
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Add your public key
echo "YOUR_PUBLIC_KEY_CONTENT" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# Disable password authentication (optional, for security)
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd
```

### 2.3 Test SSH Connection

```bash
# Test the SSH connection
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP

# Expected: Successful login without password prompt
```

### 2.4 Base64 Encode Private Key for GitHub Secret

```bash
# Base64 encode the private key for GitHub secret
cat ~/.ssh/contabo_deploy_key | base64 -w 0

# Or for multi-line output:
cat ~/.ssh/contabo_deploy_key | base64
```

## 3. Kubernetes Access Setup

### 3.1 Get Kubeconfig from VPS

```bash
# SSH into VPS
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP

# Get kubeconfig (k3s location)
cat /etc/rancher/k3s/k3s.yaml

# Or for kubeadm:
cat /etc/kubernetes/admin.conf
```

### 3.2 Update Kubeconfig Server URL

**Important:** The kubeconfig contains a local server URL that needs updating:

```bash
# Edit the kubeconfig file
sed -i 's/https:\/\/127.0.0.1:6443/https:\/\/YOUR_VPS_IP:6443/g' kubeconfig.yaml

# Re-encode for GitHub secret
cat kubeconfig.yaml | base64 -w 0
```

### 3.3 Test Kubernetes Access

```bash
# Set up test kubeconfig
export KUBE_CONFIG="$(cat kubeconfig.yaml | base64 -w 0)"
echo "$KUBE_CONFIG" | base64 -d > /tmp/test-kubeconfig
export KUBECONFIG=/tmp/test-kubeconfig

# Test connection
kubectl get nodes
kubectl get namespaces
```

## 4. Contabo API Setup

### 4.1 Create Contabo API Credentials

1. **Login to Contabo Control Panel:**
   - Go to https://my.contabo.com
   - Navigate to Account → Security

2. **Create OAuth2 Client:**
   - Click "Create OAuth2 Client"
   - Note down the `Client ID` and `Client Secret`

3. **API User Credentials:**
   - Use your Contabo username and password (same as web login)

### 4.2 Test API Access

```bash
# Get OAuth token
curl -X POST https://auth.contabo.com/oauth2/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=password&username=YOUR_USERNAME&password=YOUR_PASSWORD&client_id=CLIENT_ID&client_secret=CLIENT_SECRET&scope=openid"

# Test instance access
curl -H "Authorization: Bearer ACCESS_TOKEN" \
  https://api.contabo.com/v1/compute/instances
```

### 4.3 Store API Credentials in GitHub

Add these **organization-level** secrets:

| Secret Name | Description |
|-------------|-------------|
| `CONTABO_CLIENT_ID` | OAuth2 client ID |
| `CONTABO_CLIENT_SECRET` | OAuth2 client secret |
| `CONTABO_API_USERNAME` | Contabo username |
| `CONTABO_API_PASSWORD` | Contabo password |

**Note:** Organization-level secrets are accessed using `${{ secrets.SECRET_NAME }}` in GitHub Actions workflows, just like repository secrets.

## 5. Testing and Verification

### 5.1 Complete Access Test Script

```bash
#!/bin/bash
# Complete Access Verification Script

echo "=== BengoERP Deployment Access Test ==="

# Test SSH Access
echo "1. Testing SSH access..."
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP "echo 'SSH: OK'" || {
    echo "SSH: FAILED"
    exit 1
}

# Test Docker
echo "2. Testing Docker..."
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP "docker --version" || {
    echo "Docker: FAILED"
    exit 1
}

# Test Kubernetes
echo "3. Testing Kubernetes..."
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP "kubectl get nodes" || {
    echo "Kubernetes: FAILED"
    exit 1
}

# Test GitHub Token
echo "4. Testing GitHub token..."
curl -H "Authorization: Bearer $GITHUB_TOKEN" \
  https://api.github.com/repos/Bengo-Hub/devops-k8s > /dev/null || {
    echo "GitHub Token: FAILED"
    exit 1
}

# Test Kubernetes External Access
echo "5. Testing external K8s access..."
echo "$KUBE_CONFIG" | base64 -d > /tmp/test-kubeconfig
export KUBECONFIG=/tmp/test-kubeconfig
kubectl get nodes > /dev/null || {
    echo "External K8s: FAILED"
    exit 1
}

echo "=== All access tests PASSED! ==="
```

### 5.2 Manual Testing Steps

Run these tests in order:

1. **SSH Access:** `ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP`
2. **VPS Services:** Check Docker and Kubernetes are running
3. **GitHub Token:** `curl -H "Authorization: Bearer TOKEN" https://api.github.com/user`
4. **Kubernetes Access:** `kubectl get nodes` with external kubeconfig
5. **Contabo API:** Generate OAuth token and list instances

## 6. Troubleshooting

### 6.1 SSH Issues

**Problem:** `ssh: connect to host YOUR_VPS_IP port 22: Connection refused`

**Solutions:**
```bash
# Check VPS reachability
ping YOUR_VPS_IP

# Check SSH service on VPS
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP "systemctl status ssh"

# Check firewall
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP "ufw status"
```

### 6.2 GitHub Token Issues

**Problem:** `git@github.com: Permission denied (publickey)` or `401 Unauthorized`

**Solutions:**
```bash
# Test token validity
curl -H "Authorization: Bearer YOUR_TOKEN" https://api.github.com/user

# Check repository access
curl -H "Authorization: Bearer YOUR_TOKEN" \
  https://api.github.com/repos/Bengo-Hub/devops-k8s

# Verify token scopes include 'repo'
```

### 6.3 Kubernetes Access Issues

**Problem:** `Unable to connect to the server`

**Solutions:**
```bash
# Check kubeconfig server URL
kubectl config view | grep server

# Test direct API access
curl -k https://YOUR_VPS_IP:6443/healthz

# Verify API server is running
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP "systemctl status k3s"
```

### 6.4 Contabo API Issues

**Problem:** `401 Unauthorized`

**Solutions:**
```bash
# Test token generation
curl -X POST https://auth.contabo.com/oauth2/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=password&username=USER&password=PASS&client_id=ID&client_secret=SECRET&scope=openid"
```

## 7. Security Best Practices

### 7.1 Token Management

- **Rotate tokens regularly** (every 90 days)
- **Use least privilege** - only grant necessary permissions
- **Monitor token usage** via GitHub audit logs
- **Store tokens securely** - use GitHub organization secrets

### 7.2 SSH Key Security

- **Use Ed25519 keys** (stronger than RSA)
- **Rotate SSH keys** regularly
- **Disable password authentication** on VPS
- **Use unique keys** for different purposes

### 7.3 Network Security

- **Configure firewalls** properly on VPS
- **Use VPN** for sensitive operations when possible
- **Monitor access logs** regularly
- **Keep systems updated**

### 7.4 Kubernetes Security

- **Secure kubeconfig** storage and transmission
- **Use RBAC** for access control
- **Regular security audits** of cluster
- **Monitor cluster access** logs

## 8. Maintenance

### 8.1 Regular Updates

```bash
# Update system packages
apt-get update && apt-get upgrade -y

# Update k3s
curl -sfL https://get.k3s.io | sh -

# Update Docker
apt-get update && apt-get install docker-ce docker-ce-cli containerd.io
```

### 8.2 Monitor Resource Usage

```bash
# System resources
htop
df -h
free -h

# Kubernetes resources
kubectl top nodes
kubectl top pods -A
```

### 8.3 Backup Important Data

```bash
# Kubernetes resources
kubectl get all --all-namespaces -o yaml > k8s-backup.yaml

# etcd backup (k3s)
cp /var/lib/rancher/k3s/server/db/state.db /backup/k3s-state.db
```

## 9. Support and Resources

### 9.1 Documentation References

- [Contabo Setup Guide](./contabo-setup.md)
- [Comprehensive Access Setup](./comprehensive-access-setup.md)
- [VPS Access Testing Guide](./vps-access-testing-guide.md)

### 9.2 Getting Help

- **Email:** codevertexitsolutions@gmail.com
- **Website:** https://www.codevertexitsolutions.com
- **GitHub Issues:** Create issues in relevant repositories

### 9.3 Emergency Contacts

For urgent deployment issues:
- Check GitHub Actions logs for detailed error messages
- Verify all secrets are properly configured in GitHub
- Test individual components using the testing guides above
- Contact support if systematic issues persist

---

This guide ensures complete setup of all access requirements for the BengoERP deployment pipeline. Follow each section carefully and test thoroughly before deploying to production.
