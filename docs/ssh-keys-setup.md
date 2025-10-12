# SSH Keys Setup Guide for BengoERP Deployment

## Overview

This guide explains the different SSH keys used in the BengoERP deployment pipeline and how to set them up correctly. Understanding these keys is crucial for both development workflows and automated deployments.

## SSH Key Types and Purposes

### 1. VPS Access Key (SSH_PRIVATE_KEY)

**Purpose:** Used for accessing your Contabo VPS for deployment operations.

**Usage in workflows:**
- SSH deployment to VPS (when `ssh_deploy: true`)
- Remote command execution on VPS
- Kubernetes cluster access and management

**Key characteristics:**
- Stored as: `SSH_PRIVATE_KEY` (organization secret)
- Used by: `appleboy/ssh-action@v1.2.0` in workflows
- Generated with: `ssh-keygen -t ed25519 -C "devops@codevertex" -f ~/.ssh/contabo_deploy_key -N "codevertex"`

### 2. Docker Build SSH Key (DOCKER_SSH_KEY)

**Purpose:** Used during Docker builds to access private GitHub repositories that contain source code or dependencies.

**Usage in workflows:**
- Docker builds with `--ssh` flag when accessing private repos
- Enables `git clone` operations during container build process
- Falls back to `SSH_PRIVATE_KEY` if `DOCKER_SSH_KEY` is not available

**Key characteristics:**
- Stored as: `DOCKER_SSH_KEY` (organization secret)
- Used by: Docker build process in GitHub Actions
- Same key generation process as VPS access key

### 3. Git Operations SSH Key (GitHub Deploy Keys)

**Purpose:** Used for automated git operations within workflows (git pull, git push, git commit).

**Usage in workflows:**
- Updating Helm values files in the devops-k8s repository
- Committing deployment artifacts
- Automated repository synchronization

**Key characteristics:**
- Uses either `DOCKER_SSH_KEY` or `SSH_PRIVATE_KEY` (workflow handles fallback)
- Configured in workflow step: `Configure SSH for build secrets`

## Architecture Overview

### Centralized vs App-Specific Logic

The BengoERP deployment system uses a **centralized architecture** where:

**Centralized Logic (in `devops-k8s/.github/workflows/reusable-build-deploy.yml`):**
- Docker build process with SSH support
- Trivy security scanning
- Registry operations (login, push)
- Database setup (postgres, redis, mongo, mysql)
- Kubernetes operations and secrets management
- Helm deployment updates
- ArgoCD application refresh
- Service URL discovery

**App-Specific Logic (in individual `build.sh` files):**
- App configuration (name, namespace, secrets)
- App-specific build context and Dockerfile paths
- App-specific deployment validation
- App-specific secrets generation (Django migrations for erp-api)
- Workflow orchestration and parameter passing

### How Build Scripts Work

Each application's `build.sh` script:

1. **Handles app-specific configuration** (namespace, database types, secrets names)
2. **Runs security scans** (Trivy filesystem and image scanning)
3. **Builds Docker images** with SSH support for private repos
4. **Calls the centralized workflow** with app-specific parameters
5. **Provides deployment summary** and service URLs

**Example workflow call from `erp-api/build.sh`:**
```bash
# Call the reusable workflow with app-specific parameters
gh workflow run reusable-build-deploy \
    --ref main \
    --field app_name="${APP_NAME}" \
    --field registry_server="${REGISTRY_SERVER}" \
    --field registry_namespace="${REGISTRY_NAMESPACE}" \
    --field deploy=true \
    --field values_file_path="${VALUES_FILE_PATH}" \
    --field namespace="${NAMESPACE}" \
    --field git_user="${GIT_USER}" \
    --field git_email="${GIT_EMAIL}" \
    --field devops_repo="${DEVOPS_REPO}" \
    --field setup_databases="${SETUP_DATABASES}" \
    --field db_types="${DB_TYPES}" \
    --field env_secret_name="${ENV_SECRET_NAME}" \
    --field provider="${PROVIDER}" \
    --field contabo_api="${CONTABO_API}" \
    --field ssh_deploy="${SSH_DEPLOY}" \
    --field ssh_host="${SSH_HOST:-}" \
    --field ssh_user="${SSH_USER:-}" \
    --field ssh_port="${SSH_PORT:-22}"
```

## SSH Key Setup Process

### Step 1: Generate SSH Key Pair

**Important:** All SSH keys in this project use the passphrase `"codevertex"` for consistency in automated deployments.

```bash
# Generate SSH key pair for both VPS access and Docker builds
ssh-keygen -t ed25519 -C "devops@codevertex" -f ~/.ssh/contabo_deploy_key -N "codevertex"
```

This creates:
- `~/.ssh/contabo_deploy_key` (private key)
- `~/.ssh/contabo_deploy_key.pub` (public key)

### Step 2: Add Public Key to Contabo VPS

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

### Step 3: Add Public Key to GitHub (for Docker builds)

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

### Step 4: Store Private Keys in GitHub Secrets

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

## How SSH Keys Work in Workflows

### Docker Build Process

When a workflow runs with `DOCKER_SSH_KEY` configured:

1. **SSH Agent Setup:** The workflow configures an SSH agent with your private key
2. **Git Operations:** Docker can clone private repositories during build
3. **Key Security:** Keys are loaded into memory only during the build process

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

### **SSH Configuration (RECOMMENDED FINAL SOLUTION)**

#### Step 1: Generate SSH Key Pair on VPS
Run these commands on your VPS (erp-k8s-prod):

```bash
# Generate SSH key pair (ED25519 recommended)
ssh-keygen -t ed25519 -C "vps-git-access@bengoerp" -f ~/.ssh/git_deploy_key -N ""

# Set proper permissions
chmod 600 ~/.ssh/git_deploy_key
chmod 644 ~/.ssh/git_deploy_key.pub

# Display the public key (you'll need this for GitHub)
cat ~/.ssh/git_deploy_key.pub
```
 A. configure ssh agent
 ```bash
 # Start SSH agent
eval "$(ssh-agent -s)"

# Add your SSH key to the agent
ssh-add ~/.ssh/git_deploy_key

# Verify the key is loaded
ssh-add -l

# Set SSH_AUTH_SOCK for git operations
echo "SSH_AUTH_SOCK=$SSH_AUTH_SOCK" >> ~/.bashrc
```

B. Configure Git to Use SSH Key
```bash
# Configure git to use SSH (not HTTPS)
git config --global url."git@github.com:".insteadOf "https://github.com/"

# Test SSH connection again
ssh -T git@github.com

# Try git operations with explicit SSH key
GIT_SSH_COMMAND="ssh -i ~/.ssh/git_deploy_key -o IdentitiesOnly=yes" git clone git@github.com:Bengo-Hub/devops-k8s.git /devops-repo
```

#### Step 2: Add Public Key to GitHub
Copy the public key output from the command above
Go to your GitHub repository → Settings → Deploy keys
Click "Add deploy key"
Paste the public key you copied
Title: VPS Git Access
Check "Allow write access" (needed for workflows that push changes)
Click "Add key"

#### Step 3: Configure SSH for Git Operations
On your VPS, set up SSH to use the new key for GitHub:
```bash
# Add GitHub to known hosts
ssh-keyscan github.com >> ~/.ssh/known_hosts

# Test SSH connection
ssh -T -i ~/.ssh/git_deploy_key git@github.com

# Test git clone
git clone git@github.com:Bengo-Hub/devops-k8s.git /devops-repo
```

#### Step 4: Create SSH Config File

The most reliable approach is to create an SSH config file that ensures git operations always use the correct SSH key:

```bash
# Create SSH config file (RECOMMENDED APPROACH)
cat > ~/.ssh/config << 'EOF'
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/git_deploy_key
    IdentitiesOnly yes
    StrictHostKeyChecking no
EOF
chmod 600 ~/.ssh/config
```

**What this config does:**
- **IdentityFile**: Specifies which SSH key to use
- **IdentitiesOnly yes**: Forces SSH to only use the specified key (prevents conflicts)
- **StrictHostKeyChecking no**: Automatically accepts GitHub's host key

### **Git Operations in Workflows**

Git operations in GitHub Actions workflows use this SSH configuration. The workflow ensures:

1. **SSH keys are loaded** from GitHub secrets (`DOCKER_SSH_KEY` or `SSH_PRIVATE_KEY`)
2. **SSH config file is created** with the correct settings
3. **Git operations use SSH** by default when keys are available
4. **Fallback to tokens** when SSH keys aren't configured

**Workflow SSH Setup Process:**
```yaml
# Example from reusable-build-deploy.yml
- name: Update values in devops-k8s
  run: |
    # Create SSH config for reliable git operations
    cat > ~/.ssh/config << 'EOF'
    Host github.com
        HostName github.com
        User git
        IdentitiesOnly yes
        StrictHostKeyChecking no
        IdentityFile ~/.ssh/id_rsa
    EOF
    
    git pull --rebase
    git push
```

**Troubleshooting Git Operations:**
- Verify `DOCKER_SSH_KEY` or `SSH_PRIVATE_KEY` secrets are properly base64-encoded
- Ensure the public key is added as a deploy key to the target repository
- Check that "Allow write access" is enabled for push operations
- The workflow will show "🔑 Using SSH for git operations" if SSH is configured correctly
- **Final Solution:** SSH config file ensures reliable git operations with `IdentitiesOnly=yes`

```yaml
# Example from reusable-build-deploy.yml
- name: Update values in devops-k8s
  run: |
    git config user.name "DevOps Bot"
    git config user.email "devops@bot.local"
    git pull --rebase
    # ... make changes ...
    git add .
    git commit -m "Update deployment"
    git push
```

The SSH keys configured earlier enable these git operations to work with private repositories.

## Testing SSH Key Setup

### Test VPS Access

```bash
# Test SSH connection
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP

# Test Docker and Kubernetes
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP "
  docker --version
  kubectl get nodes
"
```

### Test GitHub SSH Access

```bash
# Test git clone with SSH
git clone git@github.com:your-org/private-repo.git /tmp/test-repo
```

### Test Complete Workflow

1. **Trigger a deployment** in your application repository
2. **Monitor GitHub Actions logs** for SSH-related errors
3. **Verify:**
   - Docker builds complete successfully
   - Git operations (pull/push) work
   - SSH deployment to VPS succeeds

## Troubleshooting

### SSH Connection Issues

**Problem:** `Permission denied (publickey)`

**Solutions:**
- Verify public key is correctly added to VPS authorized_keys
- Check SSH service is running: `systemctl status ssh`
- Ensure correct permissions: `chmod 600 ~/.ssh/authorized_keys`

**Problem:** `ssh: connect to host YOUR_VPS_IP port 22: Connection refused`

**Solutions:**
- Verify VPS IP address is correct
- Check VPS is running and accessible
- Ensure port 22 is open in VPS firewall

### Docker Build SSH Issues

**Problem:** `git@github.com: Permission denied (publickey)` during Docker build

**Solutions:**
- Verify `DOCKER_SSH_KEY` secret is correctly configured
- Check deploy key is added to the private repository
- Ensure "Allow write access" is enabled if workflow needs to push

### Git Operations Failures

**Problem:** `git pull` or `git push` fails in workflows

**Solutions:**
- Verify SSH keys are properly loaded in workflow
- Check repository access permissions
- Ensure SSH agent is running: `echo "SSH_AUTH_SOCK=$SSH_AUTH_SOCK"`

## Security Best Practices

1. **Use Ed25519 keys** (stronger than RSA)
2. **Rotate SSH keys regularly** (every 90 days)
3. **Use different keys** for different purposes when possible
4. **Disable password authentication** on VPS
5. **Monitor SSH access logs** regularly
6. **Use organization-level secrets** for consistency

## Key Takeaways

- **DOCKER_SSH_KEY** and **SSH_PRIVATE_KEY** can be the same key for simplicity
- Both keys use the same passphrase (`"codevertex"`) for automation
- SSH keys enable git@github.com access in workflows
- Proper SSH key setup is essential for both development and deployment workflows
- Regular key rotation and monitoring are important security practices

For additional support:
- **Email:** codevertexitsolutions@gmail.com
- **Website:** https://www.codevertexitsolutions.com
