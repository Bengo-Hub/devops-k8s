Pipelines
---------

This repo provides multiple deployment approaches for different use cases:

## 1. Application-Specific Deployment (Recommended)

For applications that need full control over their deployment process, use the **deploy.yml approach** where each application manages its own build and deployment logic through build.sh scripts.

### Features
- **Self-contained**: Each application controls its complete build and deployment process
- **Highly flexible**: Easy to customize per application requirements
- **Comprehensive logging**: Detailed colored output and error handling
- **Security scanning**: Built-in Trivy filesystem and image scanning
- **Multi-environment support**: Configurable for different deployment scenarios
- **Database automation**: Automatic setup and configuration
- **Kubernetes integration**: Direct management of K8s resources and Helm charts

### Setup Requirements
Each application needs:
- `.github/workflows/deploy.yml` - GitHub Actions workflow that calls build.sh
- `build.sh` - Complete deployment script with all phases
- `kubeSecrets/devENV.yaml` - Kubernetes secrets configuration

### Example Application Structure
```
your-app/
├── .github/workflows/
│   └── deploy.yml             # Calls build.sh script
├── build.sh                   # Complete deployment logic
├── kubeSecrets/
│   └── devENV.yaml            # Dynamic secrets (no hardcoded values)
└── Dockerfile
```

### Deployment Flow
1. **Build Phase**: Security scanning, Docker build with SSH support, container vulnerability scanning
2. **Deploy Phase**: Registry authentication, image push, database setup, K8s secrets, Helm updates
3. **Post-Deploy**: Database migrations (for applicable apps)

### Example Workflow Structure
```yaml
# .github/workflows/deploy.yml
name: Build and Deploy MyApp

on:
  push:
    branches: [ main, master ]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
    - name: Checkout code
      uses: actions/checkout@v4

    - name: Set up Docker Buildx
      uses: docker/setup-buildx-action@v3

    - name: Install DevOps Tools
      uses: Bengo-Hub/devops-k8s/.github/actions/install-devops-tools@main

    - name: Run deployment script
      env:
        # All deployment parameters passed to build.sh
        DEPLOY: true
        SETUP_DATABASES: true
        # ... other environment variables
      run: |
        chmod +x build.sh
        ./build.sh
```

### Build Script Features (build.sh)
The build.sh script handles the complete deployment process:

#### Core Phases
- **Prerequisites Check**: Validates required tools (git, docker, kubectl, helm, etc.)
- **Security Scanning**: Trivy filesystem and container image scanning
- **Docker Build**: SSH-aware container building with fallback support
- **Registry Operations**: Authentication and image push to container registry
- **Database Setup**: Automatic PostgreSQL and Redis installation via Helm
- **Kubernetes Integration**: Namespace creation, secret management, JWT configuration
- **Helm Updates**: Values file updates in devops-k8s repository
- **Database Migrations**: Django migration job execution
- **Deployment Summary**: Comprehensive status reporting

#### Environment Variables
| Variable | Purpose | Default |
|----------|---------|---------|
| `DEPLOY` | Enable/disable deployment phase | `true` |
| `SETUP_DATABASES` | Enable/disable database setup | `true` (API), `false` (UI) |
| `DB_TYPES` | Comma-separated database list | `postgres,redis` |
| `NAMESPACE` | Kubernetes namespace | `erp` |
| `ENV_SECRET_NAME` | Kubernetes secret name | `app-env` |
| `REGISTRY_SERVER` | Container registry | `docker.io` |
| `REGISTRY_NAMESPACE` | Registry namespace | `codevertex` |

### For Centralized Reusable Workflow

See the reusable workflow inputs documented in the workflow definition.

## Security Best Practices

### Dynamic Secret Generation
- **Application approach**: Secrets are managed through GitHub repository secrets
- **devENV.yaml**: Use placeholder values like `__DYNAMIC_PASSWORD__` that get replaced during deployment
- **Never commit**: Hardcoded secrets to version control

### Secret Management
- Store sensitive values in GitHub repository secrets
- Use different secrets for different environments
- Rotate secrets regularly
- Use strong, randomly generated passwords

## Migration Guide

### Current Architecture (build.sh-based)

The current recommended approach uses build.sh scripts that contain all deployment logic:

1. **deploy.yml**: Simple workflow that calls build.sh with environment variables
2. **build.sh**: Complete deployment script handling all phases
3. **Environment variables**: Configuration passed from deploy.yml to build.sh
4. **GitHub secrets**: Sensitive data stored securely in repository secrets

### Benefits of Current Approach
- ✅ **Simplified**: Single script handles complete deployment
- ✅ **Self-contained**: All logic in one place per application
- ✅ **Easy debugging**: Clear execution flow and error reporting
- ✅ **Flexible**: Easy to modify per application needs
- ✅ **GitHub-native**: Full integration with Actions environment

### Troubleshooting

#### Common Issues
- **YQ Syntax**: Ensure using `yq eval` with `-i` flag for in-place editing
- **SSH Keys**: Verify SSH key passphrase is "codevertex" for automated deployments
- **Kubeconfig**: Base64 encoded kubeconfig should be valid and current
- **Git Access**: SSH keys must have write access to devops-k8s repository

#### Debug Mode
Add `set -x` at the top of build.sh for detailed execution tracing:
```bash
#!/usr/bin/env bash
set -x  # Enable debug mode
# ... rest of script
```
