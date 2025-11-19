# Comprehensive Access Setup Guide for BengoERP Deployment Pipeline

## Overview

This guide provides step-by-step instructions for setting up all required access permissions and authentication methods needed for the BengoERP deployment pipeline to work successfully. It includes SSH key setup, GitHub authentication, Contabo API configuration, Kubernetes access, and comprehensive testing procedures.

## Related Documentation

**Next Steps (After Access Setup):**
- **[Cluster Setup Workflow](./CLUSTER-SETUP-WORKFLOW.md)** ⚙️ - Complete automated cluster setup guide
- **[Kubernetes Setup Guide](./contabo-setup-kubeadm.md)** 📘 - Detailed Kubernetes cluster setup
- **[GitHub Secrets Guide](./github-secrets.md)** 🔐 - Complete secrets documentation

---

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

For the ERP UI repository (`bengobox-erp-ui`), add these repository secrets:

- `DEVOPS_K8S_ACCESS_TOKEN` - The PAT created above
- `DOCKER_SSH_KEY` - Base64-encoded SSH private key for Docker builds (optional)
- `KUBE_CONFIG` - Base64-encoded kubeconfig for Kubernetes access
- `REGISTRY_USERNAME` - Docker Hub username (`codevertex`)
- `GIT_USER` - Your git username (`Titus Owuor`)
- `GIT_EMAIL` - Your git email (`titusowuor30@gmail.com`)

---

## 2. SSH Keys Setup

### 2.1 SSH Key Types and Purposes

The deployment pipeline uses three types of SSH keys:

**1. VPS Access Key (SSH_PRIVATE_KEY)**
- **Purpose:** Used for accessing your Contabo VPS for deployment operations
- **Usage:** SSH deployment to VPS, remote command execution, Kubernetes cluster access
- **Stored as:** `SSH_PRIVATE_KEY` (organization secret)

**2. Docker Build SSH Key (DOCKER_SSH_KEY)**
- **Purpose:** Used during Docker builds to access private GitHub repositories
- **Usage:** Docker builds with `--ssh` flag, enables `git clone` during container build
- **Stored as:** `DOCKER_SSH_KEY` (organization secret)
- **Fallback:** Uses `SSH_PRIVATE_KEY` if `DOCKER_SSH_KEY` is not available

**3. Git Operations SSH Key**
- **Purpose:** Used for automated git operations (git pull, git push, git commit)
- **Usage:** Updating Helm values files, committing deployment artifacts
- **Uses:** Either `DOCKER_SSH_KEY` or `SSH_PRIVATE_KEY` (workflow handles fallback)

**Note:** The same SSH key can be used for all three purposes for simplicity.

### 2.2 Generate SSH Key Pair

**Important:** All SSH keys in this project use the passphrase `"codevertex"` for consistency in automated deployments.

```bash
# Generate SSH key pair for both VPS access and Docker builds
ssh-keygen -t ed25519 -C "devops@codevertex" -f ~/.ssh/contabo_deploy_key -N "codevertex"
```

This creates:
- `~/.ssh/contabo_deploy_key` (private key)
- `~/.ssh/contabo_deploy_key.pub` (public key)

**Why Ed25519?** Ed25519 keys are more secure and faster than RSA keys, and are recommended for modern deployments.

### 2.3 Add Public Key to Contabo VPS

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

### 2.4 Add Public Key to GitHub (for Docker builds)

If you need to access private repositories during Docker builds:

1. **Copy the public key:**
   ```bash
   cat ~/.ssh/contabo_deploy_key.pub
   ```

2. **Add to GitHub repository:**
   - Go to your private repository → Settings → Deploy keys
   - Click "Add deploy key"
   - Paste the public key content
   - Check "Allow write access" if the workflow needs to push changes

### 2.5 Store Private Keys in GitHub Secrets

**Important:** Store all secrets at the **organization level** for consistency across repositories.

#### Base64 Encode Private Keys

```bash
# For SSH_PRIVATE_KEY (VPS access)
cat ~/.ssh/contabo_deploy_key | base64 -w 0

# For DOCKER_SSH_KEY (Docker builds) - same key
cat ~/.ssh/contabo_deploy_key | base64 -w 0
```

#### Add Organization Secrets

Go to GitHub organization → Settings → Secrets and variables → Actions

Add these secrets:

| Secret Name | Description | Value |
|-------------|-------------|-------|
| `SSH_PRIVATE_KEY` | SSH private key for VPS access | Base64-encoded private key |
| `DOCKER_SSH_KEY` | SSH private key for Docker builds | Base64-encoded private key (same as above) |

### 2.6 How SSH Keys Work in Workflows

#### Docker Build Process

When a workflow runs with `DOCKER_SSH_KEY` configured:

1. **SSH Agent Setup:** The workflow configures an SSH agent with your private key
2. **Git Operations:** Docker can clone private repositories during build
3. **Key Security:** Keys are loaded into memory only during the build process

**Workflow SSH Setup Process:**
```yaml
# Example from reusable-build-deploy.yml
- name: Configure SSH for build secrets (optional)
  env:
    DOCKER_SSH_KEY_B64: ${{ secrets.DOCKER_SSH_KEY }}
  run: |
    if [ -n "${DOCKER_SSH_KEY_B64:-}" ]; then
      echo "Loading DOCKER_SSH_KEY"
      echo "$DOCKER_SSH_KEY_B64" | base64 -d > $HOME/.ssh/id_rsa
      chmod 0600 $HOME/.ssh/id_rsa
      ssh-keyscan github.com >> $HOME/.ssh/known_hosts
      eval "$(ssh-agent)"
      ssh-add $HOME/.ssh/id_rsa
      export SSH_AUTH_SOCK=$(ssh-agent -s)
      cat > ~/.ssh/config << 'EOF'
      Host github.com
          HostName github.com
          User git
          IdentityFile ~/.ssh/id_rsa
          IdentitiesOnly yes
          StrictHostKeyChecking no
      EOF
      chmod 600 ~/.ssh/config
      git config --global core.sshCommand "ssh -o IdentitiesOnly=yes"
    fi
```

#### Git Operations in Workflows

Git operations use SSH keys for git pull/push operations. The workflow ensures:
1. SSH keys are loaded from GitHub secrets (`DOCKER_SSH_KEY` or `SSH_PRIVATE_KEY`)
2. SSH config file is created with correct settings
3. Git operations use SSH by default when keys are available
4. Fallback to tokens when SSH keys aren't configured

---

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
- `CONTABO_INSTANCE_ID` - Your VPS instance ID (optional, defaults to `14285715`)

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

---

## 4. Kubernetes Access Setup

### 4.1 Get Kubeconfig from Contabo VPS

1. **SSH into your VPS:**
   ```bash
   ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP
   ```

2. **Copy the kubeconfig:**
   ```bash
   # Get kubeconfig from default location
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

### 4.4 Store Kubeconfig in GitHub Secrets

Add as organization secret:

- `KUBE_CONFIG` - Base64-encoded kubeconfig for Kubernetes access

---

## 5. Testing and Verification

### 5.1 SSH Access Testing

#### Test Basic SSH Connection

```bash
# Test SSH connection using the private key
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP

# Expected output: Successful login to VPS
# If this fails, check:
# 1. VPS IP address is correct
# 2. SSH key is properly added to VPS authorized_keys
# 3. SSH service is running on VPS
# 4. Port 22 is open in VPS firewall
```

#### Test SSH with Verbose Output

```bash
# Get detailed connection information
ssh -v -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP

# Look for:
# - Successful key exchange
# - Server authentication
# - Permission denied vs connection refused errors
```

#### Test SSH Commands Execution

```bash
# Test command execution over SSH
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP "whoami && pwd && ls -la"

# Expected: Shows root user, /root directory, and file listing
```

#### Verify Required Services

```bash
# Check if essential services are running
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP "
systemctl status kubelet --no-pager -l
kubectl get nodes
"
```

### 5.2 GitHub Authentication Testing

#### Test GitHub Token Access

```bash
# Test token has access to devops-k8s repository
curl -H "Authorization: Bearer YOUR_TOKEN" \
  https://api.github.com/repos/Bengo-Hub/devops-k8s

# Should return repository information if token has access
# If fails: Check token has 'repo' scope and access to repository

# Note: GitHub tokens and all other secrets should be stored at the organization level
# in GitHub organization settings, not repository settings.
```

#### Test Repository Clone

```bash
# Test cloning the devops repository
git clone https://x-access-token:YOUR_GITHUB_TOKEN@github.com/Bengo-Hub/devops-k8s.git /tmp/test-devops

# Expected: Successful clone
# If fails: Check token permissions and repository access
```

#### Test SSH-based Git Access

```bash
# Set up SSH key for git
mkdir -p ~/.ssh
echo "YOUR_GIT_SSH_PRIVATE_KEY" | base64 -d > ~/.ssh/git_key
chmod 600 ~/.ssh/git_key
ssh-keyscan github.com >> ~/.ssh/known_hosts

# Test git clone with SSH
GIT_SSH_COMMAND="ssh -i ~/.ssh/git_key -o StrictHostKeyChecking=no" \
  git clone git@github.com:Bengo-Hub/devops-k8s.git /tmp/test-devops-ssh

# Expected: Successful clone
```

### 5.3 Kubernetes Access Testing

#### Test Kubeconfig Validation

```bash
# Decode and validate kubeconfig
echo "YOUR_BASE64_KUBECONFIG" | base64 -d > /tmp/test-kubeconfig
export KUBECONFIG=/tmp/test-kubeconfig

# Test kubeconfig validity
kubectl config view
kubectl config get-contexts
kubectl config current-context
```

#### Test Cluster Connectivity

```bash
# Test connection to cluster
kubectl cluster-info
kubectl get nodes
kubectl get namespaces

# Expected: Shows cluster information and node status
# If fails: Check kubeconfig server URL points to correct VPS IP
```

#### Test Namespace and Resource Access

```bash
# Test namespace access
kubectl get pods -n erp
kubectl get secrets -n erp
kubectl get ingress -n erp

# Expected: Lists existing resources or empty results (not errors)
```

#### Test ArgoCD Access

```bash
# Check ArgoCD applications
kubectl get applications -n argocd
kubectl get application erp-ui -n argocd -o yaml

# Expected: Shows ArgoCD application status
```

### 5.4 Contabo API Testing

#### Test API Token Generation

```bash
# Get OAuth token
curl -X POST https://auth.contabo.com/oauth2/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=password&username=YOUR_CONTABO_USERNAME&password=YOUR_CONTABO_PASSWORD&client_id=YOUR_CLIENT_ID&client_secret=YOUR_CLIENT_SECRET&scope=openid"

# Expected: Returns access_token, expires_in, token_type
# Save the access_token for next steps
```

#### Test Instance Access

```bash
# List instances (replace ACCESS_TOKEN)
curl -H "Authorization: Bearer ACCESS_TOKEN" \
  https://api.contabo.com/v1/compute/instances

# Expected: Returns list of VPS instances with details
```

#### Test Instance Status

```bash
# Get specific instance details
curl -H "Authorization: Bearer ACCESS_TOKEN" \
  https://api.contabo.com/v1/compute/instances/INSTANCE_ID

# Expected: Returns detailed instance information including status
```

### 5.5 Complete Pipeline Testing

#### Test Docker Operations

```bash
# Test Docker connectivity
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP "
docker --version
docker run hello-world
docker login -u codevertex -p YOUR_DOCKER_TOKEN
"
```

#### Test Registry Access

```bash
# Test image pull from registry
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP "
docker pull codevertex/erp-ui:latest
docker images | grep erp-ui
"
```

#### Test Kubernetes Secret Application

```bash
# Test applying secrets (if KUBE_CONFIG is set)
export KUBE_CONFIG="YOUR_BASE64_KUBECONFIG"
echo "$KUBE_CONFIG" | base64 -d > /tmp/test-kubeconfig

# Apply test secret
kubectl --kubeconfig=/tmp/test-kubeconfig apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: test-secret
  namespace: erp
type: Opaque
data:
  test-key: dGVzdC12YWx1ZQ==
EOF

# Verify secret was created
kubectl --kubeconfig=/tmp/test-kubeconfig get secret test-secret -n erp
```

#### Test Complete Pipeline

1. **Trigger a deployment** in the ERP UI repository
2. **Monitor the GitHub Actions logs** for any authentication errors
3. **Check that:**
   - Docker images are built and pushed
   - Kubernetes secrets are applied
   - Helm values are updated
   - ArgoCD application is refreshed
   - Pods are created in the cluster

---

## 6. Troubleshooting

### 6.1 Git Operations Issues

**Problem:** `git@github.com: Permission denied (publickey)` during git pull/push operations

**Root Cause:** The workflow uses SSH keys for git operations (git pull, git push, git commit), not tokens.

**Solutions:**
- **Verify SSH keys are properly configured** in GitHub secrets (`DOCKER_SSH_KEY` or `SSH_PRIVATE_KEY`)
- **Ensure SSH agent is running** - the workflow sets `SSH_AUTH_SOCK` environment variable
- **Check SSH key format** - must be base64-encoded private key without passphrase or with passphrase `codevertex`
- **Verify public key is added** to the repository as a deploy key (for private repos during Docker builds)

**Workflow SSH Setup Process:**
1. SSH keys are loaded from secrets
2. SSH agent is started with `eval "$(ssh-agent)"`
3. Keys are added with `ssh-add`
4. `SSH_AUTH_SOCK` is exported for use in git operations

**Debug SSH Setup:**
```bash
echo "SSH_AUTH_SOCK=", $SSH_AUTH_SOCK
ssh-add -l
```

**Alternative:** Use `DEVOPS_K8S_ACCESS_TOKEN` for workflows that don't require SSH key access.

### 6.2 SSH Connection Issues

**Problem:** `ssh: connect to host YOUR_VPS_IP port 22: Connection refused`

**Solutions:**
```bash
# Check if VPS is reachable
ping YOUR_VPS_IP

# Check if SSH service is running on VPS
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP "systemctl status ssh"

# Check firewall settings
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP "ufw status"

# Check SSH configuration
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP "ss -tuln | grep :22"
```

### 6.3 GitHub Token Issues

**Problem:** `git@github.com: Permission denied (publickey)` or `401 Unauthorized`

**Solutions:**
```bash
# Test token validity
curl -H "Authorization: Bearer YOUR_TOKEN" \
  https://api.github.com/user

# Check token scopes
curl -H "Authorization: Bearer YOUR_TOKEN" \
  https://api.github.com/repos/Bengo-Hub/devops-k8s

# Verify repository access
curl -H "Authorization: Bearer YOUR_TOKEN" \
  https://api.github.com/repos/Bengo-Hub/devops-k8s/contents/apps/erp-ui
```

### 6.4 Kubernetes Access Issues

**Problem:** `Unable to connect to the server` or `dial tcp: lookup kubernetes.default.svc`

**Solutions:**
```bash
# Check kubeconfig server URL
kubectl config view | grep server

# Test direct API server access
curl -k https://YOUR_VPS_IP:6443/healthz

# Check if API server is running
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP "systemctl status kubelet"

# Check kubelet status
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP "systemctl status kubelet"
```

### 6.5 Contabo API Issues

**Problem:** `401 Unauthorized` or `403 Forbidden`

**Solutions:**
```bash
# Test token generation with verbose output
curl -v -X POST https://auth.contabo.com/oauth2/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=password&username=YOUR_USERNAME&password=YOUR_PASSWORD&client_id=YOUR_CLIENT_ID&client_secret=YOUR_CLIENT_SECRET&scope=openid"

# Check API credentials in Contabo control panel
# Verify OAuth2 client has correct permissions
# Ensure API user has access to the instance
```

---

## 7. Security Best Practices

1. **Rotate tokens regularly** - Set expiration dates and rotate tokens periodically
2. **Use least privilege** - Only grant necessary permissions to tokens
3. **Store secrets securely** - Use GitHub organization secrets instead of repository secrets when possible
4. **Monitor access** - Regularly review GitHub organization audit logs
5. **Disable password auth** - Use only SSH key authentication on VPS
6. **Keep software updated** - Regularly update all systems and dependencies
7. **Standard SSH passphrase** - All project SSH keys use passphrase "codevertex" for consistency
8. **Use Ed25519 keys** - Stronger than RSA, recommended for modern deployments
9. **Rotate SSH keys regularly** - Change VPS SSH keys every 90 days
10. **Monitor access logs** - Check SSH and Kubernetes audit logs regularly

---

## 8. Next Steps After Access Setup

Once all access is configured (SSH keys, GitHub PAT/token, Contabo API):

### Automated Cluster Setup

Run the orchestrated cluster setup script:

```bash
# On your VPS (via SSH)
cd /path/to/devops-k8s
chmod +x scripts/cluster/*.sh
./scripts/cluster/setup-cluster.sh
```

This will automatically:
- Set up initial VPS configuration
- Install containerd
- Install Kubernetes cluster
- Configure Calico CNI
- Set up etcd auto-compaction
- Generate kubeconfig for GitHub secrets

### After Cluster Setup

1. Copy the base64 kubeconfig output from the script
2. Add it as GitHub organization secret: `KUBE_CONFIG`
3. Run the provisioning workflow to install infrastructure

**See:** `docs/contabo-setup-kubeadm.md` for complete cluster setup guide

---

## 9. Automated Testing Script

Create a comprehensive testing script for regular validation:

```bash
#!/bin/bash
# VPS Access Test Script

set -e

# Configuration
VPS_IP="YOUR_VPS_IP"
SSH_KEY="~/.ssh/contabo_deploy_key"
GITHUB_TOKEN="YOUR_GITHUB_TOKEN"
KUBE_CONFIG="YOUR_BASE64_KUBECONFIG"

echo "=== VPS Access Test ==="
echo "1. Testing SSH access..."
ssh -i "$SSH_KEY" root@"$VPS_IP" "echo 'SSH OK'"

echo "2. Testing Kubernetes..."
ssh -i "$SSH_KEY" root@"$VPS_IP" "kubectl get nodes"

echo "3. Testing GitHub access..."
curl -H "Authorization: Bearer $GITHUB_TOKEN" \
  https://api.github.com/repos/Bengo-Hub/devops-k8s > /dev/null && echo "GitHub OK"

echo "4. Testing Kubernetes external access..."
echo "$KUBE_CONFIG" | base64 -d > /tmp/test-kubeconfig
export KUBECONFIG=/tmp/test-kubeconfig
kubectl get nodes > /dev/null && echo "K8s External Access OK"

echo "=== All tests passed! ==="
```

---

## 10. Support

For issues or questions:
- **Email:** codevertexitsolutions@gmail.com
- **Website:** https://www.codevertexitsolutions.com
- **GitHub Issues:** Create issues in the respective repositories
