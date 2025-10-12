# Comprehensive Access Setup Guide for BengoERP Deployment

## Overview

This guide provides step-by-step instructions for setting up all required access permissions and authentication methods needed for the BengoERP deployment pipeline to work successfully.

## Prerequisites

- Contabo VPS with Ubuntu/Debian-based system
- GitHub organization access with admin permissions
- Local machine with git, kubectl, and SSH client installed

## 1. GitHub Access Setup

### 1.1 Create GitHub Personal Access Token for DevOps Repository

1. **Create a Personal Access Token (PAT) with repository permissions:**

   - Go to GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)
   - Click "Generate new token (classic)"
   - Give it a descriptive name: `BengoERP DevOps K8s Access`
   - Set expiration to "No expiration" (or set a long duration)
   - Select these scopes:
     - `repo` (Full control of private repositories)
     - `workflow` (Update GitHub Action workflows)
     - `admin:org` (Full control of organizations and teams)

2. **Store the token securely** - Copy the token immediately as it won't be shown again.

3. **Add to GitHub Organization Secrets:**

   - Go to your GitHub organization → Settings → Secrets and variables → Actions
   - Click "New organization secret"
   - Name: `DEVOPS_K8S_ACCESS_TOKEN`
   - Value: Paste your personal access token

### 1.2 Repository-Specific Secrets

For the ERP UI repository (`bengobox-erpi-ui`), add these repository secrets:

- `DEVOPS_K8S_ACCESS_TOKEN` - The PAT created above
- `DOCKER_SSH_KEY` - Base64-encoded SSH private key for Docker builds (optional)
- `KUBE_CONFIG` - Base64-encoded kubeconfig for Kubernetes access
- `REGISTRY_USERNAME` - Docker Hub username (`codevertex`)
- `REGISTRY_PASSWORD` - Docker Hub access token
- `SSH_PRIVATE_KEY` - Base64-encoded SSH private key for VPS access
- `GIT_USER` - Your git username (`Titus Owuor`)
- `GIT_EMAIL` - Your git email (`titusowuor30@gmail.com`)

## 2. SSH Key Setup for Contabo VPS

### 2.1 Generate SSH Key Pair

**Important:** All SSH keys in this project use the default passphrase `"codevertex"` and are designed to work without requiring user input during automated deployments.

```bash
# On your local machine
ssh-keygen -t ed25519 -C "devops@codevertex" -f ~/.ssh/contabo_deploy_key -N "codevertex"
```

This creates:
- `~/.ssh/contabo_deploy_key` (private key)
- `~/.ssh/contabo_deploy_key.pub` (public key)

**Note:** The passphrase "codevertex" is used consistently across all SSH keys in this project for automated deployment scenarios.

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

# Create .ssh directory if it doesn't exist
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
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP
```

### 2.4 Store Private Key in GitHub Secrets

**Important:** All secrets must be stored at the **organization level**, not repository level, to ensure they are available across all repositories in the organization.

```bash
# Base64 encode the private key for GitHub secret
cat ~/.ssh/contabo_deploy_key | base64 -w 0
```

**Organization-level secrets to configure in GitHub:**

Add these **organization-level** secrets in your GitHub organization settings:

| Secret Name | Description | Source |
|-------------|-------------|---------|
| `DOCKER_SSH_KEY` | Base64-encoded SSH private key for Docker builds | Generated above |
| `KUBE_CONFIG` | Base64-encoded kubeconfig for Kubernetes access | From VPS kubeconfig |
| `REGISTRY_USERNAME` | Docker Hub username | `codevertex` |
| `REGISTRY_PASSWORD` | Docker Hub access token | From Docker Hub |
| `SSH_PRIVATE_KEY` | Base64-encoded SSH private key for VPS access | Generated above |
| `GIT_USER` | Git username | `Titus Owuor` |
| `GIT_EMAIL` | Git email | `titusowuor30@gmail.com` |
| `GITHUB_TOKEN` | GitHub personal access token for repo access | Generated earlier |

**Note:** Organization-level secrets are accessed using `${{ secrets.SECRET_NAME }}` in GitHub Actions workflows, just like repository secrets.

## 3. Contabo API Setup

### 3.1 Create Contabo API Credentials

1. **Login to Contabo Control Panel:**
   - Go to https://my.contabo.com
   - Navigate to Account → Security

2. **Create OAuth2 Client:**
   - Click "Create OAuth2 Client"
   - Note down the `Client ID` and `Client Secret`

3. **API User Credentials:**
   - Use your Contabo username and password
   - These are the same credentials used to login to the control panel

### 3.2 Store API Credentials in GitHub Secrets

Add these organization secrets:

- `CONTABO_CLIENT_ID` - OAuth2 client ID
- `CONTABO_CLIENT_SECRET` - OAuth2 client secret
- `CONTABO_API_USERNAME` - Your Contabo username
- `CONTABO_API_PASSWORD` - Your Contabo password

### 3.3 Test API Access

```bash
# Get OAuth token
curl -X POST https://auth.contabo.com/oauth2/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=password&username=YOUR_USERNAME&password=YOUR_PASSWORD&client_id=CLIENT_ID&client_secret=CLIENT_SECRET&scope=openid"

# List instances (replace ACCESS_TOKEN with actual token)
curl -H "Authorization: Bearer ACCESS_TOKEN" \
  https://api.contabo.com/v1/compute/instances
```

## 4. Kubernetes Access Setup

### 4.1 Get Kubeconfig from Contabo VPS

1. **SSH into your VPS:**
   ```bash
   ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP
   ```

2. **Copy the kubeconfig:**
   ```bash
   # For k3s (default location)
   cat /etc/rancher/k3s/k3s.yaml

   # For kubeadm (default location)
   cat /etc/kubernetes/admin.conf
   ```

3. **Save the kubeconfig content** to a local file (e.g., `kubeconfig.yaml`)

### 4.2 Base64 Encode Kubeconfig

```bash
# Base64 encode for GitHub secret
base64 -w 0 kubeconfig.yaml

# Or without line wrapping
cat kubeconfig.yaml | base64
```

### 4.3 Update Kubeconfig Server URL

**Important:** The kubeconfig contains a local server URL that needs to be updated for external access:

1. **Find the server URL** in the kubeconfig (usually `https://127.0.0.1:6443`)
2. **Replace with your VPS IP:**
   ```bash
   # Edit the kubeconfig file
   sed -i 's/https:\/\/127.0.0.1:6443/https:\/\/YOUR_VPS_IP:6443/g' kubeconfig.yaml
   ```

3. **Re-encode and update GitHub secret:**
   ```bash
   cat kubeconfig.yaml | base64 -w 0
   ```

### 4.4 Test Kubernetes Access

```bash
# Set kubeconfig environment variable
export KUBE_CONFIG="$(cat kubeconfig.yaml | base64 -w 0)"

# Test connection (this should work if properly configured)
echo "$KUBE_CONFIG" | base64 -d > /tmp/test-kubeconfig
export KUBECONFIG=/tmp/test-kubeconfig
kubectl get nodes
```

## 5. Testing the Setup

### 5.1 Test VPS Access

```bash
# Test SSH connection
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP

# Check if Docker is installed and running
docker --version
docker run hello-world

# Check if Kubernetes is installed and running
kubectl get nodes
kubectl get pods -A
```

### 5.2 Test GitHub Token Access

```bash
# Test token has access to devops-k8s repository
curl -H "Authorization: Bearer YOUR_TOKEN" \
  https://api.github.com/repos/Bengo-Hub/devops-k8s

# Should return repository information if token has access
```

### 5.3 Test Contabo API Access

```bash
# Test API token generation
curl -X POST https://auth.contabo.com/oauth2/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=password&username=$CONTABO_API_USERNAME&password=$CONTABO_API_PASSWORD&client_id=$CONTABO_CLIENT_ID&client_secret=$CONTABO_CLIENT_SECRET&scope=openid"

# Test instance access
curl -H "Authorization: Bearer ACCESS_TOKEN" \
  https://api.contabo.com/v1/compute/instances
```

### 5.4 Test Complete Pipeline

1. **Trigger a deployment** in the ERP UI repository
2. **Monitor the GitHub Actions logs** for any authentication errors
3. **Check that:**
   - Docker images are built and pushed
   - Kubernetes secrets are applied
   - Helm values are updated
   - ArgoCD application is refreshed
   - Pods are created in the cluster

## 6. Troubleshooting

### 6.1 GitHub Token Issues

**Problem:** `git@github.com: Permission denied (publickey)`

**Solution:**
- Ensure the `DEVOPS_K8S_ACCESS_TOKEN` secret exists and has the correct value
- Verify the token has `repo` scope enabled
- Check that the token belongs to a user with access to the `Bengo-Hub/devops-k8s` repository

### 6.2 SSH Connection Issues

**Problem:** `ssh: connect to host YOUR_VPS_IP port 22: Connection refused`

**Solutions:**
- Verify the VPS IP address is correct
- Check if the VPS is running and accessible
- Ensure port 22 is open in the VPS firewall
- Verify the SSH key was added correctly to the VPS

### 6.3 Kubernetes Access Issues

**Problem:** `Unable to connect to the server: dial tcp: lookup kubernetes.default.svc`

**Solutions:**
- Ensure the kubeconfig server URL points to the correct VPS IP
- Verify the Kubernetes API server is running on the VPS
- Check that port 6443 is accessible from your location

### 6.4 Contabo API Issues

**Problem:** `401 Unauthorized` when calling Contabo API

**Solutions:**
- Verify API credentials are correct
- Ensure OAuth2 client has proper permissions
- Check that the API user has access to the instance

## 7. Security Best Practices

1. **Rotate tokens regularly** - Set expiration dates and rotate tokens periodically
2. **Use least privilege** - Only grant necessary permissions to tokens
3. **Store secrets securely** - Use GitHub organization secrets instead of repository secrets when possible
4. **Monitor access** - Regularly review GitHub organization audit logs
5. **Disable password auth** - Use only SSH key authentication on VPS
6. **Keep software updated** - Regularly update all systems and dependencies
7. **Standard SSH passphrase** - All project SSH keys use passphrase "codevertex" for consistency

## 8. Maintenance

### 8.1 Update Dependencies
```bash
# Update system packages on VPS
apt-get update && apt-get upgrade -y

# Update k3s (if using k3s)
curl -sfL https://get.k3s.io | sh -
```

### 8.2 Monitor Resource Usage
```bash
# Check VPS resources
htop
df -h
free -h

# Check Kubernetes resources
kubectl top nodes
kubectl top pods -A
```

### 8.3 Backup Important Data
```bash
# Backup Kubernetes resources
kubectl get all --all-namespaces -o yaml > k8s-backup.yaml

# Backup etcd (k3s)
cp /var/lib/rancher/k3s/server/db/state.db /backup/k3s-state.db

# Backup Docker data (if needed)
docker system df
```

## 9. Support

For issues or questions:
- **Email:** codevertexitsolutions@gmail.com
- **Website:** https://www.codevertexitsolutions.com
- **GitHub Issues:** Create issues in the respective repositories
