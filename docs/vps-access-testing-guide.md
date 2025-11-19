# VPS Access Testing Guide for Contabo Deployment

## Overview

This guide provides step-by-step instructions for testing and verifying all access requirements for the BengoERP deployment pipeline on Contabo VPS. It covers SSH access, GitHub authentication, Kubernetes connectivity, and Contabo API access.

## Prerequisites

- Contabo VPS instance with Ubuntu 24.04 LTS
- SSH key pair for VPS access (already discussed in Contabo setup)
- GitHub personal access token with repository permissions
- Kubernetes cluster running on the VPS
- Required tools: `git`, `kubectl`, `ssh`, `curl`

## 1. SSH Access Testing

### 1.1 Test Basic SSH Connection

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

### 1.2 Test SSH with Verbose Output

```bash
# Get detailed connection information
ssh -v -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP

# Look for:
# - Successful key exchange
# - Server authentication
# - Permission denied vs connection refused errors
```

### 1.3 Test SSH Commands Execution

```bash
# Test command execution over SSH
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP "whoami && pwd && ls -la"

# Expected: Shows root user, /root directory, and file listing
```

### 1.4 Verify Required Services

```bash
# Check if essential services are running
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP "
systemctl status docker --no-pager -l
systemctl status kubelet --no-pager -l
kubectl get nodes
"
```

## 2. GitHub Authentication Testing

### 2.1 Test GitHub Token Access

```bash
# Test token has access to devops-k8s repository
curl -H "Authorization: Bearer YOUR_TOKEN" \
  https://api.github.com/repos/Bengo-Hub/devops-k8s

# Should return repository information if token has access
# If fails: Check token has 'repo' scope and access to repository

# Note: GitHub tokens and all other secrets should be stored at the organization level
# in GitHub organization settings, not repository settings.
```

### 2.2 Test Repository Clone

```bash
# Test cloning the devops repository
git clone https://x-access-token:YOUR_GITHUB_TOKEN@github.com/Bengo-Hub/devops-k8s.git /tmp/test-devops

# Expected: Successful clone
# If fails: Check token permissions and repository access
```

### 2.3 Test SSH-based Git Access (if configured)

```bash
# Set up SSH key for git
mkdir -p ~/.ssh
echo "YOUR_GIT_SSH_PRIVATE_KEY" > ~/.ssh/git_key
chmod 600 ~/.ssh/git_key
ssh-keyscan github.com >> ~/.ssh/known_hosts

# Test git clone with SSH
GIT_SSH_COMMAND="ssh -i ~/.ssh/git_key -o StrictHostKeyChecking=no" \
  git clone git@github.com:Bengo-Hub/devops-k8s.git /tmp/test-devops-ssh

# Expected: Successful clone
```

## 3. Kubernetes Access Testing

### 3.1 Test Kubeconfig Validation

```bash
# Decode and validate kubeconfig
echo "YOUR_BASE64_KUBECONFIG" | base64 -d > /tmp/test-kubeconfig
export KUBECONFIG=/tmp/test-kubeconfig

# Test kubeconfig validity
kubectl config view
kubectl config get-contexts
kubectl config current-context
```

### 3.2 Test Cluster Connectivity

```bash
# Test connection to cluster
kubectl cluster-info
kubectl get nodes
kubectl get namespaces

# Expected: Shows cluster information and node status
# If fails: Check kubeconfig server URL points to correct VPS IP
```

### 3.3 Test Namespace and Resource Access

```bash
# Test namespace access
kubectl get pods -n erp
kubectl get secrets -n erp
kubectl get ingress -n erp

# Expected: Lists existing resources or empty results (not errors)
```

### 3.4 Test ArgoCD Access

```bash
# Check ArgoCD applications
kubectl get applications -n argocd
kubectl get application erp-ui -n argocd -o yaml

# Expected: Shows ArgoCD application status
```

## 4. Contabo API Testing

### 4.1 Test API Token Generation

```bash
# Get OAuth token
curl -X POST https://auth.contabo.com/oauth2/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=password&username=YOUR_CONTABO_USERNAME&password=YOUR_CONTABO_PASSWORD&client_id=YOUR_CLIENT_ID&client_secret=YOUR_CLIENT_SECRET&scope=openid"

# Expected: Returns access_token, expires_in, token_type
# Save the access_token for next steps
```

### 4.2 Test Instance Access

```bash
# List instances (replace ACCESS_TOKEN)
curl -H "Authorization: Bearer ACCESS_TOKEN" \
  https://api.contabo.com/v1/compute/instances

# Expected: Returns list of VPS instances with details
```

### 4.3 Test Instance Status

```bash
# Get specific instance details
curl -H "Authorization: Bearer ACCESS_TOKEN" \
  https://api.contabo.com/v1/compute/instances/INSTANCE_ID

# Expected: Returns detailed instance information including status
```

## 5. Complete Pipeline Testing

### 5.1 Test Docker Operations

```bash
# Test Docker connectivity
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP "
docker --version
docker run hello-world
docker login -u codevertex -p YOUR_DOCKER_TOKEN
"
```

### 5.2 Test Registry Access

```bash
# Test image pull from registry
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP "
docker pull codevertex/erp-ui:latest
docker images | grep erp-ui
"
```

### 5.3 Test Kubernetes Secret Application

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

### 5.4 Test ArgoCD Application Refresh

```bash
# Test ArgoCD application refresh
kubectl --kubeconfig=/tmp/test-kubeconfig patch application erp-ui -n argocd \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' --type=merge

# Monitor application status
kubectl --kubeconfig=/tmp/test-kubeconfig get application erp-ui -n argocd -o yaml | grep -A 5 -B 5 "status:"
```

## 6. Troubleshooting Common Issues

### 6.1 SSH Connection Issues

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

### 6.2 GitHub Token Issues

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

### 6.3 Kubernetes Access Issues

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

### 6.4 Contabo API Issues

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

## 7. Automated Testing Script

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

echo "2. Testing Docker..."
ssh -i "$SSH_KEY" root@"$VPS_IP" "docker --version"

echo "3. Testing Kubernetes..."
ssh -i "$SSH_KEY" root@"$VPS_IP" "kubectl get nodes"

echo "4. Testing GitHub access..."
curl -H "Authorization: Bearer $GITHUB_TOKEN" \
  https://api.github.com/repos/Bengo-Hub/devops-k8s > /dev/null && echo "GitHub OK"

echo "5. Testing Kubernetes external access..."
echo "$KUBE_CONFIG" | base64 -d > /tmp/test-kubeconfig
export KUBECONFIG=/tmp/test-kubeconfig
kubectl get nodes > /dev/null && echo "K8s External Access OK"

echo "=== All tests passed! ==="
```

## 8. Maintenance and Monitoring

### 8.1 Regular Access Verification

```bash
# Set up cron job for regular testing
crontab -e
# Add: 0 6 * * * /path/to/vps-access-test.sh
```

### 8.2 Monitor GitHub Token Expiration

```bash
# Check token expiration (if using expiring tokens)
curl -H "Authorization: Bearer YOUR_TOKEN" \
  https://api.github.com/user | jq -r '.created_at'
```

### 8.3 Monitor VPS Resource Usage

```bash
# Check VPS resources regularly
ssh -i ~/.ssh/contabo_deploy_key root@YOUR_VPS_IP "
df -h
free -h
kubectl top nodes
"
```

## 9. Security Considerations

1. **Rotate SSH keys regularly** - Change VPS SSH keys every 90 days
2. **Rotate GitHub tokens** - Set appropriate expiration and rotate regularly
3. **Monitor access logs** - Check SSH and Kubernetes audit logs
4. **Use least privilege** - Ensure tokens only have necessary permissions
5. **Secure kubeconfig** - Store kubeconfig securely and rotate if compromised

## 10. Getting Help

For issues or questions:
- **Email:** codevertexitsolutions@gmail.com
- **Website:** https://www.codevertexitsolutions.com
- **GitHub Issues:** Create issues in the respective repositories

This guide ensures all access components work correctly before deployment, preventing pipeline failures due to authentication or connectivity issues.
